#!/usr/bin/env bash
#==============================================================================
# Linux 运维工具合集 v1.1
# 适用系统: Debian 13 (兼容 Debian 11/12、Ubuntu 20.04+)
#
# 交互模式: bash Linux运维工具合集.sh
# 命令模式: bash Linux运维工具合集.sh <子命令> [参数]   （支持自动化）
#   例: bash Linux运维工具合集.sh hostname web01
#       bash Linux运维工具合集.sh bbr
#       bash Linux运维工具合集.sh swap-add 2G /swapfile
#       bash Linux运维工具合集.sh dns apply
#       bash Linux运维工具合集.sh help
#
# v1.1 变更（相对 v1.0）:
#   - 融合五个独立老脚本优点: 虚拟化检测 / BBR 模块预检 / GB、MB 智能单位
#   - 新增命令行子命令模式（非交互，适合 Ansible/CI/一键脚本调用）
#   - 保留 v1.0 的全部缺陷修复 (gai precedence / fstab 显示 / 原子自更新 等)
#   - BBR 模块加载改用 modprobe -n 预检，避免盲加载
#   - swap 增加 OpenVZ/LXC/Docker 警告
#   - 系统信息面板 DNS 锁状态显示更准确
#==============================================================================

set -o pipefail

VERSION="1.1"
SCRIPT_NAME="Linux 运维工具合集"
UPDATE_URL="https://raw.githubusercontent.com/DarkerLab/tools/refs/heads/main/shell/Linux.sh"

SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
BACKUP_DIR="/root/.linux-tools-backup"
LOG_FILE="/var/log/linux-tools-$(date +%Y%m%d).log"

# 命令行模式下自动确认（可在子命令中按需绕过）
ASSUME_YES=0
VIRT_TYPE="none"

#------------------------------------------------------------------------------
# 颜色与输出
#------------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET=$'\033[0m';  C_RED=$'\033[0;31m';  C_GREEN=$'\033[0;32m'
    C_YELL=$'\033[0;33m'; C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELL=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_DIM=""
fi

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local msg="$*"
    echo "$(ts) $msg" >> "$LOG_FILE" 2>/dev/null || true
}

info()  { echo "${C_CYAN}[*]${C_RESET} $*"; }
ok()    { echo "${C_GREEN}[✓]${C_RESET} $*"; log "OK   : $*"; }
warn()  { echo "${C_YELL}[!]${C_RESET} $*"; log "WARN : $*"; }
err()   { echo "${C_RED}[✗]${C_RESET} $*" >&2; log "ERROR: $*"; }
title() { echo; echo "${C_BOLD}${C_BLUE}── $* ──${C_RESET}"; }

pause() {
    [ "$ASSUME_YES" = "1" ] && return 0
    echo
    read -r -p "${C_DIM}按回车键返回菜单...${C_RESET}" _
}

confirm() {
    local prompt="$1" ans
    [ "$ASSUME_YES" = "1" ] && return 0
    echo
    read -r -p "${C_YELL}${prompt} [y/N]: ${C_RESET}" ans
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

#------------------------------------------------------------------------------
# 通用工具
#------------------------------------------------------------------------------
backup_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    mkdir -p "$BACKUP_DIR"
    local name
    name="$(basename "$f").$(date +%Y%m%d%H%M%S).bak"
    cp -a "$f" "${BACKUP_DIR}/${name}" && info "已备份 ${f} → ${BACKUP_DIR}/${name}"
}

is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }
have()   { command -v "$1" >/dev/null 2>&1; }

# [v1.1] 虚拟化环境检测（融合 swap.sh 的 OpenVZ 检测）
detect_virt() {
    VIRT_TYPE="none"
    if [ -f /proc/vz/veinfo ] || [ -f /proc/user_beancounters ] || have vzctl; then
        VIRT_TYPE="openvz"
    elif [ -n "${container:-}" ]; then
        VIRT_TYPE="$container"
    elif grep -qaE '(docker|lxc|kubepods|containerd|podman)' /proc/1/cgroup 2>/dev/null; then
        VIRT_TYPE="container"
    elif have systemd-detect-virt; then
        local v
        v=$(systemd-detect-virt 2>/dev/null)
        [ -n "$v" ] && [ "$v" != "none" ] && VIRT_TYPE="$v"
    fi
}

# [v1.1] 智能解析大小（如 512M / 2G / 1024），统一返回 MB
parse_size_mb() {
    local input="$1" n unit
    if [[ "$input" =~ ^([0-9]+)([MmGg])$ ]]; then
        n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2],,}"
        if [ "$unit" = "g" ]; then
            echo $((n * 1024))
        else
            echo "$n"
        fi
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
    else
        echo ""
    fi
}

#------------------------------------------------------------------------------
# 环境检查
#------------------------------------------------------------------------------
preflight() {
    if [ "$(id -u)" -ne 0 ]; then
        err "本脚本必须以 root 权限运行"
        echo "    请使用: sudo bash $0"
        exit 1
    fi

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_PRETTY="${PRETTY_NAME:-未知系统}"
        OS_ID="${ID:-linux}"
        OS_VER="${VERSION_ID:-}"
    else
        OS_PRETTY="未知系统"; OS_ID="linux"; OS_VER=""
    fi

    KERNEL="$(uname -r)"

    mkdir -p "$BACKUP_DIR"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/linux-tools-$(date +%Y%m%d).log"
    log "==== 脚本启动 v${VERSION} | ${OS_PRETTY} | kernel ${KERNEL} ===="

    detect_virt
    if [ "$VIRT_TYPE" != "none" ]; then
        log "虚拟化环境: ${VIRT_TYPE}"
    fi

    if [ "$OS_ID" != "debian" ] && [ "$OS_ID" != "ubuntu" ]; then
        warn "当前系统为 ${OS_PRETTY}，本脚本主要针对 Debian/Ubuntu 优化，部分功能可能不适用"
    fi
}

# 各功能开始前的虚拟化提示（在进入具体操作时调用）
virt_warn_for() {
    local action="$1"
    case "$VIRT_TYPE" in
        openvz)
            warn "检测到 OpenVZ 环境，${action} 在 OpenVZ 下可能不生效或不支持"
            confirm "是否仍继续?" || { info "已取消"; return 1; }
            ;;
        lxc|container|docker)
            warn "检测到容器环境 (${VIRT_TYPE})，${action} 可能影响宿主机或不被允许"
            confirm "是否仍继续?" || { info "已取消"; return 1; }
            ;;
    esac
    return 0
}

