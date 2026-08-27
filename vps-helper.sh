#!/usr/bin/env bash
# =========================================================
# VPS 综合运维助手 (V9.5 TCP智能调优版)
# 重点改动：
#  - 默认写操作日志到 /var/log/vps-helper.log
#  - 远程脚本执行前下载到本地并显示 SHA256
#  - x-ui 固定使用 FranzKafkaYu/x-ui，安装/更新前自动备份数据库和核心配置
#  - 证书申请自动安装到 /root/cert/<domain>/，并同步到 x-ui 证书目录
#  - acme.sh 安装前自动安装 cron/curl/socat
#  - Fail2Ban 改用 jail.d/vps-helper.local，不覆盖 jail.local
#  - 80 端口释放不再默认 kill 非 systemd 进程
#  - 增加系统体检、端口查看辅助
#  - 增加网络质量检测、AI/流媒体解锁、测速、安全体检、tcpfit 调优
#  - 增加 TCP 智能调优/回滚，根据 BBR、缓冲、重传、443 连接状态给出建议
#  - 借鉴 netshape：增加 qdisc/限速诊断、fq 单连接限速实验
#  - 增加 iperf3 结果判读，根据上下行/重传/官方限速推荐调优档
#  - 增加本地网络画像记录/对比，区分家宽/公司/手机网络测试结果
#  - 增加 IPQuality 原生 IP / 流媒体解锁检测独立入口
# =========================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

DRY_RUN=0
NON_INTERACTIVE=0
ASSUME_YES=0
LOG_FILE="/var/log/vps-helper.log"

trap 'echo -e "\033[0;31m❌ 脚本在第 $LINENO 行出错\033[0m" >&2' ERR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        *)
            echo -e "${RED}未知参数：$1${PLAIN}"
            echo "用法: $0 [--dry-run] [--non-interactive] [--yes]"
            exit 1
            ;;
    esac
    shift
done

[[ ${EUID:-999} -ne 0 ]] && echo -e "${RED}错误：请使用 root 用户运行！${PLAIN}" && exit 1

if (( BASH_VERSINFO[0] < 4 )); then
    echo -e "${RED}错误：此脚本需要 Bash 4.0 及以上版本（Debian/Ubuntu 默认满足）。${PLAIN}" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" 2>/dev/null || true

log() {
    local msg="$*"
    echo -e "$msg"
    printf '[%s] %b\n' "$(date '+%F %T')" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        log "${BLUE}[dry-run]${PLAIN} $*"
        return 0
    fi
    log "${BLUE}[run]${PLAIN} $*"
    "$@"
}

