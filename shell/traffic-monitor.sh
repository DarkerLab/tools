
#!/bin/bash
# ==============================================================================
# 脚本名称: traffic-monitor.sh
# 描述: 基于 vnStat 的流量监控、Telegram 每日报告、预警及超限关机助手
# 系统环境: Debian 13
# GitHub 仓库: https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh
# ==============================================================================

CONF_FILE="/etc/traffic-monitor.conf"
STATE_FILE="/etc/traffic-monitor.state"
PY_SCRIPT="/usr/local/bin/traffic-monitor-calc.py"
SCRIPT_PATH="/usr/local/bin/traffic-monitor.sh"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
NC='\033[0m'

# 检查 Root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[错误] 请使用 root 权限运行此脚本！(sudo -i)${NC}"
        exit 1
    }
}

# 打印 Logo
print_logo() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${GREEN}${BOLD}        vnstat 流量监控助手 v1.1 (Debian 13)          ${NC}"
    echo -e "${CYAN}======================================================${NC}"
}

# 1. 安装部署/修改配置
install_or_update() {
    echo -e "${YELLOW}[信息] 正在检查系统环境与更新依赖...${NC}"
    apt update -y && apt install -y vnstat curl jq python3 bc cron

    # 确保 vnstat 服务运行
    systemctl enable --now vnstat

    # 检查系统时区是否为 Asia/Shanghai
    CURRENT_TZ=$(timedatectl show --property=Timezone --value)
    if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
        echo -e "${YELLOW}[信息] 当前时区为 $CURRENT_TZ，正在自动设置时区为 Asia/Shanghai...${NC}"
        timedatectl set-timezone Asia/Shanghai
    else
        echo -e "${GREEN}[√] 系统时区已确认: Asia/Shanghai${NC}"
    fi

    # 获取可用网卡列表
    AVAILABLE_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")
    echo -e "\n${CYAN}当前可用网卡接口:${NC} $AVAILABLE_IFACES"

    # 读取已有配置（如果存在）
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi

    echo -e "\n${YELLOW}=== 请配置监控参数 ===${NC}"
    read -p "请输入自定义服务器名称 [默认: $(hostname)]: " INPUT_SERVER_NAME
    SERVER_NAME="${INPUT_SERVER_NAME:-$(hostname)}"

    read -p "请输入监控网卡接口（单或多网卡用逗号隔开，例: eth0 或 eth0,eth1） [默认: $(echo $AVAILABLE_IFACES | awk '{print $1}')]: " INPUT_IFACES
    INTERFACES="${INPUT_IFACES:-$(echo $AVAILABLE_IFACES | awk '{print $1}')}"

    read -p "请输入每月流量重置日期 (1-31) [默认: 1]: " INPUT_RESET_DAY
    RESET_DAY="${INPUT_RESET_DAY:-1}"

    echo "请选择时区模式:"
    echo "1) UTC+8 (Asia/Shanghai)"
    echo "2) UTC+0"
    read -p "请输入选项 [默认: 1]: " INPUT_TZ_MODE
    if [ "$INPUT_TZ_MODE" = "2" ]; then
        TIMEZONE_MODE="UTC0"
    else
        TIMEZONE_MODE="UTC8"
    fi

    echo "请选择流量统计类型:"
    echo "1) 总流量 (上传 + 下载)"
    echo "2) 仅上传流量"
    echo "3) 仅下载流量"
    read -p "请输入选项 [默认: 1]: " INPUT_TRAFFIC_TYPE
    TRAFFIC_TYPE="${INPUT_TRAFFIC_TYPE:-1}"

    read -p "请输入每月流量总额度 (单位: GB) [默认: 1000]: " INPUT_LIMIT_GB
    LIMIT_GB="${INPUT_LIMIT_GB:-1000}"

    read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
    read -p "请输入 Telegram Chat ID: " TG_CHAT_ID

    # 保存配置文件
    cat << EOF > "$CONF_FILE"
SERVER_NAME="$SERVER_NAME"
INTERFACES="$INTERFACES"
RESET_DAY="$RESET_DAY"
TIMEZONE_MODE="$TIMEZONE_MODE"
TRAFFIC_TYPE="$TRAFFIC_TYPE"
LIMIT_GB="$LIMIT_GB"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF

    # 生成 Python 计算与解析脚本
    cat << 'EOF' > "$PY_SCRIPT"
#!/usr/bin/env python3
import json
import subprocess
import sys
from datetime import datetime, timezone, timedelta

def get_traffic_data(interfaces, reset_day, tz_mode, traffic_type, limit_gb):
    if tz_mode == 'UTC0':
        tz = timezone.utc
    else:
        tz = timezone(timedelta(hours=8))
    
    now = datetime.now(tz)
    
    if now.day >= reset_day:
        start_date = datetime(now.year, now.month, reset_day, tzinfo=tz)
    else:
        if now.month == 1:
            start_date = datetime(now.year - 1, 12, reset_day, tzinfo=tz)
        else:
            start_date = datetime(now.year, now.month - 1, reset_day, tzinfo=tz)
    
    total_rx = 0
    total_tx = 0
    
    ifaces = [iface.strip() for iface in interfaces.split(',') if iface.strip()]
    
    for iface in ifaces:
        try:
            res = subprocess.run(['vnstat', '-i', iface, '--json'], capture_output=True, text=True, check=True)
            data = json.loads(res.stdout)
            for interface in data.get('interfaces', []):
                days = interface.get('traffic', {}).get('days', [])
                for d in days:
                    date_info = d.get('date', {})
                    y = date_info.get('year')
                    m = date_info.get('month')
                    day = date_info.get('day')
                    if None in (y, m, day):
                        continue
                    d_date = datetime(y, m, day, tzinfo=tz)
                    if start_date <= d_date <= now:
                        total_rx += d.get('rx', 0)
                        total_tx += d.get('tx', 0)
        except Exception:
            pass
    
    if traffic_type == 1:
        used_bytes = total_rx + total_tx
    elif traffic_type == 2:
        used_bytes = total_tx
    else:
        used_bytes = total_rx
        
    used_gb = used_bytes / (1024 * 1024 * 1024)
    pct = (used_gb / limit_gb * 100) if limit_gb > 0 else 0
    
    result = {
        "start_date": start_date.strftime("%Y-%m-%d"),
        "end_date": now.strftime("%Y-%m-%d %H:%M:%S"),
        "used_bytes": used_bytes,
        "used_gb": round(used_gb, 2),
        "rx_gb": round(total_rx / (1024 * 1024 * 1024), 2),
        "tx_gb": round(total_tx / (1024 * 1024 * 1024), 2),
        "limit_gb": limit_gb,
        "percentage": round(pct, 2)
    }
    print(json.dumps(result))

if __name__ == '__main__':
    if len(sys.argv) < 6:
        sys.exit(1)
    get_traffic_data(sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), float(sys.argv[5]))