#------------------------------------------------------------------------------
# 1. 修改主机名并同步 hosts
#------------------------------------------------------------------------------
do_hostname() {
    local NEW_HOST="${1:-}"

    if [ -z "$NEW_HOST" ]; then
        title "1. 修改主机名并同步 hosts"
        echo "  当前主机名 : $(hostname)"
        echo "  当前 FQDN  : $(hostname -f 2>/dev/null || echo '未设置')"
        echo "  /etc/hosts 现有内容:"
        sed 's/^/    /' /etc/hosts 2>/dev/null || echo "    (文件不存在)"
        echo
        read -r -p "${C_CYAN}请输入新主机名 (字母/数字/连字符/点，支持 FQDN): ${C_RESET}" NEW_HOST
    fi

    if [ -z "$NEW_HOST" ]; then
        warn "未输入，已取消"
        return 1
    fi
    # [v1.1] 允许点号以支持 FQDN（兼容老脚本 hostname-set.sh 行为）
    if ! [[ "$NEW_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        err "主机名格式非法：字母/数字/连字符/点，不能以连字符或点开头/结尾"
        return 1
    fi
    if [ ${#NEW_HOST} -gt 253 ]; then
        err "主机名过长（FQDN 上限 253 字符）"
        return 1
    fi
    NEW_HOST="$(echo "$NEW_HOST" | tr 'A-Z' 'a-z')"

    if [ "$NEW_HOST" = "$(hostname)" ]; then
        warn "新主机名与当前一致，无需修改"
        return 0
    fi

    confirm "确认将主机名修改为 ${NEW_HOST} ?" || { info "已取消"; return 1; }

    backup_file /etc/hosts
    backup_file /etc/hostname

    if have hostnamectl; then
        hostnamectl set-hostname "$NEW_HOST" && ok "hostnamectl 设置成功" \
            || warn "hostnamectl 执行失败，改用传统方式"
    fi
    echo "$NEW_HOST" > /etc/hostname
    hostname "$NEW_HOST" 2>/dev/null || true

    touch /etc/hosts
    grep -v '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts > /etc/hosts.tmp 2>/dev/null \
        || cp /etc/hosts /etc/hosts.tmp
    local OLD_HOST
    OLD_HOST="$(awk '/^127\.0\.0\.1/{for(i=2;i<=NF;i++) if($i!~/localhost/) print $i; exit}' /etc/hosts.tmp)"
    if [ -n "$OLD_HOST" ] && [ "$OLD_HOST" != "$NEW_HOST" ]; then
        sed -i "/^127\.0\.0\.1/s/\b${OLD_HOST}\b//g" /etc/hosts.tmp
        sed -i '/^127\.0\.0\.1/s/[[:space:]]\{2,\}/ /g' /etc/hosts.tmp
        sed -i 's/[[:space:]]*$//' /etc/hosts.tmp
        info "已从 127.0.0.1 行移除旧主机名 ${OLD_HOST}"
    fi
    grep -qE '^127\.0\.0\.1[[:space:]]' /etc/hosts.tmp \
        || sed -i '1i 127.0.0.1\tlocalhost' /etc/hosts.tmp
    sed -i "/^127\.0\.0\.1[[:space:]]/a 127.0.1.1\t${NEW_HOST}" /etc/hosts.tmp
    grep -qE '^::1[[:space:]]' /etc/hosts.tmp \
        || echo -e "::1\tlocalhost ip6-localhost ip6-loopback" >> /etc/hosts.tmp

    cat /etc/hosts.tmp > /etc/hosts
    rm -f /etc/hosts.tmp
    chmod 644 /etc/hosts

    ok "主机名已修改为 ${NEW_HOST}"
    echo
    echo "  生效后的 /etc/hosts:"
    sed 's/^/    /' /etc/hosts
    echo
    info "hostname 已即时生效；部分服务（如 SSH 横幅、面板）需重启或重新登录后刷新"
    log "主机名修改: ${OLD_HOST:-none} -> ${NEW_HOST}"
}

#------------------------------------------------------------------------------
# 2. 设置 IPv4 解析优先
#------------------------------------------------------------------------------
do_ipv4_first() {
    title "2. 设置 IPv4 解析优先"

    echo "  原理: 通过 /etc/gai.conf 提高 IPv4 映射地址 (::ffff:0:0/96) 优先级，"
    echo "        使 getaddrinfo() 优先返回 A 记录。"
    echo
    echo "  当前状态:"
    if [ -f /etc/gai.conf ] \
       && grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' /etc/gai.conf; then
        echo "    ${C_GREEN}已启用 IPv4 优先 (precedence = 100)${C_RESET}"
        grep -nE '^[[:space:]]*precedence' /etc/gai.conf | sed 's/^/      /'
    elif [ -f /etc/gai.conf ] \
         && grep -qE '^[[:space:]]*#?[[:space:]]*precedence[[:space:]]+::ffff:0:0/96' /etc/gai.conf; then
        echo "    ${C_YELL}存在 precedence 行，但值不为 100${C_RESET}"
        grep -nE '^[[:space:]]*#?[[:space:]]*precedence[[:space:]]+::ffff:0:0/96' /etc/gai.conf | sed 's/^/      /'
    else
        echo "    ${C_YELL}未启用${C_RESET}"
    fi
    echo
    echo "  验证测试:"
    getent ahosts "$(hostname)" 2>/dev/null | head -3 | sed 's/^/      /'

    if ! confirm "是否启用 IPv4 解析优先?"; then
        info "已取消"; return 0
    fi

    backup_file /etc/gai.conf
    touch /etc/gai.conf

    # [FIX 1] 强制 precedence = 100：删除所有该前缀行再追加
    sed -i -E '/^[[:space:]]*#?[[:space:]]*precedence[[:space:]]+::ffff:0:0\/96/d' /etc/gai.conf
    {
        echo ""
        echo "# >>> IPv4 preferred (added by ${SCRIPT_NAME} $(date '+%F %T'))"
        echo "precedence ::ffff:0:0/96  100"
    } >> /etc/gai.conf

    # 调整 /etc/hosts 顺序：IPv4 记录前移，IPv6 后置
    if [ -f /etc/hosts ]; then
        awk 'BEGIN{rest="";v6=""}
             /^::1/{v6=v6 $0 ORS; next}
             /^fe80|^ff0|^2[0-9a-fA-F][0-9a-fA-F]*:/{v6=v6 $0 ORS; next}
             {rest=rest $0 ORS}
             END{printf "%s%s", rest, v6}' /etc/hosts > /etc/hosts.new
        if [ -s /etc/hosts.new ]; then
            cat /etc/hosts.new > /etc/hosts
            chmod 644 /etc/hosts
        fi
        rm -f /etc/hosts.new
        info "已调整 /etc/hosts 中 IPv4 记录顺序"
    fi

    ok "IPv4 解析优先已启用（立即生效）"
    echo "  生效内容:"
    grep -nE '^[[:space:]]*precedence' /etc/gai.conf | sed 's/^/    /'
    echo
    echo "  验证命令: getent ahosts example.com | head"
    getent ahosts example.com 2>/dev/null | head -4 | sed 's/^/    /'
    log "已启用 IPv4 解析优先"
}

#------------------------------------------------------------------------------
# 3. 配置 DNS 并锁定 resolv.conf
#------------------------------------------------------------------------------
DNS_CONTENT='nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888'

menu_dns() {
    title "3. 配置 DNS 并锁定 resolv.conf"
    while true; do
        echo
        echo "  当前 /etc/resolv.conf:"
        if [ -L /etc/resolv.conf ]; then
            echo "    ${C_YELL}(符号链接 → $(readlink -f /etc/resolv.conf))${C_RESET}"
        fi
        sed 's/^/    /' /etc/resolv.conf 2>/dev/null || echo "    (文件不存在)"

        local lock_state="未锁定"
        if have lsattr && [ -e /etc/resolv.conf ]; then
            lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i' \
                && lock_state="${C_GREEN}已锁定 (immutable)${C_RESET}"
        elif ! have lsattr; then
            lock_state="未知 (缺少 lsattr/e2fsprogs)"
        fi
        echo "  锁定状态: ${lock_state}"
        echo "  备份目录: ${BACKUP_DIR}"
        echo
        echo "  ${C_BOLD}[1]${C_RESET} 写入预设 DNS 并锁定"
        echo "  ${C_BOLD}[2]${C_RESET} 解锁 resolv.conf"
        echo "  ${C_BOLD}[3]${C_RESET} 测试当前 DNS 连通性"
        echo "  ${C_BOLD}[0]${C_RESET} 返回主菜单"
        echo
        read -r -p "${C_CYAN}请选择: ${C_RESET}" c
        case "$c" in
            1) dns_apply ;;
            2) dns_unlock ;;
            3) dns_test ;;
            0|"") return 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

dns_apply() {
    echo
    echo "  将写入以下 DNS:"
    echo "$DNS_CONTENT" | sed 's/^/    /'
    if ! confirm "确认写入并锁定 /etc/resolv.conf ?"; then
        info "已取消"; return 0
    fi

    backup_file /etc/resolv.conf

    if [ -L /etc/resolv.conf ]; then
        local target
        target="$(readlink -f /etc/resolv.conf)"
        case "$target" in
            */run/systemd/resolve/*|*/run/NetworkManager/*|*/run/resolvconf/*)
                warn "检测到 ${target} 由服务托管，将替换为静态文件"
                if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
                    if confirm "同时禁用 systemd-resolved 以防其重新接管 DNS ?"; then
                        systemctl disable --now systemd-resolved 2>/dev/null \
                            && ok "systemd-resolved 已停用" \
                            || warn "停用 systemd-resolved 失败"
                    fi
                fi
                rm -f /etc/resolv.conf ;;
            *) rm -f /etc/resolv.conf ;;
        esac
    fi

    have chattr && chattr -i /etc/resolv.conf 2>/dev/null

    printf '%s\n' "$DNS_CONTENT" > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    ok "DNS 已写入"

    if have chattr; then
        if chattr +i /etc/resolv.conf 2>/dev/null; then
            ok "已锁定 (chattr +i)"
            lsattr /etc/resolv.conf 2>/dev/null | sed 's/^/    /'
        else
            warn "chattr +i 失败（文件系统可能不支持 immutable）"
            dns_fallback_watch
        fi
    else
        warn "未安装 e2fsprogs (chattr)，无法锁定"
        echo "    安装命令: apt-get install -y e2fsprogs"
        dns_fallback_watch
    fi

    log "DNS 已配置并锁定"
    echo
    dns_test
}

dns_fallback_watch() {
    if ! have systemctl; then
        warn "无 systemd，跳过守护配置"; return 0
    fi
    printf '%s\n' "$DNS_CONTENT" > /etc/resolv.conf.locked
    chmod 644 /etc/resolv.conf.locked
    cat > /etc/systemd/system/resolvconf-guard.service <<'EOF'
[Unit]
Description=Guard /etc/resolv.conf content

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'cmp -s /etc/resolv.conf.locked /etc/resolv.conf || { chattr -i /etc/resolv.conf 2>/dev/null; cp /etc/resolv.conf.locked /etc/resolv.conf; chmod 644 /etc/resolv.conf; }'
EOF
    cat > /etc/systemd/system/resolvconf-guard.timer <<'EOF'
[Unit]
Description=Periodically restore /etc/resolv.conf

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now resolvconf-guard.timer 2>/dev/null \
        && ok "已启用 resolvconf-guard.timer 作为锁定替代方案" \
        || warn "守护定时器启用失败"
}

dns_unlock() {
    [ -e /etc/resolv.conf ] || { warn "文件不存在"; return 0; }
    if have chattr; then
        chattr -i /etc/resolv.conf 2>/dev/null && ok "已解锁 (chattr -i)" || warn "解锁失败或原本未锁定"
        lsattr /etc/resolv.conf 2>/dev/null | sed 's/^/    /'
    else
        warn "缺少 chattr 命令"
    fi
    if [ -f /etc/systemd/system/resolvconf-guard.timer ]; then
        systemctl disable --now resolvconf-guard.timer 2>/dev/null
        rm -f /etc/systemd/system/resolvconf-guard.service /etc/systemd/system/resolvconf-guard.timer
        rm -f /etc/resolv.conf.locked
        systemctl daemon-reload
        ok "已移除 resolvconf-guard 守护"
    fi
    log "resolv.conf 已解锁"
}

dns_test() {
    echo
    echo "  DNS 连通性测试:"
    local d t flag
    for d in 1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888; do
        if have ping; then
            flag="-4"; [[ "$d" == *:* ]] && flag="-6"
            if ping $flag -c 1 -W 3 "$d" >/dev/null 2>&1; then
                t=$(ping $flag -c 1 -W 3 "$d" 2>/dev/null | awk -F'=' '/time=/{print $NF; exit}')
                printf "    ${C_GREEN}✓${C_RESET} %-28s 可达  %s\n" "$d" "${t:-}"
            else
                printf "    ${C_RED}✗${C_RESET} %-28s 不可达\n" "$d"
            fi
        else
            printf "    ${C_YELL}?${C_RESET} %-28s (缺少 ping)\n" "$d"
        fi
    done
    echo
    echo "  域名解析测试:"
    if have getent; then
        getent ahostsv4 example.com >/dev/null 2>&1 \
            && echo "    ${C_GREEN}✓${C_RESET} IPv4 解析正常: $(getent ahostsv4 example.com | awk '{print $1; exit}')" \
            || echo "    ${C_RED}✗${C_RESET} IPv4 解析失败"
        getent ahostsv6 example.com >/dev/null 2>&1 \
            && echo "    ${C_GREEN}✓${C_RESET} IPv6 解析正常: $(getent ahostsv6 example.com | awk '{print $1; exit}')" \
            || echo "    ${C_YELL}!${C_RESET} IPv6 解析失败（无 IPv6 网络属正常）"
    else
        echo "    (缺少 getent，跳过)"
    fi
}

#------------------------------------------------------------------------------
# 4. 交换分区 (Swap) 管理
#------------------------------------------------------------------------------
menu_swap() {
    title "4. 交换分区 (Swap) 管理"
    # [v1.1] 虚拟化预警
    if [ "$VIRT_TYPE" = "openvz" ]; then
        warn "当前为 OpenVZ 环境，swap 操作通常不被支持，可能失败"
    fi

    while true; do
        echo
        echo "  内存概况:"
        free -h 2>/dev/null | sed 's/^/    /'
        echo
        echo "  当前 Swap 设备:"
        if swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings 2>/dev/null | grep -q .; then
            printf "    %-24s %-8s %-8s %-8s %-6s\n" "设备" "类型" "大小" "已用" "优先级"
            swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings 2>/dev/null \
                | awk '{printf "    %-24s %-8s %-8s %-8s %-6s\n",$1,$2,$3,$4,$5}'
        else
            echo "    ${C_YELL}(无已启用的 swap)${C_RESET}"
        fi
        echo
        echo "  /etc/fstab 中的 swap 条目:"
        # [FIX 2] 避免 grep|sed 掩盖 grep 的失败
        if grep -qE '\sswap\s|swapfile' /etc/fstab 2>/dev/null; then
            grep -nE '\sswap\s|swapfile' /etc/fstab | sed 's/^/    /'
        else
            echo "    (无)"
        fi
        echo
        echo "  vm.swappiness = $(cat /proc/sys/vm/swappiness 2>/dev/null || echo '未知')"
        echo
        echo "  ${C_BOLD}[1]${C_RESET} 添加 swap 文件"
        echo "  ${C_BOLD}[2]${C_RESET} 添加 swap 分区（已有未挂载的分区/设备）"
        echo "  ${C_BOLD}[3]${C_RESET} 删除 swap（文件或分区）"
        echo "  ${C_BOLD}[4]${C_RESET} 调整 vm.swappiness"
        echo "  ${C_BOLD}[0]${C_RESET} 返回主菜单"
        echo
        read -r -p "${C_CYAN}请选择: ${C_RESET}" c
        case "$c" in
            1) swap_add_file ;;
            2) swap_add_partition ;;
            3) swap_remove ;;
            4) swap_swappiness ;;
            0|"") return 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

swap_add_file() {
    local SIZE_INPUT="${1:-}" SWAPFILE="${2:-}"

    echo
    echo "  磁盘剩余空间:"
    df -h / | sed 's/^/    /'
    echo

    if [ -z "$SIZE_INPUT" ]; then
        read -r -p "${C_CYAN}swap 文件大小 (支持 512M / 2G，默认 1024M): ${C_RESET}" SIZE_INPUT
    fi
    SIZE_INPUT="${SIZE_INPUT:-1024M}"

    # [v1.1] 智能解析大小
    local SIZE_MB
    SIZE_MB="$(parse_size_mb "$SIZE_INPUT")"
    if [ -z "$SIZE_MB" ] || [ "$SIZE_MB" -lt 64 ]; then
        err "大小无效或过小（最小 64MB），输入: ${SIZE_INPUT}"
        return 1
    fi

    if [ -z "$SWAPFILE" ]; then
        read -r -p "${C_CYAN}文件路径 [默认 /swapfile]: ${C_RESET}" SWAPFILE
    fi
    SWAPFILE="${SWAPFILE:-/swapfile}"

    # [FIX 4] 绝对路径校验
    if [[ "$SWAPFILE" != /* ]]; then
        err "请使用绝对路径（如 /swapfile），当前输入: ${SWAPFILE}"
        return 1
    fi

    local avail_kb
    avail_kb=$(df -Pk "$(dirname "$SWAPFILE")" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$avail_kb" ] && [ "$((SIZE_MB * 1024))" -gt "$avail_kb" ]; then
        err "空间不足：需要 ${SIZE_MB}MB，可用 $((avail_kb / 1024))MB"
        return 1
    fi
    if [ -e "$SWAPFILE" ]; then
        err "${SWAPFILE} 已存在，请先删除或换路径"
        return 1
    fi

    # 虚拟化环境二次确认（OpenVZ 等）
    virt_warn_for "添加 swap 文件" || return 0

    confirm "确认创建 ${SIZE_MB}MB (${SIZE_INPUT}) 的 swap 文件 ${SWAPFILE} ?" || { info "已取消"; return 0; }

    info "分配空间 (${SIZE_MB}MB)..."
    if ! fallocate -l "${SIZE_MB}M" "$SWAPFILE" 2>/dev/null; then
        warn "fallocate 不可用（btrfs 等），改用 dd，速度较慢"
        dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SIZE_MB" status=progress 2>/dev/null \
            || dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SIZE_MB"
    fi
    [ -s "$SWAPFILE" ] || { err "文件创建失败"; rm -f "$SWAPFILE"; return 1; }

    chmod 600 "$SWAPFILE"
    ok "权限已设为 600"

    mkswap "$SWAPFILE" >/dev/null 2>&1 || { err "mkswap 失败"; rm -f "$SWAPFILE"; return 1; }
    ok "已格式化"

    if swapon "$SWAPFILE" 2>/dev/null; then
        ok "已启用 swap"
    else
        err "swapon 失败，常见原因："
        echo "    - 文件系统不支持（btrfs 需在目标目录 chattr +C 后用 dd 重建）"
        echo "    - 文件含空洞：删除后用 dd 重新生成"
        rm -f "$SWAPFILE"
        return 1
    fi

    # [FIX 6] awk 按字段精确匹配
    if ! awk -v f="$SWAPFILE" '!/^[[:space:]]*#/ && $1==f {found=1} END{exit !found}' /etc/fstab 2>/dev/null; then
        backup_file /etc/fstab
        echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
        ok "已写入 /etc/fstab"
    else
        info "/etc/fstab 已存在该条目，跳过"
    fi

    # [FIX] 不覆盖已有 99-swap.conf（尊重用户 swappiness 设置）
    mkdir -p /etc/sysctl.d
    if [ -f /etc/sysctl.d/99-swap.conf ]; then
        info "/etc/sysctl.d/99-swap.conf 已存在，保留现有配置"
    else
        cat > /etc/sysctl.d/99-swap.conf <<'EOF'
# Swap 调优 (由 Linux 运维工具合集 写入)
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 0
EOF
        sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null 2>&1
        ok "已写入 /etc/sysctl.d/99-swap.conf 并应用"
    fi

    echo
    ok "swap 添加完成"
    free -h | sed 's/^/    /'
    log "添加 swap 文件 ${SWAPFILE} ${SIZE_MB}MB"
}

swap_add_partition() {
    echo
    echo "  可用块设备:"
    if have lsblk; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | sed 's/^/    /'
    else
        fdisk -l 2>/dev/null | grep -E '^/dev/' | sed 's/^/    /'
    fi
    echo
    read -r -p "${C_CYAN}请输入要作为 swap 的设备路径 (如 /dev/sdb1): ${C_RESET}" DEV
    if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
        err "无效设备: ${DEV:-空}"; return 1
    fi
    if findmnt -S "$DEV" >/dev/null 2>&1; then
        err "该设备已挂载，请先卸载"; return 1
    fi
    local fstype
    fstype=$(lsblk -no FSTYPE "$DEV" 2>/dev/null || echo "")
    echo
    warn "即将 ${C_RED}格式化${C_RESET} ${DEV}，当前文件系统: ${fstype:-未知}"
    if ! confirm "该操作会${C_RED}永久清除${C_RESET}设备上所有数据，确认继续?"; then
        info "已取消"; return 0
    fi

    mkswap "$DEV" || { err "mkswap 失败"; return 1; }
    swapon "$DEV" && ok "已启用 swap 分区 ${DEV}" || { err "swapon 失败"; return 1; }

    local uuid
    uuid=$(blkid -s UUID -o value "$DEV" 2>/dev/null)
    if [ -n "$uuid" ]; then
        backup_file /etc/fstab
        grep -qE "^[^#]*UUID=${uuid}\b" /etc/fstab 2>/dev/null \
            || echo "UUID=${uuid} none swap sw 0 0" >> /etc/fstab
        ok "已按 UUID 写入 /etc/fstab: ${uuid}"
    else
        warn "无法获取 UUID，请手动添加: ${DEV} none swap sw 0 0"
    fi
    free -h | sed 's/^/    /'
    log "添加 swap 分区 ${DEV}"
}

# [v1.1] 支持直接指定目标（命令行模式），无参数则交互选择
swap_remove() {
    local target="${1:-}"

    if [ -z "$target" ]; then
        local entries=()
        while IFS= read -r line; do
            [ -n "$line" ] && entries+=("$line")
        done < <(swapon --show=NAME --noheadings 2>/dev/null)

        if [ "${#entries[@]}" -eq 0 ]; then
            warn "当前没有已启用的 swap"; return 0
        fi

        echo "  可删除的 swap:"
        local i=1
        for e in "${entries[@]}"; do
            local sz ty
            sz=$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | awk -v n="$e" '$1==n{print $2}')
            ty=$([ -b "$e" ] && echo "分区" || echo "文件")
            echo "    ${C_BOLD}[${i}]${C_RESET} ${e}  (${ty}, ${sz})"
            i=$((i + 1))
        done
        echo
        read -r -p "${C_CYAN}请输入编号: ${C_RESET}" idx
        if ! is_num "$idx" || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#entries[@]}" ]; then
            err "无效编号"; return 1
        fi
        target="${entries[$((idx - 1))]}"
    fi

    # 校验目标确实是已启用的 swap
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$target"; then
        err "该设备/文件未启用为 swap: ${target}"
        return 1
    fi

    echo
    warn "目标: ${target}"
    if ! confirm "确认关闭并移除该 swap?"; then
        info "已取消"; return 0
    fi

    swapoff "$target" && ok "已关闭 ${target}" \
        || { err "swapoff 失败（内存不足时无法回迁）"; return 1; }

    backup_file /etc/fstab
    # [FIX 6] awk 按路径或 UUID 精确删除
    if grep -qF "$target" /etc/fstab 2>/dev/null; then
        awk -v t="$target" '
            /^[[:space:]]*#/ { print; next }
            index($0, t) && /[[:space:]]swap[[:space:]]/ { next }
            { print }
        ' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
        chmod 644 /etc/fstab
        ok "已从 /etc/fstab 移除 ${target}"
    else
        local u
        u=$(blkid -s UUID -o value "$target" 2>/dev/null)
        if [ -n "$u" ] && grep -q "UUID=${u}" /etc/fstab 2>/dev/null; then
            awk -v u="UUID=${u}" '
                /^[[:space:]]*#/ { print; next }
                index($0, u) && /[[:space:]]swap[[:space:]]/ { next }
                { print }
            ' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
            chmod 644 /etc/fstab
            ok "已从 /etc/fstab 移除 UUID 条目: ${u}"
        else
            info "/etc/fstab 中未发现对应条目"
        fi
    fi

    if [ -f "$target" ]; then
        if confirm "是否删除 swap 文件 ${target} 以释放磁盘空间?"; then
            have chattr && chattr -i "$target" 2>/dev/null
            rm -f "$target" && ok "文件已删除" || err "删除失败"
        else
            info "文件已保留"
        fi
    else
        info "分区保留原样，彻底清除签名可执行: wipefs -a ${target}"
    fi

    free -h | sed 's/^/    /'
    log "移除 swap ${target}"
}

swap_swappiness() {
    local v="${1:-}"
    echo
    echo "  当前 vm.swappiness = $(cat /proc/sys/vm/swappiness 2>/dev/null)"
    echo "  说明: 0-100，值越大越倾向使用 swap。服务器常用 10，桌面常用 60。"
    if [ -z "$v" ]; then
        read -r -p "${C_CYAN}请输入新值 (0-100): ${C_RESET}" v
    fi
    if ! is_num "$v" || [ "$v" -gt 100 ]; then
        err "请输入 0-100 的整数"; return 1
    fi
    mkdir -p /etc/sysctl.d
    if [ -f /etc/sysctl.d/99-swap.conf ]; then
        sed -i -E "s/^vm\.swappiness.*/vm.swappiness = ${v}/" /etc/sysctl.d/99-swap.conf
        grep -q '^vm.swappiness' /etc/sysctl.d/99-swap.conf \
            || echo "vm.swappiness = ${v}" >> /etc/sysctl.d/99-swap.conf
    else
        echo "vm.swappiness = ${v}" > /etc/sysctl.d/99-swap.conf
    fi
    sysctl -w "vm.swappiness=${v}" >/dev/null 2>&1
    ok "已设置并持久化（当前值: $(cat /proc/sys/vm/swappiness)）"
    log "vm.swappiness -> ${v}"
}

#------------------------------------------------------------------------------
# 5. 启用 TCP BBR 拥塞控制
#------------------------------------------------------------------------------
do_bbr() {
    title "5. 启用 TCP BBR 拥塞控制"

    echo "  内核版本  : ${KERNEL}"
    echo "  当前算法  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo "  当前 qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
    echo "  可用算法  : $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo '未知')"
    echo

    local kMajor kMinor
    kMajor=$(echo "$KERNEL" | cut -d. -f1)
    kMinor=$(echo "$KERNEL" | cut -d. -f2 | grep -oE '^[0-9]+' || echo 0)
    if [ "$kMajor" -lt 4 ] || { [ "$kMajor" -eq 4 ] && [ "$kMinor" -lt 9 ]; }; then
        err "内核 ${KERNEL} 过低，BBR 需要 >= 4.9"
        return 1
    fi

    # [v1.1] 融合 bbr-enable.sh: modprobe -n 预检内核是否支持
    if ! modprobe -n tcp_bbr >/dev/null 2>&1; then
        err "当前内核模块池中没有 tcp_bbr，无法启用 BBR"
        echo "    Debian 13 默认内核 6.x 已原生支持；如为自定义内核请重新编译"
        return 1
    fi
    info "内核模块 tcp_bbr 可用"

    local cur
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$cur" = "bbr" ]; then
        ok "TCP BBR 已处于启用状态"
        if ! confirm "是否仍要重写配置文件以确保重启后生效?"; then
            return 0
        fi
    fi

    virt_warn_for "启用 BBR" || return 0

    if ! confirm "是否启用 TCP BBR?"; then
        info "已取消"; return 0
    fi

    # 加载模块
    if [ ! -d /sys/module/tcp_bbr ]; then
        modprobe tcp_bbr 2>/dev/null && ok "已加载 tcp_bbr 模块" \
            || warn "modprobe tcp_bbr 失败（可能已内置于内核）"
    else
        info "tcp_bbr 模块已加载"
    fi
    grep -qs '^tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null || {
        mkdir -p /etc/modules-load.d
        echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf
        ok "已写入 /etc/modules-load.d/bbr.conf"
    }

    mkdir -p /etc/sysctl.d
    backup_file /etc/sysctl.d/99-bbr.conf
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
#==============================================================================
# TCP BBR + FQ 网络加速配置
# 写入位置: /etc/sysctl.d/99-bbr.conf
# 由 ${SCRIPT_NAME} v${VERSION} 于 $(date '+%F %T') 生成
#==============================================================================

# --- BBR 核心 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 连接队列与 backlog ---
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

# --- TIME_WAIT 复用 ---
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 262144

# --- Keepalive ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10

# --- 缓冲区 ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 786432 1048576 1572864

# --- 其他优化 ---
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 1024 65535
EOF
    ok "已写入 /etc/sysctl.d/99-bbr.conf"

    # 清理旧位置的历史配置
    if [ -f /etc/sysctl.conf ] && grep -qE '^\s*net\.ipv4\.tcp_congestion_control' /etc/sysctl.conf; then
        backup_file /etc/sysctl.conf
        sed -i -E '/^\s*net\.ipv4\.tcp_congestion_control/d; /^\s*net\.core\.default_qdisc/d' /etc/sysctl.conf
        warn "已清理 /etc/sysctl.conf 中的旧 BBR 配置"
    fi

    info "应用配置中..."
    if sysctl --system >/dev/null 2>&1; then
        ok "sysctl --system 执行完成"
    else
        warn "sysctl --system 有告警，逐项应用关键参数"
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    fi

    echo
    title "验证结果"
    local nowAlgo nowQdisc
    nowAlgo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    nowQdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    printf "  %-32s %s\n" "net.ipv4.tcp_congestion_control" "$nowAlgo"
    printf "  %-32s %s\n" "net.core.default_qdisc" "$nowQdisc"
    printf "  %-32s %s\n" "tcp_bbr 模块" "$(lsmod 2>/dev/null | awk '/^tcp_bbr/{print "已加载 (refcnt "$3")"; f=1} END{if(!f) print "内置/未加载"}')"
    echo "  可用算法: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"

    if [ "$nowAlgo" = "bbr" ] && [ "$nowQdisc" = "fq" ]; then
        echo
        ok "TCP BBR 启用成功，配置已持久化"
    elif [ "$nowAlgo" = "bbr" ]; then
        echo
        warn "BBR 已启用，qdisc 为 ${nowQdisc}（尝试加载 sch_fq）"
        modprobe sch_fq 2>/dev/null && sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
        echo "  当前 qdisc: $(sysctl -n net.core.default_qdisc)"
    else
        echo
        err "BBR 未生效，请检查:"
        echo "    1) lsmod | grep bbr        → 模块是否加载"
        echo "    2) uname -r                → 内核是否 >= 4.9"
        echo "    3) 是否为 OpenVZ/LXC 容器 → 不支持自定义拥塞算法"
        echo "    4) dmesg | tail -20        → 内核报错"
    fi
    log "BBR 配置完成，当前算法: ${nowAlgo}"
}

