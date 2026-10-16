#!/usr/bin/env bash
# ==============================================================================
# Script Name: traffic-monitor.sh
# Description: Debian 13 Traffic Monitor, Daily Telegram Report, and Auto-Shutdown
# ==============================================================================

CONF_FILE="/etc/traffic-monitor.conf"
STATE_FILE="/var/lib/traffic-monitor/state.json"
SCRIPT_PATH="/usr/local/bin/traffic-monitor.sh"
LOG_FILE="/var/log/traffic-monitor.log"
VERSION="v1.2.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Ensure root privilege
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[Error] Please run this script as root (sudo).${NC}"
    exit 1
fi

# Initialize environment and dependencies
init_environment() {
    echo -e "${CYAN}[Info] Checking system environment and dependencies...${NC}"
    
    # Check timezone
    CURRENT_TZ=$(timedatectl show --property=Timezone --value)
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        echo -e "${YELLOW}[Info] Current timezone is $CURRENT_TZ. Setting timezone to Asia/Shanghai...${NC}"
        timedatectl set-timezone Asia/Shanghai
    else
        echo -e "${GREEN}[Info] Timezone is already Asia/Shanghai.${NC}"
    fi

    # Update and install dependencies
    apt-get update -y
    apt-get install -y vnstat curl jq bc python3 cron

    # Enable and start vnstat
    systemctl enable --now vnstat
    
    # Create required directories
    mkdir -p /var/lib/traffic-monitor
    touch "$LOG_FILE"
}

# Load Configuration
load_config() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    else
        SERVER_NAME=$(hostname)
        INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n 1)
        RESET_DAY=1
        TZ_OFFSET="UTC8"
        TRAFFIC_TYPE=1
        TOTAL_LIMIT_GB=1000
        WARN_PERCENT=90
        SHUTDOWN_PERCENT=95
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi
}

# Save Configuration
save_config() {
    cat <<EOF > "$CONF_FILE"
SERVER_NAME="$SERVER_NAME"
INTERFACES="$INTERFACES"
RESET_DAY=$RESET_DAY
TZ_OFFSET="$TZ_OFFSET"
TRAFFIC_TYPE=$TRAFFIC_TYPE
TOTAL_LIMIT_GB=$TOTAL_LIMIT_GB
WARN_PERCENT=$WARN_PERCENT
SHUTDOWN_PERCENT=$SHUTDOWN_PERCENT
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
}

# Setup Cron Jobs for 1-min check and daily report (08:10 Beijing time)
setup_cron() {
    CRON_CHECK="* * * * * /usr/local/bin/traffic-monitor.sh --check >> /var/log/traffic-monitor.log 2>&1"
    CRON_REPORT="10 8 * * * /usr/local/bin/traffic-monitor.sh --daily-report >> /var/log/traffic-monitor.log 2>&1"
    
    (crontab -l 2>/dev/null | grep -v "traffic-monitor.sh"; echo "$CRON_CHECK"; echo "$CRON_REPORT") | crontab -
}

