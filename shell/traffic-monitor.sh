#!/bin/bash
# ==============================================================================
# Script Name: traffic-monitor.sh
# Description: Debian 13 Traffic Monitor & Telegram Alert System using vnstat
# Author: DarkerLab
# Version: 1.2.3
# ==============================================================================

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/traffic-monitor.conf"
STATE_DIR="/var/lib/traffic-monitor"
SCRIPT_PATH="/usr/local/bin/traffic-monitor.sh"
GITHUB_URL="https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh"
VERSION="1.2.3"

# 检查Root权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 初始化目录
mkdir -p "$STATE_DIR"

# 检查并修复系统时区
check_timezone() {
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null)
    if [ "$current_tz" != "Asia/Shanghai" ]; then
        echo -e "${YELLOW}当前系统时区为 [$current_tz]，正在自动调整为 Asia/Shanghai...${PLAIN}"
        timedatectl set-timezone Asia/Shanghai
    fi
}

# 安装依赖并初始化网卡监控
install_dependencies() {
    echo -e "${BLUE}正在检查并安装必要依赖 (vnstat, curl, jq, bc, cron)...${PLAIN}"
    apt-get update -y
    apt-get install -y vnstat curl jq bc cron systemd
    systemctl enable --now vnstat
    systemctl enable --now cron
    
    # 自动为所有可用网卡初始化 vnstat 监控
    mapfile -t available_ifs < <(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo')
    for iface in "${available_ifs[@]}"; do
        vnstat -i "$iface" >/dev/null 2>&1
    done
}

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# 保存配置
save_config() {
    cat <<EOF > "$CONFIG_FILE"
SERVER_NAME="$SERVER_NAME"
INTERFACES="$INTERFACES"
RESET_DAY="$RESET_DAY"
RESET_TZ="$RESET_TZ"
TRAFFIC_TYPE="$TRAFFIC_TYPE"
TOTAL_QUOTA_GB="$TOTAL_QUOTA_GB"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
}

# 发送 Telegram 消息
send_tg_msg() {
    local msg="$1"
    if [ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ]; then
        return 1
    fi
    local response http_code
    response=$(curl -s -w "%{http_code}" -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${msg}" \
        -d "parse_mode=Markdown")
    http_code="${response: -3}"
    if [ "$http_code" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

# 交互式配置向导
configure_parameters() {
    clear
    load_config
    echo -e "${BLUE}=== 流量监控参数配置向导 ===${PLAIN}"
    
    # 1. 服务器名称
    local default_name="${SERVER_NAME:-Debian-Server}"
    read -p "请输入自定义服务器名称 [默认: $default_name]: " input_name
    SERVER_NAME="${input_name:-$default_name}"

    # 2. 网卡接口检测与选择
    echo -e "\n${BLUE}当前系统可用网卡接口：${PLAIN}"
    mapfile -t available_ifs < <(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo')
    for i in "${!available_ifs[@]}"; do
        echo " [$i] ${available_ifs[$i]}"
    done
    local default_if="${INTERFACES:-${available_ifs[0]}}"
    read -p "请选择网卡编号（多个网卡请用空格隔开，如 0 1）[默认已选: $default_if]: " if_indices
    if [ -z "$if_indices" ]; then
        INTERFACES="$default_if"
    else
        INTERFACES=""
        for idx in $if_indices; do
            if [ -n "${available_ifs[$idx]}" ]; then
                INTERFACES="$INTERFACES ${available_ifs[$idx]}"
            fi
        done
        INTERFACES=$(echo "$INTERFACES" | xargs)
    fi
    [ -z "$INTERFACES" ] && INTERFACES="${available_ifs[0]}"

    # 确保所选网卡已被 vnstat 初始化
    for iface in $INTERFACES; do
        vnstat -i "$iface" >/dev/null 2>&1
    done

    # 3. 每月流量重置日
    local default_reset_day="${RESET_DAY:-1}"
    read -p "请输入每月流量重置日期 (1-31) [默认: $default_reset_day]: " input_day
    RESET_DAY="${input_day:-$default_reset_day}"

    # 4. 结算时区选择
    local default_tz_choice="2"
    [ "$RESET_TZ" = "UTC0" ] && default_tz_choice="1"
    echo -e "请选择流量统计与重置时区："
    echo " 1) UTC+0 (世界标准时间)"
    echo " 2) UTC+8 (北京时间)"
    read -p "请选择 [1-2] [默认: $default_tz_choice]: " tz_choice
    tz_choice="${tz_choice:-$default_tz_choice}"
    if [ "$tz_choice" = "1" ]; then
        RESET_TZ="UTC0"
    else
        RESET_TZ="UTC8"
    fi

    # 5. 流量统计类型
    local default_type="${TRAFFIC_TYPE:-1}"
    echo -e "请选择流量统计类型："
    echo " 1) 总流量 (上传 + 下载)"
    echo " 2) 仅上传流量 (Upload)"
    echo " 3) 仅下载流量 (Download)"
    read -p "请选择 [1-3] [默认: $default_type]: " type_choice
    TRAFFIC_TYPE="${type_choice:-$default_type}"

    # 6. 总流量阈值 (GB)
    local default_quota="${TOTAL_QUOTA_GB:-1000}"
    read -p "请输入每月总流量额度 (GB) [默认: $default_quota]: " input_quota
    TOTAL_QUOTA_GB="${input_quota:-$default_quota}"

    # 7. Telegram 配置
    local token_hint="${TG_BOT_TOKEN:0:6}***(已配置)"
    [ -z "$TG_BOT_TOKEN" ] && token_hint="未配置"
    read -p "请输入 Telegram Bot Token [当前: $token_hint，直接回车保留]: " input_token
    [ -n "$input_token" ] && TG_BOT_TOKEN="$input_token"

    local chatid_hint="${TG_CHAT_ID:0:4}***(已配置)"
    [ -z "$TG_CHAT_ID" ] && chatid_hint="未配置"
    read -p "请输入 Telegram Chat ID [当前: $chatid_hint，直接回车保留]: " input_chatid
    [ -n "$input_chatid" ] && TG_CHAT_ID="$input_chatid"

    save_config
    setup_cron
    echo -e "${GREEN}配置保存成功！监控任务已生效（每1分钟检测一次）。${PLAIN}"
    read -p "按回车键返回主菜单..."
}

# 设置Cron定时任务
setup_cron() {
    local cron_cmd="* * * * * /usr/local/bin/traffic-monitor.sh check >/dev/null 2>&1"
    crontab -l 2>/dev/null | grep -v "traffic-monitor.sh" | { cat; echo "$cron_cmd"; } | crontab -
}

# 计算当前周期内的已用流量（已增强容错与网卡自动初始化）
calculate_traffic() {
    load_config
    [ -z "$INTERFACES" ] && echo "0.00 0 N/A N/A" && return

    local cur_date cur_day cur_month cur_year
    if [ "$RESET_TZ" = "UTC0" ]; then
        cur_date=$(TZ='UTC' date +'%Y-%m-%d')
        cur_day=$(TZ='UTC' date +'%d')
        cur_month=$(TZ='UTC' date +'%m')
        cur_year=$(TZ='UTC' date +'%Y')
    else
        cur_date=$(TZ='Asia/Shanghai' date +'%Y-%m-%d')
        cur_day=$(TZ='Asia/Shanghai' date +'%d')
        cur_month=$(TZ='Asia/Shanghai' date +'%m')
        cur_year=$(TZ='Asia/Shanghai' date +'%Y')
    fi

    local c_day=$((10#$cur_day))
    local c_month=$((10#$cur_month))
    local c_year=$((10#$cur_year))
    local r_day=$((10#$RESET_DAY))
    local start_year start_month start_day

    if [ "$c_day" -ge "$r_day" ]; then
        start_year=$c_year
        start_month=$c_month
        start_day=$r_day
    else
        start_month=$((c_month - 1))
        start_year=$c_year
        if [ "$start_month" -eq 0 ]; then
            start_month=12
            start_year=$((c_year - 1))
        fi
        start_day=$r_day
    fi
    local start_date_str
    start_date_str=$(printf "\%04d-\%02d-\%02d" "$start_year" "$start_month" "$start_day")

    local total_rx=0
    local total_tx=0

    for iface in $INTERFACES; do
        vnstat -i "$iface" >/dev/null 2>&1
        local if_json
        if_json=$(vnstat -i "$iface" --json 2>/dev/null)
        
        # 验证是否为合法 JSON
        if ! echo "$if_json" | jq empty >/dev/null 2>&1; then
            continue
        fi

        local parsed
        parsed=$(echo "$if_json" | jq -r --arg start "$start_date_str" '
            if .interfaces[0].traffic.day? then
                .interfaces[0].traffic.day[] |
                select(
                    (.date.year | tostring) + "-" + 
                    ((.date.month | tostring) | if length == 1 then "0" + . else . end) + "-" + 
                    ((.date.day | tostring) | if length == 1 then "0" + . else . end) >= $start
                ) |
                [.rx, .tx] | @tsv
            else
                empty
            end
        ' 2>/dev/null)

        while IFS=$'\t' read -r rx tx; do
            [ -n "$rx" ] && [ "$rx" -gt 0 ] && total_rx=$((total_rx + rx))
            [ -n "$tx" ] && [ "$tx" -gt 0 ] && total_tx=$((total_tx + tx))
        done <<< "$parsed"
    done

    local used_bytes=0
    case "$TRAFFIC_TYPE" in
        2) used_bytes=$total_tx ;; 3) used_bytes=$total_rx ;;
        *) used_bytes=$((total_rx + total_tx)) ;;
    esac

    local used_gb quota_bytes percentage
    used_gb=$(echo "scale=2; $used_bytes / (1024 * 1024 * 1024)" | bc)
    [[ "$used_gb" == .* ]] && used_gb="0$used_gb"

    quota_bytes=$(echo "$TOTAL_QUOTA_GB * 1024 * 1024 * 1024" | bc | cut -d'.' -f1)
    
    if [ -n "$quota_bytes" ] && [ "$quota_bytes" -gt 0 ]; then
        percentage=$(echo "scale=1; ($used_bytes * 100) /$quota_bytes" | bc)
        [[ "$percentage" == .* ]] && percentage="0$percentage"
    else
        percentage=0
    fi

    echo "$used_gb$percentage $start_date_str$cur_date"
}

# 后台定时检测主逻辑
check_traffic_daemon() {
    load_config
    [ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ] && exit 0

    local bj_hour bj_min bj_date
    bj_hour=$(TZ='Asia/Shanghai' date +'%H')
    bj_min=$(TZ='Asia/Shanghai' date +'%M')
    bj_date=$(TZ='Asia/Shanghai' date +'%Y-%m-%d')

    read -r used_gb percentage start_date cur_date < <(calculate_traffic)
    [ -z "$used_gb" ] && exit 0

    # 1. 每日流量报告 (北京时间 08:10 推送)
    local report_file="$STATE_DIR/last_report_date"
    local last_report=""
    [ -f "$report_file" ] && last_report=$(cat "$report_file")

    if [ "$bj_hour" = "08" ] && [ "$bj_min" = "10" ] && [ "$last_report" != "$bj_date" ]; then
        local type_str="总流量(上传+下载)"
        [ "$TRAFFIC_TYPE" = "2" ] && type_str="仅上传流量"
        [ "$TRAFFIC_TYPE" = "3" ] && type_str="仅下载流量"

        local msg="📊 *服务器每日流量报告*
🏷️ *服务器名称*: \`$SERVER_NAME\`
🌐 *监控网口*: \`$INTERFACES\`
📈 *统计类型*: \`$type_str\`
🔄 *统计周期*: \`$start_date\` 至 \`$bj_date 08:10\`
📊 *已用流量*: \`$used_gb GB\` / \`$TOTAL_QUOTA_GB GB\` (\`$percentage%\`)
⏱️ *当前时间*: \`$(TZ='Asia/Shanghai' date +'%Y-%m-%d %H:%M:%S')\`"

        if send_tg_msg "$msg"; then
            echo "$bj_date" > "$report_file"
        fi
    fi

    # 2. 90% 流量预警
    local warn_file="$STATE_DIR/last_warning_month"
    local current_month_key
    current_month_key=$(date +'%Y-%m')
    local last_warn_month=""
    [ -f "$warn_file" ] && last_warn_month=$(cat "$warn_file")

    local is_over_90
    is_over_90=$(echo "$percentage >= 90.0" | bc)
    if [ "$is_over_90" -eq 1 ] && [ "$last_warn_month" != "$current_month_key" ]; then
        local warn_msg="⚠️ *流量预警通知*
🏷️ *服务器名称*: \`$SERVER_NAME\`
🚨 *状态*: 流量使用已达到 *\`$percentage%\`*！
📊 *已用流量*: \`$used_gb GB\` / \`$TOTAL_QUOTA_GB GB\`
⏱️ *时间*: \`$(TZ='Asia/Shanghai' date +'%Y-%m-%d %H:%M:%S')\`"

        if send_tg_msg "$warn_msg"; then
            echo "$current_month_key" > "$warn_file"
        fi
    fi

    # 3. 95% 安全关机报警
    local shutdown_file="$STATE_DIR/last_shutdown_month"
    local last_shutdown_month=""
    [ -f "$shutdown_file" ] && last_shutdown_month=$(cat "$shutdown_file")

    local is_over_95
    is_over_95=$(echo "$percentage >= 95.0" | bc)
    if [ "$is_over_95" -eq 1 ] && [ "$last_shutdown_month" != "$current_month_key" ]; then
        local shutdown_msg="🚨 *流量耗尽关机报警*
🏷️ *服务器名称*: \`$SERVER_NAME\`
🛑 *状态*: 流量使用已达到 *\`$percentage%\`*，服务器即将执行关机！
📊 *已用流量*: \`$used_gb GB\` / \`$TOTAL_QUOTA_GB GB\`
⏱️ *时间*: \`$(TZ='Asia/Shanghai' date +'%Y-%m-%d %H:%M:%S')\`"

        if send_tg_msg "$shutdown_msg"; then
            echo "$current_month_key" > "$shutdown_file"
            sync
            sleep 2
            shutdown now
        fi
    fi
}

# 脚本更新功能
update_script() {
    echo -e "${BLUE}正在检查并更新一键脚本...${PLAIN}"
    if [ -f "$SCRIPT_PATH" ]; then
        rm -f "$SCRIPT_PATH"
    fi
    if curl -sL "${GITHUB_URL}?t=$(date +\%s)" -o "$SCRIPT_PATH"; then
        chmod +x "$SCRIPT_PATH"
        source "$SCRIPT_PATH" check >/dev/null 2>&1
        echo -e "${GREEN}脚本更新成功！当前版本: v$VERSION${PLAIN}"
    else
        echo -e "${RED}脚本更新失败，请检查网络连接或 GitHub 链接是否正确。${PLAIN}"
    fi
    read -p "按回车键返回主菜单..."
}

# 查看当前状态与流量
view_status() {
    clear
    load_config
    echo -e "${BLUE}=== Debian 13 流量监控状态 ===${PLAIN}"
    echo -e "当前版本: v$VERSION"
    echo -e "服务器名称: ${GREEN}$SERVER_NAME${PLAIN}"
    echo -e "监控网口: ${GREEN}$INTERFACES${PLAIN}"
    echo -e "重置日期: 每月 ${GREEN}$RESET_DAY${PLAIN} 号 (${RESET_TZ})"
    echo -e "总流量额度: ${GREEN}$TOTAL_QUOTA_GB GB${PLAIN}"
    echo "--------------------------------------------------"
    if [ -n "$INTERFACES" ]; then
        local calc_result
        calc_result=$(calculate_traffic)
        read -r used_gb percentage start_date cur_date <<< "$calc_result"
        echo -e "统计周期起止: ${GREEN}${start_date:-N/A}${PLAIN} 至 ${GREEN}${cur_date:-N/A}${PLAIN}"
        echo -e "已使用流量:   ${YELLOW}${used_gb:-0} GB${PLAIN}"
        echo -e "使用百分比:   ${YELLOW}${percentage:-0}\%${PLAIN}"
    else
        echo -e "${RED}尚未配置监控网口！${PLAIN}"
    fi
    echo "--------------------------------------------------"
    read -p "按回车键返回主菜单..."
}

# 卸载监控
uninstall_monitor() {
    read -p "确认卸载流量监控及定时任务？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        crontab -l 2>/dev/null | grep -v "traffic-monitor.sh" | crontab -
        rm -f "$CONFIG_FILE"
        rm -rf "$STATE_DIR"
        echo -e "${GREEN}流量监控已成功卸载。${PLAIN}"
    fi
    read -p "按回车键返回主菜单..."
}

# 交互主菜单
main_menu() {
    while true; do
        clear
        echo -e "=================================================="
        echo -e "        Debian 13 流量监控与 Telegram 报警系统       "
        echo -e "        版本: v$VERSION                              "
        echo -e "=================================================="
        echo -e " 1. ${GREEN}安装 / 初始化部署流量监控${PLAIN}"
        echo -e " 2. ${BLUE}检查更新一键脚本${PLAIN}"
        echo -e " 3. ${YELLOW}修改配置参数${PLAIN}"
        echo -e " 4. ${BLUE}查看当前流量统计与状态${PLAIN}"
        echo -e " 5. ${RED}卸载流量监控${PLAIN}"
        echo -e " 0. 退出脚本"
        echo -e "=================================================="
        read -p "请输入选项 [0-5]: " choice

        case "$choice" in
            1)
                check_timezone
                install_dependencies
                configure_parameters
                ;;
            2)
                update_script
                ;;
            3)
                configure_parameters
                ;;
            4)
                view_status
                ;;
            5)
                uninstall_monitor
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# 入口分发
case "$1" in
    check)
        check_traffic_daemon
        ;;
    install)
        check_timezone
        install_dependencies
        configure_parameters
        ;;
    *)
        main_menu
        ;;
esac
