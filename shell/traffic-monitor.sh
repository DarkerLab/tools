#!/bin/sh

# 确保以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 权限运行此脚本！(sudo sh install.sh)"
    exit 1
fi

CONF_FILE="/etc/traffic-monitor.conf"
CHECK_SCRIPT="/usr/local/bin/traffic-monitor-check.sh"
REPORT_SCRIPT="/usr/local/bin/traffic-monitor-report.sh"

# 检查并安装依赖
install_dependencies() {
    echo "正在更新软件源并安装必要的依赖 (vnstat, jq, curl, bc)..."
    apt-get update -y
    apt-get install -y vnstat jq curl bc
    systemctl enable --now vnstat
}

# 交互式配置向导
configure_menu() {
    clear
    echo "=========================================="
    echo "       Debian 13 流量监控与报警系统配置       "
    echo "=========================================="

    # 加载现有配置（如果存在）
    if [ -f "$CONF_FILE" ]; then
        . "$CONF_FILE"
        echo "检测到已有配置文件，当前配置："
        echo "  - 监控网口: $INTERFACES"
        echo "  - 月流量上限: ${MONTHLY_LIMIT_GB} GB"
        echo "  - 每月重置日: $RESET_DAY 日"
        echo "  - 统计时区: $TIMEZONE"
        echo "  - Telegram Chat ID: $TG_CHAT_ID"
        echo "  - 流量预警线: ${WARN_PERCENT}%"
        echo "  - 关机保护线: ${SHUTDOWN_PERCENT}%"
        echo ""
        printf "是否基于现有配置进行修改？[y/N]: "
        read modify_choice
        case "$modify_choice" in
            [yY]) ;;
            *) echo "取消修改。"; return ;;
        esac
    fi

    # 1. 网卡选择
    echo ""
    echo "当前系统可用网口列表："
    ip -o link show | awk -F': ' '{print "  - " $2}'
    echo "提示：如需同时监控多个网口，请用空格隔开（例如：eth0 eth1）。"
    printf "请输入要监控的网口名称 [%s]: " "${INTERFACES:-eth0}"
    read input_ifaces
    INTERFACES="${input_ifaces:-${INTERFACES:-eth0}}"

    # 2. 月流量上限
    printf "请输入每月流量上限 (单位: GB) [%s]: " "${MONTHLY_LIMIT_GB:-1000}"
    read input_limit
    MONTHLY_LIMIT_GB="${input_limit:-${MONTHLY_LIMIT_GB:-1000}}"

    # 3. 每月重置日
    printf "请输入每月流量重置日 (1-28) [%s]: " "${RESET_DAY:-1}"
    read input_reset
    RESET_DAY="${input_reset:-${RESET_DAY:-1}}"

    # 4. 时区选择
    echo ""
    echo "请选择流量统计与重置时区："
    echo "  1) UTC+8 (Asia/Shanghai - 北京时间)"
    echo "  2) UTC+0 (Etc/UTC)"
    printf "请选择 [1-2] [%s]: " "1"
    read input_tz_choice
    case "$input_tz_choice" in
        2) TIMEZONE="Etc/UTC" ;;
        *) TIMEZONE="Asia/Shanghai" ;;
    esac

    # 5. Telegram 配置
    printf "请输入 Telegram Bot Token [%s]: " "$TG_BOT_TOKEN"
    read input_token
    [ -n "$input_token" ] && TG_BOT_TOKEN="$input_token"

    printf "请输入 Telegram Chat ID [%s]: " "$TG_CHAT_ID"
    read input_chatid
    [ -n "$input_chatid" ] && TG_CHAT_ID="$input_chatid"

    # 6. 预警与关机阈值
    printf "请输入流量预警百分比 (默认 90) [%s]: " "${WARN_PERCENT:-90}"
    read input_warn
    WARN_PERCENT="${input_warn:-${WARN_PERCENT:-90}}"

    printf "请输入超额关机百分比 (默认 95) [%s]: " "${SHUTDOWN_PERCENT:-95}"
    read input_shut
    SHUTDOWN_PERCENT="${input_shut:-${SHUTDOWN_PERCENT:-95}}"

    # 保存配置文件
    cat << EOF > "$CONF_FILE"
INTERFACES="$INTERFACES"
MONTHLY_LIMIT_GB="$MONTHLY_LIMIT_GB"
RESET_DAY="$RESET_DAY"
TIMEZONE="$TIMEZONE"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
WARN_PERCENT="$WARN_PERCENT"
SHUTDOWN_PERCENT="$SHUTDOWN_PERCENT"
EOF

    echo "配置文件已保存至 $CONF_FILE"

    # 更新 vnstat 全局配置中的 MonthRotate
    if grep -q "^MonthRotate" /etc/vnstat.conf; then
        sed -i "s/^MonthRotate.*/MonthRotate $RESET_DAY/" /etc/vnstat.conf
    else
        echo "MonthRotate $RESET_DAY" >> /etc/vnstat.conf
    fi
    systemctl restart vnstat

    # 确保 vnstat 正在监控选定的所有网口
    for iface in $INTERFACES; do
        vnstat -i "$iface" --add 2>/dev/null
    done

    generate_scripts
    setup_systemd_timers
    echo ""
    echo "=========================================="
    echo "       初始化/配置更新成功完成！          "
    echo "=========================================="
}

