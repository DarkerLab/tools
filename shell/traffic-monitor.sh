cat << 'EOF' > traffic-monitor.sh
#!/usr/bin/env bash
# ==============================================================================
# Script Name: traffic-monitor.sh
# Description: Debian 13 Traffic Monitor & Telegram Alert System using vnStat
# Version: 1.0.1
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
VERSION="1.0.1"

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
    echo -e "${GREEN}[+] Configuration saved successfully to $CONFIG_FILE${NC}"
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
    echo "1
