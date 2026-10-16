#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: traffic-monitor.sh
# 适用系统: Debian 13 / Linux
# 脚本版本: v1.2.0
# 脚本作者: DarkerLab
# GitHub Raw 链接: https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh
# ==============================================================================

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[-] 请以 root 权限运行此脚本 (例如: sudo ./traffic-monitor.sh)\033[0m"
    exit 1
fi

CONFIG_FILE="/etc/traffic-monitor/config.json"
STATE_FILE="/etc/traffic-monitor/state.json"
LOG_FILE="/var/log/traffic-monitor.log"
SCRIPT_PATH="/usr/local/bin/traffic-monitor.sh"
VERSION="v1.2.0"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 清除颜色

# ------------------------------------------------------------------------------
# 1. 系统环境检查与依赖安装
# ------------------------------------------------------------------------------
init_system() {
    echo -e "${BLUE}[+] 正在检查系统环境与依赖工具...${NC}"
    
    # 检查并设置系统时区为 Asia/Shanghai
    CURRENT_TZ=$(timedatectl show --property=Timezone --value)
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        echo -e "${YELLOW}[*] 当前系统时区为 $CURRENT_TZ，正在修改为 Asia/Shanghai...${NC}"
        timedatectl set-timezone Asia/Shanghai
    else
        echo -e "${GREEN}[+] 当前系统时区已正确设置为 Asia/Shanghai。${NC}"
    fi

    # 更新软件包列表并安装依赖
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y vnstat curl jq bc cron gawk

    # 启动并开机自启 vnstat 服务
    systemctl enable --now vnstat
    
    # 创建配置目录与日志文件
    mkdir -p /etc/traffic-monitor
    touch "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# 2. 配置读取与保存
# ------------------------------------------------------------------------------
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        SERVER_NAME=$(jq -r '.server_name // "我的服务器"' "$CONFIG_FILE")
        INTERFACES=$(jq -r '.interfaces // "eth0"' "$CONFIG_FILE")
        RESET_DAY=$(jq -r '.reset_day // 1' "$CONFIG_FILE")
        RESET_TZ=$(jq -r '.reset_tz // "UTC8"' "$CONFIG_FILE")
        TRAFFIC_TYPE=$(jq -r '.traffic_type // 1' "$CONFIG_FILE")
        TOTAL_LIMIT_GB=$(jq -r '.total_limit_gb // 1000' "$CONFIG_FILE")
        TG_BOT_TOKEN=$(jq -r '.tg_bot_token // ""' "$CONFIG_FILE")
        TG_CHAT_ID=$(jq -r '.tg_chat_id // ""' "$CONFIG_FILE")
    else
        SERVER_NAME="我的服务器"
        INTERFACES="eth0"
        RESET_DAY=1
        RESET_TZ="UTC8"
        TRAFFIC_TYPE=1
        TOTAL_LIMIT_GB=1000
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi
}

save_config() {
    mkdir -p /etc/traffic-monitor
    jq -n \
        --arg server_name "$SERVER_NAME" \
        --arg interfaces "$INTERFACES" \
        --argjson reset_day "$RESET_DAY" \
        --arg reset_tz "$RESET_TZ" \
        --argjson traffic_type "$TRAFFIC_TYPE" \
        --argjson total_limit_gb "$TOTAL_LIMIT_GB" \
        --arg tg_bot_token "$TG_BOT_TOKEN" \
        --arg tg_chat_id "$TG_CHAT_ID" \
        '{
            server_name: $server_name,
            interfaces: $interfaces,
            reset_day: $reset_day,
            reset_tz: $reset_tz,
            traffic_type: $traffic_type,
            total_limit_gb: $total_limit_gb,
            tg_bot_token: $tg_bot_token,
            tg_chat_id: $tg_chat_id
        }' > "$CONFIG_FILE"
}

