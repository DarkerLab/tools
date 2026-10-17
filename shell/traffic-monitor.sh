#!/usr/bin/env bash
#===============================================================================
# 脚本名称 : traffic-monitor.sh
# 版    本 : v1.1
# 适用系统 : Debian 13 (兼容 Debian 11/12、Ubuntu 20.04+)，依赖 vnStat 2.x
# 功能说明 :
#   1. 基于 vnStat 的账单周期流量监控（支持自定义每月重置日，UTC0 时间基准）
#   2. Telegram 每日流量日报（北京时间 08:00 推送）
#   3. 流量达 90% 首次预警推送（每账单周期仅推送一次）
#   4. 流量达 95% 关机报警推送（失败自动重试 3 次），延迟 1 分钟并二次确认
#      阈值仍达标后执行关机，防止账单重置后误关机
#   5. 每分钟定时检查（cron），安装/修改配置后自动创建、更新并重载定时任务
#   6. 完整日志记录、权限检查、依赖检查、配置校验、中文交互提示
# 更新地址 : https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh
#===============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C

VERSION="v1.1"
SCRIPT_PATH="$(readlink -f "$0")"
BASE_DIR="/etc/traffic-monitor"
CONF_FILE="${BASE_DIR}/config.conf"
STATE_FILE="${BASE_DIR}/state.conf"
LOG_FILE="${BASE_DIR}/monitor.log"
LOCK_SHUTDOWN="${BASE_DIR}/shutdown.lock"
UPDATE_URL="https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh"
VNSTAT_CONF="/etc/vnstat.conf"
MAX_LOG_SIZE=$((5*1024*1024))   # 日志超过 5MB 自动截断

#===============================================================================
# 基础工具函数
#===============================================================================
c_red()    { echo -e "\033[31m$*\033[0m"; }
c_green()  { echo -e "\033[32m$*\033[0m"; }
c_yellow() { echo -e "\033[33m$*\033[0m"; }
c_blue()   { echo -e "\033[36m$*\033[0m"; }

log() {
    # $1=级别(INFO/WARN/ERROR/OK) $2=内容
    mkdir -p "$BASE_DIR" 2>/dev/null
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "[${ts}] [$1] $2" >> "$LOG_FILE" 2>/dev/null
    # 日志轮转：超过上限保留后 2000 行
    if [ -f "$LOG_FILE" ]; then
        local sz; sz=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$sz" -gt "$MAX_LOG_SIZE" ]; then
            tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] 日志超过上限，已自动截断" >> "$LOG_FILE"
        fi
    fi
}

die() { c_red "[错误] $1"; log "ERROR" "$1"; exit 1; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 权限运行本脚本（sudo bash $0）"
    fi
}

# 字节数转可读单位
human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB PB", u, " ");
        i = 1;
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf "%.2f %s", b, u[i];
    }'
}

#===============================================================================
# 配置读写
#===============================================================================
load_config() {
    [ -f "$CONF_FILE" ] || return 1
    # shellcheck disable=SC1090
    . "$CONF_FILE" || return 1
    return 0
}

load_state() {
    WARNED_CYCLE=""
    [ -f "$STATE_FILE" ] && . "$STATE_FILE" 2>/dev/null
    return 0
}

save_state_var() {
    # $1=变量名 $2=值
    mkdir -p "$BASE_DIR"
    if [ -f "$STATE_FILE" ] && grep -q "^$1=" "$STATE_FILE"; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$STATE_FILE"
    else
        echo "$1=\"$2\"" >> "$STATE_FILE"
    fi
}

# 配置校验
validate_config() {
    local err=0
    [ -n "$SERVER_NAME" ] || { c_red "  × 服务器名称为空"; err=1; }
    if [ -z "$IFACE" ] || [ ! -d "/sys/class/net/$IFACE" ]; then
        c_red "  × 监控网口 [$IFACE] 不存在"; err=1
    fi
    if ! [[ "$RESET_DAY" =~ ^[0-9]+$ ]] || [ "$RESET_DAY" -lt 1 ] || [ "$RESET_DAY" -gt 31 ]; then
        c_red "  × 账单重置日 [$RESET_DAY] 非法（应为 1-31）"; err=1
    fi
    case "$STAT_TYPE" in 1|2|3) ;; *) c_red "  × 流量统计类型 [$STAT_TYPE] 非法（应为 1/2/3）"; err=1;; esac
    [ -n "$TG_TOKEN" ] || { c_red "  × Telegram Bot Token 为空"; err=1; }
    [ -n "$TG_CHATID" ] || { c_red "  × Telegram Chat ID 为空"; err=1; }
    if ! awk -v l="$LIMIT_GB" 'BEGIN{exit !(l+0>0)}' 2>/dev/null; then
        c_red "  × 流量总额 [$LIMIT_GB] 非法（应为大于 0 的数字，单位 GB）"; err=1
    fi
    [ "$err" -eq 0 ] || die "配置校验失败，请重新执行【安装部署/修改配置】"
}