EOF
    chmod +x "$PY_SCRIPT"

    # 将当前脚本复制到全局路径以供定时任务调用
    cp "$0" "$SCRIPT_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_PATH"

    # 配置 Cron 定时任务 (1分钟阈值检测，每日北京时间 8:10 推送报告)
    CRON_TEMP="/tmp/traffic_cron"
    crontab -l 2>/dev/null | grep -v "traffic-monitor.sh" > "$CRON_TEMP"
    echo "*/1 * * * * /usr/local/bin/traffic-monitor.sh --check-threshold >/dev/null 2>&1" >> "$CRON_TEMP"
    echo "10 8 * * * /usr/local/bin/traffic-monitor.sh --daily-push >/dev/null 2>&1" >> "$CRON_TEMP"
    crontab "$CRON_TEMP"
    rm -f "$CRON_TEMP"
    systemctl restart cron

    echo -e "\n${GREEN}[√] 部署与配置完成！定时任务已成功激活。${NC}"
    read -p "按回车键返回主菜单..."
}

# 发送 Telegram 消息函数
send_tg() {
    local msg="$1"
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        return 1
    fi
    response=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=${msg}")
    
    if echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 获取统计 JSON 数据
fetch_stats() {
    if [ ! -f "$CONF_FILE" ] || [ ! -f "$PY_SCRIPT" ]; then
        echo "{}"
        return
    fi
    source "$CONF_FILE"
    python3 "$PY_SCRIPT" "$INTERFACES" "$RESET_DAY" "$TIMEZONE_MODE" "$TRAFFIC_TYPE" "$LIMIT_GB"
}

# 2. 测试发送每日流量推送
test_daily_push() {
    echo -e "${YELLOW}[信息] 正在测试发送每日流量报告...${NC}"
    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}[错误] 请先完成安装部署与配置！${NC}"
        sleep 2
        return
    fi
    source "$CONF_FILE"
    
    stats_json=$(fetch_stats)
    if [ "$stats_json" = "{}" ]; then
        echo -e "${RED}[错误] 获取流量数据失败！${NC}"
        sleep 2
        return
    fi

    start_date=$(echo "$stats_json" | jq -r '.start_date')
    end_date=$(echo "$stats_json" | jq -r '.end_date')
    used_gb=$(echo "$stats_json" | jq -r '.used_gb')
    rx_gb=$(echo "$stats_json" | jq -r '.rx_gb')
    tx_gb=$(echo "$stats_json" | jq -r '.tx_gb')
    limit_gb=$(echo "$stats_json" | jq -r '.limit_gb')
    pct=$(echo "$stats_json" | jq -r '.percentage')

    type_str="总流量 (上传+下载)"
    [ "$TRAFFIC_TYPE" = "2" ] && type_str="仅上传流量"
    [ "$TRAFFIC_TYPE" = "3" ] && type_str="仅下载流量"

    msg="<b>📊 每日流量监控报告</b>
━━━━━━━━━━━━━━━
<b>服务器名称:</b> <code>${SERVER_NAME}</code>
<b>监控网卡:</b> <code>${INTERFACES}</code>
<b>统计类型:</b> ${type_str}
<b>统计周期:</b> ${start_date} 至 ${end_date}
<b>已用流量:</b> <b>${used_gb} GB</b> / ${limit_gb} GB (<b>${pct}%</b>)
<b>上传:</b> ${tx_gb} GB | <b>下载:</b> ${rx_gb} GB
━━━━━━━━━━━━━━━
<b>推送时间:</b> $(date '+%Y-%m-%d %H:%M:%S') (UTC+8)"

    if send_tg "$msg"; then
        echo -e "${GREEN}[√] 测试报告发送成功！请检查 Telegram 消息。${NC}"
    else
        echo -e "${RED}[×] 发送失败，请检查 Telegram Token 和 Chat ID 是否正确。${NC}"
    fi
    read -p "按回车键返回主菜单..."
}