#------------------------------------------------------------------------------
# 6. 更新脚本
#------------------------------------------------------------------------------
menu_update() {
    title "6. 更新 ${SCRIPT_NAME}"

    echo "  当前版本 : v${VERSION}"
    echo "  当前路径 : ${SELF_PATH}"
    echo "  更新源   : ${UPDATE_URL}"
    echo

    if ! have curl && ! have wget; then
        err "未找到 curl 或 wget，无法下载更新"
        echo "    安装: apt-get update && apt-get install -y curl"
        return 1
    fi

    local tmp_new
    tmp_new="$(mktemp /tmp/linux-tools-new.XXXXXX.sh)"
    info "正在拉取最新版本（强制绕过缓存）..."

    local nocache="t=$(date +%s%N)"
    local ok_dl=0
    if have curl; then
        if curl -fsSL --connect-timeout 15 --max-time 120 --retry 2 \
                -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
                -o "$tmp_new" "${UPDATE_URL}?${nocache}" 2>/dev/null; then
            ok_dl=1
        elif curl -fsSL --connect-timeout 15 --max-time 120 \
                -H 'Cache-Control: no-cache' \
                -o "$tmp_new" "${UPDATE_URL}" 2>/dev/null; then
            ok_dl=1; warn "带随机参数失败，已回退"
        fi
    fi
    if [ "$ok_dl" -ne 1 ] && have wget; then
        if wget -q --no-cache --timeout=15 --tries=2 -O "$tmp_new" "${UPDATE_URL}?${nocache}" 2>/dev/null \
           || wget -q --no-cache --timeout=15 -O "$tmp_new" "${UPDATE_URL}" 2>/dev/null; then
            ok_dl=1
        fi
    fi

    if [ "$ok_dl" -ne 1 ] || [ ! -s "$tmp_new" ]; then
        rm -f "$tmp_new"
        err "下载失败，请检查网络 / DNS / GitHub 可达性"
        echo "    手动测试: curl -fsSLI '${UPDATE_URL}'"
        return 1
    fi

    local size newVer
    size=$(wc -c < "$tmp_new")
    newVer=$(grep -m1 -oE 'VERSION="[0-9][^"]*"' "$tmp_new" | cut -d'"' -f2)
    newVer="${newVer:-未知}"

    echo
    echo "  ${C_BOLD}下载完成，安全校验:${C_RESET}"
    printf "    %-14s %s bytes\n" "文件大小" "$size"
    printf "    %-14s v%s\n" "远端版本" "$newVer"
    printf "    %-14s %s\n" "SHA256" "$(sha256sum "$tmp_new" 2>/dev/null | cut -d' ' -f1)"

    if ! head -1 "$tmp_new" | grep -qE '^#!.*(bash|sh)'; then
        rm -f "$tmp_new"
        err "下载内容不是合法 shell 脚本（首行无 shebang），已中止"
        return 1
    fi
    if [ "$size" -lt 512 ]; then
        rm -f "$tmp_new"
        err "文件过小 (${size} bytes)，疑似不完整，已中止"
        return 1
    fi
    if bash -n "$tmp_new" 2>/dev/null; then
        printf "    %-14s ${C_GREEN}通过${C_RESET}\n" "语法检查"
    else
        printf "    %-14s ${C_RED}失败${C_RESET}\n" "语法检查"
        bash -n "$tmp_new" 2>&1 | head -5 | sed 's/^/      /'
        rm -f "$tmp_new"
        err "新脚本语法错误，已中止（当前版本不变）"
        return 1
    fi

    if [ "$newVer" = "$VERSION" ]; then
        warn "远端版本与本地相同 (v${newVer})"
        if ! confirm "是否仍然强制覆盖安装?"; then
            rm -f "$tmp_new"; info "已取消"; return 0
        fi
    fi

    if have diff && [ -f "$SELF_PATH" ]; then
        echo
        echo "  ${C_BOLD}变更摘要 (diff):${C_RESET}"
        local dl
        dl=$(diff "$SELF_PATH" "$tmp_new" | grep -cE '^[<>]' 2>/dev/null || echo 0)
        echo "    共 ${dl} 行差异，前 25 行预览:"
        diff "$SELF_PATH" "$tmp_new" 2>/dev/null | head -25 | sed 's/^/      /'
        [ "$dl" -gt 25 ] && echo "      ${C_DIM}... (其余 ${dl} 行已省略)${C_RESET}"
    fi

    echo
    warn "${C_BOLD}即将用远端脚本覆盖本地: ${SELF_PATH}${C_RESET}"
    warn "远端代码来自第三方仓库，覆盖后将以 root 权限运行。"
    if ! confirm "确认安装 v${newVer} ?"; then
        rm -f "$tmp_new"; info "已取消"; return 0
    fi

    # [FIX 3] 原子替换
    backup_file "$SELF_PATH"
    local new_tmp="${SELF_PATH}.new"
    if cp "$tmp_new" "$new_tmp" 2>/dev/null \
       && chmod +x "$new_tmp" 2>/dev/null \
       && mv -f "$new_tmp" "$SELF_PATH" 2>/dev/null; then
        ok "更新成功: v${VERSION} → v${newVer}"
        ok "原文件已备份至 ${BACKUP_DIR}"
        log "脚本更新 v${VERSION} -> v${newVer}"
        rm -f "$tmp_new"
        if confirm "是否立即运行新版本?"; then
            echo; info "正在启动新版本..."; sleep 1
            exec bash "$SELF_PATH"
        fi
    else
        cp -f "$tmp_new" "${SELF_PATH}.new" 2>/dev/null
        rm -f "$tmp_new"
        err "无法写入 ${SELF_PATH}"
        echo "    新版本已保存为: ${SELF_PATH}.new"
        echo "    手动替换: mv -f '${SELF_PATH}.new' '${SELF_PATH}' && chmod +x '${SELF_PATH}'"
        return 1
    fi
}