# ------------------------------------------------------------------------------
# 3. 中文交互式配置向导
# ------------------------------------------------------------------------------
configure_wizard() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}      流量监控与预警系统 - 参数配置向导              ${NC}"
    echo -e "${CYAN}      版本号: $VERSION${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    load_config

    read -p "请输入服务器自定义名称 [当前: $SERVER_NAME]: " input_name
    [ -n "$input_name" ] && SERVER_NAME="$input_name"

    echo -e "\n${YELLOW}当前系统可用的网络接口如下:${NC}"
    ip -o link show | awk -F': ' '{print $2}'
    read -p "请输入要监控的网卡名称(多网口请用空格隔开) [当前: $INTERFACES]: " input_ifaces
    [ -n "$input_ifaces" ] && INTERFACES="$input_ifaces"

    read -p "请输入每月流量重置日期 (1-31) [当前: $RESET_DAY]: " input_day
    if [ -n "$input_day" ]; then
        RESET_DAY="$input_day"
    fi

    echo -e "\n请选择流量统计与重置时区:"
    echo "1) UTC+0 时区"
    echo "2) UTC+8 时区 (北京时间)"
    read -p "请输入选项 (1-2) [当前: $RESET_TZ]: " input_tz_choice
    if [ "$input_tz_choice" = "1" ]; then
        RESET_TZ="UTC0"
    elif [ "$input_tz_choice" = "2" ]; then
        RESET_TZ="UTC8"
    fi

    echo -e "\n请选择流量统计类型:"
    echo "1) 总流量 (上传 + 下载)"
    echo "2) 仅统计上传流量"
    echo "3) 仅统计下载流量"
    read -p "请输入选项 (1-3) [当前: $TRAFFIC_TYPE]: " input_type
    [ -n "$input_type" ] && TRAFFIC_TYPE="$input_type"

    read -p "请输入每月流量上限阈值 (单位: GB) [当前: $TOTAL_LIMIT_GB]: " input_limit
    [ -n "$input_limit" ] && TOTAL_LIMIT_GB="$input_limit"

    read -p "请输入 Telegram Bot Token [当前: $TG_BOT_TOKEN]: " input_token
    [ -n "$input_token" ] && TG_BOT_TOKEN="$input_token"

    read -p "请输入 Telegram Chat ID [当前: $TG_CHAT_ID]: " input_chat_id
    [ -n "$input_chat_id" ] && TG_CHAT_ID="$input_chat_id"

    save_config
    setup_cron_and_script
    
    # 创建全局快捷命令
    ln -sf "$SCRIPT_PATH" /usr/local/bin/traffic-monitor

    echo -e "\n${GREEN}[+] 参数配置已成功保存！定时任务与执行脚本已更新。${NC}"
    read -p "按回车键返回主菜单..."
}

