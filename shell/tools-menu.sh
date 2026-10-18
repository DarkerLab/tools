#!/bin/bash
# tools-menu.sh - Linux 运维工具合集交互菜单
# 仓库：DarkerLab/tools/shell 目录

# ========== 配置区 ==========
BASE_URL="https://raw.githubusercontent.com/DarkerLab/tools/refs/heads/main/shell"
SCRIPTS=(
    "hostname-set.sh"
    "gai-priority.sh"
    "dns-resolv.sh"
    "swap.sh"
    "bbr-enable.sh"
)
NAMES=(
    "修改主机名并同步 hosts"
    "设置 IPv4 解析优先"
    "配置 DNS 并锁定 resolv.conf"
    "交换分区添加/删除管理"
    "启用 TCP BBR 拥塞控制"
)
MAX_OPTION=${#SCRIPTS[@]}
# ============================

# 校验 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行此工具"
    exit 1
fi

# 执行指定脚本
run_script() {
    local index=$1
    local script_name="${SCRIPTS[$index]}"
    local script_url="${BASE_URL}/${script_name}"
    local tmp_file="/tmp/${script_name}.$$"

    echo "正在下载: ${script_name}"
    if ! wget -nv -O "$tmp_file" "$script_url" 2>/dev/null; then
        echo "❌ 下载失败，请检查网络连接或脚本地址是否正确"
        rm -f "$tmp_file"
        return 1
    fi

    echo "===== 开始执行: ${NAMES[$index]} ====="
    bash "$tmp_file"
    rm -f "$tmp_file"
    echo -e "\n===== 执行完成 ====="
    read -p "按回车键返回菜单..." _
}

# 主循环
while true; do
    # 仅在真实交互终端时清屏
    [ -t 0 ] && clear
    echo "=================================="
    echo "  Linux 运维工具合集 v1.2"
    echo "  仓库: DarkerLab/tools"
    echo "=================================="
    for i in "${!SCRIPTS[@]}"; do
        echo "  $((i+1)). ${NAMES[$i]}"
    done
    echo "  0. 退出"
    echo "=================================="
    read -p "请输入选项 [0-${MAX_OPTION}]: " choice

    case "$choice" in
        0)
            echo "已退出"
            exit 0
            ;;
        [1-9]*)
            if [ "$choice" -ge 1 ] && [ "$choice" -le "$MAX_OPTION" ]; then
                run_script $((choice-1))
            else
                echo "❌ 无效选项，请输入 0-${MAX_OPTION} 的数字"
                sleep 1
            fi
            ;;
        *)
            echo "❌ 请输入有效数字"
            sleep 1
            ;;
    esac
done