#===============================================================================
# vnStat 相关
#===============================================================================
# 计算当前账单周期起始日期（UTC）
cycle_start_date() {
    local y m d rd first cand fm
    y=$(date -u +%Y); m=$(date -u +%m); d=$((10#$(date -u +%d)))
    rd=$((10#$RESET_DAY))
    if [ "$d" -ge "$rd" ]; then
        first="${y}-${m}-01"
    else
        first=$(date -u -d "${y}-${m}-01 -1 month" +%Y-%m-01)
    fi
    cand=$(date -u -d "${first} +$((rd-1)) days" +%Y-%m-%d)
    fm=$(echo "$first" | cut -c6-7)
    # 重置日超出当月天数（如 31 日遇到 2 月），取当月最后一天
    if [ "$(date -u -d "$cand" +%m)" != "$fm" ]; then
        cand=$(date -u -d "${first} +1 month -1 day" +%Y-%m-%d)
    fi
    echo "$cand"
}

# 获取当前账单周期已用流量（字节，UTC 基准）
get_cycle_bytes() {
    local start startnum field json
    start=$(cycle_start_date)
    startnum=${start//-/}
    case "$STAT_TYPE" in
        1) field="(.rx + .tx)" ;;   # 总流量
        2) field=".tx" ;;           # 上传
        3) field=".rx" ;;           # 下载
    esac
    json=$(vnstat --json d -i "$IFACE" 2>/dev/null)
    [ -n "$json" ] || { echo 0; return; }
    echo "$json" | jq "[ .interface[0].day[]
        | select((.date.year*10000 + .date.month*100 + .date.day) >= $startnum)
        | $field ] | add // 0" 2>/dev/null || echo 0
}

# 计算已用百分比（保留 1 位小数）
calc_percent() {
    local used_bytes limit_bytes
    used_bytes=$1
    limit_bytes=$(awk -v l="$LIMIT_GB" 'BEGIN{printf "%.0f", l*1024*1024*1024}')
    awk -v u="$used_bytes" -v l="$limit_bytes" 'BEGIN{ if (l<=0) {print 0} else {printf "%.1f", u/l*100} }'
}

stat_type_name() {
    case "$STAT_TYPE" in
        1) echo "总流量(上传+下载)" ;;
        2) echo "上传流量" ;;
        3) echo "下载流量" ;;
    esac
}

#===============================================================================
# Telegram 推送
#===============================================================================
tg_send() {
    # $1=消息文本  返回 0=成功 1=失败（内部已重试）
    local text="$1" i resp
    for i in 1 2 3; do
        resp=$(curl -sS -m 20 -X POST \
            "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHATID}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=HTML" 2>&1)
        if echo "$resp" | grep -q '"ok":true'; then
            return 0
        fi
        log "WARN" "Telegram 推送第 ${i}/3 次失败: $(echo "$resp" | head -c 200)"
        [ "$i" -lt 3 ] && sleep 2
    done
    return 1
}

# 组装日报消息
build_report() {
    local used_bytes percent start now_bj now_utc
    used_bytes=$(get_cycle_bytes)
    percent=$(calc_percent "$used_bytes")
    start=$(cycle_start_date)
    now_bj=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')
    now_utc=$(date -u '+%Y-%m-%d %H:%M')
    cat <<EOF
📊 <b>Traffic Daily Report</b>
━━━━━━━━━━━━━━━
🖥 服务器: <b>${SERVER_NAME}</b>
📡 网口: ${IFACE} | 类型: $(stat_type_name)
📈 已用: <b>$(human_bytes "$used_bytes")</b> / ${LIMIT_GB} GB (<b>${percent}%</b>)
🔄 账单周期: ${start} 起 (UTC)
⏰ 时间: ${now_bj} (北京时间) / ${now_utc} (UTC)
EOF
}

