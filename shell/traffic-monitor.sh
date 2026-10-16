#!/usr/bin/env bash
# ==============================================================================
# Script Name: traffic-monitor.sh
# Description: Advanced Traffic Monitor & Telegram Alert System for Debian 13
# Version: v1.1.0
# Author: DarkerLab
# GitHub Raw URL: https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh
# ==============================================================================

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run this script as root (sudo ./traffic-monitor.sh)"
    exit 1
fi

CONFIG_FILE="/etc/traffic-monitor/config.json"
STATE_FILE="/etc/traffic-monitor/state.json"
LOG_FILE="/var/log/traffic-monitor.log"
SCRIPT_PATH="/usr/local/bin/traffic-monitor.sh"
VERSION="v1.1.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# 1. System Environment Check & Dependencies
# ------------------------------------------------------------------------------
init_system() {
    echo -e "${BLUE}[+] Checking system environment and dependencies...${NC}"
    
    # Check Timezone
    CURRENT_TZ=$(timedatectl show --property=Timezone --value)
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        echo -e "${YELLOW}[*] Current timezone is$CURRENT_TZ. Changing to Asia/Shanghai...${NC}"
        timedatectl set-timezone Asia/Shanghai
    else
        echo -e "${GREEN}[+] Timezone is correctly set to Asia/Shanghai.${NC}"
    fi

    # Update package list and install dependencies
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y vnstat curl jq bc cron gawk

    # Ensure vnstat service is running and enabled
    systemctl enable --now vnstat
    
    # Create configuration directory
    mkdir -p /etc/traffic-monitor
    touch "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# 2. Configuration Management
# ------------------------------------------------------------------------------
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        SERVER_NAME=$(jq -r '.server_name // "MyServer"' "$CONFIG_FILE")
        INTERFACES=$(jq -r '.interfaces // "eth0"' "$CONFIG_FILE")
        RESET_DAY=$(jq -r '.reset_day // 1' "$CONFIG_FILE")
        RESET_TZ=$(jq -r '.reset_tz // "UTC8"' "$CONFIG_FILE")
        TRAFFIC_TYPE=$(jq -r '.traffic_type // 1' "$CONFIG_FILE")
        TOTAL_LIMIT_GB=$(jq -r '.total_limit_gb // 1000' "$CONFIG_FILE")
        TG_BOT_TOKEN=$(jq -r '.tg_bot_token // ""' "$CONFIG_FILE")
        TG_CHAT_ID=$(jq -r '.tg_chat_id // ""' "$CONFIG_FILE")
    else
        SERVER_NAME="MyServer"
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
# 3. Interactive Configuration Wizard
# ------------------------------------------------------------------------------
configure_wizard() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}      Traffic Monitor & Alert System Setup Wizard${NC}"
    echo -e "${CYAN}      Version: $VERSION${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    load_config

    read -p "Enter Server Name [Current: $SERVER_NAME]: " input_name
    [ -n "$input_name" ] && SERVER_NAME="$input_name"

    echo -e "\n${YELLOW}Available Network Interfaces:${NC}"
    ip -o link show | awk -F': ' '{print $2}'
    read -p "Enter monitored interface(s), space-separated for multiple [Current: $INTERFACES]: " input_ifaces
    [ -n "$input_ifaces" ] && INTERFACES="$input_ifaces"

    read -p "Enter monthly traffic reset day (1-31) [Current: $RESET_DAY]: " input_day
    if [ -n "$input_day" ]; then
        RESET_DAY="$input_day"
    fi

    echo -e "\nSelect Reset Timezone:"
    echo "1) UTC+0"
    echo "2) UTC+8 (Beijing Time)"
    read -p "Enter choice (1-2) [Current: $RESET_TZ]: " input_tz_choice
    if [ "$input_tz_choice" = "1" ]; then
        RESET_TZ="UTC0"
    elif [ "$input_tz_choice" = "2" ]; then
        RESET_TZ="UTC8"
    fi

    echo -e "\nSelect Traffic Statistics Type:"
    echo "1) Total Traffic (Upload + Download)"
    echo "2) Upload Traffic Only"
    echo "3) Download Traffic Only"
    read -p "Enter choice (1-3) [Current: $TRAFFIC_TYPE]: " input_type
    [ -n "$input_type" ] && TRAFFIC_TYPE="$input_type"

    read -p "Enter Monthly Traffic Limit in GB [Current: $TOTAL_LIMIT_GB]: " input_limit
    [ -n "$input_limit" ] && TOTAL_LIMIT_GB="$input_limit"

    read -p "Enter Telegram Bot Token [Current: $TG_BOT_TOKEN]: " input_token
    [ -n "$input_token" ] && TG_BOT_TOKEN="$input_token"

    read -p "Enter Telegram Chat ID [Current: $TG_CHAT_ID]: " input_chat_id
    [ -n "$input_chat_id" ] && TG_CHAT_ID="$input_chat_id"

    save_config
    setup_cron_and_script
    
    # Create symlink for quick global access
    ln -sf "$SCRIPT_PATH" /usr/local/bin/traffic-monitor

    echo -e "\n${GREEN}[+] Configuration saved successfully and cron job updated!${NC}"
    read -p "Press Enter to return to menu..."
}

