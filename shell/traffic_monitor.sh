#!/usr/bin/env bash
# ==============================================================================
# Telegram 流量监控与自动化预警助手 (traffic_monitor.sh)
# Repository Path: DarkerLab/tools/main/shell/traffic_monitor.sh
# ==============================================================================

set -u

# ------------------------------------------------------------------------------
# 基础配置与全局常量
# ------------------------------------------------------------------------------
CONFIG_FILE="/etc/traffic_monitor.conf"
SCRIPT_PATH="/usr/local/bin/traffic_monitor.sh"
ALIAS_PATH="/usr/local/bin/traffic"
export TZ="Asia/Shanghai"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ------------------------------------------------------------------------------
# 辅助函数：权限校验与依赖管理（强制升级到最新 vnstat）
# ------------------------------------------------------------------------------
check_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo "❌ 错误: 请使用 sudo 或 root 权限运行此脚本！"
        exit 1
    fi
}

check_dependencies() {
    local need_pkg=0
    local pkgs=""

    command -v jq >/dev/null 2>&1      || { need_pkg=1; pkgs="$pkgs jq"; }
    command -v curl >/dev/null 2>&1    || { need_pkg=1; pkgs="$pkgs curl"; }
    command -v awk >/dev/null 2>&1     || { need_pkg=1; pkgs="$pkgs gawk"; }
    command -v crontab >/dev/null 2>&1 || { need_pkg=1; pkgs="$pkgs cron"; }

    if [ "$need_pkg" -eq 1 ]; then
        echo "📦 正在自动安装基础依赖:$pkgs ..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y $pkgs >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y epel-release >/dev/null 2>&1 || true
            dnf install -y $pkgs >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release >/dev/null 2>&1 || true
            yum install -y $pkgs >/dev/null 2>&1
        fi
    fi

    # 检查并强制确保安装 vnstat 2.x
    local install_vnstat=0
    if command -v vnstat >/dev/null 2>&1; then
        local vn_ver
        vn_ver=$(vnstat --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo "0.0")
        local main_ver="${vn_ver%%.*}"
        if [ "$main_ver" -lt 2 ]; then
            echo "⚠️ 检测到旧版 vnstat ($vn_ver)，准备更新至最新版 2.x..."
            install_vnstat=1
        fi
    else
        install_vnstat=1
    fi

    if [ "$install_vnstat" -eq 1 ]; then
        echo "📦 正在安装最新版 vnstat 2.x ..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y vnstat >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y epel-release >/dev/null 2>&1 || true
            dnf install -y vnstat >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release >/dev/null 2>&1 || true
            yum install -y vnstat >/dev/null 2>&1
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now vnstat >/dev/null 2>&1 || true
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            if [[ "$key" =~ ^[A-Z_]+$ ]]; then
                value="${value%\"}"
                value="${value#\"}"
                export "$key=$value" 2>/dev/null || true
            fi
        done < <(grep -E '^[A-Z_]+=' "$CONFIG_FILE" 2>/dev/null)
    fi

    BOT_TOKEN="${BOT_TOKEN:-}"
    CHAT_ID="${CHAT_ID:-}"
    SERVER_NAME="${SERVER_NAME:-$(hostname 2>/dev/null || echo 'VPS-Server')}"
    LIMIT_GB="${LIMIT_GB:-1000}"
    ALERT_PCT="${ALERT_PCT:-90}"
    SHUTDOWN_PCT="${SHUTDOWN_PCT:-95}"
    INTERFACE="${INTERFACE:-all}"
    RESET_TZ="${RESET_TZ:-Asia/Shanghai}"
    RESET_DAY="${RESET_DAY:-1}"
}

# ------------------------------------------------------------------------------
# 核心网络/流量统计逻辑（纯基于最新 vnstat 2.x 标准结构）
# ------------------------------------------------------------------------------
escape_html() {
    local str="${1:-}"
    str="${str//&/&amp;}"
    str="${str//</&lt;}"
    str="${str//>/&gt;}"
    echo "$str"
}