# ------------------------------------------------------------------------------
# 4. 设置 Cron 定时任务与脚本文件同步
# ------------------------------------------------------------------------------
setup_cron_and_script() {
    if [ "$0" != "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi

    # 设置 1 分钟执行一次的定时任务
    CRON_JOB="* * * * * $SCRIPT_PATH --monitor >>$LOG_FILE 2>&1"
    (crontab -l 2>/dev/null | grep -v "traffic-monitor.sh") | { cat; echo "$CRON_JOB"; } | crontab -
}

# ------------------------------------------------------------------------------
# 5. Telegram 消息推送函数
# ------------------------------------------------------------------------------
send_telegram() {
    local message="$1"
    if [ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ]; then
        return 1
    fi

    response=$(curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$message" \
        -d "parse_mode=Markdown")

    if echo "$response" | jq -e '.ok == true' >/dev/null; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 6. vnstat 流量计算核心逻辑
# ------------------------------------------------------------------------------
get_current_traffic_bytes() {
    local total_rx=0
    local total_tx=0
    
    vnstat -u >/dev/null 2>&1

    for iface in $INTERFACES; do
        json_data=$(vnstat -i "$iface" --json 2>/dev/null)
        if [ -z "$json_data" ]; then
            continue
        fi

        if [ "$RESET_TZ" = "UTC8" ]; then
            TZ='Asia/Shanghai'
        else
            TZ='UTC'
        fi

        curr_year=$(TZ=$TZ date +%Y)
        curr_month=$(TZ=$TZ date +%m)
        curr_day=$(TZ=$TZ date +%d)

        start_year=$curr_year
        start_month=$((10#$curr_month - 1))
        if [ $start_month -eq 0 ]; then
            start_month=12
            start_year=$((curr_year - 1))
        fi
        
        if [ 10#$curr_day -ge 10#$RESET_DAY ]; then
            start_month=$curr_month
            start_year=$curr_year
        fi

        while IFS=read -r day_obj; do
            [ -z "$day_obj" ] && continue
            d_y=$(echo "$day_obj" | jq '.date.year')
            d_m=$(echo "$day_obj" | jq '.date.month')
            d_d=$(echo "$day_obj" | jq '.date.day')
            
            d_str=$(printf "\%04d\%02d\%02d" "$d_y" "$d_m" "$d_d")
            s_str=$(printf "\%04d\%02d\%02d" "$start_year" "$start_month" "$RESET_DAY")
            c_str=$(printf "\%04d\%02d\%02d" "$curr_year" "$curr_month" "$curr_day")

            if [ "$d_str" -ge "$s_str" ] && [ "$d_str" -le "$c_str" ]; then
                rx=$(echo "$day_obj" | jq '.rx')
                tx=$(echo "$day_obj" | jq '.tx')
                total_rx=$((total_rx + rx))
                total_tx=$((total_tx + tx))
            fi
        done <<EOF
        $(echo "$json_data" | jq -c '.interfaces[0].traffic.days[]?')
EOF
    done

    if [ "$TRAFFIC_TYPE" = "2" ]; then
        echo "$total_tx"
    elif [ "$TRAFFIC_TYPE" = "3" ]; then
        echo "$total_rx"
    else
        echo $((total_rx + total_tx))
    fi
}

bytes_to_gb() {
    local bytes=$1
    echo "scale=2; $bytes / 1024 / 1024 / 1024" | bc
}

# ------------------------------------------------------------------------------
# 7. 流量监控核心与报警任务（每1分钟由Cron调用）
# ------------------------------------------------------------------------------
run_monitor() {
    load_config
    
    if [ "$RESET_TZ" = "UTC8" ]; then
        TZ='Asia/Shanghai'
    else
        TZ='UTC'
    fi

    current_time=$(TZ=$TZ date "+%Y-%m-%d %H:%M:%S")

    used_bytes=$(get_current_traffic_bytes)
    used_gb=$(bytes_to_gb "$used_bytes")
    
    if [ "$(echo "$TOTAL_LIMIT_GB > 0" | bc)" -eq 1 ]; then
        percentage=$(echo "scale=2; ($used_gb / $TOTAL_LIMIT_GB) * 100" | bc)
    else
        percentage=0
    fi

    if [ -f "$STATE_FILE" ]; then
        last_daily_date=$(jq -r '.last_daily_date // ""' "$STATE_FILE")
        warn_90_sent=$(jq -r '.warn_90_sent // "false"' "$STATE_FILE")
        shutdown_95_sent=$(jq -r '.shutdown_95_sent // "false"' "$STATE_FILE")
        state_cycle=$(jq -r '.state_cycle // ""' "$STATE_FILE")
    else
        last_daily_date=""
        warn_90_sent="false"
        shutdown_95_sent="false"
        state_cycle=""
    fi

    current_cycle=$(TZ=$TZ date "+%Y-%m")
    if [ "$state_cycle" != "$current_cycle" ]; then
        warn_90_sent="false"
        shutdown_95_sent="false"
        state_cycle="$current_cycle"
    fi

    # 1. Telegram 每日流量报告（北京时间 08:10 准时推送）
    bj_hm=$(TZ='Asia/Shanghai' date "+%H:%M")
    bj_date=$(TZ='Asia/Shanghai' date "+%Y-%m-%d")
    
    if [ "$bj_hm" = "08:10" ] && [ "$last_daily_date" != "$bj_date" ]; then
        report_msg="📊 *【服务器每日流量报告】*
━━━━━━━━━━━━━━━━━━
🖥️ *服务器名称*: \`$SERVER_NAME\`
🌐 *监控网卡接口*: \`$INTERFACES\`
📈 *流量统计类型*: \`$( [ "$TRAFFIC_TYPE" = "2" ] && echo "仅上传" || ( [ "$TRAFFIC_TYPE" = "3" ] && echo "仅下载" || echo "总流量 (上传+下载)" ) )\ `
📦 *当前已用 / 总限额*: \`${used_gb} GB / ${TOTAL_LIMIT_GB} GB\`
📊 *使用百分比*: \`${percentage}%\`
📅 *重置规则*: \`每月 ${RESET_DAY} 号 ($RESET_TZ)\`
🕒 *统计时间*: \`$current_time\`
━━━━━━━━━━━━━━━━━━
🟢 *运行状态*: 系统正常监控中"

        if send_telegram "$report_msg"; then
            last_daily_date="$bj_date"
        fi
    fi

    # 2. 90% 流量预警推送
    is_above_90=$(echo "$percentage >= 90 &&$percentage < 95" | bc)
    if [ "$is_above_90" -eq 1 ] && [ "$warn_90_sent" = "false" ]; then
        warn_msg="⚠️ *【流量使用 90% 预警通知】*
━━━━━━━━━━━━━━━━━━
🖥️ *服务器名称*: \`$SERVER_NAME\`
📦 *已用 / 总限额*: \`${used_gb} GB / ${TOTAL_LIMIT_GB} GB\`
📊 *使用百分比*: \`${percentage}%\`
🕒 *触发时间*: \`$current_time\`
━━━━━━━━━━━━━━━━━━
💡 *温馨提示*: 本周期流量已消耗超过 90%，请合理控制网络使用！"
        if send_telegram "$warn_msg"; then
            warn_90_sent="true"
        fi
    fi

    # 3. 95% 流量超限自动关机推送
    is_above_95=$(echo "$percentage >= 95" | bc)
    if [ "$is_above_95" -eq 1 ] && [ "$shutdown_95_sent" = "false" ]; then
        shutdown_msg="🚨 *【流量超限自动关机报警】*
━━━━━━━━━━━━━━━━━━
🖥️ *服务器名称*: \`$SERVER_NAME\`
📦 *已用 / 总限额*: \`${used_gb} GB / ${TOTAL_LIMIT_GB} GB\`
📊 *使用百分比*: \`${percentage}%\`
🕒 *触发时间*: \`$current_time\`
━━━━━━━━━━━━━━━━━━
🛑 *严重警告*: 流量使用已达到或超过 95% 阈值，为了防止超出流量产生额外扣费，系统即将执行自动关机！"
        
        # 先校验 Telegram 关机通知是否正常发送成功，成功后再执行关机
        if send_telegram "$shutdown_msg"; then
            shutdown_95_sent="true"
            jq -n \
                --arg last_daily "$last_daily_date" \
                --arg w90 "$warn_90_sent" \
                --arg s95 "$shutdown_95_sent" \
                --arg cyc "$state_cycle" \
                '{last_daily_date: $last_daily, warn_90_sent: $w90, shutdown_95_sent:$s95, state_cycle: $cyc}' > "$STATE_FILE"
            
            shutdown -h now
        fi
    fi

    jq -n \
        --arg last_daily "$last_daily_date" \
        --arg w90 "$warn_90_sent" \
        --arg s95 "$shutdown_95_sent" \
        --arg cyc "$state_cycle" \
        '{last_daily_date: $last_daily, warn_90_sent: $w90, shutdown_95_sent:$s95, state_cycle: $cyc}' > "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# 8. GitHub 一键更新脚本
# ------------------------------------------------------------------------------
update_script() {
    echo -e "${BLUE}[+] 正在从 GitHub 检查并拉取最新脚本...${NC}"
    TEMP_SCRIPT="/tmp/traffic-monitor.sh"
    
    # 检查本地是否存在 traffic-monitor.sh 脚本，若存在则先执行删除
    if [ -f "$SCRIPT_PATH" ]; then
        echo -e "${YELLOW}[*] 检测到本地已存在脚本文件，正在执行删除并拉取更新...${NC}"
        rm -f "$SCRIPT_PATH"
    fi

    if curl -s -o "$TEMP_SCRIPT" "https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh"; then
        if grep -q "VERSION=" "$TEMP_SCRIPT"; then
            cp "$TEMP_SCRIPT" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            rm -f "$TEMP_SCRIPT"
            ln -sf "$SCRIPT_PATH" /usr/local/bin/traffic-monitor
            echo -e "${GREEN}[+] 脚本已成功更新至最新版本！${NC}"
        else
            echo -e "${RED}[-] 下载的文件格式异常，更新失败。${NC}"
        fi
    else
        echo -e "${RED}[-] 从 GitHub 下载脚本失败，请检查网络连接。${NC}"
    fi
    read -p "按回车键返回主菜单..."
}

# ------------------------------------------------------------------------------
# 9. 中文交互主菜单
# ------------------------------------------------------------------------------
show_menu() {
    while true; do
        clear
        load_config
        used_bytes=$(get_current_traffic_bytes 2>/dev/null || echo 0)
        used_gb=$(bytes_to_gb "$used_bytes")
        if [ "$(echo "$TOTAL_LIMIT_GB > 0" | bc)" -eq 1 ]; then
            percentage=$(echo "scale=2; ($used_gb / $TOTAL_LIMIT_GB) * 100" | bc)
        else
            percentage=0
        fi

        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}        流量监控与 Telegram 预警管理面板             ${NC}${YELLOW}$VERSION${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e " 🖥️  服务器名称   : ${GREEN}$SERVER_NAME${NC}"
        echo -e " 🌐 监控网卡接口 : ${GREEN}$INTERFACES${NC}"
        echo -e " 📅 流量重置规则 : ${GREEN}每月 ${RESET_DAY} 号 ($RESET_TZ)${NC}"
        echo -e " 📈 流量统计类型 : ${GREEN}$( [ "$TRAFFIC_TYPE" = "2" ] && echo "仅统计上传" || ( [ "$TRAFFIC_TYPE" = "3" ] && echo "仅统计下载" \vert{}\vert{} echo "总流量 (上传+下载)" ) )${NC}"
        echo -e " 📦 本周期已用流量: ${YELLOW}${used_gb} GB / ${TOTAL_LIMIT_GB} GB (${percentage}\%)${NC}"
        echo -e "${CYAN}------------------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} 修改/设置监控参数"
        echo -e " ${GREEN}2.${NC} 查看当前详细流量统计"
        echo -e " ${GREEN}3.${NC} 测试 Telegram 机器人通知"
        echo -e " ${GREEN}4.${NC} 手动触发一次流量检查"
        echo -e " ${GREEN}5.${NC} 一键更新脚本 (GitHub 最新版)"
        echo -e " ${RED}0.${NC} 退出脚本"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请输入对应的操作编号 [0-5]: " choice

        case $choice in
            1)
                configure_wizard
                ;;
            2)
                clear
                echo -e "${CYAN}=== vnstat 原始流量统计结果 ===${NC}"
                vnstat -i "$INTERFACES"
                echo -e "\n当前周期计算得出使用量: ${GREEN}${used_gb} GB / ${TOTAL_LIMIT_GB} GB (${percentage}\%)${NC}"
                read -p "按回车键返回主菜单..."
                ;;
            3)
                echo -e "${BLUE}[+] 正在向 Telegram 发送测试消息...${NC}"
                if send_telegram "🔔 *【流量监控测试通知】*
━━━━━━━━━━━━━━━━━━
🖥️ *服务器名称*: \`$SERVER_NAME\`
📦 *当前已用流量*: \`${used_gb} GB / ${TOTAL_LIMIT_GB} GB\` (${percentage}%)
🕒 *测试时间*: \`$(date '+%Y-%m-%d %H:%M:%S')\`
━━━━━━━━━━━━━━━━━━
✅ *状态提示*: Telegram 机器人配置正确，推送正常！"; then
                    echo -e "${GREEN}[+] 测试消息发送成功！请检查 Telegram 聊天窗口。${NC}"
                else
                    echo -e "${RED}[-] 测试消息发送失败，请检查 Bot Token 和 Chat ID 是否正确。${NC}"
                fi
                read -p "按回车键返回主菜单..."
                ;;
            4)
                echo -e "${BLUE}[+] 正在执行手动流量检查...${NC}"
                run_monitor
                echo -e "${GREEN}[+] 手动检查完成！如需查看日志请运行: tail -f $LOG_FILE${NC}"
                read -p "按回车键返回主菜单..."
                ;;
            5)
                update_script
                ;;
            0)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[-] 输入有误，请输入 0-5 之间的数字。${NC}"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 10. 脚本入口点处理
# ------------------------------------------------------------------------------
case "$1" in
    --monitor)
        run_monitor
        ;;
    --install)
        init_system
        configure_wizard
        ;;
    *)
        if [ ! -f "$CONFIG_FILE" ]; then
            init_system
            configure_wizard
        else
            show_menu
        fi
        ;;
esac