#------------------------------------------------------------------------------
# 系统信息面板
#------------------------------------------------------------------------------
show_sysinfo() {
    echo "${C_DIM}────────────────────────────────────────────────────────${C_RESET}"
    printf "  %-10s %s\n" "系统"   "${OS_PRETTY}"
    printf "  %-10s %s\n" "内核"   "${KERNEL}"
    printf "  %-10s %s\n" "虚拟化" "${VIRT_TYPE}"
    printf "  %-10s %s\n" "主机名" "$(hostname)"
    printf "  %-10s %s\n" "IP"     "$(hostname -I 2>/dev/null | awk '{print $1}' || echo '未知')"
    printf "  %-10s %s\n" "运行"   "$(uptime -p 2>/dev/null || uptime | sed 's/.*up/up/')"
    printf "  %-10s %s %s\n" "拥塞算法" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" \
                                  "$( [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] && echo "${C_GREEN}(BBR ✓)${C_RESET}" )"
    printf "  %-10s %s\n" "Swap"   "$(free -h 2>/dev/null | awk '/^Swap:/{print $3" / "$2}')"

    # [v1.1] DNS 锁状态更准确
    local dns_lock="未知"
    if have lsattr && [ -e /etc/resolv.conf ]; then
        if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q i; then
            dns_lock="已锁定"
        else
            dns_lock="未锁定"
        fi
    fi
    printf "  %-10s %s\n" "DNS锁" "$dns_lock"
    echo "${C_DIM}────────────────────────────────────────────────────────${C_RESET}"
}

