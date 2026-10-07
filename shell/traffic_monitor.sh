#!/usr/bin/env bash

if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 sudo 或 root 权限运行此脚本！"
    exit 1
fi

CONFIG_FILE="/etc/traffic_monitor.conf"
SCRIPT_PATH="/usr/local/bin/traffic_monitor.sh"
export TZ="Asia/Shanghai"

check_dependencies() {
    local need_install=0
    local pkgs=""

    if ! command -v vnstat >/dev/null 2>&1; then need_install=1; pkgs="$pkgs vnstat"; fi
    if ! command -v jq >/dev/null 2>&1; then need_install=1; pkgs="$pkgs jq"; fi
    if ! command -v curl >/dev/null 2>&1; then need_install=1; pkgs="$pkgs curl"; fi
    if ! command -v awk >/dev/null 2>&1; then need_install=1; pkgs="$pkgs gawk"; fi
    if ! command -v crontab >/dev/null 2>&1; then need_install=1; pkgs="$pkgs cron"; fi

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

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now vnstat >/dev/null 2>&1 || true
    fi
}

send_telegram() {
    local text="$1"
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
            curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d "chat_id=${CHAT_ID}" \
                -d "parse_mode=Markdown" \
                --data-urlencode "text=${text}" > /dev/null 2>&1
        fi
    fi
}

get_traffic_bytes() {
    local ifaces="$1"
    local total_all=0
    local query_tz="${RESET_TZ:-Asia/Shanghai}"

    if [ "$ifaces" = "all" ]; then
        ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")
    fi

    for iface in $ifaces; do
        local json_data
        json_data=$(TZ="$query_tz" vnstat --json m 1 -i "$iface" 2>/dev/null)
        if [ -n "$json_data" ]; then
            local rx tx
            rx=$(echo "$json_data" | jq -r '(.interfaces[0].traffic.month[0].rx // .interfaces[0].traffic.months[0].rx // .interfaces[0].traffic.month[-1].rx // .interfaces[0].traffic.months[-1].rx) // 0' 2>/dev/null)
            tx=$(echo "$json_data" | jq -r '(.interfaces[0].traffic.month[0].tx // .interfaces[0].traffic.months[0].tx // .interfaces[0].traffic.month[-1].tx // .interfaces[0].traffic.months[-1].tx) // 0' 2>/dev/null)
            if [[ ! "$rx" =~ ^[0-9]+$ ]]; then rx=0; fi
            if [[ ! "$tx" =~ ^[0-9]+$ ]]; then tx=0; fi
            total_all=$((total_all + rx + tx))
        fi
    done
    echo "$total_all"
}

format_bytes() {
    local bytes=${1:-0}
    echo "$bytes" | awk '{
        if ($1 >= 1073741824*1024) printf "%.2f TB", $1/1073741824/1024;
        else if ($1 >= 1073741824) printf "%.2f GB", $1/1073741824;
        else if ($1 >= 1048576) printf "%.2f MB", $1/1048576;
        else printf "%.2f KB", $1/1024;
    }'
}

do_status() {
    check_dependencies
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ 尚未进行配置，请先运行选项 1 进行配置。"
        return 1
    fi
    source "$CONFIG_FILE"

    local bytes
    bytes=$(get_traffic_bytes "$INTERFACE")
    local formatted_used
    formatted_used=$(format_bytes "$bytes")

    local tz_disp="UTC+8 (北京时间)"
    if [ "$RESET_TZ" = "UTC" ]; then tz_disp="UTC+0 (零时区)"; fi

    local display_name="${SERVER_NAME:-$(hostname)}"

    local p_sign=$(printf '\x25')
    local pipe_sign=$(printf '\x7c')

    echo "=========================================="
    echo "• 服务器名称: $display_name"
    echo "• 监控网卡: $INTERFACE"
    echo "• 当月汇总使用量: $formatted_used / ${LIMIT_GB} GB (结算时区: ${tz_disp})"
    echo "• 预警阈值: ${ALERT_PCT}${p_sign}${pipe_sign} 关机阈值: ${SHUTDOWN_PCT}${p_sign}"
    echo "=========================================="
}