# 3. 测试运行阈值检测
test_threshold_check() {
    echo -e "${YELLOW}[信息] 正在手动执行阈值检测...${NC}"
    do_threshold_check "test"
    read -p "按回车键返回主菜单..."
}

# 阈值检测核心逻辑
do_threshold_check() {
    local mode="$1"
    if [ ! -f "$CONF_FILE" ]; then
        [ "$mode" != "test" ] && exit 0
        echo -e "${RED}[错误] 未配置监控参数${NC}"
        return
    fi
    source "$CONF_FILE"

    stats_json=$(fetch_stats)
    [ "$stats_json" = "{}" ] && return

    pct=$(echo "$stats_json" | jq -r '.percentage')
    used_gb=$(echo "$stats_json" | jq -r '.used_gb')
    limit_gb=$(echo "$stats_json" | jq -r '.limit_gb')

    # 初始化状态文件记录当前周期警报状态
    current_month_key=$(date +%Y-%m)
    if [ ! -f "$STATE_FILE" ]; then
        echo "MONTH=$current_month_key" > "$STATE_FILE"
        echo "WARN_90=0" >> "$STATE_FILE"
        echo "SHUTDOWN_95=0" >> "$STATE_FILE"
    fi
    source "$STATE_FILE"
    if [ "$MONTH" != "$current_month_key" ]; then
        current_month_key="$current_month_key"
        WARN_90=0
        SHUTDOWN_95=0
        cat << EOF > "$STATE_FILE"
MONTH=$current_month_key
WARN_90=$WARN_90
SHUTDOWN_95=$SHUTDOWN_95
EOF
    fi

    # 检查 95% 关机阈值
    is_ge_95=$(echo "$pct >= 95" | bc -l)
    if [ "$is_ge_95" -eq 1 ]; then
        if [ "$SHUTDOWN_95" -eq 0 ] || [ "$mode" = "test" ]; then
            msg="<b>🚨 流量超限关机警报</b>
━━━━━━━━━━━━━━━
<b>服务器名称:</b> <code>${SERVER_NAME}</code>
<b>当前使用率:</b> <b>${pct}%</b> (已达到/超过 95% 关机阈值)
<b>已用流量:</b> ${used_gb} GB / ${limit_gb} GB
<b>通知发送成功，服务器正在执行关机操作...</b>
━━━━━━━━━━━━━━━
<b>时间:</b> $(date '+%Y-%m-%d %H:%M:%S')"
            
            if send_tg "$msg"; then
                echo -e "${GREEN}[√] 95% 关机警报通知发送成功！${NC}"
                sed -i 's/^SHUTDOWN_95=.*/SHUTDOWN_95=1/' "$STATE_FILE"
                if [ "$mode" != "test" ]; then
                    shutdown -h now
                fi
            else
                echo -e "${RED}[×] 关机通知发送失败！为确保安全，取消关机操作。${NC}"
            fi
        else
            [ "$mode" = "test" ] && echo "95% 关机警报在本周期内已发送过。"
        fi
        return
    fi

    # 检查 90% 预警阈值
    is_ge_90=$(echo "$pct >= 90" | bc -l)
    if [ "$is_ge_90" -eq 1 ]; then
        if [ "$WARN_90" -eq 0 ] || [ "$mode" = "test" ]; then
            msg="<b>⚠️ 流量预警通知</b>
━━━━━━━━━━━━━━━
<b>服务器名称:</b> <code>${SERVER_NAME}</code>
<b>当前使用率:</b> <b>${pct}%</b> (已达到 90% 预警线)
<b>已用流量:</b> ${used_gb} GB / ${limit_gb} GB
<b>请及时关注流量情况！</b>
━━━━━━━━━━━━━━━
<b>时间:</b> $(date '+%Y-%m-%d %H:%M:%S')"
            
            if send_tg "$msg"; then
                echo -e "${GREEN}[√] 90% 预警通知发送成功！${NC}"
                sed -i 's/^WARN_90=.*/WARN_90=1/' "$STATE_FILE"
            else
                echo -e "${RED}[×] 90% 预警通知发送失败。${NC}"
            fi
        else
            [ "$mode" = "test" ] && echo "90% 预警通知在本周期内已发送过。"
        fi
    fi

    if [ "$mode" = "test" ]; then
        echo -e "${GREEN}当前流量使用率: ${pct}% (未达到预警/关机线)${NC}"
    fi
}

