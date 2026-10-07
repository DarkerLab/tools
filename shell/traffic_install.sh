#!/usr/bin/env bash
# ==============================================================================
# Telegram 流量监控助手 - 一键安装脚本 (traffic_install.sh)
# Repository Path: DarkerLab/tools/main/shell/traffic_install.sh
# ==============================================================================

set -u

GITHUB_USER="DarkerLab"
GITHUB_REPO="tools"
BRANCH="main"
SCRIPT_FOLDER="shell"
SCRIPT_NAME="traffic_monitor.sh"

RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/${SCRIPT_FOLDER}/${SCRIPT_NAME}"
TARGET_PATH="/usr/local/bin/traffic_monitor.sh"
SHORTCUT_PATH="/usr/local/bin/traffic"

# 1. 检查 root 权限
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "❌ 错误: 请使用 sudo 或 root 权限运行此安装脚本！"
    exit 1
fi

echo "=========================================="
echo "🚀 开始下载并安装 Telegram 流量监控服务..."
echo "=========================================="

# 2. 下载主程序脚本
echo "📥 正在从 GitHub 获取最新版本..."
curl -sSL "$RAW_URL" -o "$TARGET_PATH"

if [ $? -ne 0 ] || [ ! -s "$TARGET_PATH" ]; then
    echo "❌ 下载失败！请检查 GitHub 路径或网络状态。"
    echo "    目标链接: $RAW_URL"
    exit 1
fi

# 3. 自动清理 Windows \r 换行符（防止 CRLF 格式错误）
sed -i 's/\r$//' "$TARGET_PATH"

# 4. 赋予执行权限并创建终端快捷命令
chmod +x "$TARGET_PATH"
rm -f "$SHORTCUT_PATH" "/usr/bin/traffic" 2>/dev/null || true
ln -sf "$TARGET_PATH" "$SHORTCUT_PATH"
ln -sf "$TARGET_PATH" "/usr/bin/traffic" 2>/dev/null || true

echo "✅ 安装成功！"
echo "💡 提示：以后随时在终端输入【 traffic 】即可打开控制菜单。"
echo "=========================================="
echo ""

# 5. 替换当前进程，直接运行主程序交互菜单
exec bash "$TARGET_PATH"