# Interactive Configuration Menu
interactive_menu() {
    load_config
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       Debian 13 Traffic Monitor & Alert System       ${NC}"
    echo -e "${CYAN}       Version: ${VERSION}                             ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo " 1. Configure Parameters (Server Name, Interfaces, Limits)"
    echo " 2. Configure Telegram Bot & Notifications"
    echo " 3. View Current Traffic Statistics"
    echo " 4. Test Telegram Notification"
    echo " 5. Check & Update Script (Self-Update)"
    echo " 0. Exit & Save"
    echo -e "${CYAN}======================================================${NC}"
    read -p "Select an option [0-5]: " choice

    case $choice in
        1)
            read -p "Enter Server Name [$SERVER_NAME]: " input_name
            [ -n "$input_name" ] && SERVER_NAME="$input_name"

            echo "Available network interfaces:"
            ip -o link show | awk -F': ' '{print " - " $2}'
            read -p "Enter Monitoring Interface(s) (space separated) [$INTERFACES]: " input_iface
            [ -n "$input_iface" ] && INTERFACES="$input_iface"

            read -p "Enter Monthly Reset Day (1-31) [$RESET_DAY]: " input_day
            [[ "$input_day" =~ ^[0-9]+$ ]] && RESET_DAY="$input_day"

            echo "Select Timezone for Traffic Reset:"
            echo " 1) UTC0"
            echo " 2) UTC8 (Beijing Time)"
            read -p "Select [1-2] (default 2): " tz_choice
            [ "$tz_choice" = "1" ] && TZ_OFFSET="UTC0" || TZ_OFFSET="UTC8"

            echo "Select Traffic Statistic Type:"
            echo " 1) Total (Upload + Download)"
            echo " 2) Upload Only"
            echo " 3) Download Only"
            read -p "Select [1-3] [$TRAFFIC_TYPE]: " input_ttype
            [[ "$input_ttype" =~ ^[1-3]$ ]] && TRAFFIC_TYPE="$input_ttype"

            read -p "Enter Monthly Traffic Limit in GB (0 for unlimited) [$TOTAL_LIMIT_GB]: " input_limit
            [[ "$input_limit" =~ ^[0-9]+$ ]] && TOTAL_LIMIT_GB="$input_limit"

            read -p "Enter Warning Threshold Percentage [$WARN_PERCENT]: " input_warn
            [[ "$input_warn" =~ ^[0-9]+$ ]] && WARN_PERCENT="$input_warn"

            read -p "Enter Shutdown Threshold Percentage [$SHUTDOWN_PERCENT]: " input_shut
            [[ "$input_shut" =~ ^[0-9]+$ ]] && SHUTDOWN_PERCENT="$input_shut"

            save_config
            setup_cron
            # Copy script to /usr/local/bin if not already there
            if [ "$0" != "$SCRIPT_PATH" ]; then
                cp "$0" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
            fi
            echo -e "${GREEN}[Success] Configuration updated successfully!${NC}"
            sleep 2
            interactive_menu
            ;;
        2)
            read -p "Enter Telegram Bot Token [$TG_BOT_TOKEN]: " input_token
            [ -n "$input_token" ] && TG_BOT_TOKEN="$input_token"

            read -p "Enter Telegram Chat ID [$TG_CHAT_ID]: " input_chat
            [ -n "$input_chat" ] && TG_CHAT_ID="$input_chat"

            save_config
            echo -e "${GREEN}[Success] Telegram settings saved!${NC}"
            sleep 2
            interactive_menu
            ;;
        3)
            clear
            echo -e "${CYAN}=== Current Traffic Statistics ===${NC}"
            get_traffic_stats
            echo ""
            read -p "Press Enter to return to menu..."
            interactive_menu
            ;;
        4)
            if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
                echo -e "${RED}[Error] Telegram Bot Token and Chat ID are not configured.${NC}"
            else
                send_telegram "🔔 <b>Test Notification</b>\nServer: <code>$SERVER_NAME</code>\nStatus: Telegram bot configured successfully!"
                echo -e "${GREEN}[Info] Test message sent. Check your Telegram.${NC}"
            fi
            sleep 2
            interactive_menu
            ;;
        5)
            echo -e "${CYAN}[Info] Checking for script updates...${NC}"
            if [ -f "$SCRIPT_PATH" ]; then
                rm -f "$SCRIPT_PATH"
            fi
            if curl -sSL "https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh" -o "$SCRIPT_PATH"; then
                chmod +x "$SCRIPT_PATH"
                echo -e "${GREEN}[Success] Script updated successfully! Restarting script...${NC}"
                sleep 2
                exec "$SCRIPT_PATH"
            else
                echo -e "${RED}[Error] Failed to download update from GitHub.${NC}"
            fi
            sleep 2
            interactive_menu
            ;;
        0)
            echo -e "${GREEN}Exiting. Monitor is running in background.${NC}"
            exit 0
            ;;
        *)
            interactive_menu
            ;;
    esac
}