cmd_daily() {
    load_config || { log "ERROR" "每日推送失败：配置文件不存在"; exit 1; }
    validate_config
    local msg
    msg=$(build_report)
    if tg_send "$msg"; then
        log "OK" "每日流量日报推送成功"
    else
        log "ERROR" "每日流量日报推送失败（已重试 3 次）"
        exit 1
    fi
}

cmd_test_push() {
    load_config || die "尚未安装配置，请先执行【1. 安装部署/修改配置】"
    validate_config
    echo "正在发送测试日报..."
    local msg
    msg="$(build_report)
✅ <i>这是一条测试消息</i>"
    if tg_send "$msg"; then
        c_green "✔ 测试推送成功，请到 Telegram 查收"
        log "OK" "测试日报推送成功"
    else
        c_red "✘ 测试推送失败（已重试 3 次），请检查 Token / Chat ID / 网络连通性"
        log "ERROR" "测试日报推送失败"
    fi
}

#===============================================================================
# 每分钟阈值检查
#===============================================================================
cmd_check() {
    load_config || exit 0
    validate_config
    local used_bytes percent start
    used_bytes=$(get_cycle_bytes)
    percent=$(calc_percent "$used_bytes")
    start=$(cycle_start_date)

    # ---- 95% 关机报警 ----
    if awk -v p="$percent" 'BEGIN{exit !(p >= 95)}'; then
        # 防重复：同一账单周期只执行一次关机流程
        if [ -f "$LOCK_SHUTDOWN" ] && grep -q "$start" "$LOCK_SHUTDOWN" 2>/dev/null; then
            log "WARN" "阈值 ${percent}% ≥95%，但本周期关机流程已触发过，跳过"
            exit 0
        fi
        log "WARN" "流量达到关机阈值: ${percent}% ($(human_bytes "$used_bytes")/${LIMIT_GB}GB)"
        echo "$start" > "$LOCK_SHUTDOWN"

        local msg="🚨 <b>关机警报</b>
━━━━━━━━━━━━━━━
🖥 服务器: <b>${SERVER_NAME}</b>
📈 已用: <b>$(human_bytes "$used_bytes")</b> / ${LIMIT_GB} GB (<b>${percent}%</b>)
⚠️ 已达 95% 关机阈值，服务器将在 <b>1 分钟</b> 后自动关机！
⏰ $(date -u '+%Y-%m-%d %H:%M') UTC"
        if tg_send "$msg"; then
            log "OK" "关机报警推送成功"
        else
            log "ERROR" "关机报警推送失败（已重试 3 次），按预设流程继续执行关机"
        fi

        # 延迟 1 分钟
        sleep 60

        # 关机前二次确认：防止账单周期重置导致误关机
        used_bytes=$(get_cycle_bytes)
        percent=$(calc_percent "$used_bytes")
        local new_start; new_start=$(cycle_start_date)
        if awk -v p="$percent" 'BEGIN{exit !(p >= 95)}'; then
            log "WARN" "二次确认通过（${percent}% ≥95%，周期 ${new_start}），执行关机命令"
            tg_send "⛔ 服务器 <b>${SERVER_NAME}</b> 阈值二次确认 ${percent}% ≥95%，正在执行关机... $(date -u '+%Y-%m-%d %H:%M') UTC" >/dev/null 2>&1
            sync
            shutdown -h now "traffic-monitor: 流量达到 95% 阈值，自动关机"
            exit 0
        else
            log "INFO" "二次确认未通过（当前 ${percent}%，周期 ${new_start}），取消关机（可能已进入新账单周期）"
            rm -f "$LOCK_SHUTDOWN"
        fi
        exit 0
    fi

    # ---- 90% 预警（每周期仅首次触发） ----
    if awk -v p="$percent" 'BEGIN{exit !(p >= 90)}'; then
        load_state
        if [ "$WARNED_CYCLE" != "$start" ]; then
            log "WARN" "流量达到预警阈值: ${percent}%，周期 ${start}，首次触发推送"
            local msg="⚠️ <b>流量预警</b>
━━━━━━━━━━━━━━━
🖥 服务器: <b>${SERVER_NAME}</b>
📈 已用: <b>$(human_bytes "$used_bytes")</b> / ${LIMIT_GB} GB (<b>${percent}%</b>)
🔔 已达 90% 预警阈值，请注意流量使用（95% 将自动关机）
⏰ $(date -u '+%Y-%m-%d %H:%M') UTC"
            if tg_send "$msg"; then
                save_state_var "WARNED_CYCLE" "$start"
                log "OK" "90% 预警推送成功（本周期不再重复推送）"
            else
                log "ERROR" "90% 预警推送失败（已重试 3 次），下一分钟将再次尝试"
            fi
        fi
    fi
    exit 0
}

