
#!/bin/bash

# 确保以root权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本 (sudo bash $0)"
  exit 1
fi

CONFIG_FILE="/etc/traffic-monitor.conf"
CRON_FILE="/etc/cron.d/traffic-monitor"
LOG_FILE="/var/log/traffic-monitor.log"
SCRIPT_PATH="/usr/local/bin/traffic-monitor.sh"
RAW_URL="https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh"

# 颜色定义
RED='\033[01;31m'
GREEN='\033[01;32m'
YELLOW='\033[01;33m'
BLUE='\033[01;34m'
NC='\033[0m'

# ==================== 1. 安装与配置模块 ====================
install_or_config() {
    clear
    echo -e "${BLUE}=== vnstat 流量监控助手 - 安装与配置 ===${NC}"
    
    # 检查并安装依赖
    echo -e "${YELLOW}[*] 检查系统环境与依赖工具...${NC}"
    apt-get update -y
    apt-get install -y vnstat curl jq bc cron systemd iproute2

    # 启动并启用服务
    systemctl enable --now vnstat
    systemctl enable --now cron

    # 检查时区
    CURRENT_TZ=$(timedatectl show --property=Timezone --value)
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        echo -e "${YELLOW}[*] 当前系统时区为 $CURRENT_TZ，正在自动调整为 Asia/Shanghai...${NC}"
        timedatectl set-timezone Asia/Shanghai
    else
        echo -e "${GREEN}[√] 系统时区已确认：Asia/Shanghai${NC}"
    fi

    # 获取可用网卡列表
    echo -e "\n${YELLOW}当前可用网卡列表：${NC}"
    ip -o link show | awk -F': ' '{print $2}' | grep -v "lo"
    
    # 读取旧配置（如果存在）
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}[√] 检测到已有配置文件，将加载默认值进行更新。${NC}"
    fi

    # 交互式参数配置
    read -p "请输入自定义监控服务器名称 [默认: $(hostname)]: " SERVER_NAME
    SERVER_NAME="${SERVER_NAME:-$(hostname)}"

    read -p "请输入监控网口（单网口如 eth0，多网口可用空格或逗号分隔如 ens18,ens19）[默认: $(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n 1)]: " INTERFACES
    INTERFACES="${INTERFACES:-$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n 1)}"

    read -p "请输入每月流量重置日期 (1-31) [默认: 1]: " RESET_DAY
    RESET_DAY="${RESET_DAY:-1}"

    echo "请选择流量统计时区模式："
    echo "1. UTC+8 (北京时间)"
    echo "2. UTC+0 (零时区)"
    read -p "请选择 [1-2, 默认: 1]: " TZ_MODE
    TZ_MODE="${TZ_MODE:-1}"
    if [ "$TZ_MODE" == "2" ]; then
        USE_UTC="yes"
        sed -i 's/^[#]*UseUTC .*/UseUTC 1/' /etc/vnstat.conf 2>/dev/null || true
    else
        USE_UTC="no"
        sed -i 's/^[#]*UseUTC .*/UseUTC 0/' /etc/vnstat.conf 2>/dev/null || true
    fi
    systemctl restart vnstat

    echo "请选择流量统计类型："
    echo "1. 总流量 (上传 + 下载)"
    echo "2. 仅上传流量"
    echo "3. 仅下载流量"
    read -p "请选择 [1-3, 默认: 1]: " TRAFFIC_TYPE
    TRAFFIC_TYPE="${TRAFFIC_TYPE:-1}"

    read -p "请输入每月总流量限制 (单位: GB) [默认: 1000]: " TOTAL_LIMIT_GB
    TOTAL_LIMIT_GB="${TOTAL_LIMIT_GB:-1000}"

    read -p "请输入Telegram Bot Token: " TG_BOT_TOKEN
    read -p "请输入Telegram Chat ID: " TG_CHAT_ID

    # 保存配置文件
    cat << EOF > "$CONFIG_FILE"