confirm_action() {
    local prompt="$1"
    if [[ $ASSUME_YES -eq 1 || $NON_INTERACTIVE -eq 1 ]]; then
        return 0
    fi
    read -r -p "${prompt} [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

calc_sha256() {
    local file="$1"
    if has_cmd sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif has_cmd shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        return 1
    fi
}

download_file() {
    local url="$1"
    local out="$2"
    if has_cmd curl; then
        run_cmd curl -fsSL "$url" -o "$out"
    elif has_cmd wget; then
        run_cmd wget -qO "$out" "$url"
    else
        log "${RED}未检测到 curl/wget，无法下载：${url}${PLAIN}"
        return 1
    fi
}

run_remote_script() {
    local name="$1"
    local url="$2"
    local interpreter="$3"
    local expected_sha="${4:-}"
    local tmp sha

    if [[ $DRY_RUN -eq 1 ]]; then
        log "${BLUE}[dry-run]${PLAIN} 将下载并执行远程脚本: ${name}"
        log "${BLUE}[dry-run]${PLAIN} URL: ${url}"
        log "${BLUE}[dry-run]${PLAIN} 解释器: ${interpreter}"
        return 0
    fi

    tmp=$(mktemp "/tmp/${name}.XXXXXX")
    log "${YELLOW}下载远程脚本：${name}${PLAIN}"
    download_file "$url" "$tmp" || { rm -f "$tmp"; return 1; }

    if sha=$(calc_sha256 "$tmp" 2>/dev/null); then
        log "${BLUE}${name} SHA256:${PLAIN} ${sha}"
        if [[ -n "$expected_sha" && "$sha" != "$expected_sha" ]]; then
            log "${RED}SHA256 校验失败，已中止执行。${PLAIN}"
            rm -f "$tmp"
            return 1
        fi
        [[ -z "$expected_sha" ]] && log "${YELLOW}未配置预期 SHA256，仅展示摘要。建议后续补充固定哈希。${PLAIN}"
    else
        log "${YELLOW}系统无 sha256sum/shasum，跳过摘要校验。${PLAIN}"
    fi

    if ! confirm_action "确认执行 ${name} 吗？"; then
        log "${YELLOW}已取消执行 ${name}${PLAIN}"
        rm -f "$tmp"
        return 0
    fi

    chmod +x "$tmp" 2>/dev/null || true
    local rc=0
    run_cmd "$interpreter" "$tmp" || rc=$?
    rm -f "$tmp"
    return $rc
}

unlock_apt() {
    has_cmd apt || return 0
    [[ $DRY_RUN -eq 1 ]] && { log "${BLUE}[dry-run]${PLAIN} 跳过 APT 解锁实际操作"; return 0; }

    systemctl stop unattended-upgrades 2>/dev/null || true

    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
    if has_cmd lsof; then
        if lsof "${locks[@]}" >/dev/null 2>&1; then
            log "${YELLOW}检测到 apt/dpkg 锁正在被占用：${PLAIN}"
            lsof "${locks[@]}" 2>/dev/null || true
            log "${YELLOW}等待 5 秒后重试...${PLAIN}"
            sleep 5
        fi
        if lsof "${locks[@]}" >/dev/null 2>&1; then
            log "${RED}锁仍被进程占用，未强制删除。请先结束占用进程后再试。${PLAIN}"
            return 1
        fi
        rm -f "${locks[@]}"
    elif has_cmd fuser; then
        if fuser "${locks[@]}" >/dev/null 2>&1; then
            log "${RED}检测到 apt/dpkg 锁正在被占用，未删除锁文件。${PLAIN}"
            fuser "${locks[@]}" 2>/dev/null || true
            return 1
        fi
        rm -f "${locks[@]}"
    else
        log "${YELLOW}未检测到 lsof/fuser，跳过删除 APT 锁文件以避免误伤。${PLAIN}"
    fi
    dpkg --configure -a >/dev/null 2>&1 || true
}

ensure_packages() {
    unlock_apt || true
    export DEBIAN_FRONTEND=noninteractive
    run_cmd apt-get update -y
    run_cmd apt-get install -y "$@"
}

backup_xui() {
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过 x-ui 备份写入"
        return 0
    fi
    local ts dir
    ts=$(date +%Y%m%d-%H%M%S)
    dir="/root/backup/x-ui-${ts}"
    mkdir -p "$dir"

    [[ -f /etc/x-ui/x-ui.db ]] && cp -a /etc/x-ui/x-ui.db "$dir/x-ui.db"
    [[ -f /usr/local/x-ui/bin/config.json ]] && cp -a /usr/local/x-ui/bin/config.json "$dir/config.json"
    [[ -f /usr/local/x-ui/bin/xray-linux-amd64 ]] && cp -a /usr/local/x-ui/bin/xray-linux-amd64 "$dir/xray-linux-amd64"
    [[ -d /root/cert ]] && tar -czf "$dir/cert.tgz" -C /root cert 2>/dev/null || true

    log "${GREEN}✅ x-ui 相关文件已备份到：${dir}${PLAIN}"
}

get_status_display() {
    local out=""
    declare -A svc_status
    for svc in nps x-ui komari docker fail2ban; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            svc_status["$svc"]=1
        else
            svc_status["$svc"]=0
        fi
    done

    [[ -f "/usr/bin/nps" || -f "/usr/local/bin/nps" ]] && [[ ${svc_status["nps"]} -eq 1 ]] && out+=" ${GREEN}●${PLAIN} nps    "
    [[ -f "/usr/local/x-ui/x-ui" ]] && [[ ${svc_status["x-ui"]} -eq 1 ]] && out+=" ${GREEN}●${PLAIN} x-ui    "
    [[ -d "/etc/komari" || -f "/usr/bin/komari" ]] && pgrep -x "komari" >/dev/null 2>&1 && out+=" ${GREEN}●${PLAIN} komari    "
    [[ ${svc_status["docker"]} -eq 1 ]] && out+=" ${GREEN}●${PLAIN} docker    "
    [[ ${svc_status["fail2ban"]} -eq 1 ]] && out+=" ${GREEN}●${PLAIN} fail2ban    "

    echo -e "${out:-${YELLOW}未发现活跃服务${PLAIN}}"
}

system_check() {
    clear 2>/dev/null || true
    log "${BLUE}================ 系统体检 ================${PLAIN}"
    log "主机名: $(hostname)"
    log "系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || uname -a)"
    log "内核: $(uname -r)"
    log "时间: $(date)"
    log ""
    log "${YELLOW}CPU/内存/磁盘:${PLAIN}"
    uptime || true
    free -h || true
    df -hT / || true
    log ""
    log "${YELLOW}网络地址:${PLAIN}"
    ip -brief addr show scope global 2>/dev/null || true
    log ""
    log "${YELLOW}BBR 状态:${PLAIN}"
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
    log ""
    log "${YELLOW}监听端口:${PLAIN}"
    ss -lntup 2>/dev/null | sed -n '1,120p' || true
    log "${BLUE}==========================================${PLAIN}"
}

manage_swap() {
    log "${YELLOW}--- SWAP 虚拟内存管理 ---${PLAIN}"
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过 SWAP 创建/删除及 /etc/fstab 写入"
        return 0
    fi
    echo "1. 添加/修改 SWAP"
    echo "2. 删除 SWAP"
    read -r -p "请选择 [1-2]: " sw_num

    if [[ "$sw_num" == "1" ]]; then
        read -r -p "请输入 SWAP 大小 (MB): " sw_size
        [[ -z "${sw_size}" || ! "${sw_size}" =~ ^[0-9]+$ ]] && log "${RED}请输入有效数字（MB）${PLAIN}" && return

        local disk_free
        disk_free=$(df / | tail -1 | awk '{print $4}')
        [[ $sw_size -gt $((disk_free / 1024)) ]] && log "${RED}磁盘空间不足，无法创建 SWAP${PLAIN}" && return

        [[ -f /swapfile ]] && (swapoff /swapfile || true; rm -f /swapfile)
        run_cmd dd if=/dev/zero of=/swapfile bs=1M count="$sw_size" status=progress
        run_cmd chmod 600 /swapfile
        run_cmd mkswap /swapfile
        run_cmd swapon /swapfile
        sed -i '/\/swapfile/d' /etc/fstab
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "${GREEN}✅ SWAP 设置成功${PLAIN}"
    elif [[ "$sw_num" == "2" ]]; then
        swapoff /swapfile || true
        rm -f /swapfile
        sed -i '/\/swapfile/d' /etc/fstab
        log "${GREEN}✅ SWAP 已卸载并删除${PLAIN}"
    else
        log "${RED}无效选择${PLAIN}"
    fi
}

smart_fix_fail2ban() {
    log "${YELLOW}同步分类防御监狱...${PLAIN}"
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过 Fail2Ban 配置文件写入和服务重启"
        return 0
    fi
    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d /usr/local/x-ui /var/log

    local ssh_log="/var/log/auth.log"
    [[ -f /var/log/secure ]] && ssh_log="/var/log/secure"
    touch "$ssh_log"
    touch /usr/local/x-ui/access.log /var/log/nps.log /var/log/komari.log

    [[ -f /etc/fail2ban/jail.local ]] && cp -a /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak.$(date +%F_%H%M%S)"
    [[ -f /etc/fail2ban/jail.d/vps-helper.local ]] && cp -a /etc/fail2ban/jail.d/vps-helper.local "/etc/fail2ban/jail.d/vps-helper.local.bak.$(date +%F_%H%M%S)"

    cat > /etc/fail2ban/filter.d/x-ui.conf <<'EOF'
[Definition]
failregex = .*Login error.*IP: <HOST>
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/nps.conf <<'EOF'
[Definition]
failregex = .*login error.*from <HOST>
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/komari.conf <<'EOF'
[Definition]
failregex = .*auth failed.*from <HOST>
ignoreregex =
EOF

    local c_ip=""
    [[ -n "${SSH_CLIENT:-}" ]] && c_ip=${SSH_CLIENT%% *}

    cat > /etc/fail2ban/jail.d/vps-helper.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${c_ip:-}
bantime  = 1d
findtime = 10m
maxretry = 5
backend  = polling

[sshd]
enabled = true
port    = ssh
logpath = ${ssh_log}

[x-ui]
enabled = true
port    = 1-65535
filter  = x-ui
logpath = /usr/local/x-ui/access.log

[nps]
enabled = true
port    = 1-65535
filter  = nps
logpath = /var/log/nps.log

[komari]
enabled = true
port    = 1-65535
filter  = komari
logpath = /var/log/komari.log
EOF

    systemctl restart fail2ban || true
    systemctl enable fail2ban >/dev/null 2>&1 || true
    log "${GREEN}✅ 分类监狱加固已同步：/etc/fail2ban/jail.d/vps-helper.local${PLAIN}"
}

view_security_report() {
    clear 2>/dev/null || true
    if ! has_cmd fail2ban-client; then
        log "${YELLOW}未检测到 fail2ban-client，尝试安装 fail2ban...${PLAIN}"
        ensure_packages fail2ban || true
    fi
    has_cmd geoiplookup || ensure_packages geoip-bin || true
    fail2ban-client ping >/dev/null 2>&1 || smart_fix_fail2ban

    log "${BLUE}======================================${PLAIN}"
    log "          🛡️ Fail2Ban 分类防御战报       "
    log "${BLUE}======================================${PLAIN}"

    local jails
    jails=$(fail2ban-client status 2>/dev/null | awk -F':' '/Jail list/ {print $2}' | tr ',' ' ' | xargs || true)
    [[ -z "${jails}" ]] && { log "${YELLOW}未获取到 Jail 列表。${PLAIN}"; return; }

    local j ip loc ips
    for j in $jails; do
        echo -e "${YELLOW}[监狱: $j]${PLAIN}"
        ips=$(fail2ban-client status "$j" 2>/dev/null | awk -F':' '/Banned IP list/ {print $2}' | xargs || true)
        if [[ -z "${ips// /}" ]]; then
            echo "  └─ 🟢 暂无封禁"
        else
            for ip in $ips; do
                loc=$(geoiplookup "$ip" 2>/dev/null | awk -F': ' '{print $2}' | cut -d',' -f1 || true)
                echo -e "  └─ ${RED}$ip${PLAIN} [${GREEN}${loc:-??}${PLAIN}]"
            done
        fi
        echo ""
    done
}

PORT80_STOPPED_UNITS=()

port80_in_use() {
    if has_cmd ss; then
        ss -ltn '( sport = :80 )' 2>/dev/null | awk 'NR>1{found=1} END{exit(found?0:1)}'
        return $?
    fi
    has_cmd lsof && lsof -iTCP:80 -sTCP:LISTEN -nP >/dev/null 2>&1
}

release_port80_temporarily() {
    PORT80_STOPPED_UNITS=()
    ! port80_in_use && return 0

    log "${YELLOW}检测到 80 端口被占用，尝试临时停止 systemd 服务...${PLAIN}"
    ss -ltnp '( sport = :80 )' 2>/dev/null || true

    local proc_names name unit
    proc_names=$(ss -ltnp '( sport = :80 )' 2>/dev/null | awk -F'"' '/users:\(\("/{for(i=2;i<=NF;i+=2) print $i}' | sort -u | xargs || true)
    for name in $proc_names; do
        for unit in "${name}.service" "$name"; do
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                log "${YELLOW}停止服务: ${unit}${PLAIN}"
                run_cmd systemctl stop "$unit" || true
                PORT80_STOPPED_UNITS+=("$unit")
                break
            fi
        done
    done

    if port80_in_use; then
        log "${RED}80 端口仍被占用。为安全起见，脚本不会自动 kill 非 systemd 进程。${PLAIN}"
        log "${YELLOW}请手动处理后重试，或改用 DNS 验证。${PLAIN}"
        return 1
    fi

    log "${GREEN}✅ 80 端口已临时释放${PLAIN}"
}

restore_port80_after_renew() {
    local unit
    for unit in "${PORT80_STOPPED_UNITS[@]}"; do
        log "${YELLOW}恢复服务: ${unit}${PLAIN}"
        run_cmd systemctl start "$unit" || true
    done
    PORT80_STOPPED_UNITS=()
}

ensure_acme() {
    if [[ ! -x /root/.acme.sh/acme.sh && ! -x ~/.acme.sh/acme.sh ]]; then
        ensure_packages cron curl socat
        if (( DRY_RUN )); then
            log "${BLUE}[dry-run]${PLAIN} 跳过 cron 启用"
        else
            systemctl enable --now cron >/dev/null 2>&1 || true
        fi
        run_remote_script "acme_install" "https://get.acme.sh" "sh"
    fi
    if [[ -x /root/.acme.sh/acme.sh ]]; then
        ACME="/root/.acme.sh/acme.sh"
    elif [[ -x ~/.acme.sh/acme.sh ]]; then
        ACME="$HOME/.acme.sh/acme.sh"
    else
        log "${RED}acme.sh 安装失败。${PLAIN}"
        return 1
    fi
    "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

acme_managed_domains() {
    local acme_home="${ACME%/*}"
    local d base
    for d in "$acme_home"/*_ecc "$acme_home"/*; do
        [[ -d "$d" ]] || continue
        base="${d##*/}"
        if [[ "$base" == *_ecc ]]; then
            base="${base%_ecc}"
        fi
        [[ -n "$base" && "$base" != "ca" && "$base" != "deploy" && "$base" != "notify" ]] || continue
        [[ -f "$d/${base}.cer" || -f "$d/${base}.key" ]] || continue
        printf '%s\n' "$base"
    done | sort -u
}

manage_acme_certificate() {
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过证书申请/续期、证书目录及 x-ui 路径写入"
        return 0
    fi
    ensure_acme || return

    local selected_domain renewal_mode=0 acme_ecc=1
    local -a managed_domains=()
    mapfile -t managed_domains < <(acme_managed_domains)

    if ((${#managed_domains[@]} > 0)); then
        log "${GREEN}已扫描到 acme.sh 域名：${PLAIN}"
        if ((${#managed_domains[@]} == 1)); then
            selected_domain="${managed_domains[0]}"
            log "自动选择：${selected_domain}"
        else
            local i choice
            for i in "${!managed_domains[@]}"; do
                printf '%s. %s\n' "$((i + 1))" "${managed_domains[$i]}"
            done
            read -r -p "选择要续期的域名 [1-${#managed_domains[@]}]: " choice
            [[ "$choice" =~ ^[0-9]+$ ]] || { log "${RED}选择无效${PLAIN}"; return; }
            ((choice >= 1 && choice <= ${#managed_domains[@]})) || { log "${RED}选择无效${PLAIN}"; return; }
            selected_domain="${managed_domains[$((choice - 1))]}"
        fi
        renewal_mode=1
        [[ -d "${ACME%/*}/${selected_domain}_ecc" ]] && acme_ecc=1 || acme_ecc=0
    else
        read -r -p "未扫描到已管理域名，请输入新域名: " selected_domain
        [[ -z "$selected_domain" ]] && { log "${RED}域名不能为空${PLAIN}"; return; }
        acme_ecc=1
    fi

    release_port80_temporarily || return
    local acme_ok=0
    if ((renewal_mode)); then
        if ((acme_ecc)); then
            "$ACME" --renew -d "$selected_domain" --ecc && acme_ok=1 || true
        else
            "$ACME" --renew -d "$selected_domain" && acme_ok=1 || true
        fi
    else
        "$ACME" --issue -d "$selected_domain" --standalone -k ec-256 && acme_ok=1 || true
    fi
    restore_port80_after_renew

    if [[ "$acme_ok" -ne 1 ]]; then
        log "${RED}证书申请失败：${selected_domain}${PLAIN}"
        log "${YELLOW}请确认域名解析到本机，安全组/防火墙放行 80。${PLAIN}"
        return
    fi

    local cert_dir="/root/cert/${selected_domain}"
    mkdir -p "$cert_dir"
    local -a install_args=(--install-cert -d "$selected_domain")
    ((acme_ecc)) && install_args+=(--ecc)
    install_args+=(
        --fullchain-file "${cert_dir}/fullchain.pem"
        --key-file "${cert_dir}/privkey.pem"
    )
    "$ACME" "${install_args[@]}"

    log "${GREEN}✅ 证书已安装：${selected_domain}${PLAIN}"
    log "证书文件路径: ${cert_dir}/fullchain.pem"
    log "密钥文件路径: ${cert_dir}/privkey.pem"

    # x-ui 通常安装在 /usr/local/x-ui；用软链接保持续期后的证书自动同步。
    # 若当前机器尚未安装 x-ui，则只保留 /root/cert 下的证书。
    local xui_root=""
    if [[ -d /usr/local/x-ui ]]; then
        xui_root="/usr/local/x-ui"
    elif [[ -d /etc/x-ui ]]; then
        xui_root="/etc/x-ui"
    fi
    if [[ -n "$xui_root" ]]; then
        local xui_cert_dir="${xui_root}/cert/${selected_domain}"
        mkdir -p "$xui_cert_dir"
        ln -sfn "${cert_dir}/fullchain.pem" "${xui_cert_dir}/fullchain.pem"
        ln -sfn "${cert_dir}/privkey.pem" "${xui_cert_dir}/privkey.pem"
        chmod 700 "$xui_cert_dir" 2>/dev/null || true
        log "${GREEN}✅ 已同步到 x-ui 证书目录（自动跟随续期）${PLAIN}"
        log "x-ui 证书路径: ${xui_cert_dir}/fullchain.pem"
        log "x-ui 密钥路径: ${xui_cert_dir}/privkey.pem"
        log "在 x-ui 中填入上述两条路径即可。"
    else
        log "${YELLOW}未发现 x-ui 目录，跳过同步；安装 x-ui 后可重新执行本项。${PLAIN}"
    fi
}

install_or_update_xui() {
    log "${YELLOW}--- 安装/更新 x-ui 面板 ---${PLAIN}"
    local url="https://raw.githubusercontent.com/FranzKafkaYu/x-ui/master/install.sh"
    log "安装源：FranzKafkaYu/x-ui"
    backup_xui
    run_remote_script "x-ui_install" "$url" "bash"
}

generate_reality_link_helper() {
    log "${YELLOW}--- Reality 节点链接辅助 ---${PLAIN}"
    if [[ ! -x /usr/local/x-ui/bin/xray-linux-amd64 ]]; then
        log "${RED}未发现 Xray 核心。${PLAIN}"
        return
    fi
    log "${BLUE}生成 X25519 密钥：${PLAIN}"
    /usr/local/x-ui/bin/xray-linux-amd64 x25519 || true
    log ""
    log "${YELLOW}提示：创建 Reality 入站时推荐：443 + tcp + reality + xtls-rprx-vision。${PLAIN}"
    log "常用 SNI: www.cloudflare.com / www.apple.com / www.speedtest.cn"
}

network_quality_check() {
    clear 2>/dev/null || true
    log "${BLUE}================ 网络质量检测 ================${PLAIN}"
    log "${YELLOW}公网 IP:${PLAIN}"
    curl -4 --connect-timeout 8 -sS https://ip.sb || true
    echo ""
    curl -6 --connect-timeout 8 -sS https://ip.sb || true
    echo ""

    log "${YELLOW}IP 归属信息:${PLAIN}"
    curl -4 --connect-timeout 8 -sS https://ipinfo.io || true
    echo ""

    log "${YELLOW}IPv4/IPv6 连通性:${PLAIN}"
    ping -4 -c 4 -W 2 1.1.1.1 || true
    ping -4 -c 4 -W 2 223.5.5.5 || true
    ping -6 -c 4 -W 2 2606:4700:4700::1111 || true

    log "${YELLOW}TCP 443 连接测试:${PLAIN}"
    curl -4 -I --connect-timeout 8 https://www.cloudflare.com/ 2>&1 | sed -n '1,12p' || true
    curl -6 -I --connect-timeout 8 https://www.cloudflare.com/ 2>&1 | sed -n '1,12p' || true

    if has_cmd mtr; then
        log "${YELLOW}MTR 到 1.1.1.1 简测:${PLAIN}"
        mtr -rwzc 20 1.1.1.1 || true
    else
        log "${YELLOW}未安装 mtr，可执行环境初始化后再测。${PLAIN}"
    fi
    log "${BLUE}==============================================${PLAIN}"
}

unlock_media_ai_check() {
    log "${YELLOW}--- 流媒体 / AI 解锁检测 ---${PLAIN}"
    echo "1. RegionRestrictionCheck"
    echo "2. lmc999 RegionRestrictionCheck"
    echo "3. OpenAI 专项可达性简测"
    read -r -p "请选择 [1-3]: " n
    case "$n" in
        1) run_remote_script "unlock_media_check" "https://raw.githubusercontent.com/RegionRestrictionCheck/check/main/check.sh" "bash" ;;
        2) run_remote_script "unlock_media_check_lmc999" "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh" "bash" ;;
        3)
            log "${YELLOW}OpenAI / AI 服务简测:${PLAIN}"
            curl -4 -I --connect-timeout 10 https://chat.openai.com/ 2>&1 | sed -n '1,20p' || true
            curl -4 -I --connect-timeout 10 https://api.openai.com/ 2>&1 | sed -n '1,20p' || true
            curl -4 -I --connect-timeout 10 https://claude.ai/ 2>&1 | sed -n '1,20p' || true
            curl -4 -I --connect-timeout 10 https://gemini.google.com/ 2>&1 | sed -n '1,20p' || true
            ;;
        *) log "${RED}无效选择${PLAIN}" ;;
    esac
}

ip_quality_media_check() {
    log "${YELLOW}--- IP 质量 / 原生 IP / 流媒体解锁检测 ---${PLAIN}"
    log "检测来源：https://IP.Check.Place（IPQuality）"
    log "脚本会自动检测 IPv4/IPv6、IP 类型、风险、流媒体及 AI 服务。"
    run_remote_script "ip_quality_check" "https://IP.Check.Place" "bash"
}

tcpfit_tune() {
    log "${YELLOW}--- tcpfit TCP 调优 ---${PLAIN}"
    log "调优来源：https://github.com/Kylin010/tcpfit"
    log "执行前会下载脚本并显示 SHA256，确认后才运行。"
    run_remote_script "tcpfit" "https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh" "bash"
}

speedtest_menu() {
    log "${YELLOW}--- Speedtest / iperf3 测速 ---${PLAIN}"
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过 speedtest/iperf3 启停操作"
        return 0
    fi
    echo "1. 启动 iperf3 服务端"
    echo "2. 停止 iperf3 服务端"
    echo "3. 查看 iperf3 状态"
    echo "4. 执行 speedtest-go 一键测速脚本"
    read -r -p "请选择 [1-4]: " n
    case "$n" in
        1)
            has_cmd iperf3 || ensure_packages iperf3
            iperf3 -s -D || true
            log "${GREEN}✅ iperf3 server 已后台运行：iperf3 -c <服务器IP>${PLAIN}"
            ;;
        2)
            pkill -x iperf3 2>/dev/null || true
            log "${GREEN}✅ 已尝试停止 iperf3${PLAIN}"
            ;;
        3)
            pgrep -a iperf3 || log "${YELLOW}iperf3 未运行${PLAIN}"
            ss -lntup | grep ':5201' || true
            ;;
        4)
            run_remote_script "speedtest_script" "https://raw.githubusercontent.com/i-abc/Speedtest/main/speedtest.sh" "bash"
            ;;
        *) log "${RED}无效选择${PLAIN}" ;;
    esac
}

security_audit() {
    clear 2>/dev/null || true
    log "${BLUE}================ VPS 安全体检 ================${PLAIN}"
    log "${YELLOW}SSH 配置:${PLAIN}"
    if [[ -f /etc/ssh/sshd_config ]]; then
        grep -Ei '^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)' /etc/ssh/sshd_config || true
    fi

    log "${YELLOW}SSH 监听:${PLAIN}"
    ss -lntup | grep -E ':(22|2222)\b' || true

    log "${YELLOW}最近登录:${PLAIN}"
    last -a | head -n 12 || true

    log "${YELLOW}失败登录统计:${PLAIN}"
    local ssh_log="/var/log/auth.log"
    [[ -f /var/log/secure ]] && ssh_log="/var/log/secure"
    if [[ -f "$ssh_log" ]]; then
        grep -Ei 'Failed password|Invalid user|authentication failure' "$ssh_log" | tail -n 30 || true
    else
        log "${YELLOW}未找到 SSH 日志。${PLAIN}"
    fi

    log "${YELLOW}防火墙状态:${PLAIN}"
    has_cmd ufw && ufw status verbose || true
    has_cmd nft && nft list ruleset 2>/dev/null | sed -n '1,120p' || true
    has_cmd iptables && iptables -S 2>/dev/null | sed -n '1,120p' || true

    log "${YELLOW}关键服务:${PLAIN}"
    systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true
    systemctl is-active fail2ban 2>/dev/null || true
    systemctl is-active x-ui 2>/dev/null || true

    log "${BLUE}==============================================${PLAIN}"
}

generate_subscription_files() {
    log "${YELLOW}--- 自建订阅文件生成 ---${PLAIN}"
    local sub_dir="/var/www/sub"
    mkdir -p "$sub_dir"
    local raw_file="${sub_dir}/nodes.txt"
    local clash_file="${sub_dir}/clash.yaml"

    log "请输入节点链接，每行一个。输入空行结束："
    : > "$raw_file"
    local line
    while true; do
        read -r line
        [[ -z "$line" ]] && break
        echo "$line" >> "$raw_file"
    done

    python3 - "$raw_file" "$clash_file" <<'PY'
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote
import sys
raw=Path(sys.argv[1])
out=Path(sys.argv[2])
nodes=[x.strip() for x in raw.read_text().splitlines() if x.strip()]
lines=["proxies:"]
names=[]
for i,u in enumerate(nodes,1):
    p=urlparse(u)
    if p.scheme != "vless":
        continue
    qs=parse_qs(p.query)
    name=unquote(p.fragment or f"node-{i}")
    names.append(name)
    uuid=p.username
    server=p.hostname
    port=p.port or 443
    sni=(qs.get("sni") or qs.get("servername") or [""])[0]
    pbk=(qs.get("pbk") or [""])[0]
    sid=(qs.get("sid") or [""])[0]
    fp=(qs.get("fp") or ["chrome"])[0]
    flow=(qs.get("flow") or [""])[0]
    lines += [
        f"  - name: {name}",
        "    type: vless",
        f"    server: {server}",
        f"    port: {port}",
        f"    uuid: {uuid}",
        "    network: tcp",
        "    tls: true",
        "    udp: true",
    ]
    if flow:
        lines.append(f"    flow: {flow}")
    if sni:
        lines.append(f"    servername: {sni}")
    if pbk:
        lines += ["    reality-opts:", f"      public-key: {pbk}"]
        if sid:
            lines.append(f"      short-id: {sid}")
    lines.append(f"    client-fingerprint: {fp}")
lines += ["", "proxy-groups:", "  - name: PROXY", "    type: select", "    proxies:"]
for n in names:
    lines.append(f"      - {n}")
lines.append("      - DIRECT")
lines += ["", "rules:", "  - MATCH,PROXY"]
out.write_text("\\n".join(lines)+"\\n")
PY

    log "${GREEN}✅ 已生成：${raw_file}${PLAIN}"
    log "${GREEN}✅ 已生成：${clash_file}${PLAIN}"
    log "${YELLOW}如需通过 HTTP 访问，可用 Nginx/Caddy 暴露 /var/www/sub。${PLAIN}"
}


# ---------------- TCP 智能调优 ----------------
tcp_show_current_state() {
    clear 2>/dev/null || true
    log "${BLUE}================ TCP 线路状态检测 ================${PLAIN}"

    log "${YELLOW}核心 TCP 参数:${PLAIN}"
    sysctl \
        net.ipv4.tcp_congestion_control \
        net.core.default_qdisc \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_mtu_probing \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_notsent_lowat \
        net.core.netdev_max_backlog \
        net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog \
        net.ipv4.tcp_ecn \
        2>/dev/null || true

    log "${YELLOW}队列算法 / 网卡队列:${PLAIN}"
    has_cmd tc && tc qdisc show 2>/dev/null || true
    ip -br link 2>/dev/null || true

    log "${YELLOW}TCP 累计统计（重传比例只能作趋势参考，重启后会清零）:${PLAIN}"
    if has_cmd nstat; then
        nstat -az TcpOutSegs TcpRetransSegs TcpExtTCPSynRetrans TcpExtTCPTimeouts 2>/dev/null || true
        local out retrans ratio
        out=$(nstat -az TcpOutSegs 2>/dev/null | awk '/TcpOutSegs/ {print $2}' || true)
        retrans=$(nstat -az TcpRetransSegs 2>/dev/null | awk '/TcpRetransSegs/ {print $2}' || true)
        if [[ "${out:-0}" =~ ^[0-9]+$ && "${retrans:-0}" =~ ^[0-9]+$ && "${out:-0}" -gt 0 ]]; then
            ratio=$(awk -v r="$retrans" -v o="$out" 'BEGIN{printf "%.2f", r*100/o}')
            log "重传比例约：${ratio}%"
            awk -v x="$ratio" 'BEGIN{exit !(x>=3)}' && log "${YELLOW}判断：重传偏高，线路可能有丢包/QoS/拥塞。${PLAIN}" || true
        fi
    else
        log "${YELLOW}未安装 nstat/iproute2，跳过 TCP 统计。${PLAIN}"
    fi

    log "${YELLOW}当前 443 连接观察（关注 rtt/retrans/notsent/Send-Q）:${PLAIN}"
    ss -tnpi state established '( sport = :443 or dport = :443 )' 2>/dev/null | sed -n '1,120p' || true

    log "${YELLOW}推荐判断:${PLAIN}"
    local cc qdisc rmax wmax backlog notsent
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    rmax=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    wmax=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 0)
    notsent=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo 0)

    if [[ "$cc" != "bbr" || "$qdisc" != "fq" ]]; then
        log "- 建议先应用【基础 BBR/fq 调优】。"
    elif [[ "$rmax" -lt 16777216 || "$wmax" -lt 16777216 || "$backlog" -lt 10000 ]]; then
        log "- BBR 已开启，但缓冲/队列偏小；建议应用【跨境高延迟调优】。"
    elif [[ "$notsent" == "4294967295" || "$notsent" -gt 1048576 ]]; then
        log "- 建议设置 tcp_notsent_lowat，改善代理长连接发送排队。"
    else
        log "- 当前参数已经比较适合代理场景；若仍卡顿，多半是线路/QoS，不建议继续盲调。"
    fi
    log "${BLUE}==================================================${PLAIN}"
}