#===============================================================================
# 依赖安装 / 时区 / vnStat 配置
#===============================================================================
install_deps() {
    echo "→ 检查并安装依赖软件 (vnstat curl jq cron) ..."
    log "INFO" "开始安装依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || c_yellow "  ! apt-get update 失败，尝试继续安装"
    local pkgs="vnstat curl jq cron ca-certificates"
    if ! apt-get install -y $pkgs >/dev/null 2>&1; then
        die "依赖安装失败，请检查网络或 apt 源后重试"
    fi
    # 逐个确认
    local p
    for p in vnstat curl jq crontab; do
        command -v "$p" >/dev/null 2>&1 || die "依赖 [$p] 安装后仍不可用"
    done
    systemctl enable vnstat >/dev/null 2>&1
    systemctl start vnstat >/dev/null 2>&1
    systemctl enable cron >/dev/null 2>&1
    systemctl start cron >/dev/null 2>&1
    c_green "✔ 依赖安装完成: $(vnstat --version 2>/dev/null | head -n1)"
    log "OK" "依赖安装完成"
}

setup_timezone() {
    echo "→ 检查系统时区 ..."
    local tz
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
    if [ "$tz" = "Asia/Shanghai" ]; then
        c_green "✔ 当前时区已是 Asia/Shanghai，跳过设置"
        log "INFO" "时区已是 Asia/Shanghai，跳过"
        return
    fi
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || {
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
    }
    c_green "✔ 系统时区已设置为 Asia/Shanghai（原时区: ${tz:-未知}）"
    log "INFO" "系统时区由 [$tz] 改为 Asia/Shanghai"
}

setup_vnstat_utc() {
    echo "→ 配置 vnStat 使用 UTC0 时间基准 (UseUTC 1) ..."
    [ -f "$VNSTAT_CONF" ] || vnstat -u >/dev/null 2>&1
    if [ ! -f "$VNSTAT_CONF" ]; then
        # 部分版本配置在别处或不存在，直接创建最小配置
        echo "UseUTC 1" > "$VNSTAT_CONF"
    elif grep -qE '^[#[:space:]]*UseUTC' "$VNSTAT_CONF"; then
        sed -i -E 's/^[#[:space:]]*UseUTC.*/UseUTC 1/' "$VNSTAT_CONF"
    else
        echo "UseUTC 1" >> "$VNSTAT_CONF"
    fi
    grep -qE '^UseUTC 1' "$VNSTAT_CONF" || die "vnStat UseUTC 配置写入失败"
    systemctl restart vnstat >/dev/null 2>&1
    c_green "✔ vnStat UseUTC=1 已生效，流量统计与重置日均以 UTC0 为基准"
    log "INFO" "vnStat UseUTC=1 配置完成"
}

#===============================================================================
# 交互式配置（首次=安装配置，再次=读取旧配置更新）
#===============================================================================
prompt_input() {
    # $1=提示语 $2=默认值  结果写入 REPLY_VAL
    local tip="$1" def="$2" val
    if [ -n "$def" ]; then
        read -rp "$(c_blue "$tip [当前: $def，回车保留]: ")" val
        REPLY_VAL="${val:-$def}"
    else
        while true; do
            read -rp "$(c_blue "$tip: ")" val
            [ -n "$val" ] && break
            c_yellow "  ! 不能为空，请重新输入"
        done
        REPLY_VAL="$val"
    fi
}