SERVER_NAME="$SERVER_NAME"
INTERFACES="$INTERFACES"
RESET_DAY="$RESET_DAY"
USE_UTC="$USE_UTC"
TRAFFIC_TYPE="$TRAFFIC_TYPE"
TOTAL_LIMIT_GB="$TOTAL_LIMIT_GB"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF

    echo -e "${GREEN}[√] 配置文件已成功保存至 $CONFIG_FILE${NC}"

    # 配置定时任务 (每分钟执行一次检查)
    # 将自身复制到 /usr/local/bin/traffic-monitor.sh
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    cat << EOF > "$CRON_FILE"
* * * * * root /usr/local/bin/traffic-monitor.sh check >/dev/null 2>&1
EOF
    systemctl restart cron

    # 初始化状态标记文件目录
    mkdir -p /var/lib/traffic-monitor
    
    echo -e "${GREEN}[√] 监控定时任务已部署（每1分钟检查一次）。${NC}"
    read -p "按回车键返回主菜单..."
    show_menu
}

# ==================== 2. 发送 Telegram 通知函数 ====================
send_tg_msg() {
    local message="$1"
    if [ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ]; then
        return 1
    fi
    response=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=Markdown" \
        -d "text=${message}")
    
    if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ==================== 3. 流量计算核心逻辑 ====================
get_current_traffic_bytes() {
    # 兼容多网口求和
    local total_rx=0
    local total_tx=0
    
    # 将逗号或空格分隔的网口转换为数组
    IFS=', ' read -r -a if_array <<< "$INTERFACES"
    
    for iface in "${if_array[@]}"; do
        iface=$(echo "$iface" | xargs)
        [ -z "$iface" ] && continue
        
        json_data=$(vnstat -i "$iface" --json 2>/dev/null)
        if [ $? -ne 0 ] \vert{}\vert{} [ -z "$json_data" ]; then
            continue
        fi
        
        # 使用 jq 获取当前月（或者从重置日起）的流量
        # vnstat json 中 month 数组包含当前月的统计
        rx=$(echo "$json_data" | jq --argjson rday "$RESET_DAY" '
            .interfaces[0].traffic.month | 
            map(select(.date.day >= $rday)) | 
            map(.rx) | add // 0
        ')
        tx=$(echo "$json_data" | jq --argjson rday "$RESET_DAY" '
            .interfaces[0].traffic.month | 
            map(select(.date.day >= $rday)) | 
            map(.tx) | add // 0
        ')
        
        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))
    done

    case "$TRAFFIC_TYPE" in
        2) echo "$total_tx" ;;
        3) echo "$total_rx" ;;
        *) echo $((total_rx + total_tx)) ;;
    esas
}

format_bytes() {
    local bytes=$1
    if [ "$bytes" -gt 1073741824000 ]; then
        awk "BEGIN {printf \"%.2f TB\", $bytes / 1099511627776}"
    elif [ "$bytes" -gt 1048576000 ]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes / 1073741824}"
    elif [ "$bytes" -gt 1024000 ]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes / 1048576}"
    else
        echo "$bytes Bytes"
    fi
}