tcp_backup_config() {
    local tag="$1"
    local ts dir
    ts=$(date +%Y%m%d-%H%M%S)
    dir="/root/backup/tcp-smart-${tag}-${ts}"
    mkdir -p "$dir"
    cp -a /etc/sysctl.conf "$dir/sysctl.conf.bak" 2>/dev/null || true
    cp -a /etc/sysctl.d "$dir/sysctl.d.bak" 2>/dev/null || true
    sysctl \
        net.core.default_qdisc \
        net.ipv4.tcp_congestion_control \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_mtu_probing \
        net.ipv4.tcp_no_metrics_save \
        net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog \
        net.core.netdev_max_backlog \
        net.core.rmem_max \
        net.core.wmem_max \
        net.core.rmem_default \
        net.core.wmem_default \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_notsent_lowat \
        net.ipv4.ip_local_port_range \
        net.ipv4.tcp_fin_timeout \
        net.ipv4.tcp_keepalive_time \
        net.ipv4.tcp_keepalive_intvl \
        net.ipv4.tcp_keepalive_probes \
        net.ipv4.tcp_tw_reuse \
        net.ipv4.tcp_syn_retries \
        net.ipv4.tcp_synack_retries \
        net.ipv4.tcp_ecn \
        > "$dir/runtime-sysctl.values" 2>/dev/null || true
    if systemctl list-unit-files x-ui.service >/dev/null 2>&1; then
        mkdir -p "$dir/systemd"
        cp -a /etc/systemd/system/x-ui.service.d "$dir/systemd/x-ui.service.d.bak" 2>/dev/null || true
    fi
    echo "$dir"
}