choose_iface() {
    local ifaces=() i idx=0 n
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        [ "$n" = "lo" ] && continue
        ifaces+=("$n")
    done
    [ ${#ifaces[@]} -gt 0 ] || die "未检测到任何可用网卡接口"
    echo "检测到以下网卡接口:"
    for i in "${!ifaces[@]}"; do
        local ip; ip=$(ip -4 addr show "${ifaces[$i]}" 2>/dev/null | grep -oP '(?<=inet )[\d.]+' | head -n1)
        echo "  $((i+1))) ${ifaces[$i]} ${ip:+(IP: $ip)}"
    done
    if [ ${#ifaces[@]} -eq 1 ]; then
        read -rp "$(c_blue "仅检测到一个网口，使用 [${ifaces[0]}]？(Y/n): ")" REPLY_VAL
        case "$REPLY_VAL" in n|N) ;; *) REPLY_VAL="${ifaces[0]}"; return;; esac
    fi
    while true; do
        read -rp "$(c_blue "请选择监控网口编号 [默认: ${IFACE:-1}]: ")" idx
        idx="${idx:-1}"
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le ${#ifaces[@]} ]; then
            REPLY_VAL="${ifaces[$((idx-1))]}"
            return
        fi
        # 也允许直接输入接口名
        for n in "${ifaces[@]}"; do
            [ "$idx" = "$n" ] && { REPLY_VAL="$n"; return; }
        done
        c_yellow "  ! 无效选择，请输入 1-${#ifaces[@]} 的编号或接口名"
    done
}

interactive_config() {
    local is_update=0
    if load_config; then
        is_update=1
        c_yellow "检测到已有配置，将以【修改配置】模式更新（回车保留原值）"
        log "INFO" "以修改配置模式进入交互设置"
    else
        c_green "首次安装，进入交互配置"
        log "INFO" "首次安装，进入交互配置"
    fi
    echo

    prompt_input "① 监控服务器名称" "$SERVER_NAME";           SERVER_NAME="$REPLY_VAL"
    echo
    echo "② 监控网口设置:"
    choose_iface;                                              IFACE="$REPLY_VAL"
    echo
    prompt_input "③ 每月账单流量重置日 (1-31, UTC 基准)" "$RESET_DAY"
    if ! [[ "$REPLY_VAL" =~ ^[0-9]+$ ]] || [ "$REPLY_VAL" -lt 1 ] || [ "$REPLY_VAL" -gt 31 ]; then
        die "重置日非法：$REPLY_VAL"
    fi
    RESET_DAY=$((10#$REPLY_VAL))
    echo
    echo "④ 流量统计类型: 1)总流量(上传+下载)  2)上传流量  3)下载流量"
    prompt_input "   请选择" "${STAT_TYPE:-1}"
    case "$REPLY_VAL" in 1|2|3) STAT_TYPE="$REPLY_VAL" ;; *) die "统计类型非法：$REPLY_VAL" ;; esac
    echo
    prompt_input "⑤ Telegram Bot Token" "$TG_TOKEN";           TG_TOKEN="$REPLY_VAL"
    prompt_input "⑥ Telegram Chat ID" "$TG_CHATID";            TG_CHATID="$REPLY_VAL"
    echo
    prompt_input "⑦ 账单周期总流量 (GB, 支持小数)" "$LIMIT_GB"
    if ! awk -v l="$REPLY_VAL" 'BEGIN{exit !(l+0>0)}' 2>/dev/null; then
        die "流量总额非法：$REPLY_VAL"
    fi
    LIMIT_GB="$REPLY_VAL"
    echo

    c_yellow "配置预览:"
    echo "  服务器名称 : $SERVER_NAME"
    echo "  监控网口   : $IFACE"
    echo "  账单重置日 : 每月 ${RESET_DAY} 日 (UTC0)"
    echo "  统计类型   : $(stat_type_name)"
    echo "  流量总额   : ${LIMIT_GB} GB"
    echo "  TG Token   : ${TG_TOKEN:0:12}****"
    echo "  TG Chat ID : $TG_CHATID"
    read -rp "$(c_blue "确认保存配置？(Y/n): ")" REPLY_VAL
    case "$REPLY_VAL" in n|N) die "用户取消保存";; esac

    mkdir -p "$BASE_DIR"
    cat > "$CONF_FILE" <<EOF
# traffic-monitor 配置文件 ($VERSION)
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
SERVER_NAME="$SERVER_NAME"
IFACE="$IFACE"
RESET_DAY=$RESET_DAY
STAT_TYPE=$STAT_TYPE
TG_TOKEN="$TG_TOKEN"
TG_CHATID="$TG_CHATID"
LIMIT_GB="$LIMIT_GB"
EOF
    chmod 600 "$CONF_FILE"

    if [ "$is_update" -eq 1 ]; then
        # 更新配置：清除旧的预警/关机状态，避免沿用旧周期标记
        rm -f "$STATE_FILE" "$LOCK_SHUTDOWN"
        log "OK" "配置文件已更新: 名称=$SERVER_NAME 网口=$IFACE 重置日=$RESET_DAY 类型=$STAT_TYPE 总额=${LIMIT_GB}GB"
        c_green "✔ 配置文件已更新: $CONF_FILE"
    else
        log "OK" "配置文件已创建: 名称=$SERVER_NAME 网口=$IFACE 重置日=$RESET_DAY 类型=$STAT_TYPE 总额=${LIMIT_GB}GB"
        c_green "✔ 配置文件已创建: $CONF_FILE"
    fi

    # 将监控网口加入 vnStat 数据库（已存在则忽略报错）
    vnstat --add -i "$IFACE" >/dev/null 2>&1
    systemctl restart vnstat >/dev/null 2>&1
}

install_cron() {
    echo "→ 创建/更新定时任务 ..."
    local tmp; tmp=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# traffic-monitor" > "$tmp"
    # 每日日报：服务器时区已设为 Asia/Shanghai，即北京时间 08:00
    echo "0 8 * * * $SCRIPT_PATH daily >> $LOG_FILE 2>&1 # traffic-monitor" >> "$tmp"
    # 每分钟阈值检查
    echo "* * * * * $SCRIPT_PATH check >> $LOG_FILE 2>&1 # traffic-monitor" >> "$tmp"
    crontab "$tmp" || { rm -f "$tmp"; die "crontab 写入失败"; }
    rm -f "$tmp"
    systemctl restart cron >/dev/null 2>&1 || service cron restart >/dev/null 2>&1
    c_green "✔ 定时任务已重载:"
    crontab -l | grep "# traffic-monitor" | sed 's/^/    /'
    log "OK" "定时任务已创建/更新并重载 cron"
}

cmd_install() {
    check_root
    echo "==============================================="
    echo "  安装部署 / 修改配置  ($VERSION)"
    echo "==============================================="
    install_deps
    setup_timezone
    setup_vnstat_utc
    interactive_config
    install_cron
    echo
    c_green "✔ 全部完成！"
    echo "  - 每日日报: 北京时间 08:00 自动推送（流量统计以 UTC0 账单周期为准）"
    echo "  - 阈值检查: 每分钟一次（90% 首次预警 / 95% 报警并延迟 1 分钟关机）"
    echo "  - 日志文件: $LOG_FILE"
    echo
    read -rp "$(c_blue "是否立即发送一条测试日报？(Y/n): ")" REPLY_VAL
    case "$REPLY_VAL" in n|N) ;; *) cmd_test_push ;; esac
}

