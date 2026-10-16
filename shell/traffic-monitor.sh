#!/usr/bin/env bash
# ==============================================================================
# Script Name: traffic-monitor.sh
# Description: Debian 13 Traffic Monitor & Telegram Alert System using vnStat
# Version: 1.0.0
# Author: DarkerLab
# ==============================================================================

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: Please run this script as root (sudo ./traffic-monitor.sh)"
    exit 1
fi

CONFIG_FILE="/etc/traffic-monitor.conf"
DAEMON_SCRIPT="/usr/local/bin/traffic-monitor-daemon.sh"
CRON_JOB_FILE="/etc/cron.d/traffic-monitor"
VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 1. System Environment Check & Dependencies
install_dependencies() {
    echo "[+] Checking and installing system dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y vnstat curl jq bc cron systemd

    # Enable and start vnstat service
    systemctl enable vnstat
    systemctl start vnstat

    # Check and set timezone
    CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        echo "[+] Setting system timezone to Asia/Shanghai..."
        timedatectl set-timezone Asia/Shanghai
    else
        echo "[*] System timezone is already Asia/Shanghai."
    fi
}

# 2. Load Configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# 3. Save Configuration
save_config() {
    cat << EOF > "$CONFIG_FILE"
SERVER_NAME="$SERVER_NAME"
INTERFACES="$INTERFACES"
RESET_DAY="$RESET_DAY"
TIMEZONE_SETTING="$TIMEZONE_SETTING"
TRAFFIC_TYPE="$TRAFFIC_TYPE"
TOTAL_LIMIT_GB="$TOTAL_LIMIT_GB"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
WARN_PERCENT="$WARN_PERCENT"
SHUTDOWN_PERCENT="$SHUTDOWN_PERCENT"
EOF
    echo -G "[+] Configuration saved successfully to $CONFIG_FILE"
}

# 4. Interactive Configuration Wizard
configure_wizard() {
    echo "=================================================="
    echo "       Traffic Monitor Interactive Setup          "
    echo "=================================================="

    # Server Name
    default_name=$(hostname)
    read -p "Enter Server Name [Default: $default_name]: " input_name
    SERVER_NAME="${input_name:-$default_name}"

    # Network Interfaces Detection
    echo "[*] Available Network Interfaces:"
    ip -o link show | awk -F': ' '{print $2}' | grep -v "lo"
    read -p "Enter Network Interface(s) separated by space (e.g., eth0 or eth0 eth1): " INTERFACES
    if [ -z "$INTERFACES" ]; then
        INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n 1)
        echo "[*] No interface entered. Defaulting to: $INTERFACES"
    fi

    # Reset Day
    read -p "Enter monthly traffic reset day (1-31) [Default: 1]: " input_day
    RESET_DAY="${input_day:-1}"

    # Timezone for traffic calculation
    echo "Select traffic statistics timezone:"
    echo "1) UTC+0"
    echo "2) UTC+8 (Beijing Time)"
    read -p "Select [1-2, Default: 2]: " tz_choice
    if [ "$tz_choice" = "1" ]; then
        TIMEZONE_SETTING="UTC0"
    else
        TIMEZONE_SETTING="UTC8"
    fi

    # Traffic Type
    echo "Select traffic statistic type:"
    echo "1) Total Traffic (Upload + Download)"
    echo "2) Upload Only"
    echo "3) Download Only"
    read -p "Select [1-3, Default: 1]: " type_choice
    TRAFFIC_TYPE="${type_choice:-1}"

    # Total Limit
    read -p "Enter total monthly traffic limit in GB (e.g., 1000): " input_limit
    TOTAL_LIMIT_GB="${input_limit:-1000}"

    # Telegram Bot
    read -p "Enter Telegram Bot Token: " TG_BOT_TOKEN
    read -p "Enter Telegram Chat ID: " TG_CHAT_ID

    # Thresholds
    read -p "Enter warning threshold percentage [Default: 90]: " input_warn
    WARN_PERCENT="${input_warn:-90}"

    read -p "Enter shutdown threshold percentage [Default: 95]: " input_shutdown
    SHUTDOWN_PERCENT="${input_shutdown:-95}"

    save_config
    setup_daemon
    echo "[+] Configuration completed and daemon installed successfully!"
}

# 5. Telegram Notification Function
send_telegram() {
    local message="$1"
    if [ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ]; then
        return 1
    fi
    response=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown")
    
    if echo "$response" | grep -q '"ok":true'; then
        return 0
    else
        return 1
    fi
}