tcp_neutralize_sysctl_conf_conflicts() {
    local tune_file="$1"
    local backup_dir="$2"
    local tmp changed=0

    [[ -f /etc/sysctl.conf && -f "$tune_file" ]] || return 0

    tmp=$(mktemp /tmp/vps-helper-sysctl-conf.XXXXXX)
    awk '
        FNR == NR {
            if ($0 ~ /^[[:space:]]*#/ || $0 !~ /=/) next
            split($0, a, "=")
            k = a[1]
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k != "") keys[k] = 1
            next
        }
        {
            if ($0 ~ /^[[:space:]]*#/ || $0 !~ /=/) {
                print
                next
            }
            split($0, a, "=")
            k = a[1]
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k in keys) {
                print "# vps-helper disabled duplicate: " $0
            } else {
                print
            }
        }
    ' "$tune_file" /etc/sysctl.conf > "$tmp"

    if ! cmp -s "$tmp" /etc/sysctl.conf; then
        cp -a /etc/sysctl.conf "$backup_dir/sysctl.conf.before-vps-helper-dedupe" 2>/dev/null || true
        cp "$tmp" /etc/sysctl.conf
        changed=1
    fi
    rm -f "$tmp"

    if [[ "$changed" -eq 1 ]]; then
        log "${YELLOW}已注释 /etc/sysctl.conf 中与 TCP 调优档冲突的旧参数（备份已保存）。${PLAIN}"
    fi
}