#===============================================================================
# 查看当前流量数据
#===============================================================================
cmd_show() {
    load_config || die "尚未安装配置，请先执行【1. 安装部署/修改配置】"
    validate_config
    local used_bytes percent start
    used_bytes=$(get_cycle_bytes)
    percent=$(calc_percent "$used_bytes")
    start=$(cycle_start_date)
    echo "==============================================="
    echo "  当前流量数据 — ${SERVER_NAME}"
    echo "==============================================="
    echo "  监控网口   : $IFACE"
    echo "  统计类型   : $(stat_type_name)"
    echo "  账单周期   : ${start} 起 (UTC0) → 当前 $(date -u '+%Y-%m-%d %H:%M') UTC"
    echo "  已用流量   : $(human_bytes "$used_bytes") / ${LIMIT_GB} GB (${percent}%)"
    echo "  预警阈值   : 90% (首次触发推送) / 95% (报警并关机)"
    echo "-----------------------------------------------"
    echo "  vnStat 实时概况:"
    vnstat -i "$IFACE" 2>/dev/null | sed 's/^/    /' || c_yellow "  (vnStat 暂无该网口数据，等待守护进程采集，约需几分钟)"
    echo "==============================================="
}

#===============================================================================
# 从 GitHub 更新脚本（强制刷新，绕过 CDN 缓存）
#===============================================================================
cmd_update() {
    check_root
    echo "→ 正在从 GitHub 拉取最新脚本（强制刷新，绕过 CDN 缓存）..."
    local tmp url
    tmp=$(mktemp)
    url="${UPDATE_URL}?t=$(date +%s)$RANDOM"
    if ! curl -fsSL -m 60 \
            -H "Cache-Control: no-cache, no-store, must-revalidate" \
            -H "Pragma: no-cache" \
            "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "下载失败，请检查网络或仓库地址: $UPDATE_URL"
    fi
    # 基本校验：非空、含 shebang、bash 语法检查
    [ -s "$tmp" ] || { rm -f "$tmp"; die "下载内容为空"; }
    head -n1 "$tmp" | grep -q '^#!' || { rm -f "$tmp"; die "下载内容不是有效脚本（缺少 shebang）"; }
    bash -n "$tmp" || { rm -f "$tmp"; die "新脚本语法校验未通过，已放弃更新"; }
    cp -f "$tmp" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    rm -f "$tmp"
    c_green "✔ 脚本已更新: $SCRIPT_PATH"
    log "OK" "脚本已从 GitHub 更新至最新版本"
    local newver; newver=$(grep -m1 '^VERSION=' "$SCRIPT_PATH" | cut -d'"' -f2)
    echo "  当前版本: ${newver:-未知}"
    echo "  提示: 如需应用新版本功能，可重新执行【1. 安装部署/修改配置】"
}

