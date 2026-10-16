#!/bin/bash

# 确保以root权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本 (sudo bash 或 root 直接运行)"
  exit 1
fi

CONFIG_FILE="/etc/traffic-monitor.conf"
SCRIPT_FILE="/usr/local/bin/traffic-monitor.py"
CRON_JOB="* * * * * /usr/bin/python3 /usr/local/bin/traffic-monitor.py >/dev/null 2>&1"

install_dependencies() {
    echo "==> 正在更新系统并安装依赖工具..."
    apt update && apt upgrade -y
    apt install -y vnstat curl jq python3 bc cron
    
    # 设置系统时区为 Asia/Shanghai
    echo "==> 设置系统时区为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai
    
    # 启动并启用 vnstat服务
    systemctl enable --now vnstat
    sleep 2
}

detect_interfaces() {
    echo "==> 检测当前可用的网卡接口..."
    ip -o link show | awk -F': ' '{print $2}' | grep -v "lo"
}

configure_params() {
    echo "============================================="
    echo "       Debian 13 流量监控与告警脚本配置 v0.1"
    echo "============================================="

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    read -p "请输入自定义监控服务器名称 [当前: ${SERVER_NAME:-My-Server}]: " input_name
    SERVER_NAME="${input_name:-${SERVER_NAME:-My-Server}}"

    echo "可用网卡列表："
    detect_interfaces
    read -p "请输入要监控的网卡接口(多个网卡用空格或逗号分隔) [当前: ${INTERFACES:-eth0}]: " input_ifaces
    INTERFACES="${input_ifaces:-${INTERFACES:-eth0}}"
    INTERFACES=$(echo "$INTERFACES" | tr ',' ' ')

    read -p "请输入每月流量重置日期 (1-31) [当前: ${RESET_DAY:-1}]: " input_day
    RESET_DAY="${input_day:-${RESET_DAY:-1}}"

    echo "请选择流量重置时区基准："
    echo "1) UTC+8 (北京时间)"
    echo "2) UTC+0 (零时区)"
    read -p "请选择 [当前: ${TIMEZONE_MODE:-UTC8}]: " input_tz
    case "$input_tz" in
        2) TIMEZONE_MODE="UTC0" ;;
        *) TIMEZONE_MODE="UTC8" ;;
    esac

    echo "请选择流量统计类型："
    echo "1) 总流量 (上传 + 下载)"
    echo "2) 仅上传流量"
    echo "3) 仅下载流量"
    read -p "请选择 [当前: ${TRAFFIC_TYPE:-1}]: " input_type
    TRAFFIC_TYPE="${input_type:-${TRAFFIC_TYPE:-1}}"

    read -p "请输入每月总流量限制额度 (单位: GB，例如 2000) [当前: ${TOTAL_GB:-2000}]: " input_total
    TOTAL_GB="${input_total:-${TOTAL_GB:-2000}}"

    read -p "请输入 Telegram Bot Token [当前: ${TG_BOT_TOKEN}]: " input_token
    TG_BOT_TOKEN="${input_token:-$TG_BOT_TOKEN}"

    read -p "请输入 Telegram Chat ID [当前: ${TG_CHAT_ID}]: " input_chat
    TG_CHAT_ID="${input_chat:-$TG_CHAT_ID}"

    cat << EOF_CONF > "$CONFIG_FILE"
SERVER_NAME="$SERVER_NAME"
INTERFACES="$INTERFACES"
RESET_DAY=$RESET_DAY
TIMEZONE_MODE="$TIMEZONE_MODE"
TRAFFIC_TYPE="$TRAFFIC_TYPE"
TOTAL_GB=$TOTAL_GB
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF_CONF

    chmod 600 "$CONFIG_FILE"
    echo "==> 配置文件已保存至 $CONFIG_FILE 并完成权限加固。"
}

deploy_monitor_script() {
    echo "==> 正在生成核心监控脚本..."
    cat << 'EOF_PY' > "$SCRIPT_FILE"
#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

CONFIG_FILE = "/etc/traffic-monitor.conf"
STATE_FILE = "/var/lib/traffic-monitor/state.json"

def load_config():
    config = {}
    if not os.path.exists(CONFIG_FILE):
        return {}
    with open(CONFIG_FILE, "r") as f:
        for line in f:
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                config[k] = v.strip('"\'')
    return config

def load_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                return json.load(f)
        except:
            pass
    return {"cycle_start": "", "warn_90": False, "shutdown_95": False, "last_daily_date": ""}

def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f)

def send_tg(token, chat_id, message):
    if not token or not chat_id:
        print("[Error] Telegram Token 或 Chat ID 未配置！")
        return False
    import urllib.request
    import urllib.parse
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": chat_id, "text": message, "parse_mode": "HTML"}).encode()
    try:
        req = urllib.request.Request(url, data=data, method="POST")
        with urllib.request.urlopen(req, timeout=10) as response:
            return True
    except Exception as e:
        print(f"[Error] Telegram 发送失败: {e}")
        return False