tcp_apply_profile() {
    local profile="$1"
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过 TCP 调优档写入、sysctl 加载、qdisc 修改和 x-ui 重启：${profile}"
        return 0
    fi
    local backup_dir tune_file="/etc/sysctl.d/99-vps-proxy-tcp-tune.conf"
    backup_dir=$(tcp_backup_config "$profile")

    case "$profile" in
        baseline)
            cat > "$tune_file" <<'EOF'
# VPS proxy TCP baseline tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 2
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_synack_retries = 4
EOF
            ;;
        high_latency)
            cat > "$tune_file" <<'EOF'
# VPS proxy TCP tuning - BBR/fq + high latency path
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 2
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 250000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_synack_retries = 4
EOF
            ;;
        mobile_qos)
            cat > "$tune_file" <<'EOF'
# VPS proxy TCP tuning - mobile/QoS conservative profile
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 250000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_synack_retries = 4
EOF
            ;;
        *) log "${RED}未知档位：${profile}${PLAIN}"; return 1 ;;
    esac

    tcp_neutralize_sysctl_conf_conflicts "$tune_file" "$backup_dir"

    log "${YELLOW}应用 sysctl 参数...${PLAIN}"
    sysctl --system >/tmp/vps-helper-sysctl.log 2>&1 || {
        log "${YELLOW}sysctl --system 返回非零，以下是输出；通常是个别系统不支持某参数。${PLAIN}"
        sed -n '1,120p' /tmp/vps-helper-sysctl.log || true
    }
    sysctl -p "$tune_file" >/tmp/vps-helper-sysctl-profile.log 2>&1 || {
        log "${YELLOW}单独加载 TCP 调优档返回非零，以下是输出：${PLAIN}"
        sed -n '1,120p' /tmp/vps-helper-sysctl-profile.log || true
    }

    local dev
    dev=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)
    if [[ -n "$dev" ]]; then
        tc qdisc replace dev "$dev" root fq 2>/dev/null || true
        ip link set dev "$dev" txqueuelen 10000 2>/dev/null || true
    fi

    if systemctl list-unit-files x-ui.service >/dev/null 2>&1; then
        mkdir -p /etc/systemd/system/x-ui.service.d
        cat > /etc/systemd/system/x-ui.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
        systemctl daemon-reload
        if confirm_action "是否现在重启 x-ui 让文件句柄限制立即生效？当前连接可能短暂断开"; then
            systemctl restart x-ui || true
        else
            log "${YELLOW}已跳过重启 x-ui；文件句柄限制将在下次重启 x-ui 后生效。${PLAIN}"
        fi
    fi

    log "${GREEN}✅ TCP 调优档位已应用：${profile}${PLAIN}"
    log "${GREEN}备份目录：${backup_dir}${PLAIN}"
    tcp_show_current_state
}