# ------------------------------------------------------------------------------
# 4. Setup Cron and Script Copy
# ------------------------------------------------------------------------------
setup_cron_and_script() {
    if [ "$0" != "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi

    # Set up 1-minute cron job
    CRON_JOB="* * * * * $SCRIPT_PATH --monitor >>$LOG_FILE 2>&1"
    (crontab -l 2>/dev/null | grep -v "traffic-monitor.sh") | { cat; echo "$CRON_JOB"; } | crontab -
}

# ------------------------------------------------------------------------------
# 5. Telegram Notification Function
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
# 6. Traffic Calculation Logic
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
# 7. Monitor & Alert Core Execution (Called every 1 minute)
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

    # 1. Telegram Daily Report at 08:10 Beijing Time (UTC+8)
    bj_hm=$(TZ='Asia/Shanghai' date "+%H:%M")
    bj_date=$(TZ='Asia/Shanghai' date "+%Y-%m-%d")
    
    if [ "$bj_hm" = "08:10" ] && [ "$last_daily_date" != "$bj_date" ]; then
        report_msg="📊 *服务器流量日报*
----------------------------------
🏷️ *服务器名称*: \`$SERVER_NAME\`
🌐 *监控网口*: \`$INTERFACES\`
📈 *统计类型*: \`$( [ "$TRAFFIC_TYPE" = "2" ] && echo "上传流量" || ( [ "$TRAFFIC_TYPE" = "3" ] && echo "下载流量" || echo "总流量 (上传+下载)" ) )\`
📦 *已用 / 总流量*: \`${used_gb} GB / ${TOTAL_LIMIT_GB} GB\` (${percentage}%)
⏱️ *时区与重置*: \`$RESET_TZ (每月 ${RESET_DAY} 号重置)\`
🕒 *推送时间*: \`$current_time\`
----------------------------------
🟢 *系统状态*: 运行正常"

        if send_telegram "$report_msg"; then
            last_daily_date="$bj_date"
        fi
    fi

    # 2. 90% Warning Push Notification
    is_above_90=$(echo "$percentage >= 90 &&$percentage < 95" | bc)
    if [ "$is_above_90" -eq 1 ] && [ "$warn_90_sent" = "false" ]; then
        warn_msg="⚠️ *流量预警通知 (90%)*
----------------------------------
🏷️ *服务器名称*: \`$SERVER_NAME\`
📦 *当前已用流量*: \`${used_gb} GB / ${TOTAL_LIMIT_GB} GB\` (${percentage}%)
🕒 *触发时间*: \`$current_time\`
----------------------------------
💡 *提示*: 流量已达到 90%，请注意控制流量消耗！"
        if send_telegram "$warn_msg"; then
            warn_90_sent="true"
        fi
    fi

    # 3. 95% Shutdown Alarm Push Notification
    is_above_95=$(echo "$percentage >= 95" | bc)
    if [ "$is_above_95" -eq 1 ] && [ "$shutdown_95_sent" = "false" ]; then
        shutdown_msg="🚨 *流量超限关机报警 (95%)*
----------------------------------
🏷️ *服务器名称*: \`$SERVER_NAME\`
📦 *当前已用流量*: \`${used_gb} GB / ${TOTAL_LIMIT_GB} GB\` (${percentage}%)
🕒 *触发时间*: \`$current_time\`
----------------------------------
❌ *警告*: 流量已超过 95% 阈值，服务器即将执行关机保护！"
        
        # Verify notification success before executing shutdown
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
# 8. One-Click Script Update
# ------------------------------------------------------------------------------
update_script() {
    echo -e "${BLUE}[+] Checking for script updates from GitHub...${NC}"
    TEMP_SCRIPT="/tmp/traffic-monitor.sh"
    
    if [ -f "$SCRIPT_PATH" ]; then
        echo -e "${YELLOW}[*] Removing local script before update...${NC}"
        rm -f "$SCRIPT_PATH"
    fi

    if curl -s -o "$TEMP_SCRIPT" "https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh"; then
        if grep -q "version" "$TEMP_SCRIPT"; then
            cp "$TEMP_SCRIPT" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            rm -f "$TEMP_SCRIPT"
            ln -sf "$SCRIPT_PATH" /usr/local/bin/traffic-monitor
            echo -e "${GREEN}[+] Script updated successfully!${NC}"
        else
            echo -e "${RED}[-] Downloaded script seems invalid.${NC}"
        fi
    else
        echo -e "${RED}[-] Failed to download script from GitHub.${NC}"
    fi
    read -p "Press Enter to return to menu..."
}

# ------------------------------------------------------------------------------
# 9. Interactive Main Menu
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
        echo -e "${CYAN}        Traffic Monitor & Alert Management Panel      ${NC}v$VERSION"
        echo -e "${CYAN}======================================================${NC}"
        echo -e " Server Name    : ${GREEN}$SERVER_NAME${NC}"
        echo -e " Monitored Iface: ${GREEN}$INTERFACES${NC}"
        echo -e " Reset Day      : ${GREEN}Monthly on day$RESET_DAY ($RESET_TZ)${NC}"
        echo -e " Traffic Type   : ${GREEN}$( [ "$TRAFFIC_TYPE" = "2" ] && echo "Upload Only" || ( [ "$TRAFFIC_TYPE" = "3" ] && echo "Download Only" || echo "Total (Up+Down)" ) )${NC}"
        echo -e " Current Usage  : ${YELLOW}${used_gb} GB / ${TOTAL_LIMIT_GB} GB (${percentage}\%)${NC}"
        echo -e "${CYAN}------------------------------------------------------${NC}"
        echo -e " 1) Configure / Modify Parameters"
        echo -e " 2) View Current Traffic Status"
        echo -e " 3) Test Telegram Notification"
        echo -e " 4) Run Manual Monitor Check"
        echo -e " 5) Update Script (Pull from GitHub)"
        echo -e " 0) Exit"
        echo -e "${CYAN}======================================================${NC}"
        read -p "Please enter your choice (0-5): " choice

        case $choice in
            1)
                configure_wizard
                ;;
            2)
                clear
                echo -e "${CYAN}=== Current Traffic Status ===${NC}"
                vnstat -i "$INTERFACES"
                echo -e "\nCalculated Current Cycle Usage: ${GREEN}${used_gb} GB / ${TOTAL_LIMIT_GB} GB (${percentage}\%)${NC}"
                read -p "Press Enter to return to menu..."
                ;;
            3)
                echo -e "${BLUE}[+] Sending test notification to Telegram...${NC}"
                if send_telegram "🔔 *Traffic Monitor Test Notification*
----------------------------------
🏷️ *Server Name*: \`$SERVER_NAME\`
📦 *Current Usage*: \`${used_gb} GB / ${TOTAL_LIMIT_GB} GB\` (${percentage}%)
🕒 *Time*: \`$(date)\`
----------------------------------
✅ *Status*: Telegram Bot is working properly!"; then
                    echo -e "${GREEN}[+] Test message sent successfully!${NC}"
                else
                    echo -e "${RED}[-] Failed to send test message. Check Bot Token and Chat ID.${NC}"
                fi
                read -p "Press Enter to return to menu..."
                ;;
            4)
                echo -e "${BLUE}[+] Running manual monitor check...${NC}"
                run_monitor
                echo -e "${GREEN}[+] Manual check completed. Check logs at $LOG_FILE${NC}"
                read -p "Press Enter to return to menu..."
                ;;
            5)
                update_script
                ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[-] Invalid option, please try again.${NC}"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 10. Entry Point
# ---------------------------------------------------
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
