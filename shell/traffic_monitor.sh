#!/usr/bin/env bash

# 强制脚本运行环境时区为东八区 (北京时间)
export TZ="Asia/Shanghai"

CONFIG_FILE="/etc/traffic_monitor.conf"
SCRIPT_PATH="/usr/local/bin/traffic_monitor.sh"

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请以 root 权限运行此脚本 (sudo bash $0)"
  exit 1
fi

# 检查并自动安装缺失的依赖软件
check_dependencies() {
    local missing_pkgs=()

    command -v vnstat >/dev/null 2>&1 || missing_pkgs+=("vnstat")
    command -v jq >/dev/null 2>&1 || missing_pkgs+=("jq")
    command -v curl >/dev/null 2>&1 || missing_pkgs+=("curl")
    command -v awk >/dev/null 2>&1 || missing_pkgs+=("gawk")
    command -v crontab >/dev/null 2>&1 || missing_pkgs+=("cron")

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo "⚠️ 检测到缺少依赖软件: ${missing_pkgs[*]}"
        echo "📦 正在自动为您安装依赖工具，请稍候..."
        
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            local apt_list=()
            for pkg in "${missing_pkgs[@]}"; do
                if [ "$pkg" = "cron" ]; then
                    apt_list+=("cron")
                else
                    apt_list+=("$pkg")
                fi
            done
            apt-get install -y "${apt_list[@]}" >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y epel-release >/dev/null 2>&1 || true
            dnf install -y "${missing_pkgs[@]}" >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release >/dev/null 2>&1 || true
            yum install -y "${missing_pkgs[@]}" >/dev/null 2>&1
        else
            echo "❌ 未能检测到包管理器，请手动安装以下软件: ${missing_pkgs[*]}"
            exit 1
        fi
        echo "✅ 依赖软件安装完成！"
    fi

    # 确保 vnstat 服务开启并开机自启
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
            [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
            [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
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
    [ "$RESET_TZ" = "UTC" ] && tz_disp="UTC+0 (零时区)"

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
        fi
    else
        [ -f "$flag_shutdown" ] && rm -f "$flag_shutdown"
    fi

    if [ "$is_alert" -eq 1 ]; then
        if [ ! -f "$flag_alert" ]; then
            local formatted_used
            formatted_used=$(format_bytes "$total_bytes")
            
            local msg="🚨 *[流量用量预警]*
• 服务器: \`${display_name}\`
• 监控网卡: \`${INTERFACE}\`
• 当月汇总用量: \`${formatted_used}\` / \`${LIMIT_GB} GB\` (${pct}%)
• 预警阈值: \`${ALERT_PCT}%\`
• 关机阈值: \`${SHUTDOWN_PCT}%\`
⚠️ 已达到设定的流量预警阈值，请注意控制用量！"
            
            send_telegram "$msg"
            touch "$flag_alert"
            echo "⚠️ 已达到预警阈值 (当前 ${pct}\% >= 设定 ${ALERT_PCT}%)，预警消息已发送！"
        else
            echo "ℹ️ 已处于预警状态 (当前 ${pct}%)，不再重复提醒。"
        fi
    else
        [ -f "$flag_alert" ] && rm -f "$flag_alert"
        echo "✅ 流量正常（当前汇总已用 ${pct}\%，未达到预警阈值 ${ALERT_PCT}%）。"
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

    local tz_disp="UTC+8 (北京时间)"
    [ "$RESET_TZ" = "UTC" ] && tz_disp="UTC+0 (零时区)"

    local total_bytes
    total_bytes=$(get_traffic_bytes "$INTERFACE")
    local formatted_used
    formatted_used=$(format_bytes "$total_bytes")

    local pct="无限制"
    if [ "$LIMIT_GB" -gt 0 ] 2>/dev/null; then
        pct=$(LC_ALL=C awk -v bytes="$total_bytes" -v limit_gb="$LIMIT_GB" 'BEGIN {
            if (limit_gb > 0) {
                printf "%.1f%%", (bytes / (limit_gb * 1073741824)) * 100;
            } else {
                printf "0.0%%";
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

interactive_config() {
    check_dependencies
    ensure_system_timezone

    local is_update=0
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        is_update=1
    fi

    echo "=========================================="
    if [ "$is_update" -eq 1 ]; then
        echo "       Telegram 流量监控【修改配置】"
        echo "------------------------------------------"
        echo "ℹ️ 已检测到现有配置，直接按 [回车] 可保留原设定"
    else
        echo "       Telegram 流量监控【初始化配置】"
    fi
    echo "=========================================="
    
    local detected_ifaces
    detected_ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | xargs)

    echo "[1] 检测到的可监控网卡列表:"
    echo "$detected_ifaces"
    echo "------------------------------------------"
    
    local default_iface=${INTERFACE:-"$detected_ifaces"}
    read -p "请输入要监控的网卡接口 (多网卡用空格隔开，或填 all，默认: ${default_iface}): " input_iface
    INTERFACE=${input_iface:-$default_iface}

    local ifaces_to_init="$INTERFACE"
    [ "$ifaces_to_init" = "all" ] && ifaces_to_init=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")
    for iface_item in $ifaces_to_init; do
        vnstat -i "$iface_item" > /dev/null 2>&1
    done

    local sys_hostname
    sys_hostname=$(hostname)
    local default_sname=${SERVER_NAME:-"$sys_hostname"}
    read -p "请输入服务器通知名称 (留空默认使用主机名 [${default_sname}]): " input_sname
    SERVER_NAME=${input_sname:-$default_sname}

    local token_prompt="请输入 Telegram Bot Token"
    [ -n "$BOT_TOKEN" ] && token_prompt="请输入 Telegram Bot Token [直接回车保留原值]: " || token_prompt="请输入 Telegram Bot Token: "
    read -p "$token_prompt" input_token
    BOT_TOKEN=${input_token:-$BOT_TOKEN}
    while [ -z "$BOT_TOKEN" ]; do
        echo "❌ Bot Token 不能为空！"
        read -p "请输入 Telegram Bot Token: " input_token
        BOT_TOKEN=${input_token:-$BOT_TOKEN}
    done

    local chat_prompt="请输入 Telegram Chat ID"
    [ -n "$CHAT_ID" ] && chat_prompt="请输入 Telegram Chat ID [当前: ${CHAT_ID}, 直接回车保留]: " || chat_prompt="请输入 Telegram Chat ID: "
    read -p "$chat_prompt" input_chat
    CHAT_ID=${input_chat:-$CHAT_ID}
    while [ -z "$CHAT_ID" ]; do
        echo "❌ Chat ID 不能为空！"
        read -p "请输入 Telegram Chat ID: " input_chat
        CHAT_ID=${input_chat:-$CHAT_ID}
    done

    local default_limit=${LIMIT_GB:-1000}
    read -p "请输入每月流量上限 (GB, 填 0 为无限制, 默认: ${default_limit}): " input_limit
    LIMIT_GB=${input_limit:-$default_limit}

    local default_alert=${ALERT_PCT:-90}
    read -p "请输入【预警】百分比 (默认: ${default_alert}%): " input_alert
    ALERT_PCT=${input_alert:-$default_alert}

    local default_shutdown=${SHUTDOWN_PCT:-95}
    read -p "请输入【自动关机】百分比 (填 0 不关机, 默认: ${default_shutdown}%): " input_shutdown
    SHUTDOWN_PCT=${input_shutdown:-$default_shutdown}

    local default_reset=${RESET_DAY:-1}
    read -p "请输入每月流量结算/重置日期 (1-28 日, 默认: ${default_reset}): " input_reset
    RESET_DAY=${input_reset:-$default_reset}

    echo "------------------------------------------"
    echo "请选择流量结算重置依据的时区:"
    echo "  [1] UTC+8 (东八区 / 北京时间 - 国内及部分公有云标准)"
    echo "  [2] UTC+0 (零时区 / 国际标准时间 - 搬瓦工/Linode/GCP 等常用)"
    local default_tz_opt="1"
    [ "$RESET_TZ" = "UTC" ] && default_tz_opt="2"
    read -p "请选择重置时区 [1-2] (默认: ${default_tz_opt}): " input_tz_opt
    input_tz_opt=${input_tz_opt:-$default_tz_opt}

    if [ "$input_tz_opt" = "2" ]; then
        RESET_TZ="UTC"
        RESET_TZ_NAME="UTC+0 (零时区)"
    else
        RESET_TZ="Asia/Shanghai"
        RESET_TZ_NAME="UTC+8 (北京时间)"
    fi

    if grep -qE "^[#;]?[[:space:]]*MonthRotate" /etc/vnstat.conf 2>/dev/null; then
        sed -i -E "s/^[#;]?[[:space:]]*MonthRotate .*/MonthRotate ${RESET_DAY}/" /etc/vnstat.conf
    else
        echo "MonthRotate ${RESET_DAY}" >> /etc/vnstat.conf
    fi
    systemctl restart vnstat 2>/dev/null || true

    PUSH_TIME="08:00"

    cat <<EOF > "$CONFIG_FILE"
BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"
INTERFACE="${INTERFACE}"
SERVER_NAME="${SERVER_NAME}"
LIMIT_GB="${LIMIT_GB}"
ALERT_PCT="${ALERT_PCT}"
SHUTDOWN_PCT="${SHUTDOWN_PCT}"
RESET_DAY="${RESET_DAY}"
RESET_TZ="${RESET_TZ}"
PUSH_TIME="${PUSH_TIME}"
EOF

    chmod 600 "$CONFIG_FILE"

    local tmp_cron
    tmp_cron=$(mktemp)

    echo "CRON_TZ=Asia/Shanghai" > "$tmp_cron"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" >> "$tmp_cron"
    echo "SHELL=/bin/bash" >> "$tmp_cron"

    if crontab -l >/dev/null 2>&1; then
        crontab -l | tr -d '\r' | grep -v -F "$SCRIPT_PATH" \vert{} grep -v -E "^(PATH=\vert{}SHELL=\vert{}CRON_TZ=)" >> "$tmp_cron" 2>/dev/null || true
    fi

    echo "* * * * * $SCRIPT_PATH --check-threshold >/dev/null 2>&1" >> "$tmp_cron"
    echo "0 8 * * * $SCRIPT_PATH --daily-report >/dev/null 2>&1" >> "$tmp_cron"

    crontab "$tmp_cron"
    rm -f "$tmp_cron"

    echo "=========================================="
    if [ "$is_update" -eq 1 ]; then
        echo "✅ 配置修改成功！"
    else
        echo "✅ 配置初始化成功！"
    fi
    echo "• 服务器名称: $SERVER_NAME"
    echo "• 监控网卡: $INTERFACE"
    echo "• 结算重置日: 每月 ${RESET_DAY} 号"
    echo "• 结算时区: ${RESET_TZ_NAME}"
    echo "• 每日推送: 北京时间 08:00"
    echo "• 检测频率: 每 1 分钟"
    echo "• 预警提醒: 达到 ${ALERT_PCT}% 时发送预警"
    echo "• 自动关机: 达到 ${SHUTDOWN_PCT}% 时发送通知并强制关机"
    echo "=========================================="
    
    local title_str="*[流量监控配置成功]*"
    [ "$is_update" -eq 1 ] && title_str="*[流量监控配置已更新]*"

    local msg="🎉 ${title_str}
已成功配置流量监控服务！
• 服务器: \`${SERVER_NAME}\`
• 监控网卡: \`${INTERFACE}\`
• 结算重置: \`每月 ${RESET_DAY} 号\`
• 结算时区: \`${RESET_TZ_NAME}\`
• 预警线: \`${ALERT_PCT}%\`
• 关机线: \`${SHUTDOWN_PCT}%\`
• 推送时间: \`每天 08:00 (北京时间)\`"
    send_telegram "$msg"
}

uninstall() {
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
    rm -f "$CONFIG_FILE"
    rm -f "$SCRIPT_PATH"
    rm -f "/usr/local/bin/traffic"
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
            1) interactive_config ;;
            2) do_daily_report ;;
            3) do_check_threshold ;;
            4) do_status ;;
            5) uninstall ;;
            *) exit 0 ;;
        esac
        ;;
esac