tcp_restore_backup() {
    log "${YELLOW}最近备份目录:${PLAIN}"
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过 TCP 配置回滚写入"
        return 0
    fi
    ls -dt /root/backup/tcp-smart-* 2>/dev/null | head -n 10 || true
    read -r -p "输入要回滚的备份目录完整路径: " dir
    [[ -z "$dir" || ! -d "$dir" ]] && { log "${RED}备份目录无效${PLAIN}"; return; }
    if ! confirm_action "确认从 ${dir} 回滚 TCP/sysctl 配置吗？"; then
        log "${YELLOW}已取消回滚${PLAIN}"
        return
    fi
    [[ -f "$dir/sysctl.conf.bak" ]] && cp -a "$dir/sysctl.conf.bak" /etc/sysctl.conf
    if [[ -d "$dir/sysctl.d.bak" ]]; then
        rm -f /etc/sysctl.d/99-vps-proxy-tcp-tune.conf
        cp -a "$dir/sysctl.d.bak/." /etc/sysctl.d/ 2>/dev/null || true
    fi
    if [[ -d "$dir/systemd/x-ui.service.d.bak" ]]; then
        rm -rf /etc/systemd/system/x-ui.service.d
        cp -a "$dir/systemd/x-ui.service.d.bak" /etc/systemd/system/x-ui.service.d
        systemctl daemon-reload || true
    fi
    sysctl --system >/tmp/vps-helper-sysctl-restore.log 2>&1 || sed -n '1,120p' /tmp/vps-helper-sysctl-restore.log || true
    if [[ -f "$dir/runtime-sysctl.values" ]]; then
        sysctl -p "$dir/runtime-sysctl.values" >/tmp/vps-helper-sysctl-runtime-restore.log 2>&1 || {
            log "${YELLOW}部分运行时 sysctl 参数恢复失败，以下为输出：${PLAIN}"
            sed -n '1,120p' /tmp/vps-helper-sysctl-runtime-restore.log || true
        }
    else
        log "${YELLOW}此备份缺少 runtime-sysctl.values；配置已回滚，但部分运行时参数可能需重启后恢复。${PLAIN}"
    fi
    log "${GREEN}✅ 已尝试回滚：${dir}${PLAIN}"
}

tcp_iperf_helper() {
    log "${YELLOW}--- iperf3 辅助 ---${PLAIN}"
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过 iperf3 启停操作"
        return 0
    fi
    echo "1. 启动 iperf3 服务端（默认 5201）"
    echo "2. 启动 iperf3 服务端（自定义端口）"
    echo "3. 停止 iperf3 服务端"
    echo "4. 查看 iperf3 状态"
    read -r -p "请选择 [1-4]: " n
    case "$n" in
        1) has_cmd iperf3 || ensure_packages iperf3; pkill -x iperf3 2>/dev/null || true; iperf3 -s -D -p 5201; log "${GREEN}✅ 已启动：iperf3 -c <服务器IP> -p 5201${PLAIN}" ;;
        2) read -r -p "输入端口: " p; [[ "$p" =~ ^[0-9]+$ ]] || { log "${RED}端口无效${PLAIN}"; return; }; has_cmd iperf3 || ensure_packages iperf3; pkill -x iperf3 2>/dev/null || true; iperf3 -s -D -p "$p"; log "${GREEN}✅ 已启动：iperf3 -c <服务器IP> -p ${p}${PLAIN}" ;;
        3) pkill -x iperf3 2>/dev/null || true; log "${GREEN}✅ 已停止 iperf3${PLAIN}" ;;
        4) pgrep -a iperf3 || log "${YELLOW}iperf3 未运行${PLAIN}"; ss -lntup | grep iperf3 || true ;;
        *) log "${RED}无效选择${PLAIN}" ;;
    esac
}


tcp_qdisc_diagnose() {
    clear 2>/dev/null || true
    log "${BLUE}================ qdisc / 限速诊断 ================${PLAIN}"

    local dev
    dev=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)
    if [[ -z "$dev" ]]; then
        log "${RED}未找到默认出口网卡。${PLAIN}"
        return
    fi

    log "${YELLOW}默认出口网卡:${PLAIN} ${dev}"
    ip -br link show dev "$dev" 2>/dev/null || true

    log "${YELLOW}当前队列详情:${PLAIN}"
    if has_cmd tc; then
        tc -s qdisc show dev "$dev" 2>/dev/null || true
    else
        log "${YELLOW}未检测到 tc/iproute2。${PLAIN}"
    fi

    log "${YELLOW}判断:${PLAIN}"
    local qdisc_text
    qdisc_text=$(tc qdisc show dev "$dev" 2>/dev/null || true)
    if echo "$qdisc_text" | grep -q "fq .*maxrate"; then
        log "- 检测到 fq maxrate：当前存在单连接限速，适合压重传，但会限制峰值。"
    elif echo "$qdisc_text" | grep -qE "htb|tbf|cake"; then
        log "- 检测到整形队列（HTB/TBF/CAKE）：请确认这是你主动设置的限速。"
    elif echo "$qdisc_text" | grep -q "fq"; then
        log "- 已使用 fq 队列，适合 BBR；未发现明显 tc 限速。"
    elif echo "$qdisc_text" | grep -q "mq"; then
        log "- 根队列是 mq；如果子队列里有 fq，属于多队列网卡的正常情况。"
    else
        log "- 未看到 fq；如果使用 BBR，建议应用 TCP 调优档。"
    fi

    log "${YELLOW}可能冲突的旧服务:${PLAIN}"
    local unit
    for unit in netshape-manager.service netshape.service tc-fq-maxrate.service netpace.service; do
        if systemctl is-enabled "$unit" >/dev/null 2>&1 || systemctl is-active "$unit" >/dev/null 2>&1; then
            systemctl status "$unit" --no-pager -l | sed -n '1,18p' || true
        fi
    done

    log "${YELLOW}sysctl 重复项检查:${PLAIN}"
    grep -R "net.ipv4.tcp_congestion_control\|net.core.default_qdisc\|net.ipv4.tcp_ecn\|net.ipv4.tcp_rmem\|net.ipv4.tcp_wmem\|net.core.rmem_max\|net.core.wmem_max\|net.ipv4.tcp_notsent_lowat" \
        /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | sed -n '1,160p' || true

    log "${BLUE}==================================================${PLAIN}"
}

tcp_shape_menu() {
    local dev rate
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过 fq qdisc 限速实验和恢复操作"
        return 0
    fi
    dev=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)
    [[ -z "$dev" ]] && { log "${RED}未找到默认出口网卡。${PLAIN}"; return; }

    log "${YELLOW}--- fq 单连接限速实验（借鉴 netshape）---${PLAIN}"
    log "用途：当线路重传很高时，限制单条 TCP 峰值，避免 BBR 过冲。"
    log "注意：这会降低单连接最高速度；代理节点不建议长期盲目限速。"
    echo "1. 设置单连接 maxrate"
    echo "2. 恢复 fq 无单连接限速"
    echo "0. 返回"
    read -r -p "请选择 [0-2]: " n || return
    case "$n" in
        1)
            read -r -p "输入单连接上限 Mbps（例：50/100/200）: " rate || return
            [[ "$rate" =~ ^[0-9]+$ && "$rate" -gt 0 ]] || { log "${RED}速率无效${PLAIN}"; return; }
            if confirm_action "确认设置 ${dev} 单连接上限为 ${rate} Mbps 吗？"; then
                tc qdisc replace dev "$dev" root fq maxrate "${rate}mbit" || {
                    log "${RED}设置失败，当前内核/tc 可能不支持 fq maxrate。${PLAIN}"
                    return
                }
                ip link set dev "$dev" txqueuelen 10000 2>/dev/null || true
                log "${GREEN}✅ 已设置 fq maxrate：单连接 ≤ ${rate} Mbps${PLAIN}"
            fi
            ;;
        2)
            tc qdisc replace dev "$dev" root fq 2>/dev/null || true
            ip link set dev "$dev" txqueuelen 10000 2>/dev/null || true
            log "${GREEN}✅ 已恢复 fq，无单连接 maxrate${PLAIN}"
            ;;
        0) return ;;
        *) log "${RED}无效选择${PLAIN}" ;;
    esac
}