# 4. 查看当前流量数据
show_traffic() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${GREEN}${BOLD}                 当前流量数据看板                     ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}[错误] 请先完成安装部署与配置！${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi
    source "$CONF_FILE"

    stats_json=$(fetch_stats)
    if [ "$stats_json" = "{}" ]; then
        echo -e "${RED}[错误] 无法获取流量数据，请检查 vnstat 是否正常运行。${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi

    start_date=$(echo "$stats_json" | jq -r '.start_date')
    end_date=$(echo "$stats_json" | jq -r '.end_date')
    used_gb=$(echo "$stats_json" | jq -r '.used_gb')
    rx_gb=$(echo "$stats_json" | jq -r '.rx_gb')
    tx_gb=$(echo "$stats_json" | jq -r '.tx_gb')
    limit_gb=$(echo "$stats_json" | jq -r '.limit_gb')
    pct=$(echo "$stats_json" | jq -r '.percentage')

    echo -e "服务器名称: ${GREEN}${SERVER_NAME}${NC}"
    echo -e "监控网卡:   ${GREEN}${INTERFACES}${NC}"
    echo -e "计费周期:   ${GREEN}${start_date} ~ ${end_date}${NC}"
    echo -e "流量总限额: ${GREEN}${limit_gb} GB${NC}"
    echo -e "已用总流量: ${GREEN}${used_gb} GB${NC} (${CYAN}${pct}%${NC})"
    echo -e "  ├── 上传: ${GREEN}${tx_gb} GB${NC}"
    echo -e "  └── 下载: ${GREEN}${rx_gb} GB${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    # 同时展示系统自带的 vnstat 简要快照
    echo -e "\n${YELLOW}vnstat 实时快照:${NC}"
    vnstat -i "$INTERFACES" 2>/dev/null || vnstat

    echo ""
    read -p "按回车键返回主菜单..."
}

