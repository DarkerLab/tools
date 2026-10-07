#!/usr/bin/env bash

# 强制脚本运行环境时区为东八区 (北京时间)
export TZ="Asia/Shanghai"

CONFIG_FILE="/etc/traffic_monitor.conf"
SCRIPT_PATH="/usr/local/bin/traffic_monitor.sh"

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请以 root 权限运行此脚本 (sudo bash $0)"
  exit 1
fi

# 检查并自动安装缺失的依赖软件 (无数组兼容版)
check_dependencies() {
    local need_install=0
    local pkgs=""

    if ! command -v vnstat >/dev/null 2>&1; then need_install=1; pkgs="$pkgs vnstat"; fi
    if ! command -v jq >/dev/null 2>&1; then need_install=1; pkgs="$pkgs jq"; fi
    if ! command -v curl >/dev/null 2>&1; then need_install=1; pkgs="$pkgs curl"; fi
    if ! command -v awk >/dev/null 2>&1; then need_install=1; pkgs="$pkgs gawk"; fi
    if ! command -v crontab >/dev/null 2>&1; then need_install=1; pkgs="$pkgs cron"; fi

    if [ "$need_install" -eq 1 ]; then
        echo "⚠️ 检测到缺少依赖软件:$pkgs"
        echo "📦 正在自动为您安装依赖工具，请稍候..."
        
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y $pkgs >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y epel-release >/dev/null 2>&1 || true
            dnf install -y $pkgs >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release >/dev/null 2>&1 || true
            yum install -y $pkgs >/dev/null 2>&1
        else
            echo "❌ 未能检测到包管理器，请手动安装以下软件:$pkgs"
            exit 1
        fi
        echo "✅ 依赖软件安装完成！"
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
            rx=$(echo "$json_data" | jq -r '(.interfaces[0].traffic.month[0].rx // .interfaces[0].traffic.months[0].rx) // 0' 2>/dev/null)
            tx=$(echo "$json_data" | jq -r '(.interfaces[0].traffic.month[0].tx // .interfaces[0].traffic.months[0].tx) // 0' 2>/dev/null)
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

ensure_system_timezone() {
    local current_tz
    current_tz=$(date +%z)
    if [ "$current_tz" != "+0800" ]; then
        echo "🌐 检测到系统当前时区非东八区，正在统一设置为 Asia/Shanghai (UTC+8)..."
        timedatectl set-timezone Asia/Shanghai 2>/dev/null || ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "✅ 系统时区已成功更新为东八区 (Asia/Shanghai)。"
    fi
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

    echo "=========================================="
    echo "• 服务器名称: $display_name"
    echo "• 监控网卡: $INTERFACE"
    echo "• 当月汇总使用量: $formatted_used / ${LIMIT_GB} GB (结算时区: ${tz_disp})"
    echo "• 预警阈值: ${ALERT_PCT}\% \vert{} 关机阈值: ${SHUTDOWN_PCT}%"
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
        printf "pct=\"%.1f\"\nis_alert=%d\nis_shutdown=%d\n", pct, is_alert, is_shutdown;
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
• 当月汇总用量: \`${formatted_used}\` / \`${LIMIT_GB} GB\` (${pct}%)
• 关机阈值: \`${SHUTDOWN_PCT}%\`
⚠️ 流量已达到关机阈值，服务器将在 5 秒后自动关机！"
            
            send_telegram "$msg"
            touch "$flag_shutdown"
            echo "🛑 流量超限 (${pct}\% >=${SHUTDOWN_PCT}%)，已发送 TG 通知，5秒后自动关机！"
            sleep 5
            systemctl poweroff
            return 0