tcp_iperf_result_advisor() {
    clear 2>/dev/null || true
    log "${BLUE}================ iperf3 结果智能建议 ================${PLAIN}"
    log "请按 iperf3 结果输入 Mbps；不确定可直接回车填 0。"
    log "方向说明："
    log "  本地 -> 服务器：iperf3 -c 服务器IP"
    log "  服务器 -> 本地：iperf3 -c 服务器IP -R"

    local up1 up4 down1 down4 retr_up retr_down cap
    read -r -p "本地 -> 服务器 单线程 Mbps: " up1 || return
    read -r -p "本地 -> 服务器 多线程 Mbps: " up4 || return
    read -r -p "服务器 -> 本地 单线程 Mbps: " down1 || return
    read -r -p "服务器 -> 本地 多线程 Mbps: " down4 || return
    read -r -p "本地 -> 服务器 Retr 总数（没有填 0）: " retr_up || return
    read -r -p "服务器 -> 本地 Retr 总数（没有填 0）: " retr_down || return
    read -r -p "服务器官方/商家限速 Mbps（没有填 0）: " cap || return

    up1=${up1:-0}; up4=${up4:-0}; down1=${down1:-0}; down4=${down4:-0}; retr_up=${retr_up:-0}; retr_down=${retr_down:-0}; cap=${cap:-0}
    for x in "$up1" "$up4" "$down1" "$down4" "$retr_up" "$retr_down" "$cap"; do
        [[ "$x" =~ ^[0-9]+([.][0-9]+)?$ ]] || { log "${RED}输入包含非法数字：${x}${PLAIN}"; return; }
    done

    log "${YELLOW}分析:${PLAIN}"
    awk -v down4="$down4" -v cap="$cap" 'BEGIN{exit !(cap>0 && down4>=cap*0.85)}' \
        && log "- 下行接近官方限速；这类瓶颈不能靠 TCP 调优突破。" || true
    awk -v up1="$up1" -v down1="$down1" 'BEGIN{exit !(down1>0 && up1>0 && up1<down1*0.25)}' \
        && log "- 上行明显弱于下行，符合移动/QoS/方向性限速特征。" || true
    awk -v up4="$up4" -v up1="$up1" 'BEGIN{exit !(up1>0 && up4>up1*2)}' \
        && log "- 多线程明显好于单线程，说明单连接受限或 BBR 过冲后被压。" || true
    awk -v r="$retr_up" 'BEGIN{exit !(r>=1000)}' \
        && log "- 本地到服务器方向重传很高，建议优先保守档或单连接限速实验。" || true
    awk -v r="$retr_down" 'BEGIN{exit !(r>=3000)}' \
        && log "- 服务器到本地方向重传很高，线路拥塞/QoS 概率高。" || true

    log "${YELLOW}建议:${PLAIN}"
    local recommend
    recommend=$(tcp_profile_recommendation "$up1" "$up4" "$down1" "$down4" "$retr_up" "$retr_down" "$cap")
    case "$recommend" in
        mobile_qos) log "- 推荐应用【移动/QoS 保守档】。理由：上行弱/重传高，ECN=0 更稳。" ;;
        none) log "- 不建议继续调参。理由：已经接近官方限速。" ;;
        *) log "- 推荐应用【跨境高延迟/代理长连接调优】。" ;;
    esac

    if awk -v r="$retr_down" 'BEGIN{exit !(r>=3000)}'; then
        log "- 可额外测试【fq 单连接限速实验】，例如 50/100/200 Mbps；如果重传下降且体感更稳，再保留。"
    fi

    if [[ "$recommend" != "none" ]] && confirm_action "是否现在应用推荐档位：${recommend}"; then
        tcp_apply_profile "$recommend"
    fi

    log "${BLUE}====================================================${PLAIN}"
}



tcp_profile_recommendation() {
    local up1="$1" up4="$2" down1="$3" down4="$4" retr_up="$5" retr_down="$6" cap="$7"
    local recommend="high_latency"

    if awk -v up1="$up1" -v down1="$down1" -v retr="$retr_up" 'BEGIN{exit !(down1>0 && (up1<down1*0.35 || retr>=1000))}'; then
        recommend="mobile_qos"
    elif awk -v down4="$down4" -v cap="$cap" 'BEGIN{exit !(cap>0 && down4>=cap*0.85)}'; then
        recommend="none"
    fi

    printf '%s\n' "$recommend"
}

tcp_network_profile_file() {
    mkdir -p /root/.vps-helper
    printf '%s\n' "/root/.vps-helper/network-profiles.tsv"
}

tcp_network_profile_header() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        printf 'time\tlocal_profile\tserver_label\tup1_mbps\tup4_mbps\tdown1_mbps\tdown4_mbps\tretr_up\tretr_down\tcap_mbps\trecommend\tnote\n' > "$file"
    fi
}

tcp_network_profile_add() {
    local file local_profile server_label up1 up4 down1 down4 retr_up retr_down cap note recommend now
    file=$(tcp_network_profile_file)
    tcp_network_profile_header "$file"

    log "${YELLOW}--- 新增本地网络画像 ---${PLAIN}"
    read -r -p "本地网络名（例 home-cmcc-night / office-telecom / iphone-5g）: " local_profile || return
    read -r -p "服务器标签（例 HK-87 / JP / Oracle）: " server_label || return
    read -r -p "本地 -> 服务器 单线程 Mbps: " up1 || return
    read -r -p "本地 -> 服务器 多线程 Mbps: " up4 || return
    read -r -p "服务器 -> 本地 单线程 Mbps: " down1 || return
    read -r -p "服务器 -> 本地 多线程 Mbps: " down4 || return
    read -r -p "本地 -> 服务器 Retr 总数（没有填 0）: " retr_up || return
    read -r -p "服务器 -> 本地 Retr 总数（没有填 0）: " retr_down || return
    read -r -p "服务器官方/商家限速 Mbps（没有填 0）: " cap || return
    read -r -p "备注（可空）: " note || true

    [[ -n "$local_profile" ]] || { log "${RED}本地网络名不能为空${PLAIN}"; return; }
    [[ -n "$server_label" ]] || server_label="$(hostname 2>/dev/null || echo server)"
    up1=${up1:-0}; up4=${up4:-0}; down1=${down1:-0}; down4=${down4:-0}; retr_up=${retr_up:-0}; retr_down=${retr_down:-0}; cap=${cap:-0}
    for x in "$up1" "$up4" "$down1" "$down4" "$retr_up" "$retr_down" "$cap"; do
        [[ "$x" =~ ^[0-9]+([.][0-9]+)?$ ]] || { log "${RED}输入包含非法数字：${x}${PLAIN}"; return; }
    done

    recommend=$(tcp_profile_recommendation "$up1" "$up4" "$down1" "$down4" "$retr_up" "$retr_down" "$cap")
    now=$(date '+%F %T')

    local_profile=${local_profile//$'\t'/ }
    server_label=${server_label//$'\t'/ }
    note=${note//$'\t'/ }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$now" "$local_profile" "$server_label" "$up1" "$up4" "$down1" "$down4" "$retr_up" "$retr_down" "$cap" "$recommend" "$note" >> "$file"

    log "${GREEN}✅ 已保存画像：${local_profile} / ${server_label}${PLAIN}"
    log "${YELLOW}推荐档位:${PLAIN} ${recommend}"
    log "${YELLOW}记录文件:${PLAIN} ${file}"
}

tcp_network_profile_list() {
    local file
    file=$(tcp_network_profile_file)
    tcp_network_profile_header "$file"
    log "${BLUE}================ 本地网络画像列表 ================${PLAIN}"
    awk -F '\t' '
        NR==1 {next}
        {
            printf "%3d. %-19s  %-18s  %-10s  up:%6s/%6s  down:%6s/%6s  retr:%s/%s  cap:%s  rec:%s  %s\n",
                NR-1, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12
        }
    ' "$file"
    log "${BLUE}==================================================${PLAIN}"
}

tcp_network_profile_compare() {
    local file
    file=$(tcp_network_profile_file)
    tcp_network_profile_header "$file"
    log "${BLUE}================ 本地网络画像对比 ================${PLAIN}"
    awk -F '\t' '
        NR==1 {next}
        {
            key=$2 "\t" $3
            if (!(key in count)) keys_seen++
            count[key]++
            up1[key]+=$4; up4[key]+=$5; down1[key]+=$6; down4[key]+=$7; ru[key]+=$8; rd[key]+=$9
            rec[key]=$11
        }
        END {
            if (keys_seen==0) {
                print "暂无记录"
                exit
            }
            printf "%-20s %-12s %5s %12s %12s %12s %12s %12s %12s %-12s\n", "本地网络", "服务器", "次数", "up1均值", "up4均值", "down1均值", "down4均值", "retr_up均值", "retr_down均值", "最近推荐"
            for (k in count) {
                split(k, a, "\t")
                c=count[k]
                printf "%-20s %-12s %5d %12.1f %12.1f %12.1f %12.1f %12.0f %12.0f %-12s\n",
                    a[1], a[2], c, up1[k]/c, up4[k]/c, down1[k]/c, down4[k]/c, ru[k]/c, rd[k]/c, rec[k]
            }
        }
    ' "$file"
    log "${BLUE}==================================================${PLAIN}"
}

tcp_network_profile_delete() {
    local file idx tmp total
    file=$(tcp_network_profile_file)
    tcp_network_profile_header "$file"
    tcp_network_profile_list
    total=$(awk 'END{print NR-1}' "$file")
    [[ "${total:-0}" -le 0 ]] && { log "${YELLOW}暂无可删除记录${PLAIN}"; return; }
    read -r -p "输入要删除的编号: " idx || return
    [[ "$idx" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le "$total" ]] || { log "${RED}编号无效${PLAIN}"; return; }
    if ! confirm_action "确认删除第 ${idx} 条画像记录吗？"; then
        log "${YELLOW}已取消删除${PLAIN}"
        return
    fi
    tmp=$(mktemp /tmp/vps-helper-profile.XXXXXX)
    awk -v del="$idx" 'NR==1 || NR-1!=del {print}' "$file" > "$tmp"
    cp "$tmp" "$file"
    rm -f "$tmp"
    log "${GREEN}✅ 已删除第 ${idx} 条记录${PLAIN}"
}

tcp_network_profile_menu() {
    if (( DRY_RUN )); then
        log "${BLUE}[dry-run]${PLAIN} 跳过本地网络画像文件写入"
        return 0
    fi
    while true; do
        clear 2>/dev/null || true
        echo -e "${BLUE}================ 本地网络画像记录/对比 ================${PLAIN}"
        echo "1. 新增一条 iperf3 画像记录"
        echo "2. 查看全部记录"
        echo "3. 按 本地网络+服务器 聚合对比"
        echo "4. 删除一条记录"
        echo "0. 返回"
        echo -e "${BLUE}======================================================${PLAIN}"
        read -r -p "请选择 [0-4]: " n || return
        case "$n" in
            1) tcp_network_profile_add ;;
            2) tcp_network_profile_list ;;
            3) tcp_network_profile_compare ;;
            4) tcp_network_profile_delete ;;
            0) return ;;
            *) log "${RED}无效选择${PLAIN}" ;;
        esac
        echo ""
        read -r -p "按回车继续..." || return
    done
}