# Calculate Traffic using Python for precision and date range filtering
get_traffic_stats() {
    load_config
    python3 - "$INTERFACES" "$RESET_DAY" "$TZ_OFFSET" "$TRAFFIC_TYPE" "$TOTAL_LIMIT_GB" << 'EOF'
import json
import subprocess
import sys
from datetime import datetime, timezone, timedelta

interfaces = sys.argv[1].split()
reset_day = int(sys.argv[2])
tz_offset_str = sys.argv[3]
traffic_type = int(sys.argv[4])
limit_gb = float(sys.argv[5])

# Determine timezone offset
if tz_offset_str == "UTC8":
    tz = timezone(timedelta(hours=8))
else:
    tz = timezone.utc

now = datetime.now(tz)
current_year = now.year
current_month = now.month
current_day = now.day

# Calculate billing cycle start date
if current_day >= reset_day:
    start_date = datetime(current_year, current_month, reset_day, tzinfo=tz)
else:
    if current_month == 1:
        start_date = datetime(current_year - 1, 12, reset_day, tzinfo=tz)
    else:
        start_date = datetime(current_year, current_month - 1, reset_day, tzinfo=tz)

total_rx = 0
total_tx = 0

for iface in interfaces:
    try:
        cmd = ["vnstat", "-i", iface, "--json", "d"]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(res.stdout)
        
        for inf in data.get("interfaces", []):
            for day_entry in inf.get("traffic", {}).get("days", []):
                d_date = datetime(day_entry["date"]["year"], day_entry["date"]["month"], day_entry["date"]["day"], tzinfo=tz)
                if d_date >= start_date:
                    total_rx += day_entry.get("rx", 0)
                    total_tx += day_entry.get("tx", 0)
    except Exception as e:
        pass

if traffic_type == 1:
    used_bytes = total_rx + total_tx
elif traffic_type == 2:
    used_bytes = total_tx
else:
    used_bytes = total_rx

used_gb = used_bytes / (1024 ** 3)
limit_bytes = limit_gb * (1024 ** 3) if limit_gb > 0 else 0
percentage = (used_bytes / limit_bytes * 100) if limit_bytes > 0 else 0

print(f"USED_GB:{used_gb:.2f}")
print(f"PERCENTAGE:{percentage:.2f}")
print(f"START_DATE:{start_date.strftime('%Y-%m-%d')}")
print(f"CURRENT_DATE:{now.strftime('%Y-%m-%d %H:%M')}")
EOF
}

# Send Telegram Message with HTML formatting
send_telegram() {
    local message="$1"
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        return 1
    }
    response=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=${message}")
    
    if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 1-Minute Check Routine (Thresholds & Alerts)