# 生成流量检查与预警脚本（支持多网口流量聚合计算）
generate_scripts() {
    cat << 'EOF' > "$CHECK_SCRIPT"
#!/bin/sh
CONF="/etc/traffic-monitor.conf"
[ -f "$CONF" ] && . "$CONF"

[ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ] && exit 0

TOTAL_RX=0
TOTAL_TX=0

# 循环遍历并聚合所有监控网口的本月流量
for iface in $INTERFACES; do
    JSON_DATA=$(vnstat -i "$iface" --json 2>/dev/null)
    [ -z "$JSON_DATA" ] && continue
    RX=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0].rx // 0')
    TX=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0].tx // 0')
    TOTAL_RX=$((TOTAL_RX + RX))
    TOTAL_TX=$((TOTAL_TX + TX))
done

TOTAL_BYTES=$((TOTAL_RX + TOTAL_TX))
TOTAL_GB=$(awk "BEGIN {print $TOTAL_BYTES / 1024 / 1024 / 1024}")
LIMIT_GB="$MONTHLY_LIMIT_GB"

# 计算使用百分比
USAGE_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($TOTAL_GB / $LIMIT_GB) * 100}")
INT_PERCENT=$(echo "$USAGE_PERCENT" | awk -F'.' '{print $1}')

CURRENT_MONTH=$(date +%Y-%m)
STATE_DIR="/var/lib/traffic-monitor"
mkdir -p "$STATE_DIR"
WARN_FLAG="$STATE_DIR/warn_$CURRENT_MONTH.flag"

send_tg() {
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "parse_mode=Markdown" \
        -d "text=$1" >/dev/null 2>&1
}

# 95% 超额关机警报
if [ "$INT_PERCENT" -ge "$SHUTDOWN_PERCENT" ]; then
    SHUTDOWN_FLAG="$STATE_DIR/shutdown_$CURRENT_MONTH.flag"
    if [ ! -f "$SHUTDOWN_FLAG" ]; then
        MSG="🚨 *【超额关机警报】*