#------------------------------------------------------------------------------
# 命令行模式
#------------------------------------------------------------------------------
show_help() {
    cat <<EOF
${SCRIPT_NAME} v${VERSION}

用法:
  bash $(basename "$SELF_PATH")                       进入交互菜单
  bash $(basename "$SELF_PATH") <子命令> [参数...]    非交互执行（适合自动化）

子命令:
  hostname <新主机名>          修改主机名并同步 /etc/hosts
  ipv4-first                   设置 IPv4 解析优先
  dns apply                    写入预设 DNS 并锁定 /etc/resolv.conf
  dns unlock                   解锁 /etc/resolv.conf
  dns test                     测试 DNS 连通性
  swap-list                    列出当前 swap
  swap-add <大小> [路径]       添加 swap 文件，如 swap-add 2G /swapfile
                               大小支持 512M / 2G / 1024（纯数字视为 MB）
  swap-remove <路径|设备>      移除指定 swap
  swap-swappiness <0-100>      设置 vm.swappiness
  bbr                          启用 TCP BBR 拥塞控制
  update                       更新脚本到最新版本
  info                         显示系统信息
  help                         显示本帮助

示例:
  bash $(basename "$SELF_PATH") hostname web01
  bash $(basename "$SELF_PATH") swap-add 2G
  bash $(basename "$SELF_PATH") swap-remove /swapfile
  bash $(basename "$SELF_PATH") dns apply
  bash $(basename "$SELF_PATH") bbr
EOF
}