check_routine() {
    load_config
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        return
    fi

    stats=$(get_traffic_stats)
    used_gb=$(echo "$stats" | grep "USED_GB" | cut -d':' -f2)
    percentage=$(echo "$stats" | grep "PERCENTAGE" | cut -d':' -f2)
    current_date=$(echo "$stats" | grep "CURRENT_DATE" | cut -d':' -f2-)

    # State tracking to avoid duplicate alerts in the same cycle
    cycle_month=$(date +%Y%m)
    state_file_path="$STATE_FILE"
    
    warn_sent=false
    shutdown_sent=false
    if [ -f "$state_file_path" ]; then
        saved_month=$(jq -r '.month // ""' "$state_file_path")
        if [ "$saved_month" = "$cycle_month" ]; then
            warn_sent=$(jq -r '.warn_sent // false' "$state_file_path")
            shutdown_sent=$(jq -r '.shutdown_sent // false' "$state_file_path")
        fi
    fi

    # Check Shutdown Threshold (95%)
    is_shutdown_reached=$(echo "$percentage >= $SHUTDOWN_PERCENT" | bc -l)
    if [ "$is_shutdown_reached" -eq 1 ] && [ "$shutdown_sent" = "false" ] && [ "$TOTAL_LIMIT_GB" -gt 0 ]; then
        msg="🚨 <b>CRITICAL: Traffic Exhaustion Shutdown</b>\n"
        msg+="━━━━━━━━━━━━━━━━━━━━━━\n"
        msg+="🖥️ Server: <code>$SERVER_NAME</code>\n"
        msg+="📊 Used: <b>${used_gb} GB / ${TOTAL_LIMIT_GB} GB (${percentage}%)</b>\n"
        msg+="⏰ Time: <code>$current_date</code>\n"
        msg+="⚠️ Threshold reached <b>${SHUTDOWN_PERCENT}%</b>. Server is shutting down now."

        if send_telegram "$msg"; then
            # Update state
            jq -n --arg m "$cycle_month" --argjson w "$warn_sent" --argjson s true '{month: $m, warn_sent: $w, shutdown_sent: $s}' > "$state_file_path"
            sync
            sleep 2
            shutdown now
        fi
        return
    fi

    # Check Warning Threshold (90%)
    is_warn_reached=$(echo "$percentage >= $WARN_PERCENT" | bc -l)
    if [ "$is_warn_reached" -eq 1 ] && [ "$warn_sent" = "false" ] && [ "$TOTAL_LIMIT_GB" -gt 0 ]; then
        msg="⚠️ <b>TRAFFIC WARNING ALERT</b>\n"
        msg+="━━━━━━━━━━━━━━━━━━━━━━\n"
        msg+="🖥️ Server: <code>$SERVER_NAME</code>\n"
        msg+="📊 Used: <b>${used_gb} GB / ${TOTAL_LIMIT_GB} GB (${percentage}%)</b>\n"
        msg+="⏰ Time: <code>$current_date</code>\n"
        msg+="💡 Traffic has exceeded <b>${WARN_PERCENT}%</b> of your monthly quota."

        if send_telegram "$msg"; then
            jq -n --arg m "$cycle_month" --argjson w true --argjson s "$shutdown_sent" '{month: $m, warn_sent: $w, shutdown_sent: $s}' > "$state_file_path"
        fi
    fi
}

# Daily Report Routine (08:10 Beijing Time)
daily_report_routine() {
    load_config
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        return
    fi

    stats=$(get_traffic_stats)
    used_gb=$(echo "$stats" | grep "USED_GB" | cut -d':' -f2)
    percentage=$(echo "$stats" | grep "PERCENTAGE" | cut -d':' -f2)
    start_date=$(echo "$stats" | grep "START_DATE" | type=$(echo "$stats" | grep "TRAFFIC_TYPE" | cut -d':' -f2) cut -d':' -f2)
    current_date=$(echo "$stats" | grep "CURRENT_DATE" | cut -d':' -f2-)

    if [ "$TOTAL_LIMIT_GB" -gt 0 ]; then
        limit_str="${TOTAL_LIMIT_GB} GB"
        perc_str="(${percentage}%)"
    else
        limit_str="Unlimited"
        perc_str=""
    fi

    msg="📈 <b>Daily Traffic Report</b>\n"
    msg+="━━━━━━━━━━━━━━━━━━━━━━\n"
    msg+="🖥️ Server: <code>$SERVER_NAME</code>\n"
    msg+="📅 Period: <code>$start_date to Now</code>\n"
    msg+="📊 Usage: <b>${used_gb} GB / ${limit_str} ${perc_str}</b>\n"
    msg+="⏰ Time: <code>$current_date (UTC+8)</code>\n"
    msg+="✅ Status: Normal & Monitored"

    send_telegram "$msg"
}

# Argument Dispatcher
case "$1" in
    --check)
        check_routine
        ;;
    --daily-report)
        daily_report_routine
        ;;
    *)
        if [ ! -f "$CONF_FILE" ]; then
            init_environment
        fi
        interactive_menu
        ;;
esac
