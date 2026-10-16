#!/usr/bin/env bash
​==============================================================================
​Script Name: traffic-monitor.sh
​Description: Advanced Traffic Monitor & Telegram Alert System for Debian 13
​Version: 1.2.1
​Author: DarkerLab
​==============================================================================
​STREAMING_CHUNK:Checking system root privileges and environment...
​[[ $EUID -ne 0 ]] && { echo "[-] Error: This script must be run as root (sudo)"; exit 1; }
​CONFIG_DIR="/etc/traffic-monitor"
CONFIG_FILE="$CONFIG_DIR/config.conf"
STATE_FILE="$CONFIG_DIR/state.json"
SCRIPT_PATH="/usr/local/bin/traffic-monitor.sh"
VERSION="1.2.1"
​Ensure directories exist
​mkdir -p "$CONFIG_DIR"
​STREAMING_CHUNK:Configuring system timezone and updating packages...
​check_and_setup_system() {
echo "[+] Checking system environment and timezone..."
CURRENT_TZ=$(timedatectl show --property=Timezone --value)
if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
echo "[+] Current timezone is $CURRENT_TZ. Setting timezone to Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai
else
echo "[+] System timezone is already Asia/Shanghai."
fi
​echo "[+] Updating package lists and installing required dependencies..."
apt-get update -y
apt-get install -y vnstat curl jq bc cron
systemctl enable --now vnstat
}
​STREAMING_CHUNK:Loading configuration and setting default values...
​load_config() {
if [ -f "$CONFIG_FILE" ]; then
source "$CONFIG_FILE"
else
SERVER_NAME="My-Debian-Server"
INTERFACES="eth0"
RESET_DAY="1"
TIMEZONE="UTC8" # UTC0 or UTC8
STAT_TYPE="1"   # 1: Total, 2: Upload, 3: Download
TOTAL_LIMIT_GB="1000"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
fi
}
​save_config() {
cat << EOF > "$CONFIG_FILE"
SERVER_NAME="$SERVER_NAME"
INTERFACES="$INTERFACES"
RESET_DAY="$RESET_DAY"
TIMEZONE="$TIMEZONE"
STAT_TYPE="$STAT_TYPE"
TOTAL_LIMIT_GB="$TOTAL_LIMIT_GB"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
echo "[+] Configuration saved successfully."
}
​STREAMING_CHUNK:Rendering interactive main menu...
​show_menu() {
clear
echo ""
echo "       Debian 13 Traffic Monitor & Alert v$VERSION  "
echo ""
echo " 1. Initial Setup / Modify Configuration"
echo " 2. Run Traffic Check Manually"
echo " 3. Setup / Check Cron Job (1-minute interval)"
echo " 4. Update Script from GitHub Repository"
echo " 5. View Current Status & Statistics"
echo " 0. Exit"
echo "===================================================="
read -rp "Please select an option [0-5]: " choice
​case $choice in
1) configure_wizard; pause ;;
2) run_traffic_check; pause ;;
3) setup_cron; pause ;;
4) update_script ;;
5) show_status; pause ;;
0) exit 0 ;;
*) echo "[-] Invalid option!"; sleep 1; show_menu ;;
esac
}
​pause() {
read -rp "Press Enter to return to main menu..."
}
​STREAMING_CHUNK:Handling interactive configuration wizard...
​configure_wizard() {
echo "=== Configuration Wizard ==="
load_config
​read -rp "Enter Server Name [$SERVER_NAME]: " input
[[ -n "$input" ]] && SERVER_NAME="$input"
​echo "Available network interfaces:"
ip -o link show | awk -F': ' '{print $2}'
read -rp "Enter Network Interface(s) separated by space if multiple [$INTERFACES]: " input
[[ -n "$input" ]] && INTERFACES="$input"
​read -rp "Enter Monthly Traffic Reset Day (1-31) [$RESET_DAY]: " input
[[ -n "$input" ]] && RESET_DAY="$input"
​echo "Select Timezone for Traffic Reset & Statistics:"
echo " 1) UTC+8 (Asia/Shanghai / Beijing Time)"
echo " 2) UTC+0 (Coordinated Universal Time)"
read -rp "Select [1-2] (default: 1): " tz_choice
if [[ "$tz_choice" == "2" ]]; then
TIMEZONE="UTC0"
else
TIMEZONE="UTC8"
fi
​echo "Select Traffic Statistic Type:"
echo " 1) Total Traffic (Upload + Download)"
echo " 2) Upload Traffic Only"
echo " 3) Download Traffic Only"
read -rp "Select [1-3] [$STAT_TYPE]: " input
[[ -n "$input" ]] && STAT_TYPE="$input"
​read -rp "Enter Total Monthly Traffic Limit in GB [$TOTAL_LIMIT_GB]: " input
[[ -n "$input" ]] && TOTAL_LIMIT_GB="$input"
​read -rp "Enter Telegram Bot Token [$TG_BOT_TOKEN]: " input
[[ -n "$input" ]] && TG_BOT_TOKEN="$input"
​read -rp "Enter Telegram Chat ID [$TG_CHAT_ID]: " input
[[ -n "$input" ]] && TG_CHAT_ID="$input"
​save_config
echo "[+] Configuration completed!"
}
​STREAMING_CHUNK:Processing vnstat traffic statistics and JSON data...
​get_traffic_data() {
load_config
local total_rx=0
local total_tx=0
​# Ensure vnstat database is ready for interfaces
for iface in $INTERFACES; do
vnstat -i "$iface" --json >/dev/null 2>&1
if [ $? -ne 0 ]; then
echo "[-] Initializing vnstat for interface $iface..."
vnstat -i "$iface"
fi
done
​# Determine current date based on configured timezone
if [ "TIMEZONE" == "UTC0" ]; then
cur_y=(TZ=UTC date +%Y)
cur_m=(TZ=UTC date +%m)
cur_d=(TZ=UTC date +%d)
else
cur_y=(TZ=Asia/Shanghai date +%Y)
cur_m=(TZ=Asia/Shanghai date +%m)
cur_d=$(TZ=Asia/Shanghai date +%d)
fi
​cur_y=$((10#cur_y))
cur_m=((10#cur_m))
cur_d=((10#cur_d))
reset_day=((10#$RESET_DAY))
​if [ "$cur_d" -ge "$reset_day" ]; then
start_y="$cur_y"
start_m="$cur_m"
start_d="$reset_day"
else
if [ "cur_m" -eq 1 ]; then
start_y=((cur_y - 1))
start_m=12
else
start_y="cur_y"
start_m=((cur_m - 1))
fi
start_d="$reset_day"
fi
​start_val=$((start_y * 10000 + start_m * 100 + start_d))
​# Aggregate traffic from daily records starting from reset day
for iface in INTERFACES; do
json_data=(vnstat -i "$iface" --json 2>/dev/null)
if [ -z "$json_data" ]; then
continue
fi
​# Use jq to sum rx and tx for days where date >= start_val
iface_rx=$(echo "$json_data" | jq -r --argjson sval "$start_val" --arg iface "$iface" '
.interfaces[] | select(.name==$iface) | .traffic.days // [] |
map(select((.date.year * 10000 + .date.month * 100 + .date.day) >= sval) | .rx) | add // 0
')
iface_tx=(echo "$json_data" | jq -r --argjson sval "$start_val" --arg iface "$iface" '
.interfaces[] | select(.name==$iface) | .traffic.days // [] |
map(select((.date.year * 10000 + .date.month * 100 + .date.day) >= $sval) | .tx) | add // 0
')
​total_rx=((total_rx + iface_rx))
total_tx=((total_tx + iface_tx))
done
​# Select statistic type
local used_bytes=0
case "STAT_TYPE" in
1) used_bytes=((total_rx + total_tx)) ;;
2) used_bytes="$total_tx" ;; # Upload
3) used_bytes="total_rx" ;; # Download
*) used_bytes=((total_rx + total_tx)) ;;
esac
​# Convert bytes to GB with decimal precision using bc
used_gb=$(echo "scale=2; $used_bytes / 1024 / 1024 / 1024" | bc)
total_gb="$TOTAL_LIMIT_GB"
​if (( $(echo "total_gb > 0" | bc -l) )); then
percentage=(echo "scale=2; ($used_gb / $total_gb) * 100" | bc)
else
percentage="0.00"
fi
}
​STREAMING_CHUNK:Executing scheduled daily report and threshold checks...
​run_traffic_check() {
load_config
get_traffic_data
​# Determine current time based on configured timezone
if [ "TIMEZONE" == "UTC0" ]; then
current_date=(TZ=UTC date +%Y-%m-%d)
current_time=(TZ=UTC date +%H:%M)
full_time=(TZ=UTC date "+%Y-%m-%d %H:%M:%S")
else
current_date=(TZ=Asia/Shanghai date +%Y-%m-%d)
current_time=(TZ=Asia/Shanghai date +%H:%M)
full_time=$(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M:%S")
fi
​echo "[+] [full_time] Checking traffic: Used{used_gb}GB / {total_gb}GB ({percentage}%)"
​# State tracking file to prevent duplicate alerts per month/day
if [ ! -f "$STATE_FILE" ]; then
echo '{"last_daily_report":"","warn_90_sent":false,"shutdown_95_sent":false,"month":""}' > "$STATE_FILE"
fi
​current_month=$(echo "current_date" | cut -d'-' -f1,2)
stored_month=(jq -r '.month' "$STATE_FILE")
​if [ "$current_month" != "$stored_month" ]; then
# Reset state for new month
jq --arg m "$current_month" '.month = m | .warn_90_sent = false | .shutdown_95_sent = false' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "{STATE_FILE}.tmp" "$STATE_FILE"
fi
​# 1. Telegram Daily Report at Beijing Time 08:10
last_report=$(jq -r '.last_daily_report' "$STATE_FILE")
if [ "$current_time" == "08:10" ] && [ "$last_report" != "$current_date" ]; then
send_daily_report
jq --arg d "$current_date" '.last_daily_report = d' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "{STATE_FILE}.tmp" "$STATE_FILE"
fi
​# 2. 90% Warning Push Notification
warn_90_sent=$(jq -r '.warn_90_sent' "$STATE_FILE")
if [ "$warn_90_sent" == "false" ] && (( $(echo "percentage >= 90.00 && percentage < 95.00" | bc -l) )); then
send_alert "⚠️ <b>流量预警通知 (90%)</b>" "服务器流量已使用超过 90%，请注意控制流量消耗！"
jq '.warn_90_sent = true' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "{STATE_FILE}.tmp" "$STATE_FILE"
fi
​# 3. 95% Shutdown Alarm Push Notification with verification
shutdown_95_sent=$(jq -r '.shutdown_95_sent' "$STATE_FILE")
if [ "$shutdown_95_sent" == "false" ] && (( $(echo "$percentage >= 95.00" | bc -l) )); then
send_shutdown_alert
fi
}
​STREAMING_CHUNK:Sending Telegram notification and managing shutdown safety...
​send_telegram() {
local message="$1"
if [ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ]; then
echo "[-] Telegram bot token or chat ID not configured."
return 1
fi
​response=(curl -s -X POST "https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage" 
-d "chat_id={TG_CHAT_ID}" \
-d "parse_mode=HTML" \
-d "text={message}")
​if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
return 0
else
echo "[-] Failed to send Telegram message: $response"
return 1
fi
}
​send_daily_report() {
local stat_name="总流量 (上传+下载)"
[[ "$STAT_TYPE" == "2" ]] && stat_name="上传流量"
[[ "$STAT_TYPE" == "3" ]] && stat_name="下载流量"
​local msg="📊 <b>流量监控每日报告</b>
━━━━━━━━━━━━━━━━━━━
🖥 <b>服务器名称:</b> $SERVER_NAME
🌐 <b>监控网口:</b> $INTERFACES
⏱ <b>时区设置:</b> TIMEZONE
📈 <b>统计类型:</b> $stat_name
📅 <b>流量重置日:</b> 每月 ${RESET_DAY} 号
📊 <b>已用流量:</b> <code>${used_gb} GB</code> / <code>${total_gb} GB</code>
🔥 <b>使用比例:</b> <b>{percentage}%</b>
━━━━━━━━━━━━━━━━━━━
<i>🕒 报告时间: $(date '+%Y-%m-%d %H:%M:%S')</i>"
​send_telegram "$msg"
}
​send_alert() {
local title="$1"
local desc="$2"
local msg="title
━━━━━━━━━━━━━━━━━━━
🖥 <b>服务器名称:</b> $SERVER_NAME
🌐 <b>监控网口:</b> $INTERFACES
📊 <b>当前使用:</b> <code>${used_gb} GB</code> / <code>${total_gb} GB</code> ({percentage}%)
🚨 <b>警告状态:</b> $desc
━━━━━━━━━━━━━━━━━━━
<i>🕒 时间: $(date '+%Y-%m-%d %H:%M:%S')</i>"
​send_telegram "$msg"
}
​send_shutdown_alert() {
local msg="🛑 <b>严重警报：流量超出 95% 限制！</b>
━━━━━━━━━━━━━━━━━━━
🖥 <b>服务器名称:</b> SERVER_NAME
🌐 <b>监控网口:</b> $INTERFACES
📊 <b>当前使用:</b> <code>${used_gb} GB</code> / <code>{total_gb} GB</code> (${percentage}%)
⚡ <b>执行动作:</b> 服务器即将自动关机以避免超额欠费！
━━━━━━━━━━━━━━━━━━━
<i>🕒 时间: $(date '+%Y-%m-%d %H:%M:%S')</i>"
​echo "[!] Traffic reached 95%. Sending shutdown notification to Telegram..."
if send_telegram "msg"; then
echo "[+] Telegram shutdown notification sent successfully. Executing shutdown..."
jq '.shutdown_95_sent = true' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "{STATE_FILE}.tmp" "$STATE_FILE"
shutdown -h now
else
echo "[-] ERROR: Telegram notification failed! Aborting shutdown for safety."
fi
}
​setup_cron() {
echo "[+] Setting up cron job for 1-minute interval check..."
cron_job="* * * * * /usr/local/bin/traffic-monitor.sh --check >/dev/null 2>&1"
​(crontab -l 2>/dev/null | grep -v "traffic-monitor.sh") | { cat; echo "$cron_job"; } | crontab -
echo "[+] Cron job installed successfully."
}
​STREAMING_CHUNK:Implementing self-update and status display functions...
​update_script() {
echo "[+] Checking for updates from GitHub..."
if [ -f "$SCRIPT_PATH" ]; then
echo "[+] Removing existing local script..."
rm -f "$SCRIPT_PATH"
fi
​echo "[+] Downloading latest script..."
if curl -sSL "https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh" -o "$SCRIPT_PATH"; then
chmod +x "$SCRIPT_PATH"
echo "[+] Update completed successfully! Restarting script..."
exec "$SCRIPT_PATH"
else
echo "[-] Failed to download update script from GitHub."
fi
pause
}
​show_status() {
load_config
get_traffic_data
echo ""
echo "               Traffic Monitor Status               "
echo ""
echo " Server Name  : $SERVER_NAME"
echo " Interfaces   : $INTERFACES"
echo " Timezone     : $TIMEZONE"
echo " Reset Day    : ${RESET_DAY}st/th of month"
echo " Stat Type    : $STAT_TYPE (1:Total, 2:Upload, 3:Download)"
echo " Limit        : $TOTAL_LIMIT_GB GB"
echo " Used Traffic : {used_gb} GB ({percentage}%)"
echo "===================================================="
}
​Argument handling
​case "$1" in
--check)
run_traffic_check
;;
--install)
check_and_setup_system
configure_wizard
setup_cron
;;
*)
while true; do
show_menu
done
;;
esac