# ==================== 4. 后台检查与定时推送逻辑 ====================
run_checker() {
    [ ! -f "$CONFIG_FILE" ] && exit 0
    source "$CONFIG_FILE"

    current_bytes=$(get_current_traffic_bytes)
    total_bytes_limit=$(awk "BEGIN {print $TOTAL_LIMIT_GB * 1073741824}")
    
    if [ "$total_bytes_limit" -le 0 ]; then
        percent=0
    else
        percent=$(awk "BEGIN {printf \"%.2f\", ($current_bytes / $total_bytes_limit) * 100}")
    fi

    used_str=$(format_bytes "$current_bytes")
    total_str="${TOTAL_LIMIT_GB} GB"
    current_time=$(date '+%Y-%m-%d %H:%M:%S')

    # 1. 每日 08:10 定时报告检查
    today_date=$(date '+%Y%m%d')
    current_hm=$(date '+%H:%M')
    daily_flag="/var/lib/traffic-monitor/daily_${today_date}.flag"

    if [ "$current_hm" = "08:10" ] && [ ! -f "$daily_flag" ]; then
        msg="📊 *服务器流量日报*
━━━━━━━━━━━━━━━━━━
🖥 *名称:* \`${SERVER_NAME}\`
📈 *已用:* \`${used_str}\` / \`${total_str}\`
📊 *占比:* \`${percent}%\`
⏰ *时间:* \`${current_time}\`
━━━━━━━━━━━━━━━━━━"
        send_tg_msg "$msg"
        touch "$daily_flag"
        # 清理旧标记文件
        find /var/lib/traffic-monitor/ -name "daily_*.flag" ! -name "daily_${today_date}.flag" -delete
    fi

    # 2. 90% 预警检查 (每个周期仅发一次)
    warning_flag="/var/lib/traffic-monitor/warning_sent_${RESET_DAY}_$(date '+%Y%m')"
    is_above_90=$(awk "BEGIN {print ($percent >= 90 &&$percent < 95) ? 1 : 0}")
    if [ "$is_above_90" -eq 1 ] && [ ! -f "$warning_flag" ]; then
        msg="⚠️ *流量预警通知*
━━━━━━━━━━━━━━━━━━
🖥 *名称:* \`${SERVER_NAME}\`
🚨 *状态:* 已使用流量达到 *${percent}%*
📈 *已用:* \`${used_str}\` / \`${total_str}\`
⏰ *时间:* \`${current_time}\`
━━━━━━━━━━━━━━━━━━"
        if send_tg_msg "$msg"; then
            touch "$warning_flag"
        fi
    fi

    # 3. 95% 超阈值关机告警检查
    shutdown_flag="/var/lib/traffic-monitor/shutdown_sent_${RESET_DAY}_$(date '+%Y%m')"
    is_above_95=$(awk "BEGIN {print ($percent >= 95) ? 1 : 0}")
    if [ "$is_above_95" -eq 1 ] && [ ! -f "$shutdown_flag" ]; then
        msg="🛑 *超流量关机告警*
━━━━━━━━━━━━━━━━━━
🖥 *名称:* \`${SERVER_NAME}\`
❌ *状态:* 流量已超 95% (*${percent}%*)
📈 *已用:* \`${used_str}\` / \`${total_str}\`
🔌 *操作:* 服务器正在执行安全关机
⏰ *时间:* \`${current_time}\`
━━━━━━━━━━━━━━━━━━"
        # 强制检查关机通知是否发送成功再执行关机
        if send_tg_msg "$msg"; then
            touch "$shutdown_flag"
            sync
            sleep 2
            shutdown now
        else
            # 若推送失败，重试一次后依然关机，确保保护机制生效
            sleep 3
            send_tg_msg "$msg"
            touch "$shutdown_flag"
            sync
            shutdown now
        fi
    fi
}

# ==================== 5. 菜单功能实现 ====================

test_daily_report() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[x] 尚未安装或配置，请先选择 1 进行安装配置。${NC}"
        read -p "按回车键返回..."
        show_menu
        return
    fi
    source "$CONFIG_FILE"
    current_bytes=$(get_current_traffic_bytes)
    total_bytes_limit=$(awk "BEGIN {print $TOTAL_LIMIT_GB * 1073741824}")
    percent=$(awk "BEGIN {printf \"%.2f\", ($current_bytes / $total_bytes_limit) * 100}")
    used_str=$(format_bytes "$current_bytes")
    total_str="${TOTAL_LIMIT_GB} GB"
    current_time=$(date '+%Y-%m-%d %H:%M:%S')

    msg="🧪 *测试流量推送报告*
━━━━━━━━━━━━━━━━━━
🖥 *名称:* \`${SERVER_NAME}\`
📈 *已用:* \`${used_str}\` / \`${total_str}\`
📊 *占比:* \`${percent}%\`
⏰ *时间:* \`${current_time}\`
━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}正在发送测试消息到 Telegram...${NC}"
    if send_tg_msg "$msg"; then
        echo -e "${GREEN}[√] 测试消息发送成功！${NC}"
    else
        echo -e "${RED}[x] 发送失败，请检查 Bot Token 和 Chat ID 是否正确。${NC}"
    fi
    read -p "按回车键返回主菜单..."
    show_menu
}

view_traffic() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[x] 尚未安装或配置，请先选择 1 进行安装配置。${NC}"
        read -p "按回车键返回..."
        show_menu
        return
    fi
    source "$CONFIG_FILE"
    current_bytes=$(get_current_traffic_bytes)
    total_bytes_limit=$(awk "BEGIN {print $TOTAL_LIMIT_GB * 1073741824}")
    percent=$(awk "BEGIN {printf \"%.2f\", ($current_bytes / $total_bytes_limit) * 100}")
    used_str=$(format_bytes "$current_bytes")
    total_str="${TOTAL_LIMIT_GB} GB"

    clear
    echo -e "${BLUE}=== 当前流量数据面板 ===${NC}"
    echo -e "服务器名称: ${GREEN}${SERVER_NAME}${NC}"
    echo -e "监控网口:   ${GREEN}${INTERFACES}${NC}"
    echo -e "每月重置日: ${GREEN}每月 ${RESET_DAY} 号${NC}"
    echo -e "已用流量:   ${GREEN}${used_str}${NC}"
    echo -e "总流量限额: ${GREEN}${total_str}${NC}"
    echo -e "当前使用率: ${GREEN}${percent}\%${NC}"
    echo "----------------------------------------"
    echo -e "${YELLOW}vnstat 详细接口状态：${NC}"
    vnstat -i "$(echo "$INTERFACES" | awk -F',' '{print $1}' | xargs)"
    echo "----------------------------------------"
    read -p "按回车键返回主菜单..."
    show_menu
}

update_script() {
    echo -e "${YELLOW}正在从 GitHub 强制刷新拉取最新脚本...${NC}"
    if curl -sSL "$RAW_URL" -o "$SCRIPT_PATH"; then
        chmod +x "$SCRIPT_PATH"
        cp "$SCRIPT_PATH" "$0"
        echo -e "${GREEN}[√] 脚本更新成功，正在重新启动...${NC}"
        sleep 1
        exec "$SCRIPT_PATH"
    else
        echo -e "${RED}[x] 更新失败，请检查网络连接或 GitHub 链接是否有效。${NC}"
        read -p "按回车键返回主菜单..."
        show_menu
    fi
}

uninstall() {
    read -p "确定要卸载流量监控程序吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$CONFIG_FILE"
        rm -f "$CRON_FILE"
        rm -f "$SCRIPT_PATH"
        rm -rf "/var/lib/traffic-monitor"
        systemctl restart cron
        echo -e "${GREEN}[√] 监控程序已完全卸载。${NC}"
        exit 0
    else
        show_menu
    fi
}

show_menu() {
    clear
    echo "========================================"
    echo "       vnstat 流量监控助手 v1.1          "
    echo "========================================"
    echo " 1. 安装部署/修改配置"
    echo " 2. 测试发送每日流量推送"
    echo " 3. 查看当前流量数据"
    echo " 4. 强制刷新更新脚本"
    echo " 5. 卸载监控程序"
    echo " 0. 退出"
    echo "========================================"
    read -p "请输入选项 [0-5]: " choice
    case "$choice" in
        1) install_or_config ;;
        2) test_daily_report ;;
        3) view_traffic ;;
        4) update_script ;;
        5) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入${NC}"; sleep 1; show_menu ;;
    esac
}

# ==================== 入口控制 ====================
if [ "$1" == "check" ]; then
    run_checker
else
    show_menu
fi