🌐 监控网口: \`$INTERFACES\`
📊 本月已用: \`${TOTAL_GB}GB / ${LIMIT_GB}GB\` (${USAGE_PERCENT}%)
🛑 已达到关机阈值 (${SHUTDOWN_PERCENT}%)，服务器已执行自动关机保护！"
        send_tg "$MSG"
        touch "$SHUTDOWN_FLAG"
        shutdown -h now
    fi
# 90% 流量预警 (仅发送一次)
elif [ "$INT_PERCENT" -ge "$WARN_PERCENT" ]; then
    if [ ! -f "$WARN_FLAG" ]; then
        MSG="⚠️ *【流量预警通知】*
🌐 监控网口: \`$INTERFACES\`
📊 本月已用: \`${TOTAL_GB}GB / ${LIMIT_GB}GB\` (${USAGE_PERCENT}%)
🚨 已达到预警阈值 (${WARN_PERCENT}%)，请注意控制流量！"
        send_tg "$MSG"
        touch "$WARN_FLAG"
    fi
fi
EOF
    chmod +x "$CHECK_SCRIPT"

    # 生成每日报告脚本（严格按设置时区统计前一天整天流量，避开 0 点日切冲突）
    cat << 'EOF' > "$REPORT_SCRIPT"
#!/bin/sh
CONF="/etc/traffic-monitor.conf"
[ -f "$CONF" ] && . "$CONF"

[ -z "$TG_BOT_TOKEN" ] \vert{}\vert{} [ -z "$TG_CHAT_ID" ] && exit 0

# 根据设置的时区获取昨天的准确日期 (YYYY-MM-DD)
YESTERDAY=$(TZ="$TIMEZONE" date -d "yesterday" +%Y-%m-%d)

DAY_RX_TOTAL=0
DAY_TX_TOTAL=0
M_RX_TOTAL=0
M_TX_TOTAL=0

for iface in $INTERFACES; do
    # 查询昨天指定时区整天的流量
    JSON_DAY=$(vnstat -i "$iface" --days --begin "$YESTERDAY" --end "$YESTERDAY" --json 2>/dev/null)
    D_RX=$(echo "$JSON_DAY" | jq -r '.interfaces[0].days[0].rx // 0')
    D_TX=$(echo "$JSON_DAY" | jq -r '.interfaces[0].days[0].tx // 0')
    DAY_RX_TOTAL=$((DAY_RX_TOTAL + D_RX))
    DAY_TX_TOTAL=$((DAY_TX_TOTAL + D_TX))

    # 查询本月累计流量
    JSON_MONTH=$(vnstat -i "$iface" --json 2>/dev/null)
    M_RX=$(echo "$JSON_MONTH" | jq -r '.interfaces[0].traffic.month[0].rx // 0')
    M_TX=$(echo "$JSON_MONTH" | jq -r '.interfaces[0].traffic.month[0].tx // 0')
    M_RX_TOTAL=$((M_RX_TOTAL + M_RX))
    M_TX_TOTAL=$((M_TX_TOTAL + M_TX))
done

DAY_TOTAL=$((DAY_RX_TOTAL + DAY_TX_TOTAL))
DAY_GB=$(awk "BEGIN {printf \"\%.2f\", $DAY_TOTAL / 1024 / 1024 / 1024}")
DAY_RX_GB=$(awk "BEGIN {printf \"\%.2f\", $DAY_RX_TOTAL / 1024 / 1024 / 1024}")
DAY_TX_GB=$(awk "BEGIN {printf \"\%.2f\", $DAY_TX_TOTAL / 1024 / 1024 / 1024}")

M_TOTAL=$((M_RX_TOTAL + M_TX_TOTAL))
M_GB=$(awk "BEGIN {printf \"\%.2f\", $M_TOTAL / 1024 / 1024 / 1024}")
M_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($M_GB / $MONTHLY_LIMIT_GB) * 100}")

MSG="📊 *【每日流量报告】*
📅 统计日期: \`$YESTERDAY\` (时区: \`$TIMEZONE\`)
🌐 监控网口: \`$INTERFACES\`

---
📥 *昨日下载*: \`${DAY_RX_GB} GB\`
📤 *昨日上传*: \`${DAY_TX_GB} GB\`
📦 *昨日合计*: \`${DAY_GB} GB\`

📈 *本月累计*: \`${M_GB} GB / $MONTHLY_LIMIT_GB GB\` (${M_PERCENT}%)"

curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=$MSG" >/dev/null 2>&1
EOF
    chmod +x "$REPORT_SCRIPT"
}

# 配置 systemd 定时器与服务
setup_systemd_timers() {
    # 1. 流量检查服务与定时器：每 1 分钟运行一次
    cat << 'EOF' > /etc/systemd/system/traffic-check.service
[Unit]
Description=Traffic Limit Check and Alert Service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/traffic-monitor-check.sh
EOF

    cat << 'EOF' > /etc/systemd/system/traffic-check.timer
[Unit]
Description=Run Traffic Check every 1 minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

    # 2. 每日报告服务与定时器：改为北京时间每天 08:10:00 运行（避开 0点整点日切冲突）
    cat << 'EOF' > /etc/systemd/system/traffic-report.service
[Unit]
Description=Daily Telegram Traffic Report Service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/traffic-monitor-report.sh
EOF

    cat << 'EOF' > /etc/systemd/system/traffic-report.timer
[Unit]
Description=Daily Traffic Report at 08:10 Beijing Time

[Timer]
OnCalendar=*-*-* 08:10:00 Asia/Shanghai
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now traffic-check.timer
    systemctl enable --now traffic-report.timer
}

# 主菜单管理界面
main_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "      Debian 13 流量监控与 TG 报警管理       "
        echo "=========================================="
        if [ -f "$CONF_FILE" ]; then
            echo "状态: [已配置并运行中]"
        else
            echo "状态: [未配置]"
        fi
        echo "------------------------------------------"
        echo "  1. 首次安装 / 修改配置参数"
        echo "  2. 手动执行一次流量检查与预警测试"
        echo "  3. 手动发送一次今日流量报告"
        echo "  4. 查看当前网口实时流量状态"
        echo "  5. 卸载流量监控系统"
        echo "  0. 退出脚本"
        echo "=========================================="
        printf "请输入选项 [0-5]: "
        read choice

        case "$choice" in
            1)
                install_dependencies
                configure_menu
                echo ""
                printf "按回车键继续..."
                read dummy
                ;;
            2)
                if [ -f "$CHECK_SCRIPT" ]; then
                    sh "$CHECK_SCRIPT"
                    echo "检查脚本已手动执行完成。"
                else
                    echo "错误：脚本未安装。"
                fi
                printf "按回车键继续..."
                read dummy
                ;;
            3)
                if [ -f "$REPORT_SCRIPT" ]; then
                    sh "$REPORT_SCRIPT"
                    echo "日报脚本已手动执行完成，请检查 Telegram 接收。"
                else
                    echo "错误：脚本未安装。"
                fi
                printf "按回车键继续..."
                read dummy
                ;;
            4)
                if [ -f "$CONF_FILE" ]; then
                    . "$CONF_FILE"
                    for iface in $INTERFACES; do
                        echo "--- 网口: $iface ---"
                        vnstat -i "$iface"
                    done
                else
                    echo "尚未配置。"
                fi
                echo ""
                printf "按回车键继续..."
                read dummy
                ;;
            5)
                echo "正在卸载..."
                systemctl disable --now traffic-check.timer traffic-check.service 2>/dev/null
                systemctl disable --now traffic-report.timer traffic-report.service 2>/dev/null
                rm -f /etc/systemd/system/traffic-check.* /etc/systemd/system/traffic-report.*
                rm -f "$CHECK_SCRIPT" "$REPORT_SCRIPT" "$CONF_FILE"
                systemctl daemon-reload
                echo "卸载完成。"
                exit 0
                ;;
            0)
                exit 0
                ;;
            *)
                echo "无效选项，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

main_menu
