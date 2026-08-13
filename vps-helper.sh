#!/usr/bin/env bash
# VPS 综合运维助手 V10（精简稳定版）
# 设计原则：诊断优先、备份优先、最小改动、所有网络优化可回滚。

set -Eeuo pipefail
IFS=$'\n\t'

readonly VERSION="10.0-stable"
readonly LOG_FILE="/var/log/vps-helper.log"
readonly BACKUP_ROOT="/root/backup/vps-helper"
DRY_RUN=0
ASSUME_YES=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; RESET='\033[0m'

usage() { printf '用法: %s [--dry-run] [--yes]\n' "$0"; }
die() { printf '%b\n' "${RED}错误：$*${RESET}" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
log() {
    local msg="$*"
    printf '%b\n' "$msg"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '[%s] %b\n' "$(date '+%F %T')" "$msg" >>"$LOG_FILE" 2>/dev/null || true
}
run() {
    if ((DRY_RUN)); then log "${BLUE}[dry-run]${RESET} $*"; return 0; fi
    log "${BLUE}[执行]${RESET} $*"; "$@"
}
confirm() {
    ((ASSUME_YES)) && return 0
    local answer; read -r -p "$1 [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}
timestamp() { date '+%Y%m%d-%H%M%S'; }
backup_dir() { local d="$BACKUP_ROOT/$(timestamp)"; mkdir -p "$d"; printf '%s' "$d"; }

check_root() { ((EUID == 0)) || die '请使用 root 运行。'; }
parse_args() {
    while (($#)); do
        case "$1" in
            --dry-run) DRY_RUN=1;; --yes|-y) ASSUME_YES=1;; -h|--help) usage; exit 0;;
            *) usage; die "未知参数：$1";;
        esac; shift
    done
}

apt_install() {
    has apt-get || { log "${YELLOW}非 Debian/Ubuntu 系统，跳过 APT。${RESET}"; return 0; }
    if has lsof; then
        local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
        if lsof "${locks[@]}" >/dev/null 2>&1; then log "${YELLOW}APT 锁被占用，未强制删除。${RESET}"; return 1; fi
    fi
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

system_status() {
    log "${BLUE}========== 系统状态 ==========${RESET}"
    printf '主机：%s\n系统：%s\n内核：%s\n时间：%s\n' "$(hostname)" "$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-unknown}")" "$(uname -r)" "$(date)"
    uptime; free -h; df -hT /; printf '\n监听端口：\n'; ss -lntup 2>/dev/null | sed -n '1,100p'
    printf '\nTCP：\n'; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_ecn net.ipv4.tcp_mtu_probing 2>/dev/null || true
}

backup_tcp() {
    local d; d=$(backup_dir)
    sysctl -a 2>/dev/null | grep -E '^(net\.(ipv4\.tcp|core\.default_qdisc|core\.rmem|core\.wmem))' >"$d/sysctl-tcp.txt" || true
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc >"$d/current.txt" 2>&1 || true
    tc qdisc show >"$d/qdisc.txt" 2>&1 || true
    cp -a /etc/sysctl.conf "$d/sysctl.conf" 2>/dev/null || true
    cp -a /etc/sysctl.d "$d/sysctl.d" 2>/dev/null || true
    log "${GREEN}TCP 配置已备份：$d${RESET}"
}

tcp_diagnose() {
    local d; d=$(backup_dir)
    {
        echo "date=$(date -Is)"; uname -a
        echo '== sysctl =='; sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc net.ipv4.tcp_ecn net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen net.ipv4.tcp_slow_start_after_idle
        echo '== qdisc =='; tc qdisc show
        echo '== link =='; ip -s link
        echo '== sockets =='; ss -s
        echo '== route =='; ip route
    } | tee "$d/tcp-diagnostic.txt"
    log "${GREEN}诊断已保存：$d/tcp-diagnostic.txt${RESET}"
}

tcp_safe_profile() {
    log "仅应用经过验证的保守档：BBR + FQ；不改 ECN、MTU、缓冲区。"
    backup_tcp
    confirm '确认应用保守 TCP 档？' || return 0
    run sysctl -w net.core.default_qdisc=fq
    run sysctl -w net.ipv4.tcp_congestion_control=bbr
    run sysctl --system >/dev/null
    log "${GREEN}已应用。请重新测试后再决定是否回滚。${RESET}"
}

tcp_restore() {
    local d; read -r -p "输入备份目录（完整路径）： " d
    [[ -d "$d" ]] || { log "${RED}备份目录不存在。${RESET}"; return 1; }
    confirm "确认从 $d 恢复 sysctl 配置？" || return 0
    [[ -f "$d/sysctl.conf" ]] && run cp -a "$d/sysctl.conf" /etc/sysctl.conf
    [[ -d "$d/sysctl.d" ]] && run cp -a "$d/sysctl.d/." /etc/sysctl.d/
    run sysctl --system >/dev/null
    log "${GREEN}已恢复 sysctl；qdisc 仅按当前内核状态保留。${RESET}"
}

firewall_status() {
    printf '%s\n' '== IPv4 =='; iptables -S 2>/dev/null || true
    printf '%s\n' '== IPv6 =='; ip6tables -S 2>/dev/null || true
    printf '%s\n' '== Fail2Ban =='; systemctl is-active fail2ban 2>/dev/null || true; fail2ban-client status sshd 2>/dev/null || true
}