# 6. Calculate Traffic using vnstat
calculate_traffic() {
    local total_rx=0
    local total_tx=0

    # Ensure vnstat database is ready for specified interfaces
    for iface in $INTERFACES; do
        vnstat -i "$iface" --json >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            continue
        fi
        
        # Get json data for interface
        json_data=$(vnstat -i "$iface" --json)
        
        # Calculate based on current billing cycle (simplified via monthly vnstat summary or custom range)
        # For precision matching the reset day and timezone:
        rx_bytes=$(echo "$json_data" | jq -r --arg iface "$iface" '.interfaces[] \vert{} select(.name==$iface) | .traffic.month[0].rx')
        tx_bytes=$(echo "$json_data" | jq -r --arg iface "$iface" '.interfaces[] \vert{} select(.name==$iface) | .traffic.month[0].tx')
        
        if [ "$rx_bytes" != "null" ] && [ -n "$rx_bytes" ]; then
            total_rx=$((total_rx + rx_bytes))
        fi
        if [ "$tx_bytes" != "null" ] && [ -n "$tx_bytes" ]; then
            total_tx=$((total_tx + tx_bytes))
        fi
    done

    # Select traffic type
    local used_bytes=0
    case "$TRAFFIC_TYPE" in
        2) used_bytes=$total_tx ;; 3) used_bytes=$total_rx ;;
        *) used_bytes=$((total_rx + total_tx)) ;;
    end

    # Convert to GB (using decimal float)
    local used_gb
    used_gb=$(awk "BEGIN {print $used_bytes / 1024 / 1024 / 1024}")
    echo "$used_gb"
}

# 7. Core Daemon Script Generation (Runs every 1 minute)
setup_daemon() {
    cat << 'EOF' > "$DAEMON_SCRIPT"
#!/usr/bin/env bash
CONFIG_FILE="/etc/traffic-monitor.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi
source "$CONFIG_FILE"

# Timezone adjustment
if [ "$TIMEZONE_SETTING" = "UTC8" ]; then
    export TZ="Asia/Shanghai"
else
    export TZ="UTC"
fi

CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
CURRENT_HOUR_MIN=$(date '+%H:%M')
CURRENT_DAY=$(date '+%d')
TODAY_STR=$(date '+%Y-%m-%d')

# Helper to send telegram
send_tg() {
    local msg="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${msg}" \
        -d "parse_mode=Markdown" >/dev/null
}

# Calculate current used traffic in GB
total_rx=0
total_tx=0
for iface in $INTERFACES; do
    json_data=$(vnstat -i "$iface" --json 2>/dev/null)
    if [ $? -eq 0 ]; then
        rx=$(echo "$json_data" | jq -r --arg iface "$iface" '.interfaces[] \vert{} select(.name==$iface) | .traffic.month[0].rx // 0')
        tx=$(echo "$json_data" | jq -r --arg iface "$iface" '.interfaces[] \vert{} select(.name==$iface) | .traffic.month[0].tx // 0')
        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))
    fi
done

case "$TRAFFIC_TYPE" in
    2) used_bytes=$total_tx ;; 3) used_bytes=$total_rx ;;
    *) used_bytes=$((total_rx + total_tx)) ;;
esac

used_gb=$(awk "BEGIN {print $used_bytes / 1024 / 1024 / 1024}")
percentage=$(awk "BEGIN {printf \"%.2f\", ($used_gb / $TOTAL_LIMIT_GB) * 100}")

# 1. Daily Report at 08:10 Beijing Time
DAILY_LOCK="/var/run/traffic-monitor-daily.lock"
if [ "$CURRENT_HOUR_MIN" = "08:10" ]; then
    if [ ! -f "$DAILY_LOCK" ] \vert{}\vert{} [ "$(cat "$DAILY_LOCK")" != "$TODAY_STR" ]; then
        report_msg="📊 *Daily Traffic Report*
