#!/usr/bin/env bash

# =======================================================
# 仓库及文件配置信息 (对应 DarkerLab/tools/shell)
# =======================================================
GITHUB_USER="DarkerLab"
GITHUB_REPO="tools"
BRANCH="main"
SCRIPT_FOLDER="shell"
SCRIPT_NAME="traffic_monitor.sh"

RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/${SCRIPT_FOLDER}/${SCRIPT_NAME}"
TARGET_PATH="/usr/local/bin/traffic_monitor.sh"
SHORTCUT_PATH="/usr/local/bin/traffic"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请以 root 权限运行此脚本 (sudo bash $0)"
  exit 1
fi

echo "=========================================="
echo "🚀 开始下载并安装 Telegram 流量监控服务..."
echo "=========================================="

# 1. 下载主程序脚本
echo "📥 正在从 GitHub 获取最新版本..."
curl -sSL "$RAW_URL" -o "$TARGET_PATH"

if [ $? -ne 0 ] || [ ! -s "$TARGET_PATH" ]; then
    echo "❌ 下载失败！请检查 GitHub 路径或网络状态。"
    echo "   目标链接: $RAW_URL"
    exit 1
fi

# 2. 赋予可执行权限
chmod +x "$TARGET_PATH"

# 3. 创建快捷命令 'traffic'
ln -sf "$TARGET_PATH" "$SHORTCUT_PATH"

echo "✅ 安装成功！"
echo "💡 提示：以后随时在终端输入【 traffic 】即可打开控制菜单。"
echo "=========================================="
echo ""

# 4. 自动运行主程序进行初始化
exec "$TARGET_PATH"