#===============================================================================
# 卸载
#===============================================================================
cmd_uninstall() {
    check_root
    echo "==============================================="
    echo "  卸载 traffic-monitor"
    echo "==============================================="
    c_yellow "将执行以下清理操作:"
    echo "  1) 删除相关 cron 定时任务并重载"
    echo "  2) 删除配置/状态/日志目录: $BASE_DIR"
    echo "  3) 删除脚本文件: $SCRIPT_PATH"
    echo "  （vnStat 本体及其流量数据库默认保留，如需卸载可自行 apt purge vnstat）"
    read -rp "$(c_blue "确认卸载？(y/N): ")" REPLY_VAL
    case "$REPLY_VAL" in y|Y) ;; *) echo "已取消卸载"; return;; esac

    log "WARN" "开始执行卸载"
    # 1) 清理 cron
    local tmp; tmp=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# traffic-monitor" > "$tmp"
    if [ -s "$tmp" ]; then crontab "$tmp"; else crontab -r 2>/dev/null; fi
    rm -f "$tmp"
    systemctl restart cron >/dev/null 2>&1 || service cron restart >/dev/null 2>&1
    c_green "✔ 定时任务已清理"
    # 2) 清理配置目录（先备份日志提示）
    [ -f "$LOG_FILE" ] && cp -f "$LOG_FILE" /tmp/traffic-monitor-last.log 2>/dev/null
    rm -rf "$BASE_DIR"
    c_green "✔ 配置/状态/日志已删除（最后日志备份: /tmp/traffic-monitor-last.log）"
    # 3) 删除脚本自身
    rm -f "$SCRIPT_PATH"
    c_green "✔ 脚本文件已删除: $SCRIPT_PATH"
    echo
    c_green "卸载完成！"
    exit 0
}

#===============================================================================
# 主菜单
#===============================================================================
print_banner() {
    clear 2>/dev/null
    echo "==============================================="
    echo "      vnStat 流量监控助手  ${VERSION}"
    echo "      Debian 13 / vnStat 2.x"
    echo "==============================================="
    echo "  1. 安装部署/修改配置"
    echo "  2. 测试发送每日流量推送"
    echo "  3. 查看当前流量数据"
    echo "  4. 从 GitHub 更新脚本"
    echo "  5. 卸载监控程序"
    echo "  0. 退出"
    echo "==============================================="
}

menu() {
    while true; do
        print_banner
        read -rp "$(c_blue '请输入选项: ')" choice
        case "$choice" in
            1) cmd_install ;;
            2) cmd_test_push ;;
            3) cmd_show ;;
            4) cmd_update ;;
            5) cmd_uninstall ;;
            0) echo "再见！"; exit 0 ;;
            *) c_yellow "无效选项，请重新输入";;
        esac
        [ "$choice" != "0" ] && read -rp "$(c_blue '按回车键返回主菜单...')" _
    done
}

#===============================================================================
# 入口
#===============================================================================
main() {
    case "${1:-}" in
        daily)     cmd_daily ;;       # cron: 每日日报
        check)     cmd_check ;;       # cron: 每分钟阈值检查
        config)    cmd_install ;;
        test)      cmd_test_push ;;
        show)      cmd_show ;;
        update)    cmd_update ;;
        uninstall) cmd_uninstall ;;
        version)   echo "traffic-monitor $VERSION" ;;
        *)         menu ;;
    esac
}

main "$@"