send_telegram() {
    local text="${1:-}"
    load_config
    if [ -n "${BOT_TOKEN:-}" ] && [ -n "${CHAT_ID:-}" ]; then
        curl -s -m 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            -d "parse_mode=HTML" \
            --data-urlencode "text=${text}" > /dev/null 2>&1 || true
    fi
}

get_active_interfaces() {
    local ifaces=()
    for sys_path in /sys/class/net/*; do
        [ -e "$sys_path" ] || continue
        local iface
        iface=$(basename "$sys_path")

        if [[ "$iface" =~ ^(lo|docker|veth|br-|cni|flannel) ]]; then
            continue
        fi

        ifaces+=("$iface")
    done

    if [ ${#ifaces[@]} -eq 0 ]; then
        local default_if
        default_if=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
        if [ -n "$default_if" ]; then
            ifaces+=("$default_if")
        fi
    fi

    echo "${ifaces[*]:-}"
}

get_traffic_bytes() {
    local target_ifaces="${1:-all}"
    local query_tz="${RESET_TZ:-Asia/Shanghai}"
    local reset_day="${RESET_DAY:-1}"

    # 简单调用 Add 建立记录（已包含数据自动同步机制）
    vnstat --add >/dev/null 2>&1 || true

    local json_data
    json_data=$(TZ="$query_tz" vnstat --json 2>/dev/null || true)

    if [ -z "$json_data" ]; then
        echo "0"
        return
    fi

    local cur_y cur_m cur_d
    cur_y=$(TZ="$query_tz" date '+%Y')
    cur_m=$(TZ="$query_tz" date '+%-m')
    cur_d=$(TZ="$query_tz" date '+%-d')

    # 计算计费周期的起始数值 YYYYMMDD 和结束数值 YYYYMMDD
    local start_num end_num
    end_num=$(( cur_y * 10000 + cur_m * 100 + cur_d ))

    if [ "$reset_day" -eq 1 ]; then
        start_num=$(( cur_y * 10000 + cur_m * 100 + 1 ))
    else
        if [ "$cur_d" -ge "$reset_day" ]; then
            start_num=$(( cur_y * 10000 + cur_m * 100 + reset_day ))
        else
            local prev_y prev_m
            prev_y=$(TZ="$query_tz" date -d "1 month ago" '+%Y')
            prev_m=$(TZ="$query_tz" date -d "1 month ago" '+%-m')
            start_num=$(( prev_y * 10000 + prev_m * 100 + reset_day ))
        fi
    fi

    # 直接使用最新 vnstat 2.x 的 .traffic.day 标准数字字段算总和
    local total_bytes
    total_bytes=$(echo "$json_data" | jq -r \
        --argjson start "$start_num" \
        --argjson end "$end_num" \
        --arg target "$target_ifaces" '
        [
            .interfaces[]?
            | select($target == "all" or .id == $target or .name ==$target)
            | .traffic.day[]?
            | select(
                ((.date.year * 10000) + (.date.month * 100) + .date.day) >= $start and
                ((.date.year * 10000) + (.date.month * 100) + .date.day) <= $end
              )
            | (.rx + .tx)
        ] | add // 0
    ' 2>/dev/null)

    # 极简兜底：如果是 1 号且刚安装按天无数据，直接读取当月汇总
    if [ -z "$total_bytes" ] \vert{}\vert{} [ "$total_bytes" -eq 0 ]; then
        if [ "$reset_day" -eq 1 ]; then
            total_bytes=$(echo "$json_data" | jq -r \
                --argjson y "$cur_y" \
                --argjson m "$cur_m" \
                --arg target "$target_ifaces" '
                [
                    .interfaces[]?
                    | select($target == "all" or .id == $target or .name ==$target)
                    | .traffic.month[]?
                    | select(.date.year == $y and .date.month ==$m)
                    | (.rx + .tx)
                ] | add // 0
            ' 2>/dev/null)
        fi
    fi

    [[ "$total_bytes" =~ ^[0-9]+$ ]] || total_bytes=0
    echo "$total_bytes"
}

format_bytes() {
    local bytes=${1:-0}
    echo "$bytes" | awk '{
        if ($1 >= 1099511627776) printf "%.2f TB", $1/1099511627776;
        else if ($1 >= 1073741824) printf "%.2f GB", $1/1073741824;
        else if ($1 >= 1048576) printf "%.2f MB", $1/1048576;
        else printf "%.2f KB", $1/1024;
    }'
}

# ------------------------------------------------------------------------------
# 定时任务管理 & 软链接维护
# ------------------------------------------------------------------------------
sync_script_self() {
    chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    rm -f "$ALIAS_PATH" "/usr/bin/traffic" 2>/dev/null || true
    ln -sf "$SCRIPT_PATH" "$ALIAS_PATH" 2>/dev/null || true
    ln -sf "$SCRIPT_PATH" "/usr/bin/traffic" 2>/dev/null || true
}

setup_cron() {
    sync_script_self
    local tmp_cron
    tmp_cron=$(mktemp)
    
    (crontab -l 2>/dev/null || true) | grep -v "$SCRIPT_PATH" | grep -v "$ALIAS_PATH" \vert{} grep -v "/usr/bin/traffic" > "$tmp_cron" || true

    if ! grep -q "PATH=" "$tmp_cron"; then
        sed -i '1i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$tmp_cron"
    fi

    echo "0 8 * * * $SCRIPT_PATH --daily-report >/dev/null 2>&1" >> "$tmp_cron"
    echo "* * * * * $SCRIPT_PATH --check-threshold >/dev/null 2>&1" >> "$tmp_cron"

    crontab "$tmp_cron" 2>/dev/null
    rm -f "$tmp_cron"
}

# ------------------------------------------------------------------------------
# 业务功能模块
# ------------------------------------------------------------------------------
do_config() {
    check_dependencies
    load_config

    local detected_ifaces
    detected_ifaces=$(get_active_interfaces)

    echo "=========================================="
    echo "       ⚙️ 配置 Telegram 监控参数"
    echo "=========================================="

    read -p "请输入 Telegram Bot Token [当前: ${BOT_TOKEN:-未设置}]: " input_bot
    read -p "请输入 Telegram Chat ID [当前: ${CHAT_ID:-未设置}]: " input_chat
    read -p "请输入服务器名称 (默认: ${SERVER_NAME:-VPS-Server}): " input_name
    read -p "请输入每月流量限制 (GB, 默认: ${LIMIT_GB:-1000}): " input_limit
    read -p "请输入预警阈值百分比 (如 90, 默认: ${ALERT_PCT:-90}): " input_alert
    read -p "请输入自动关机阈值百分比 (如 95, 默认: ${SHUTDOWN_PCT:-95}): " input_shutdown

    echo "------------------------------------------"
    echo "🔍 检测到系统可用网卡为: ${detected_ifaces:-未检测到}"
    read -p "请输入监控网卡 [若检测正确可填 all，或输入具体网卡如 ens3, 默认: all]: " input_iface
    echo "------------------------------------------"

    read -p "请输入每月流量重置日期 (1-28 日, 默认: ${RESET_DAY:-1}): " input_reset_day
    read -p "请输入结算时区 (1: 北京时间 UTC+8, 2: 零时区 UTC, 默认 1): " input_tz

    local new_bot="${input_bot:-$BOT_TOKEN}"
    local new_chat="${input_chat:-$CHAT_ID}"
    local new_name="${input_name:-$SERVER_NAME}"
    local new_limit="${input_limit:-$LIMIT_GB}"
    local new_alert="${input_alert:-$ALERT_PCT}"
    local new_shutdown="${input_shutdown:-$SHUTDOWN_PCT}"
    local new_iface="${input_iface:-$INTERFACE}"
    local new_reset_day="${input_reset_day:-$RESET_DAY}"

    local new_tz="Asia/Shanghai"
    if [ "$input_tz" = "2" ]; then
        new_tz="UTC"
    elif [ -z "$input_tz" ] && [ "${RESET_TZ:-}" = "UTC" ]; then
        new_tz="UTC"
    fi

    cat <<EOF > "$CONFIG_FILE"
BOT_TOKEN="${new_bot}"
CHAT_ID="${new_chat}"
SERVER_NAME="${new_name}"
LIMIT_GB="${new_limit}"
ALERT_PCT="${new_alert}"
SHUTDOWN_PCT="${new_shutdown}"
INTERFACE="${new_iface}"
RESET_TZ="${new_tz}"
RESET_DAY="${new_reset_day}"
EOF

    setup_cron
    echo "=========================================="
    echo "✅ 配置及定时任务已成功保存与同步！"
    echo "💡 提示: 以后可在命令行直接输入 traffic 命令随时唤醒菜单。"
    echo "=========================================="
}

do_status() {
    check_dependencies
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ 尚未进行配置，请先运行选项 1 进行初始化配置。"
        return 1
    fi
    load_config

    local bytes
    bytes=$(get_traffic_bytes "$INTERFACE")
    local formatted_used
    formatted_used=$(format_bytes "$bytes")

    local tz_disp="UTC+8 (北京时间)"
    if [ "${RESET_TZ:-}" = "UTC" ]; then tz_disp="UTC+0 (零时区)"; fi

    echo "=========================================="
    echo "- 服务器名称: $SERVER_NAME"
    echo "- 监控网卡: $INTERFACE"
    echo "- 每月重置日: 每月 ${RESET_DAY:-1} 号"
    echo "- 当前周期用量: $formatted_used / ${LIMIT_GB} GB (结算时区: ${tz_disp})"
    echo "- 预警阈值: ${ALERT_PCT}\% \vert{} 关机阈值: ${SHUTDOWN_PCT}%"
    echo "=========================================="
}

do_check_threshold() {
    check_dependencies
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ 未找到配置文件，请先运行选项 1 进行配置。"
        return 1
    fi
    load_config

    local limit_gb="${LIMIT_GB:-1000}"
    if [ "$limit_gb" -le 0 ] 2>/dev/null; then
        echo "ℹ️ 流量上限设置为 0（无限制），忽略阈值检测。"
        return 0
    fi

    local total_bytes
    total_bytes=$(get_traffic_bytes "$INTERFACE")

    local pct
    pct=$(awk -v bytes="$total_bytes" -v limit_gb="$limit_gb" 'BEGIN {
        if (limit_gb > 0) {
            p = (bytes / (limit_gb * 1073741824)) * 100;
            printf "%.2f", p;
        } else {
            printf "0.00";
        }
    }')

    local alert_pct="${ALERT_PCT:-90}"
    local shutdown_pct="${SHUTDOWN_PCT:-95}"

    local is_alert=0
    local is_shutdown=0

    if awk -v p="$pct" -v s="$shutdown_pct" 'BEGIN { exit !(s > 0 && p >= s) }'; then
        is_shutdown=1
        is_alert=1
    elif awk -v p="$pct" -v a="$alert_pct" 'BEGIN { exit !(a > 0 && p >= a) }'; then
        is_alert=1
    fi

    local flag_alert="/tmp/traffic_alert_sent_multi"
    local flag_shutdown="/tmp/traffic_shutdown_sent_multi"

    local safe_server_name
    safe_server_name=$(escape_html "$SERVER_NAME")
    local safe_interface
    safe_interface=$(escape_html "$INTERFACE")

    if [ "$is_shutdown" -eq 1 ]; then
        if [ ! -f "$flag_shutdown" ]; then
            local formatted_used
            formatted_used=$(format_bytes "$total_bytes")

            local msg="🛑 <b>[流量严重超限 - 自动关机通知]</b>
- 服务器: <code>${safe_server_name}</code>
- 监控网卡: <code>${safe_interface}</code>
- 当前周期用量: <code>${formatted_used}</code> / <code>${limit_gb} GB</code> (${pct}%)
- 重置日: 每月 <code>${RESET_DAY:-1}</code> 号
- 关机阈值: <code>${shutdown_pct}%</code>
⚠️ 流量已达到关机阈值，服务器将在 5 秒后自动关机！"

            send_telegram "$msg"
            touch "$flag_shutdown"
            echo "🛑 流量超限 (${pct}\% >=${shutdown_pct}%)，已发送 TG 通知，5秒后自动关机！"
            sleep 5
            systemctl poweroff || shutdown -h now
            return 0
        fi
    else