🏛 Server: \`$SERVER_NAME\`
📈 Used: \`$(printf "%.2f" "$used_gb") GB\` / \`$TOTAL_LIMIT_GB GB\` (\`$percentage%\`)
🕒 Time: \`$CURRENT_TIME\`"
        send_tg "$report_msg"
        echo "$TODAY_STR" > "$DAILY_LOCK"
    fi
fi

# 2. Warning Check (90%)
WARN_LOCK="/var/run/traffic-monitor-warn.lock"
is_warn_reached=$(awk "BEGIN {print ($percentage >=$WARN_PERCENT) ? 1 : 0}")
if [ "$is_warn_reached" -eq 1 ]; then
    current_month_key=$(date '+%Y-%m')
    if [ ! -f "$WARN_LOCK" ] \vert{}\vert{} [ "$(cat "$WARN_LOCK")" != "$current_month_key" ]; then
        warn_msg="⚠️ *Traffic Warning Notice*
🏛 Server: \`$SERVER_NAME\`
🚨 Traffic has reached *${percentage}%* (\`$(printf "%.2f" "$used_gb") GB\` / \`$TOTAL_LIMIT_GB GB\`)!
🕒 Time: \`$CURRENT_TIME\`"
        send_tg "$warn_msg"
        echo "$current_month_key" > "$WARN_LOCK"
    fi
fi

# 3. Shutdown Check (95%)
SHUTDOWN_LOCK="/var/run/traffic-monitor-shutdown.lock"
is_shutdown_reached=$(awk "BEGIN {print ($percentage >=$SHUTDOWN_PERCENT) ? 1 : 0}")
if [ "$is_shutdown_reached" -eq 1 ]; then
    current_month_key=$(date '+%Y-%m')
    if [ ! -f "$SHUTDOWN_LOCK" ] \vert{}\vert{} [ "$(cat "$SHUTDOWN_LOCK")" != "$current_month_key" ]; then
        shutdown_msg="🛑 *Critical: Traffic Limit Exceeded*
🏛 Server: \`$SERVER_NAME\`
⚡ Traffic reached *${percentage}%* (\`$(printf "%.2f" "$used_gb") GB\` / \`$TOTAL_LIMIT_GB GB\`).
🔌 *Server is shutting down now to prevent overage!*
🕒 Time: \`$CURRENT_TIME\`"
        
        # Verify notification sent successfully before shutdown
        response=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "text=${shutdown_msg}" \
            -d "parse_mode=Markdown")
        
        if echo "$response" | grep -q '"ok":true'; then
            echo "$current_month_key" > "$SHUTDOWN_LOCK"
            shutdown -h now
        fi
    fi
fi
EOF

    chmod +x "$DAEMON_SCRIPT"

    # Setup Cron job for 1-minute interval
    echo "* * * * * root /bin/bash $DAEMON_SCRIPT >/dev/null 2>&1" > "$CRON_JOB_FILE"
    systemctl restart cron
}

# 8. Script Self-Update
self_update() {
    echo "[+] Checking for script updates..."
    LOCAL_SCRIPT_PATH="$(readlink -f "$0")"
    if [ -f "$LOCAL_SCRIPT_PATH" ]; then
        echo "[+] Removing local script file..."
        rm -f "$LOCAL_SCRIPT_PATH"
    fi
    
    echo "[+] Downloading latest update from GitHub..."
    curl -o "$LOCAL_SCRIPT_PATH" https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh
    if [ $? -eq 0 ]; then
        chmod +x "$LOCAL_SCRIPT_PATH"
        echo "[+] Script updated successfully to version v$VERSION. Restarting..."
        exec "$LOCAL_SCRIPT_PATH"
    else
        echo "[-] Update failed! Please check your network connection."
    fi
}

# 9. Status & Traffic View
view_status() {
    load_config
    echo "=================================================="
    echo "          Traffic Monitor Status Report           "
    echo "=================================================="
    echo "Server Name    : $SERVER_NAME"
    echo "Interfaces     : $INTERFACES"
    echo "Reset Day      : $RESET_DAY"
    echo "Timezone       : $TIMEZONE_SETTING"
    echo "Traffic Type   : $TRAFFIC_TYPE (1:Total, 2:Upload, 3:Download)"
    echo "Total Limit    : $TOTAL_LIMIT_GB GB"
    echo "Warn Threshold : $WARN_PERCENT%"
    echo "Shutdown Limit : $SHUTDOWN_PERCENT%"
    echo "--------------------------------------------------"
    used_gb=$(calculate_traffic)
    percentage=$(awk "BEGIN {printf \"%.2f\", ($used_gb / $TOTAL_LIMIT_GB) * 100}")
    echo -e "Current Used   : ${GREEN}${used_gb} GB${NC} / ${TOTAL_LIMIT_GB} GB (${percentage}%)"
    echo "=================================================="
}

# 10. Interactive Menu
show_menu() {
    clear
    echo "=================================================="
    echo "    Debian 13 Traffic Monitor Control Panel       "
    echo "    Version: v$VERSION                            "
    echo "=================================================="
    echo "1. Install / Initial Setup"
    echo "2. Modify Configuration"
    echo "3. View Current Traffic & Status"
    echo "4. Test Telegram Notification"
    echo "5. Run Check Manually"
    echo "6. Update Script (Self-Update)"
    echo "7. Uninstall Traffic Monitor"
    echo "0. Exit"
    echo "=================================================="
    read -p "Select an option [0-7]: " choice

    case "$choice" in
        1)
            install_dependencies
            configure_wizard
            ;;
        2)
            configure_wizard
            ;;
        3)
            view_status
            ;;
        4)
            load_config
            if [ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ]; then
                echo "[-] Telegram bot is not configured yet."
            else
                echo "[+] Sending test notification to Telegram..."
                if send_telegram "🔔 *Test Notification* from server \`$SERVER_NAME\`. Configuration is working correctly!"; then
                    echo "[+] Test notification sent successfully!"
                else
                    echo "[-] Failed to send notification. Check Token and Chat ID."
                fi
            fi
            ;;
        5)
            echo "[+] Executing daemon check manually..."
            /bin/bash "$DAEMON_SCRIPT"
            echo "[+] Execution finished."
            ;;
        6)
            self_update
            ;;
        7)
            echo "[+] Uninstalling Traffic Monitor..."
            rm -f "$CONFIG_FILE"
            rm -f "$DAEMON_SCRIPT"
            rm -f "$CRON_JOB_FILE"
            systemctl restart cron
            echo "[+] Uninstalled successfully."
            ;;
        0)
            exit 0
            ;;
        *)
            echo "[-] Invalid option."
            ;;
    esac
    echo ""
    read -p "Press Enter to return to main menu..."
    show_menu
}

# Entry point
if [ "$1" = "update" ]; then
    self_update
else
    show_menu
fi