# 5. 卸载监控程序
do_uninstall() {
    echo -e "${RED}警告: 即将卸载流量监控程序及清理相关配置、定时任务！${NC}"
    read -p "确认卸载？(y/n): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 清理 Cron
        crontab -l 2>/dev/null | grep -v "traffic-monitor.sh" | crontab -
        # 删除文件
        rm -f "$CONF_FILE" "$STATE_FILE" "$PY_SCRIPT" "$SCRIPT_PATH"
        echo -e "${GREEN}[√] 流量监控助手已成功卸载。${NC}"
    else
        echo -e "${YELLOW}取消卸载。${NC}"
    fi
    read -p "按回车键返回主菜单..."
}

# 每日推送 Cron 入口
do_daily_push() {
    if [ ! -f "$CONF_FILE" ]; then exit 0; fi
    source "$CONF_FILE"
    stats_json=$(fetch_stats)
    [ "$stats_json" = "{}" ] && exit 0

    start_date=$(echo "$stats_json" | jq -r '.start_date')
    end_date=$(echo "$stats_json" | jq -r '.end_date')
    used_gb=$(echo "$stats_json" | jq -r '.used_gb')
    rx_gb=$(echo "$stats_json" | jq -r '.rx_gb')
    tx_gb=$(echo "$stats_json" | jq -r '.tx_gb')
    limit_gb=$(echo "$stats_json" | jq -r '.limit_gb')
    pct=$(echo "$stats_json" | jq -r '.percentage')

    type_str="总流量 (上传+下载)"
    [ "$TRAFFIC_TYPE" = "2" ] && type_str="仅上传流量"
    [ "$TRAFFIC_TYPE" = "3" ] && type_str="仅下载流量"

    msg="<b>📊 每日流量监控报告</b>
━━━━━━━━━━━━━━━
<b>服务器名称:</b> <code>${SERVER_NAME}</code>
<b>监控网卡:</b> <code>${INTERFACES}</code>
<b>统计类型:</b> ${type_str}
<b>统计周期:</b> ${start_date} 至 ${end_date}
<b>已用流量:</b> <b>${used_gb} GB</b> / ${limit_gb} GB (<b>${pct}%</b>)
<b>上传:</b> ${tx_gb} GB | <b>下载:</b> ${rx_gb} GB
━━━━━━━━━━━━━━━
<b>推送时间:</b> $(date '+%Y-%m-%d %H:%M:%S') (UTC+8)"

    send_tg "$msg"
    exit 0
}

# 命令参数分发
case "$1" in
    --check-threshold)
        do_threshold_check "cron"
        exit 0
        ;;
    --daily-push)
        do_daily_push
        exit 0
        ;;
esac

check_root

# 主交互菜单循环
while true; do
    print_logo
    echo -e "1. 安装部署/修改配置"
    echo -e "2. 测试发送每日流量推送"
    echo -e "3. 测试运行阈值检测"
    echo -e "4. 查看当前流量数据"
    echo -e "5. 卸载监控程序"
    echo -e "0. 退出"
    echo -e "${CYAN}======================================================${NC}"
    read -p "请选择操作 [0-5]: " choice

    case "$choice" in
        1) install_or_update ;;
        2) test_daily_push ;;
        3) test_threshold_check ;;
        4) show_traffic ;;
        5) do_uninstall ;;
        0) echo -e "${GREEN}再见！${NC}; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${NC}"; sleep 1 ;;
    esac
done