cmd_swap_list() {
    local rows
    rows=$(swapon --show=NAME,TYPE,SIZE,USED,PRIO --noheadings 2>/dev/null)
    if [ -z "$rows" ]; then
        echo "无已启用的 swap"
        return 0
    fi
    printf "%-24s %-8s %-8s %-8s %-6s\n" "设备" "类型" "大小" "已用" "优先级"
    printf '%s\n' "$rows" | awk '{printf "%-24s %-8s %-8s %-8s %-6s\n",$1,$2,$3,$4,$5}'
}

cmd_dispatch() {
    local cmd="$1"; shift
    # 命令行模式默认自动确认（危险操作已通过"目标必须存在/已启用"校验）
    ASSUME_YES=1

    case "$cmd" in
        hostname)
            [ -n "${1:-}" ] || { err "用法: hostname <新主机名>"; exit 1; }
            do_hostname "$1"
            ;;
        ipv4-first)
            do_ipv4_first
            ;;
        dns)
            case "${1:-}" in
                apply)  dns_apply ;;
                unlock) dns_unlock ;;
                test)   dns_test ;;
                *) err "用法: dns apply|unlock|test"; exit 1 ;;
            esac
            ;;
        swap-list)
            cmd_swap_list
            ;;
        swap-add)
            [ -n "${1:-}" ] || { err "用法: swap-add <大小> [路径]，如 swap-add 2G"; exit 1; }
            swap_add_file "$1" "${2:-}"
            ;;
        swap-remove)
            [ -n "${1:-}" ] || { err "用法: swap-remove <路径|设备>"; exit 1; }
            swap_remove "$1"
            ;;
        swap-swappiness)
            [ -n "${1:-}" ] || { err "用法: swap-swappiness <0-100>"; exit 1; }
            swap_swappiness "$1"
            ;;
        bbr)
            do_bbr
            ;;
        update)
            menu_update
            ;;
        info)
            show_sysinfo
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            err "未知子命令: ${cmd}"
            show_help
            exit 1
            ;;
    esac
}