def parse_size(s):
    if not s or "--" in s: 
        return 0.0
    parts = s.split()
    if len(parts) < 2:
        return 0.0
    try:
        val = float(parts[0])
        unit = parts[1].lower()
        mult = 1.0
        if 'ki' in unit: mult = 1024.0
        elif 'mi' in unit: mult = 1024.0**2
        elif 'gi' in unit: mult = 1024.0**3
        elif 'ti' in unit: mult = 1024.0**4
        elif unit == 'kb': mult = 1000.0
        elif unit == 'mb': mult = 1000.0**2
        elif unit == 'gb': mult = 1000.0**3
        elif unit == 'tb': mult = 1000.0**4
        return val * mult
    except:
        return 0.0

def calculate_traffic():
    config = load_config()
    ifaces = config.get("INTERFACES", "eth0").split()
    reset_day = int(config.get("RESET_DAY", 1))
    tz_mode = config.get("TIMEZONE_MODE", "UTC8")
    traffic_type = int(config.get("TRAFFIC_TYPE", 1))
    
    if tz_mode == "UTC0":
        target_tz = timezone.utc
    else:
        target_tz = timezone(timedelta(hours=8))
        
    now = datetime.now(target_tz)
    year, month, day = now.year, now.month, now.day
    
    if day >= reset_day:
        cycle_start = datetime(year, month, reset_day, 0, 0, 0, tzinfo=target_tz)
    else:
        if month == 1:
            cycle_start = datetime(year - 1, 12, reset_day, 0, 0, 0, tzinfo=target_tz)
        else:
            cycle_start = datetime(year, month - 1, reset_day, 0, 0, 0, tzinfo=target_tz)
            
    cycle_start_str = cycle_start.strftime("%Y-%m-%d")
    
    used_bytes = 0.0
    combined_iface = "+".join(ifaces)
    
    try:
        # 使用 vnstat 文本表格查询，完美支持多网卡聚合（如 ens18+ens19）
        res = subprocess.run(["vnstat", "-i", combined_iface, "-m"], capture_output=True, text=True, check=True)
        target_ym = now.strftime("%Y-%m")
        
        for line in res.stdout.splitlines():
            if target_ym in line and "|" in line:
                parts = [p.strip() for p in line.split("|")]
                if len(parts) >= 4:
                    rx_bytes = parse_size(parts[1])
                    tx_bytes = parse_size(parts[2])
                    total_bytes = parse_size(parts[3])
                    
                    if traffic_type == 1:
                        used_bytes = total_bytes
                    elif traffic_type == 2:
                        used_bytes = tx_bytes
                    elif traffic_type == 3:
                        used_bytes = rx_bytes
                    break
    except Exception as e:
        print(f"[Warning] 获取 vnstat 数据失败: {e}")

    used_gb = used_bytes / (1024.0 ** 3)
    return used_gb, cycle_start_str, now

def print_status():
    config = load_config()
    server_name = config.get("SERVER_NAME", "Server")
    total_gb = float(config.get("TOTAL_GB", 1000))
    used_gb, cycle_start_str, now = calculate_traffic()
    percent = (used_gb / total_gb * 100) if total_gb > 0 else 0.0
    
    print(f"服务器名称: {server_name}")
    print(f"监控网卡: {config.get('INTERFACES', 'N/A')}")
    print(f"重置日期: 每月 {config.get('RESET_DAY', 1)} 号 ({config.get('TIMEZONE_MODE', 'UTC8')})")
    print(f"统计周期起点: {cycle_start_str}")
    print(f"流量类型: {config.get('TRAFFIC_TYPE', '1')} (1:总流量 2:上传 3:下载)")
    print(f"总流量限制: {total_gb:.2f} GB")
    print(f"---------------------------------------------")
    print(f"📊 当前已用流量: {used_gb:.2f} GB")
    print(f"📈 流量使用占比: {percent:.2f}%")
    print(f"⏰ 当前检测时间: {now.strftime('%Y-%m-%d %H:%M:%S')}")