firewall_harden() {
    apt_install fail2ban iptables-persistent || true
    local d; d=$(backup_dir); iptables-save >"$d/iptables.v4" 2>/dev/null || true; ip6tables-save >"$d/iptables.v6" 2>/dev/null || true
    confirm '确认设置保守防火墙（SSH/443/8443/ICMP）？' || return 0
    cat >/etc/fail2ban/jail.d/vps-helper.local <<'EOF'
[sshd]
enabled = true
backend = systemd
port = 22
maxretry = 5
findtime = 10m
bantime = 2h
banaction = iptables-multiport
EOF
    run systemctl enable --now fail2ban
    # x-ui 可能维护自己的封禁链；确保它位于 INPUT 最前面，避免被后续规则绕过。
    if iptables -S INPUT 2>/dev/null | grep -q -- '-A INPUT -p tcp -j xui-block-chain'; then
        iptables -D INPUT -p tcp -j xui-block-chain 2>/dev/null || true
        run iptables -I INPUT 1 -p tcp -j xui-block-chain
    fi
    # 只在规则尚未存在时添加，避免重复叠加。
    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || run iptables -I INPUT 1 -i lo -j ACCEPT
    iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || run iptables -I INPUT 2 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -C INPUT -p tcp -m multiport --dports 22,443,8443 -j ACCEPT 2>/dev/null || run iptables -I INPUT 3 -p tcp -m multiport --dports 22,443,8443 -j ACCEPT
    iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || run iptables -I INPUT 4 -p icmp -j ACCEPT
    run iptables -P INPUT DROP
    ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || run ip6tables -I INPUT 1 -i lo -j ACCEPT
    ip6tables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || run ip6tables -I INPUT 2 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -C INPUT -p tcp -m multiport --dports 22,443,8443 -j ACCEPT 2>/dev/null || run ip6tables -I INPUT 3 -p tcp -m multiport --dports 22,443,8443 -j ACCEPT
    ip6tables -C INPUT -p ipv6-icmp -j ACCEPT 2>/dev/null || run ip6tables -I INPUT 4 -p ipv6-icmp -j ACCEPT
    run ip6tables -P INPUT DROP
    run sh -c 'iptables-save > /etc/iptables/rules.v4'
    run sh -c 'ip6tables-save > /etc/iptables/rules.v6'
    log "${GREEN}防火墙已加固，备份：$d${RESET}"
}

iperf_menu() {
    apt_install iperf3 || true
    echo '1. 启动临时服务（5201）'; echo '2. 停止服务'; echo '3. 查看服务状态'
    local n; read -r -p '请选择 [1-3]： ' n
    case "$n" in
        1) run iperf3 -s -D -p 5201; log '请在测试完成后选择 2；5201 不会自动加入防火墙。';;
        2) pkill -x iperf3 2>/dev/null || true; log 'iperf3 已停止。';;
        3) pgrep -a iperf3 || log 'iperf3 未运行。';;
        *) log '无效选择。';;
    esac
}

network_check() {
    log "${BLUE}========== 网络质量 ==========${RESET}"
    ip route get 1.1.1.1 2>/dev/null || true
    for host in 1.1.1.1 8.8.8.8; do
        if has ping; then ping -4 -c 10 -W 2 "$host" || true; fi
    done
    if has curl; then curl -4 -L --max-time 10 -o /dev/null -sS -w 'Cloudflare: %{http_code} %{speed_download} bytes/s\n' https://speed.cloudflare.com/__down?bytes=10000000 || true; fi
}

security_audit() {
    log "${BLUE}========== 安全体检 ==========${RESET}"
    firewall_status
    printf '\n最近 SSH 失败：\n'; journalctl -u ssh --since '24 hours ago' --no-pager 2>/dev/null | grep -E 'Failed password|Invalid user' | tail -30 || true
    printf '\nSSH 配置：\n'; sshd -T 2>/dev/null | grep -Ei 'permitrootlogin|passwordauthentication|maxauthtries|maxstartups' || true
}

swap_menu() {
    free -h; swapon --show
    echo '1. 创建/重建 SWAP'; echo '2. 删除 /swapfile'; local n size; read -r -p '请选择 [1-2]： ' n
    case "$n" in
        1) read -r -p '大小 MB： ' size; [[ "$size" =~ ^[0-9]+$ && "$size" -ge 256 ]] || { log '大小无效。'; return; }; confirm "创建 ${size}MB SWAP？" || return; swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; run fallocate -l "${size}M" /swapfile; run chmod 600 /swapfile; run mkswap /swapfile; run swapon /swapfile; sed -i '\|/swapfile|d' /etc/fstab; echo '/swapfile none swap sw 0 0' >>/etc/fstab;;
        2) confirm '确认删除 /swapfile？' || return; swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; sed -i '\|/swapfile|d' /etc/fstab;;
        *) log '无效选择。';;
    esac
}

menu() {
    while :; do
        clear 2>/dev/null || true
        printf '%b\n' "${BLUE}VPS 综合运维助手 V${VERSION}${RESET}"
        printf '%s\n' '1. 系统状态/端口' '2. 安全体检/Fail2Ban' '3. 防火墙加固' '4. SWAP 管理' '5. 网络质量检测' '6. iperf3 临时服务' '7. TCP 诊断/备份' '8. 应用保守 TCP 档' '9. TCP 配置回滚' '0. 退出'
        local n; read -r -p '请选择 [0-9]： ' n || exit 0
        case "$n" in
            1) system_status;; 2) security_audit;; 3) firewall_harden;; 4) swap_menu;; 5) network_check;; 6) iperf_menu;; 7) backup_tcp; tcp_diagnose;; 8) tcp_safe_profile;; 9) tcp_restore;; 0) exit 0;; *) log '无效选择。';;
        esac
        read -r -p '按回车继续...' _ || true
    done
}

main() { parse_args "$@"; check_root; menu; }
main "$@"