#------------------------------------------------------------------------------
# 主菜单
#------------------------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033c'
        echo
        echo "  ${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════╗${C_RESET}"
        echo "  ${C_BOLD}${C_CYAN}║${C_RESET}     ${C_BOLD}Linux 运维工具合集  v${VERSION}${C_RESET}                     ${C_BOLD}${C_CYAN}║${C_RESET}"
        echo "  ${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════╝${C_RESET}"
        show_sysinfo
        echo
        echo "    ${C_BOLD}${C_GREEN}1${C_RESET})  修改主机名并同步 hosts"
        echo "    ${C_BOLD}${C_GREEN}2${C_RESET})  设置 IPv4 解析优先"
        echo "    ${C_BOLD}${C_GREEN}3${C_RESET})  配置 DNS 并锁定 resolv.conf"
        echo "    ${C_BOLD}${C_GREEN}4${C_RESET})  交换分区添加/删除管理"
        echo "    ${C_BOLD}${C_GREEN}5${C_RESET})  启用 TCP BBR 拥塞控制"
        echo "    ${C_BOLD}${C_GREEN}6${C_RESET})  更新 ${SCRIPT_NAME}"
        echo
        echo "    ${C_BOLD}${C_RED}0${C_RESET})  退出"
        echo
        read -r -p "  ${C_CYAN}请选择操作 [0-6]: ${C_RESET}" choice
        case "$choice" in
            1) do_hostname;    pause ;;
            2) do_ipv4_first;  pause ;;
            3) menu_dns ;;
            4) menu_swap ;;
            5) do_bbr;         pause ;;
            6) menu_update;    pause ;;
            0|q|Q|exit)
                echo
                info "日志已保存至: ${LOG_FILE}"
                info "配置备份位于: ${BACKUP_DIR}"
                ok "再见"
                log "==== 脚本退出 ===="
                exit 0
                ;;
            "") ;;
            *) warn "无效选项: ${choice}"; sleep 1 ;;
        esac
    done
}

#------------------------------------------------------------------------------
# 入口
#------------------------------------------------------------------------------
trap 'echo; err "脚本被中断"; log "中断退出"; exit 130' INT

preflight

if [ $# -eq 0 ]; then
    main_menu
else
    cmd_dispatch "$@"
    exit $?
fi