def main():
    if len(sys.argv) > 1:
        if sys.argv[1] == "--status":
            print_status()
            return
        elif sys.argv[1] == "--test":
            config = load_config()
            server_name = config.get("SERVER_NAME", "Server")
            total_gb = float(config.get("TOTAL_GB", 1000))
            token = config.get("TG_BOT_TOKEN", "")
            chat_id = config.get("TG_CHAT_ID", "")
            used_gb, cycle_start_str, now = calculate_traffic()
            percent = (used_gb / total_gb * 100) if total_gb > 0 else 0.0
            
            msg = (
                f"🧪 <b>[{server_name}] 手动测试报告</b>\n\n"
                f"▪️ <b>周期用量:</b> {used_gb:.2f} GB / {total_gb:.2f} GB ({percent:.1f}%)\n"
                f"▪️ <b>统计起止:</b> {cycle_start_str} 至今\n"
                f"▪️ <b>测试时间:</b> {now.strftime('%Y-%m-%d %H:%M')}"
            )
            success = send_tg(token, chat_id, msg)
            if success:
                print("==> 测试消息已成功发送至 Telegram，请检查接收！")
            else:
                print("==> 发送失败，请检查您的 Bot Token 和 Chat ID 是否正确。")
            return

    config = load_config()
    if not config:
        return
        
    server_name = config.get("SERVER_NAME", "Server")
    total_gb = float(config.get("TOTAL_GB", 1000))
    token = config.get("TG_BOT_TOKEN", "")
    chat_id = config.get("TG_CHAT_ID", "")
    
    used_gb, cycle_start_str, now = calculate_traffic()
    percent = (used_gb / total_gb * 100) if total_gb > 0 else 0.0
        
    state = load_state()
    
    if state.get("cycle_start") != cycle_start_str:
        state = {
            "cycle_start": cycle_start_str,
            "warn_90": False,
            "shutdown_95": False,
            "last_daily_date": ""
        }
        save_state(state)
        
    current_time_str = now.strftime("%Y-%m-%d %H:%M")
    today_date_str = now.strftime("%Y-%m-%d")
    
    # 1. 每日 08:10 北京时间报告推送
    if now.hour == 8 and now.minute == 10:
        if state.get("last_daily_date") != today_date_str:
            msg = (
                f"📊 <b>[{server_name}] 每日流量日报</b>\n\n"
                f"▪️ <b>周期用量:</b> {used_gb:.2f} GB / {total_gb:.2f} GB ({percent:.1f}%)\n"
                f"▪️ <b>统计起止:</b> {cycle_start_str} 至今\n"
                f"▪️ <b>统计时间:</b> {current_time_str}"
            )
            send_tg(token, chat_id, msg)
            state["last_daily_date"] = today_date_str
            save_state(state)

    # 2. 90% 预警推送通知
    if percent >= 90.0 and not state.get("warn_90", False):
        msg = (
            f"⚠️ <b>[{server_name}] 流量预警通知 (90%)</b>\n\n"
            f"▪️ <b>当前用量:</b> {used_gb:.2f} GB / {total_gb:.2f} GB ({percent:.1f}%)\n"
            f"▪️ <b>告警时间:</b> {current_time_str}"
        )
        success = send_tg(token, chat_id, msg)
        if success:
            state["warn_90"] = True
            save_state(state)

    # 3. 95% 关机报警推送通知
    if percent >= 95.0 and not state.get("shutdown_95", False):
        msg = (
            f"🛑 <b>[{server_name}] 流量超限关机 (95%)</b>\n\n"
            f"▪️ <b>当前用量:</b> {used_gb:.2f} GB / {total_gb:.2f} GB ({percent:.1f}%)\n"
            f"▪️ <b>触发动作:</b> 已执行自动关机保护\n"
            f"▪️ <b>报警时间:</b> {current_time_str}"
        )
        success = send_tg(token, chat_id, msg)
        if success:
            state["shutdown_95"] = True
            save_state(state)
            os.system("shutdown -h now")
        else:
            print("[Warning] 95% 关机通知发送失败，推迟关机以待重试。")

if __name__ == "__main__":
    main()
EOF_PY

    chmod +x "$SCRIPT_FILE"
    echo "==> 监控核心脚本已更新并赋予权限。"
}

setup_cron() {
    echo "==> 配置定时任务 (每1分钟检查一次)..."
    crontab -l 2>/dev/null | grep -v "traffic-monitor.py" | { cat; echo "$CRON_JOB"; } | crontab -
    systemctl restart cron
    echo "==> 定时任务设置成功！"
}

show_status() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "============================================="
        echo "          当前流量监控运行状态"
        echo "============================================="
        python3 /usr/local/bin/traffic-monitor.py --status
        echo "============================================="
    else
        echo "尚未配置监控，请先运行安装/配置。"
    fi
}

menu() {
    while true; do
        clear
        echo "============================================="
        echo "    Debian 13 vnstat 流量监控与报警一键脚本"
        echo "============================================="
        echo "1. 安装 / 初始化配置 / 修改配置"
        echo "2. 查看当前监控状态与流量使用情况"
        echo "3. 手动触发一次 Telegram 测试推送"
        echo "4. 卸载流量监控"
        echo "0. 退出脚本"
        echo "============================================="
        read -p "请选择操作 [0-4]: " choice
        case "$choice" in
            1)
                install_dependencies
                configure_params
                deploy_monitor_script
                setup_cron
                echo "==> 安装与配置完成！"
                read -p "按回车键返回主菜单..."
                ;;
            2)
                show_status
                read -p "按回车键返回主菜单..."
                ;;
            3)
                echo "==> 正在向 Telegram 发送测试消息..."
                python3 /usr/local/bin/traffic-monitor.py --test
                read -p "按回车键返回主菜单..."
                ;;
            4)
                read -p "确定要卸载流量监控吗？[y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    crontab -l 2>/dev/null | grep -v "traffic-monitor.py" | crontab -
                    rm -f "$CONFIG_FILE" "$SCRIPT_FILE"
                    echo "==> 卸载完成。"
                fi
                read -p "按回车键返回主菜单..."
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

menu
