#!/usr/bin/env bash
set -u

CONFIG_FILE="/etc/traffic_monitor.conf"
SCRIPT_PATH="/usr/local/bin/traffic_monitor.sh"
ALIAS_PATH="/usr/local/bin/traffic"
export TZ="Asia/Shanghai"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

check_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo "❌ 错误: 请使用 sudo 或 root 权限运行此脚本！"
        exit 1
    fi
}

check_dependencies() {
    local need_install=0
    local pkgs=""
    command -v vnstat >/dev/null 2>&1 || { need_install=1; pkgs="$pkgs vnstat"; }
    command -v jq >/dev/null 2>&1     || { need_install=1; pkgs="$pkgs jq"; }
    command -v curl >/dev/null 2>&1   || { need_install=1; pkgs="$pkgs curl"; }
    command -v awk >/dev/null 2>&1    || { need_install=1; pkgs="$pkgs gawk"; }
    command -v crontab >/dev/null 2>&1 || { need_install=1; pkgs="$pkgs cron"; }

    if [ "$need_install" -eq 1 ]; then
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
}

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

# 🛠️ 核心修复：精准遍历 JSON 中的所有网卡并安全求和
get_traffic_bytes() {
    local target_ifaces="${1:-all}"
    local query_tz="${RESET_TZ:-Asia/Shanghai}"
    
    local cur_year cur_month
    cur_year=$(TZ="$query_tz" date '+%Y')
    cur_month=$(TZ="$query_tz" date '+%-m')

    local json_data
    json_data=$(TZ="$query_tz" vnstat --json 2>/dev/null || true)

    if [ -z "$json_data" ]; then
        echo "0"
        return
    fi

    # 通过 jq 直接穿透所有 interfaces 数组，把符合当月 (year & month) 的 rx+tx 全加起来
    local total_bytes
    total_bytes=$(echo "$json_data" | jq -r --argjson y "$cur_year" --argjson m "$cur_month" --arg target "$target_ifaces" '
        [
            .interfaces[]?
            | select($target == "all" or .id == $target or .name == $target)
            | (
                (.traffic.month[]? | select(.date.year == $y and .date.month == $m) | (.rx + .tx)),
                (.traffic.months[]? | select(.date.year == $y and .date.month == $m) | (.rx + .tx))
              )
        ] | add // 0
    ' 2>/dev/null)

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
    echo "• 服务器名称: $SERVER_NAME"
    echo "• 监控网卡: $INTERFACE"
    echo "• 当月汇总使用量: $formatted_used / ${LIMIT_GB} GB (结算时区: ${tz_disp})"
    echo "• 原始 Byte 字节数: $bytes"
    echo "• 预警阈值: ${ALERT_PCT}% | 关机阈值: ${SHUTDOWN_PCT}%"
    echo "=========================================="
}

do_check_threshold() {
    check_dependencies
    if [ ! -f "$CONFIG_FILE" ]; then return 1; fi
    load_config

    local limit_gb="${LIMIT_GB:-1000}"
    if [ "$limit_gb" -le 0 ] 2>/dev/null; then return 0; fi

    local total_bytes
    total_bytes=$(get_traffic_bytes "$INTERFACE")

    local pct
    pct=$(awk -v bytes="$total_bytes" -v limit_gb="$limit_gb" 'BEGIN {
        if (limit_gb > 0) {
            p = (bytes / (limit_gb * 1073741824)) * 100;
            printf "%.2f", p;
        } else { printf "0.00"; }
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
- 当月汇总用量: <code>${formatted_used}</code> / <code>${limit_gb} GB</code> (${pct}%)
- 关机阈值: <code>${shutdown_pct}%</code>
⚠️ 流量已达到关机阈值，服务器将在 5 秒后自动关机！"

            send_telegram "$msg"
            touch "$flag_shutdown"
            echo "🛑 流量超限 (${pct}% >= ${shutdown_pct}%)，已发送 TG 通知，5秒后自动关机！"
            sleep 5
            systemctl poweroff || shutdown -h now
            return 0
        fi
    else
        rm -f "$flag_shutdown" 2>/dev/null
    fi

    if [ "$is_alert" -eq 1 ]; then
        if [ ! -f "$flag_alert" ]; then
            local formatted_used
            formatted_used=$(format_bytes "$total_bytes")

            local msg="🚨 <b>[流量用量预警]</b>
- 服务器: <code>${safe_server_name}</code>
- 监控网卡: <code>${safe_interface}</code>
- 当月汇总用量: <code>${formatted_used}</code> / <code>${limit_gb} GB</code> (${pct}%)
- 预警阈值: <code>${alert_pct}%</code>
- 关机阈值: <code>${shutdown_pct}%</code>
⚠️ 已达到设定的流量预警阈值，请注意控制用量！"

            send_telegram "$msg"
            touch "$flag_alert"
            echo "⚠️ 已达到预警阈值 (当前 ${pct}% >= 设定 ${alert_pct}%)，预警消息已发送！"
        else
            echo "ℹ️ 已处于预警状态 (当前 ${pct}%)，不再重复提醒。"
        fi
    else
        rm -f "$flag_alert" 2>/dev/null
        echo "✅ 流量正常（当前汇总已用 ${pct}%，未达到预警阈值 ${alert_pct}%）。"
    fi
}

do_daily_report() {
    check_dependencies
    if [ ! -f "$CONFIG_FILE" ]; then return 1; fi
    load_config

    local tz_disp="UTC+8 (北京时间)"
    if [ "${RESET_TZ:-}" = "UTC" ]; then tz_disp="UTC+0 (零时区)"; fi

    local total_bytes
    total_bytes=$(get_traffic_bytes "$INTERFACE")
    local formatted_used
    formatted_used=$(format_bytes "$total_bytes")

    local limit_gb="${LIMIT_GB:-1000}"
    local pct="无限制"
    if [ "$limit_gb" -gt 0 ] 2>/dev/null; then
        pct=$(awk -v bytes="$total_bytes" -v limit_gb="$limit_gb" 'BEGIN {
            if (limit_gb > 0) {
                p = (bytes / (limit_gb * 1073741824)) * 100;
                printf "%.2f%%", p;
            } else { printf "0.00%%"; }
        }')
    fi

    local safe_server_name
    safe_server_name=$(escape_html "$SERVER_NAME")
    local safe_interface
    safe_interface=$(escape_html "$INTERFACE")

    local current_time
    current_time=$(TZ="Asia/Shanghai" date '+%Y-%m-%d %H:%M:%S')

    local msg="📊 <b>[每日流量日报]</b>
- 服务器: <code>${safe_server_name}</code>
- 监控网卡: <code>${safe_interface}</code>
- 结算时区: <code>${tz_disp}</code>
- 当月汇总用量: <code>${formatted_used}</code> / <code>${limit_gb} GB</code> (已用 ${pct})
- 统计时间: <code>${current_time} (北京时间)</code>"

    send_telegram "$msg"
    echo "✅ 每日流量推送指令已执行！"
}

uninstall() {
    (crontab -l 2>/dev/null || true) | grep -v "$SCRIPT_PATH" | grep -v "$ALIAS_PATH" | grep -v "/usr/bin/traffic" | crontab - 2>/dev/null || true
    rm -f "$CONFIG_FILE" "$SCRIPT_PATH" "$ALIAS_PATH" "/usr/bin/traffic" /tmp/traffic_*_sent_multi 2>/dev/null
    echo "✅ 已彻底卸载监控程序。"
}

check_root

case "${1:-}" in
    --check-threshold) do_check_threshold ;;
    --daily-report) do_daily_report ;;
    --status) do_status ;;
    --uninstall) uninstall ;;
    *)
        echo "=========================================="
        echo "      Telegram 流量监控助手"
        echo "=========================================="
        echo "1. 修改配置"
        echo "2. 测试发送每日流量推送"
        echo "3. 测试运行阈值检测"
        echo "4. 查看当前流量数据"
        echo "5. 卸载监控程序"
        echo "0. 退出"
        echo "=========================================="
        read -p "请输入数字 [0-5]: " choice
        case "${choice:-0}" in
            1)
                echo "请直接运行 /usr/local/bin/traffic 重新配置。"
                ;;
            2) do_daily_report ;;
            3) do_check_threshold ;;
            4) do_status ;;
            5) uninstall ;;
            *) exit 0 ;;
        esac
        ;;
esac