tcp_smart_tune_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${BLUE}================ TCP 智能调优/回滚 ================${PLAIN}"
        echo "1. 检测当前 TCP/线路状态并给建议"
        echo "2. 应用基础 BBR/fq 调优"
        echo "3. 应用跨境高延迟/代理长连接调优（推荐）"
        echo "4. 应用移动/QoS 保守档（关闭 ECN，谨慎使用）"
        echo "5. 回滚到历史备份"
        echo "6. iperf3 服务端管理"
        echo "7. qdisc / 限速诊断"
        echo "8. 根据 iperf3 测试结果给调优建议"
        echo "9. fq 单连接限速实验"
        echo "10. 本地网络画像记录/对比"
        echo "0. 返回主菜单"
        echo -e "${BLUE}==================================================${PLAIN}"
        read -r -p "请选择 [0-10]: " n
        case "$n" in
            1) tcp_show_current_state ;;
            2) confirm_action "应用基础 BBR/fq 调优？" && tcp_apply_profile baseline ;;
            3) confirm_action "应用跨境高延迟/代理长连接调优？" && tcp_apply_profile high_latency ;;
            4) confirm_action "应用移动/QoS 保守档？如果不确定，建议先用 3" && tcp_apply_profile mobile_qos ;;
            5) tcp_restore_backup ;;
            6) tcp_iperf_helper ;;
            7) tcp_qdisc_diagnose ;;
            8) tcp_iperf_result_advisor ;;
            9) tcp_shape_menu ;;
            10) tcp_network_profile_menu ;;
            0) return ;;
            *) log "${RED}无效选择${PLAIN}" ;;
        esac
        echo ""
        read -r -p "按回车继续..." || return
    done
}

environment_init() {
    unlock_apt || true
    ensure_packages curl socat geoip-bin unzip tar php-cli sqlite3 lsof iperf3 ca-certificates
}

while true; do
    clear 2>/dev/null || true
    local_tcp_ctrl=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || true)
    BBR_INFO=$([[ "${local_tcp_ctrl}" == "bbr" ]] && echo -e "${GREEN}BBR已开启${PLAIN}" || echo -e "${YELLOW}未开启${PLAIN}")

    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}       VPS 综合运维助手 V9.5 (TCP智能调优版)       ${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "  1. 🛡️  同步防御加固 (Fail2Ban jail.d)"
    echo -e "  2. 🚀  BBR / TCPx 加速管理 [${BBR_INFO}]"
    echo -e "  3. 📦  环境初始化 (APT+工具箱)"
    echo -e "  4. 🛠️  安装/更新 x-ui 面板"
    echo -e "  5. 🐋  安装 Docker 环境"
    echo -e "  6. 📊  查看防御战报"
    echo -ne "       运行状态: "
    get_status_display
    echo -e "\n  7. 🔓  一键解封指定 IP"
    echo -e "  8. 💾  虚拟内存 (SWAP) 管理"
    echo -e "  9. 📦  Docker 状态/容器列表"
    echo -e "  10.🛣️  回程路由测试 (Backtrace)"
    echo -e "  11.📜 SSL 证书申请/续期并安装到 x-ui 路径"
    echo -e "  12.⚡ iperf3 服务端管理"
    echo -e "  13.🩺 系统体检/端口查看"
    echo -e "  14.🧩 Reality 节点参数辅助"
    echo -e "  15.🌐 网络质量检测"
    echo -e "  16.🔓 流媒体 / AI 解锁检测"
    echo -e "  17.🧪 综合测速 / iperf3"
    echo -e "  18.🔐 VPS 安全体检"
    echo -e "  19.🧰 tcpfit TCP 调优"
    echo -e "  20.🧠 TCP 智能调优/回滚"
    echo -e "  21.🧪 IP质量/原生IP/流媒体解锁检测"
    echo -e "  0. 退出"
    echo -e "${BLUE}==================================================${PLAIN}"

    read -r -p "请输入选择 [0-21]: " num || exit 0
    case "$num" in
        1) ensure_packages fail2ban && smart_fix_fail2ban ;;
        2) run_remote_script "linux_netspeed_tcp" "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcp.sh" "bash" ;;
        3) environment_init ;;
        4) install_or_update_xui ;;
        5) run_remote_script "docker_get" "https://get.docker.com" "bash" && run_cmd systemctl enable docker --now ;;
        6) view_security_report ;;
        7)
            read -r -p "输入 IP: " tip
            if (( DRY_RUN )); then
                log "${BLUE}[dry-run]${PLAIN} 跳过 Fail2Ban 解封写入：${tip}"
            elif ! has_cmd fail2ban-client; then
                log "${RED}fail2ban-client 不存在。${PLAIN}"
            else
                j_list=$(fail2ban-client status 2>/dev/null | awk -F':' '/Jail list/ {print $2}' | tr ',' ' ' | xargs || true)
                for j in $j_list; do fail2ban-client set "$j" unbanip "$tip" >/dev/null 2>&1 || true; done
                log "${GREEN}已尝试在所有 jail 中解封：${tip}${PLAIN}"
            fi
            ;;
        8) manage_swap ;;
        9)
            if has_cmd docker; then
                systemctl status docker --no-pager -l | sed -n '1,80p' || true
                docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}' || true
            else
                log "${YELLOW}未检测到 Docker。${PLAIN}"
            fi
            ;;
        10) run_remote_script "backtrace_install" "https://raw.githubusercontent.com/zhanghanyun/backtrace/master/install.sh" "bash" ;;
        11) manage_acme_certificate ;;
        12) tcp_iperf_helper ;;
        13) system_check ;;
        14) generate_reality_link_helper ;;
        15) network_quality_check ;;
        16) unlock_media_ai_check ;;
        17) speedtest_menu ;;
        18) security_audit ;;
        19) tcpfit_tune ;;
        20) tcp_smart_tune_menu ;;
        21) ip_quality_media_check ;;
        0) exit 0 ;;
        *) log "${RED}无效选项${PLAIN}" ;;
    esac

    echo ""
    read -r -p "按回车继续..." || exit 0
done
