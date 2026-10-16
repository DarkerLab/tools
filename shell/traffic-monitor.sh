#!/bin/bash
​==============================================================================
​Script Name: traffic-monitor.sh
​Description: Debian 13 Traffic Monitor & Telegram Alert System with vnStat
​Version: 1.2.0
​Author: DarkerLab
​GitHub URL: https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh
​==============================================================================
​VERSION="1.2.0"
CONFIG_FILE="/etc/traffic-monitor.conf"
STATE_FILE="/etc/traffic-monitor.state"
LOG_FILE="/var/log/traffic-monitor.log"
SCRIPT_PATH="/usr/local/bin/traffic-monitor.sh"
​Colors for UI
​RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
​Check root privileges
​[[ EUID -ne 0 ]] && { echo -e "{RED}错误：请使用 root 用户运行此脚本！${PLAIN}"; exit 1; }
​------------------------------------------------------------------------------
​1. 菜单与交互界面
​------------------------------------------------------------------------------
​show_menu() {
clear
echo -e "{CYAN}=============================================================={PLAIN}"
echo -e "{CYAN}         Debian 13 流量监控与 Telegram 报警管理脚本           ${PLAIN} "
echo -e "${CYAN}         当前版本: v{VERSION}{PLAIN}"
echo -e "{CYAN}{PLAIN}"
echo -e " 1. 安装 / 修改监控配置参数"
echo -e " 2. 查看当前流量统计与运行状态"
echo -e " 3. 手动执行一次流量检查与报警测试"
echo -e " 4. 一键更新脚本 (从 GitHub 拉取)"
echo -e " 5. 卸载流量监控与定时任务"
echo -e " 0. 退出脚本"
echo -e "{CYAN}{PLAIN}"
read -p "请输入选项 [0-5]: " choice
case "$choice" in
1) configure_all ;;
2) show_status ;;
3) do_check manual ;;
4) update_script ;;
5) uninstall ;;
0) exit 0 ;;
*) echo -e "${RED}无效选项，请重新输入！{PLAIN}"; sleep 1; show_menu ;;
esac
}
​------------------------------------------------------------------------------
​2. 环境初始化与配置向导
​------------------------------------------------------------------------------
​configure_all() {
echo -e "{YELLOW}正在检查系统环境与依赖工具...{PLAIN}"
apt update -y
apt install -y vnstat curl jq cron iproute2
​# 检查并设置时区为 Asia/Shanghai
current_tz=(timedatectl show --property=Timezone --value 2>/dev/null)
if [ "$current_tz" != "Asia/Shanghai" ]; then
echo -e "${YELLOW}当前时区为 ${current_tz:-未知}，正在自动修改为 Asia/Shanghai...${PLAIN}"
timedatectl set-timezone Asia/Shanghai
else
echo -e "{GREEN}系统时区已是 Asia/Shanghai。${PLAIN}"
fi
​# 确保 vnstat 服务运行
systemctl enable --now vnstat >/dev/null 2>&1
​# 检测可用网卡接口
available_ifs=$(ip -o link show | awk -F': ' '{print 2}' | grep -v 'lo')
echo -e "{CYAN}检测到当前系统可用网卡接口: {available_ifs}{PLAIN}"
​# 读取已有配置作为默认值
if [ -f "$CONFIG_FILE" ]; then
source "$CONFIG_FILE"
fi
​echo -e "{CYAN}================ 配置向导 ================{PLAIN}"
read -p "请输入监控服务器名称 [默认: (hostname)]: " input_server_name
SERVER_NAME="{input_server_name:-$(hostname)}"
​read -p "请输入要监控的网卡接口（支持单网卡或多网卡空格分隔） [默认: (echoavailable_ifs | awk '{print 1}'])]: " input_interfaces
INTERFACES="{input_interfaces:-(echoavailable_ifs | awk '{print $1})'}"
​read -p "请输入每月流量重置日期 (1-31) [默认: {RESET_DAY:-1}]: " input_reset_day
RESET_DAY="{input_reset_day:-1}"
​echo "请选择流量统计时区模式:"
echo "1) UTC0"
echo "2) UTC8 (北京时间)"
read -p "请输入选项 [1-2] [默认: ${TIMEZONE_MODE:-2}]: " input_tz_mode
if [ "$input_tz_mode" = "1" ]; then
TIMEZONE_MODE="UTC0"
else
TIMEZONE_MODE="UTC8"
fi
​echo "请选择流量统计类型:"
echo "1) 总流量 (上传 + 下载)"
echo "2) 上传流量"
echo "3) 下载流量"
read -p "请输入选项 [1-3] [默认: {TRAFFIC_TYPE:-1}]: " input_traffic_type
TRAFFIC_TYPE="{input_traffic_type:-1}"
​read -p "请输入每月总流量限制 (单位: GB，输入 0 表示不限制) [默认: {TOTAL_LIMIT_GB:-1000}]: " input_limit
TOTAL_LIMIT_GB="{input_limit:-1000}"
​read -p "请输入 Telegram Bot Token [默认: {TG_BOT_TOKEN}]: " input_token
TG_BOT_TOKEN="{input_token:-$TG_BOT_TOKEN}"
​read -p "请输入 Telegram Chat ID [默认: {TG_CHAT_ID}]: " input_chat_id
TG_CHAT_ID="{input_chat_id:-$TG_CHAT_ID}"
​read -p "请输入流量预警阈值百分比 (例如 90) [默认: {WARNING_PERCENT:-90}]: " input_warn
WARNING_PERCENT="{input_warn:-90}"
​read -p "请输入关机报警阈值百分比 (例如 95) [默认: {SHUTDOWN_PERCENT:-95}]: " input_shut
SHUTDOWN_PERCENT="{input_shut:-95}"
​# 保存配置文件
cat > "$CONFIG_FILE" <<EOF
SERVER_NAME="$SERVER_NAME"
INTERFACES="$INTERFACES"
RESET_DAY="$RESET_DAY"
TIMEZONE_MODE="$TIMEZONE_MODE"
TRAFFIC_TYPE="$TRAFFIC_TYPE"
TOTAL_LIMIT_GB="$TOTAL_LIMIT_GB"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
WARNING_PERCENT="$WARNING_PERCENT"
SHUTDOWN_PERCENT="$SHUTDOWN_PERCENT"
EOF
​echo -e "${GREEN}配置文件已保存至 CONFIG_FILE{PLAIN}"
​# 复制脚本到 /usr/local/bin/traffic-monitor.sh
if [ "$0" != "$SCRIPT_PATH" ]; then
cp "$0" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
fi
​# 设置 Crontab 定时任务（每分钟检查一次流量，每天 08:10 推送日报）
crontab -l 2>/dev/null | grep -v "traffic-monitor.sh" > /tmp/crontab.tmp
echo "* * * * * $SCRIPT_PATH check >/dev/null 2>&1" >> /tmp/crontab.tmp
echo "10 8 * * * $SCRIPT_PATH report >/dev/null 2>&1" >> /tmp/crontab.tmp
crontab /tmp/crontab.tmp
rm -f /tmp/crontab.tmp
​echo -e "{GREEN}定时任务设置成功：每 1 分钟自动检查流量，每天北京时间 08:10 推送日报！{PLAIN}"
​# 等待 vnstat 数据库初始化
for iface in $INTERFACES; do
vnstat -i "$iface" --create >/dev/null 2>&1
done
​echo -e "{CYAN}配置完成！{PLAIN}"
read -p "按回车键返回主菜单..."
show_menu
}
​------------------------------------------------------------------------------
​3. 核心流量计算逻辑
​------------------------------------------------------------------------------
​calculate_traffic() {
[ ! -f "$CONFIG_FILE" ] && return 1
source "$CONFIG_FILE"
​# 根据时区获取当前年月日
if [ "TIMEZONE_MODE" = "UTC0" ]; then
CUR_YEAR=(TZ=UTC date +%Y)
CUR_MONTH=(TZ=UTC date +%m)
CUR_DAY=(TZ=UTC date +%d)
else
CUR_YEAR=(TZ=Asia/Shanghai date +%Y)
CUR_MONTH=(TZ=Asia/Shanghai date +%m)
CUR_DAY=$(TZ=Asia/Shanghai date +%d)
fi
​c_year=$((10#CUR_YEAR))
c_month=((10#CUR_MONTH))
c_day=((10#CUR_DAY))
r_day=((10#$RESET_DAY))
​# 计算计费周期起始日
if [ c_day -ger_day ]; then
s_year=$c_year
s_month=$c_month
s_day=r_day
else
s_month=((c_month - 1))
s_year=$c_year
if [ s_month -eq 0 ]; then
s_month=12
s_year=((c_year - 1))
fi
s_day=$r_day
fi
​START_DATE=$(printf "%04d-%02d-%02d" s_year $s_month$s_day)
if [ "$TIMEZONE_MODE" = "UTC0" ]; then
END_DATE=$(TZ=UTC date +%Y-%m-%d)
else
END_DATE=(TZ=Asia/Shanghai date +%Y-%m-%d)
fi
​total_rx=0
total_tx=0
​for iface in INTERFACES; do
json_output=(vnstat -i "$iface" --json 2>/dev/null)
if [ -z "$json_output" ]; then
continue
fi
​iface_rx=$(echo "$json_output" | jq --arg start "$START_DATE" --arg end "$END_DATE" '
[.interfaces[].traffic.days[] | select(((.date.year|tostring) + "-" + ((.date.month|tostring) | if length == 1 then "0" + . else . end) + "-" + ((.date.day|tostring) | if length == 1 then "0" + . else . end)) >= $start and ((.date.year|tostring) + "-" + ((.date.month|tostring) | if length == 1 then "0" + . else . end) + "-" + ((.date.day|tostring) | if length == 1 then "0" + . else . end)) <= end) | .rx] | add // 0
')
iface_tx=(echo "$json_output" | jq --arg start "$START_DATE" --arg end "$END_DATE" '
[.interfaces[].traffic.days[] | select(((.date.year|tostring) + "-" + ((.date.month|tostring) | if length == 1 then "0" + . else . end) + "-" + ((.date.day|tostring) | if length == 1 then "0" + . else . end)) >= $start and ((.date.year|tostring) + "-" + ((.date.month|tostring) | if length == 1 then "0" + . else . end) + "-" + ((.date.day|tostring) | if length == 1 then "0" + . else . end)) <= $end) | .tx] | add // 0
')
​total_rx=((total_rx + iface_rx))
total_tx=((total_tx + iface_tx))
done
​case "TRAFFIC_TYPE" in
1) used_bytes=((total_rx + total_tx)) ;;
2) used_bytes=$total_tx ;; 3) used_bytes=total_rx ;;
*) used_bytes=((total_rx + total_tx)) ;;
esac
​used_gb=$(awk "BEGIN {print $used_bytes / 1024 / 1024 / 1024}")
if [ "TOTAL_LIMIT_GB" -gt 0 ] 2>/dev/null; then
percent=(awk "BEGIN {printf "%.2f", ($used_gb / $TOTAL_LIMIT_GB) * 100}")
else
percent=0
fi
}
​------------------------------------------------------------------------------
​4. Telegram 消息推送函数（带状态检查）
​------------------------------------------------------------------------------
​send_telegram() {
local message="$1"
[ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ] && return 1
​response=(curl -s -X POST "https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage" 
-d "chat_id={TG_CHAT_ID}" \
-d "text={message}" 
-d "parse_mode=Markdown")
​if echo "response" | grep -q '"ok":true'; then
return 0
else
echo "(date): Telegram 消息发送失败: $response" >> "$LOG_FILE"
return 1
fi
}
​------------------------------------------------------------------------------
​5. 定时检查与报警/关机逻辑
​------------------------------------------------------------------------------
​do_check() {
[ ! -f "$CONFIG_FILE" ] && return 1
source "$CONFIG_FILE"
​calculate_traffic
​# 当前月份标识用于重置状态记录
if [ "TIMEZONE_MODE" = "UTC0" ]; then
cur_month_key=(TZ=UTC date +%Y-%m)
now_time=(TZ=UTC date +'%Y-%m-%d %H:%M:%S')
else
cur_month_key=(TZ=Asia/Shanghai date +%Y-%m)
now_time=$(TZ=Asia/Shanghai date +'%Y-%m-%d %H:%M:%S')
fi
​# 初始化状态管理
if [ ! -f "$STATE_FILE" ]; then
echo "MONTH_KEY="$cur_month_key"" > "$STATE_FILE"
echo "WARNING_SENT="0"" >> "$STATE_FILE"
echo "SHUTDOWN_SENT="0"" >> "$STATE_FILE"
fi
​source "$STATE_FILE"
if [ "$MONTH_KEY" != "$cur_month_key" ]; then
MONTH_KEY="$cur_month_key"
WARNING_SENT="0"
SHUTDOWN_SENT="0"
echo "MONTH_KEY="$MONTH_KEY"" > "$STATE_FILE"
echo "WARNING_SENT="$WARNING_SENT"" >> "$STATE_FILE"
echo "SHUTDOWN_SENT="$SHUTDOWN_SENT"" >> "$STATE_FILE"
fi
​# 检查 95% 关机阈值
is_shutdown_exceeded=$(awk "BEGIN {print ($percent >=$SHUTDOWN_PERCENT) ? 1 : 0}")
if [ "$is_shutdown_exceeded" -eq 1 ] && [ "$SHUTDOWN_SENT" -eq 0 ]; then
type_str="总流量(上传+下载)"
[ "$TRAFFIC_TYPE" = "2" ] && type_str="上传流量"
[ "$TRAFFIC_TYPE" = "3" ] && type_str="下载流量"
​msg=$(cat <<EOF
🚨 超额关机紧急通知
​🏷 服务器名称: `{SERVER_NAME}\`
🛑 *警报触发:* 流量已使用达 *{percent}%*（超过关机阈值 {SHUTDOWN_PERCENT}%）！
📊 *统计类型:* \`{type_str}`
💾 已用流量: `{used_gb} GB\` / \`{TOTAL_LIMIT_GB} GB`
⚡ 执行动作: 服务器即将自动执行关机保护。
🕒 触发时间: `{now_time}\` ({TIMEZONE_MODE})
​🔒 验证通知成功后，正在执行关机...
EOF
)
if send_telegram "$msg"; then
echo "SHUTDOWN_SENT="1"" >> "STATE_FILE"
echo "(date): 流量达到 ${percent}%，关机通知发送成功，开始关机..." >> "LOG_FILE"
shutdown -h now
else
echo "(date): 关机通知发送失败，推迟关机操作。" >> "$LOG_FILE"
fi
return
fi
​# 检查 90% 预警阈值
is_warning_exceeded=$(awk "BEGIN {print ($percent >=$WARNING_PERCENT) ? 1 : 0}")
if [ "$is_warning_exceeded" -eq 1 ] && [ "$WARNING_SENT" -eq 0 ]; then
type_str="总流量(上传+下载)"
[ "$TRAFFIC_TYPE" = "2" ] && type_str="上传流量"
[ "$TRAFFIC_TYPE" = "3" ] && type_str="下载流量"
​msg=$(cat <<EOF
⚠️ 流量预警通知
​🏷 服务器名称: `{SERVER_NAME}\`
🚨 *警报触发:* 流量已使用达 *{percent}%*（达到预警阈值 {WARNING_PERCENT}%）！
📊 *统计类型:* \`{type_str}`
💾 已用流量: `{used_gb} GB\` / \`{TOTAL_LIMIT_GB} GB`
🕒 触发时间: `{now_time}\` ({TIMEZONE_MODE})
​💡 请注意控制流量消耗，避免超量触发关机！
EOF
)
if send_telegram "$msg"; then
echo "WARNING_SENT="1"" >> "STATE_FILE"
echo "(date): 流量达到 ${percent}%，预警通知发送成功。" >> "$LOG_FILE"
fi
fi
​# 如果是手动测试命令触发
if [ "1" = "manual" ]; then
echo -e "{GREEN}流量检查完成！当前已用流量: {used_gb} GB ({percent}%)，限制: {TOTAL_LIMIT_GB} GB{PLAIN}"
fi
}
​------------------------------------------------------------------------------
​6. Telegram 每日流量报告推送（北京时间 08:10）
​------------------------------------------------------------------------------
​do_report() {
[ ! -f "$CONFIG_FILE" ] && return 1
source "$CONFIG_FILE"
​calculate_traffic
​if [ "TIMEZONE_MODE" = "UTC0" ]; then
now_time=(TZ=UTC date +'%Y-%m-%d %H:%M:%S')
else
now_time=$(TZ=Asia/Shanghai date +'%Y-%m-%d %H:%M:%S')
fi
​type_str="总流量(上传+下载)"
[ "$TRAFFIC_TYPE" = "2" ] && type_str="上传流量"
[ "$TRAFFIC_TYPE" = "3" ] && type_str="下载流量"
​msg=$(cat <<EOF
📊 服务器流量监控日报
​🏷 服务器名称: `{SERVER_NAME}\`
📈 *统计时区:* \`{TIMEZONE_MODE}` (每月 `{RESET_DAY}\` 号重置)
📅 *统计区间:* \`{START_DATE}` 至 `{now_time}\`
📊 *统计类型:* \`{type_str}`
💾 已用流量: `{used_gb} GB\` / \`{TOTAL_LIMIT_GB} GB` (`${percent}%`)
🟢 当前状态: `运行正常`
​🕒 推送时间: `${now_time} (CST)`
EOF
)
send_telegram "$msg"
}
​------------------------------------------------------------------------------
​7. 查看当前状态与流量
​------------------------------------------------------------------------------
​show_status() {
if [ ! -f "CONFIG_FILE" ]; then
echo -e "{RED}尚未配置监控参数，请先进行配置！${PLAIN}"
sleep 2
show_menu
return
fi
source "$CONFIG_FILE"
calculate_traffic
​echo -e "{CYAN}================ 流量监控状态 ================{PLAIN}"
echo -e " 服务器名称: {GREEN}{SERVER_NAME}{PLAIN}"
echo -e " 监控网卡:   ${GREEN}${INTERFACES}{PLAIN}"
echo -e " 重置日/时区: 每月 {GREEN}{RESET_DAY}{PLAIN} 号 ({GREEN}{TIMEZONE_MODE}{PLAIN})"
echo -e " 统计类型:   {GREEN}{TRAFFIC_TYPE}{PLAIN} (1:总流量 2:上传 3:下载)"
echo -e " 流量限制:   ${GREEN}${TOTAL_LIMIT_GB} GB{PLAIN}"
echo -e " 当前已用:   {YELLOW}{used_gb} GB${PLAIN} ({YELLOW}{percent}%{PLAIN})"
echo -e " 预警阈值:   ${YELLOW}${WARNING_PERCENT}%{PLAIN} \vert{} 关机阈值: {RED}{SHUTDOWN_PERCENT}%{PLAIN}"
echo -e "{CYAN}==============================================${PLAIN}"
read -p "按回车键返回主菜单..."
show_menu
}
​------------------------------------------------------------------------------
​8. 一键更新脚本
​------------------------------------------------------------------------------
​update_script() {
echo -e "{YELLOW}正在检查并更新脚本...{PLAIN}"
if [ -f "SCRIPT_PATH" ]; then
rm -f "$SCRIPT_PATH"
echo -e "${GREEN}已删除旧的本地脚本文件...{PLAIN}"
fi
curl -sSL "https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh" -o "SCRIPT_PATH"
if [ -f "$SCRIPT_PATH" ]; then
chmod +x "$SCRIPT_PATH"
echo -e "${GREEN}脚本更新成功！正在重新启动...${PLAIN}"
exec "$SCRIPT_PATH"
else
echo -e "${RED}脚本更新失败，请检查网络连接或 GitHub 链接！{PLAIN}"
sleep 2
show_menu
fi
}
​------------------------------------------------------------------------------
​9. 卸载监控与定时任务
​------------------------------------------------------------------------------
​uninstall() {
read -p "确定要卸载流量监控及所有定时任务吗？[y/N]: " confirm
if [[ "confirm" =~ ^[Yy] ]]; then
crontab -l 2>/dev/null | grep -v "traffic-monitor.sh" > /tmp/crontab.tmp
crontab /tmp/crontab.tmp
rm -f /tmp/crontab.tmp
rm -f "$CONFIG_FILE" "STATE_FILE" "$SCRIPT_PATH"
echo -e "${GREEN}卸载完成！{PLAIN}"
else
show_menu
fi
}
​------------------------------------------------------------------------------
​入口参数分发
​------------------------------------------------------------------------------
​case "$1" in
check)
do_check
;;
report)
do_report
;;
update)
update_script
;;
*)
show_menu
;;
es:wq