do_check_threshold() {
    check_dependencies
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ 未找到配置文件，请先运行选项 1 进行配置。"
        return 1
    fi
    source "$CONFIG_FILE"

    LIMIT_GB=${LIMIT_GB:-1000}
    ALERT_PCT=${ALERT_PCT:-90}
    SHUTDOWN_PCT=${SHUTDOWN_PCT:-95}
    INTERFACE=${INTERFACE:-all}
    local display_name="${SERVER_NAME:-$(hostname)}"
    local p_sign=$(printf '\x25')

    if [ "$LIMIT_GB" -le 0 ] 2>/dev/null; then
        echo "ℹ️ 流量上限设置为 0（无限制），忽略阈值检测。"
        return 0
    fi

    local total_bytes
    total_bytes=$(get_traffic_bytes "$INTERFACE")
    
    eval $(LC_ALL=C awk -v bytes="$total_bytes" \
                        -v limit_gb="$LIMIT_GB" \
                        -v alert_pct="$ALERT_PCT" \
                        -v shutdown_pct="$SHUTDOWN_PCT" 'BEGIN {
        used_gb = bytes / 1073741824;
        pct = (limit_gb > 0) ? (used_gb / limit_gb) * 100 : 0;
        is_alert = (pct >= alert_pct) ? 1 : 0;
        is_shutdown = (shutdown_pct > 0 && pct >= shutdown_pct) ? 1 : 0;
        if (pct < 0.01 && pct > 0) {
            printf "pct=\"%.4f\"\nis_alert=%d\nis_shutdown=%d\n", pct, is_alert, is_shutdown;
        } else {
            printf "pct=\"%.2f\"\nis_alert=%d\nis_shutdown=%d\n", pct, is_alert, is_shutdown;
        }
    }')

    local flag_alert="/tmp/traffic_alert_sent_multi"
    local flag_shutdown="/tmp/traffic_shutdown_sent_multi"

    if [ "$is_shutdown" -eq 1 ]; then
        if [ ! -f "$flag_shutdown" ]; then
            local formatted_used
            formatted_used=$(format_bytes "$total_bytes")
            
            local msg="🛑 *[流量严重超限 - 自动关机通知]*
• 服务器: \`${display_name}\`
• 监控网卡: \`${INTERFACE}\`
• 当月汇总用量: \`${formatted_used}\` / \`${LIMIT_GB} GB\` (${pct}${p_sign})
• 关机阈值: \`${SHUTDOWN_PCT}${p_sign}\`
⚠️ 流量已达到关机阈值，服务器将在 5 秒后自动关机！"
            
            send_telegram "$msg"
            touch "$flag_shutdown"
            echo "🛑 流量超限 (${pct}${p_sign} >= ${SHUTDOWN_PCT}${p_sign})，已发送 TG 通知，5秒后自动关机！"
            sleep 5
            systemctl poweroff
            return 0
        fi
    else
        rm -f "$flag_shutdown" 2>/dev/null
    fi

    if [ "$is_alert" -eq 1 ]; then
        if [ ! -f "$flag_alert" ]; then
            local formatted_used
            formatted_used=$(format_bytes "$total_bytes")
            
            local msg="🚨 *[流量用量预警]*
• 服务器: \`${display_name}\`
• 监控网卡: \`${INTERFACE}\`
• 当月汇总用量: \`${formatted_used}\` / \`${LIMIT_GB} GB\` (${pct}${p_sign})
• 预警阈值: \`${ALERT_PCT}${p_sign}\`
• 关机阈值: \`${SHUTDOWN_PCT}${p_sign}\`
⚠️ 已达到设定的流量预警阈值，请注意控制用量！"
            
            send_telegram "$msg"
            touch "$flag_alert"
            echo "⚠️ 已达到预警阈值 (当前 ${pct}${p_sign} >= 设定 ${ALERT_PCT}${p_sign})，预警消息已发送！"
        else
            echo "ℹ️ 已处于预警状态 (当前 ${pct}${p_sign})，不再重复提醒。"
        fi
    else
        rm -f "$flag_alert" 2>/dev/null
        echo "✅ 流量正常（当前汇总已用 ${pct}${p_sign}，未达到预警阈值 ${ALERT_PCT}${p_sign}）。"
    fi
}

do_daily_report() {
    check_dependencies
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ 未找到配置文件，请先运行选项 1 进行配置。"
        return 1
    fi
    source "$CONFIG_FILE"

    INTERFACE=${INTERFACE:-all}
    LIMIT_GB=${LIMIT_GB:-1000}
    RESET_TZ=${RESET_TZ:-Asia/Shanghai}
    local display_name="${SERVER_NAME:-$(hostname)}"
    local p_sign=$(printf '\x25')

    local tz_disp="UTC+8 (北京时间)"
    if [ "$RESET_TZ" = "UTC" ]; then tz_disp="UTC+0 (零时区)"; fi

    local total_bytes
    total_bytes=$(get_traffic_bytes "$INTERFACE")
    local formatted_used
    formatted_used=$(format_bytes "$total_bytes")

    local pct="无限制"
    if [ "$LIMIT_GB" -gt 0 ] 2>/dev/null; then
        pct=$(LC_ALL=C awk -v bytes="$total_bytes" -v limit_gb="$LIMIT_GB" 'BEGIN {
            if (limit_gb > 0) {
                p = (bytes / (limit_gb * 1073741824)) * 100;
                if (p < 0.01 && p > 0) printf "%.4f%%", p;
                else printf "%.2f%%", p;
            } else {
                printf "0.00%%";
            }
        }')
    fi

    local msg="📊 *[每日流量日报]*
• 服务器: \`${display_name}\`
• 监控网卡: \`${INTERFACE}\`
• 结算时区: \`${tz_disp}\`
• 当月汇总用量: \`${formatted_used}\` / \`${LIMIT_GB} GB\` (已用 ${pct})
• 统计时间: \`$(date '+%Y-%m-%d %H:%M:%S') (北京时间)\`"

    send_telegram "$msg"
    echo "✅ 每日流量推送指令已执行！"
}

uninstall() {
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
    rm -f "$CONFIG_FILE"
    rm -f "$SCRIPT_PATH"
    rm -f "/usr/local/bin/traffic"
    rm -f "/usr/bin/traffic"
    echo "✅ 已彻底卸载监控程序、删除配置文件及定时任务。"
}

case "$1" in
    --check-threshold)
        do_check_threshold
        ;;
    --daily-report)
        do_daily_report
        ;;
    --status)
        do_status
        ;;
    --uninstall)
        uninstall
        ;;
    *)
        echo "=========================================="
        echo "      Telegram 流量监控助手"
        echo "=========================================="
        if [ -f "$CONFIG_FILE" ]; then
            echo "1. 修改当前配置 (已检测到现有配置文件)"
        else
            echo "1. 安装 / 初始化配置"
        fi
        echo "2. 测试发送每日流量推送"
        echo "3. 测试运行阈值检测"
        echo "4. 查看当前流量数据"
        echo "5. 卸载监控程序"
        echo "0. 退出"
        echo "=========================================="
        read -p "请输入数字 [0-5]: " choice
        case "$choice" in
            1) /usr/local/bin/traffic_monitor.sh ;;
            2) do_daily_report ;;
            3) do_check_threshold ;;
            4) do_status ;;
            5) uninstall ;;
            *) exit 0 ;;
        esac
        ;;
esac
