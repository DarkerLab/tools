#!/usr/bin/env bash
#===============================================================================
# 脚本名称 : traffic-monitor.sh
# 版    本 : v1.6.4
# 适用系统 : Debian 13 (兼容 Debian 11/12、Ubuntu 20.04+)，依赖 vnStat 2.x
# 更新记录 :
#   v1.6.4 [优化] 主菜单改为单排显示，彻底解决不同终端下中英文混杂无法对齐的问题。
#   v1.6.3 [优化] 互换菜单 5 和 7 的位置；验证自动重载功能。
#   v1.6.2 [优化] 更新 URL 改为完整 refs/heads 路径；从菜单更新成功后自动重载脚本。
#   v1.6.1 [UI] 去除复杂的 Unicode 画框，改用清爽的 ASCII 分隔线。
#   v1.6.0 [UI] 初步 UI 美化。
#   v1.5.1 [修复] 新库检测带上具体日期；强制刷新版本。
#   v1.5   [修复] 管道拦截、关机降级、自动更新原子替换、精简通知格式。
#   v1.4   全面代码审查修复。
#   v1.3   全面重写，增加环境自检。
#   v1.2   修复 vnStat 2.x JSON 解析。
#   v1.1   初始版本。
#===============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C

VERSION="v1.6.4"
SCRIPT_PATH="$(readlink -f "$0")"
BASE_DIR="/etc/traffic-monitor"
CONF_FILE="${BASE_DIR}/config.conf"
STATE_FILE="${BASE_DIR}/state.conf"
LOG_FILE="${BASE_DIR}/monitor.log"
LOCK_SHUTDOWN="${BASE_DIR}/shutdown.lock"
# 使用 GitHub 完整 refs/heads 路径
UPDATE_URL="https://raw.githubusercontent.com/DarkerLab/tools/refs/heads/main/shell/traffic-monitor.sh"
VNSTAT_CONF="/etc/vnstat.conf"
VNSTAT_DB_DIR="/var/lib/vnstat"
MAX_LOG_SIZE=$((5*1024*1024))

#===============================================================================
# 拦截在线管道执行
#===============================================================================
if [[ "$SCRIPT_PATH" =~ ^/proc/.*/fd/ ]] || [[ "$SCRIPT_PATH" =~ ^/dev/fd/ ]] || [ "$0" = "bash" ] || [ "$0" = "sh" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "\033[1;31m[错误] 检测到在线临时运行。请使用 root 权限重新执行：\033[0m"
        echo -e "\033[1;31m       sudo bash <(curl -sL $UPDATE_URL)\033[0m"
        exit 1
    fi

    _real_target="/usr/local/bin/traffic-monitor.sh"
    if [ -f "$_real_target" ] && [ "$_real_target" != "$SCRIPT_PATH" ]; then
        _real_target="/root/traffic-monitor.sh"
    fi

    if [ -r "$0" ] && [ "$0" != "bash" ] && [ "$0" != "sh" ]; then
        echo -e "\033[1;33m[提示] 检测到当前通过在线管道运行脚本，正在固化到本地...\033[0m"
        if cat "$0" > "$_real_target" 2>/dev/null; then
            chmod +x "$_real_target"
            echo -e "\033[1;32m✔ 保存成功，正在切换为本地文件重新执行...\033[0m"
            sleep 1
            exec "$_real_target" "$@"
        fi
    fi
    echo -e "\033[1;31m[错误] 脚本在内存中执行，无法固化到本地。请手动下载运行:\033[0m"
    echo -e "\033[1;31m       wget -O /root/traffic-monitor.sh $UPDATE_URL && bash /root/traffic-monitor.sh\033[0m"
    exit 1
fi

#===============================================================================
# 基础工具与颜色
#===============================================================================
c_red()    { echo -e "\033[1;31m$*\033[0m"; }
c_green()  { echo -e "\033[1;32m$*\033[0m"; }
c_yellow() { echo -e "\033[1;33m$*\033[0m"; }
c_cyan()   { echo -e "\033[1;36m$*\033[0m"; }
c_gray()   { echo -e "\033[90m$*\033[0m"; }

log() {
    mkdir -p "$BASE_DIR" 2>/dev/null
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "[${ts}] [$1] $2" >> "$LOG_FILE" 2>/dev/null
    if [ -f "$LOG_FILE" ]; then
        local sz; sz=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$sz" -gt "$MAX_LOG_SIZE" ]; then
            tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] 日志超过上限，已自动截断" >> "$LOG_FILE"
        fi
    fi
}

die() { echo -e "\n\033[1;31m[错误] $1\033[0m"; log "ERROR" "$1"; exit 1; }

check_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 权限运行本脚本（sudo bash $0）"
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB PB", u, " ");
        i = 1;
        while (b >= 1000 && i < 6) { b /= 1000; i++ }
        printf "%.2f %s", b, u[i];
    }'
}

html_escape() {
    printf '%s' "${1-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

restart_cron_service() {
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null \
        || service cron restart 2>/dev/null || service crond restart 2>/dev/null \
        || echo -e "\033[1;33m[警告] 无法自动重载 cron，请确认 cron 服务已运行\033[0m"
}

#===============================================================================
# 配置读写与校验
#===============================================================================
load_config() {
    [ -f "$CONF_FILE" ] || return 1
    . "$CONF_FILE" || return 1
    return 0
}

load_state() {
    WARNED_CYCLE=""
    if [ -r "$STATE_FILE" ]; then
        . "$STATE_FILE" 2>/dev/null || WARNED_CYCLE=""
    fi
    return 0
}

save_state_var() {
    mkdir -p "$BASE_DIR"
    if [ -f "$STATE_FILE" ] && grep -q "^$1=" "$STATE_FILE"; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$STATE_FILE"
    else
        echo "$1=\"$2\"" >> "$STATE_FILE"
    fi
}

validate_config() {
    local err=0
    [ -n "$SERVER_NAME" ] || { c_red "  ✘ 服务器名称为空"; err=1; }
    if [ -z "$IFACE" ] || [ ! -d "/sys/class/net/$IFACE" ]; then
        c_red "  ✘ 监控网口 [$IFACE] 不存在"; err=1
    fi
    if ! [[ "$RESET_DAY" =~ ^[0-9]+$ ]] || [ "$RESET_DAY" -lt 1 ] || [ "$RESET_DAY" -gt 31 ]; then
        c_red "  ✘ 账单重置日 [$RESET_DAY] 非法（应为 1-31）"; err=1
    fi
    case "${STAT_TYPE:-}" in 1|2|3) ;; *) c_red "  ✘ 流量统计类型 [$STAT_TYPE] 非法"; err=1;; esac
    [ -n "$TG_TOKEN" ]  || { c_red "  ✘ Telegram Bot Token 为空";  err=1; }
    [ -n "$TG_CHATID" ] || { c_red "  ✘ Telegram Chat ID 为空";    err=1; }
    if ! [[ "${LIMIT_GB:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] \
            || ! awk -v l="$LIMIT_GB" 'BEGIN{exit !(l+0>0)}' 2>/dev/null; then
        c_red "  ✘ 流量总额 [$LIMIT_GB] 非法（应为大于 0 的数字）"; err=1
    fi
    [ "$err" -eq 0 ] || die "配置校验失败，请重新执行【1. 安装部署/修改配置】"
}

#===============================================================================
# vnStat 数据采集
#===============================================================================
PARSE_ERROR=0

cycle_start_date() {
    local rd=$((10#$RESET_DAY)) y m d dim eff pfirst pdim peff
    y=$(date -u +%Y); m=$(date -u +%m); d=$((10#$(date -u +%d)))
    dim=$(date -u -d "${y}-${m}-01 +1 month -1 day" +%d); dim=$((10#$dim))
    eff=$rd; [ "$eff" -gt "$dim" ] && eff=$dim
    if [ "$d" -ge "$eff" ]; then
        date -u -d "${y}-${m}-01 +$((eff-1)) days" +%Y-%m-%d
    else
        pfirst=$(date -u -d "${y}-${m}-01 -1 month" +%Y-%m-01)
        pdim=$(date -u -d "${pfirst} +1 month -1 day" +%d); pdim=$((10#$pdim))
        peff=$rd; [ "$peff" -gt "$pdim" ] && peff=$pdim
        date -u -d "${pfirst} +$((peff-1)) days" +%Y-%m-%d
    fi
}

vnstat_day_json() {
    vnstat --json d -i "$IFACE" 2>/dev/null
}

jq_day_sum_filter() {
    local field=$1 startnum=${2:-} cond=""
    [ -n "$startnum" ] && cond='| select((.date.year*10000 + .date.month*100 + .date.day) >= ($sn | tonumber))'
    echo '[ .. | objects
          | select(has("day")) | select(.day | type == "array")
          | .day[]
          | select(has("date") and has("rx") and has("tx"))
          '"$cond"'
          | '"$field"' ] | add // 0'
}

get_cycle_bytes() {
    PARSE_ERROR=0
    local start startnum field json sum
    start=$(cycle_start_date)
    startnum=${start//-/}
    case "${STAT_TYPE:-1}" in
        1) field='(.rx + .tx)' ;;
        2) field='.tx' ;;
        3) field='.rx' ;;
    esac
    json=$(vnstat_day_json)
    if [ -z "$json" ]; then
        PARSE_ERROR=1
        log "ERROR" "vnStat 无 JSON 输出"
        echo 0; return 1
    fi
    if ! echo "$json" | jq -e 'has("interface") or has("interfaces") or has("traffic")' >/dev/null 2>&1; then
        PARSE_ERROR=1
        log "ERROR" "vnStat JSON 结构无法识别"
        echo 0; return 1
    fi
    sum=$(echo "$json" | jq -r --arg sn "$startnum" "$(jq_day_sum_filter "$field" "$startnum")" 2>/dev/null)
    if ! [[ "$sum" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        PARSE_ERROR=1
        log "ERROR" "vnStat JSON 解析失败，原始值: [$sum]"
        echo 0; return 1
    fi
    printf "%.0f" "$sum"
}

day_coverage_earliest() {
    local json earliest
    json=$(vnstat_day_json)
    [ -n "$json" ] || { echo "unknown"; return; }
    earliest=$(echo "$json" | jq -r '[ .. | objects
        | select(has("day")) | select(.day | type == "array")
        | .day[] | select(has("date"))
        | (.date.year*10000 + .date.month*100 + .date.day) ] | min // "none"' 2>/dev/null)
    case "$earliest" in
        ''|none|null|unknown) echo "unknown" ;;
        *[!0-9]*)             echo "unknown" ;;
        *)                    echo "$earliest" ;;
    esac
}

check_day_coverage() {
    local startnum earliest todaynum yestnum
    startnum=${1//-/}
    earliest=$(day_coverage_earliest)
    [ "$earliest" = "unknown" ] && { echo "unknown"; return; }
    if [ "$earliest" -gt "$startnum" ]; then
        todaynum=$(date -u +%Y%m%d)
        yestnum=$(date -u -d "yesterday" +%Y%m%d 2>/dev/null || echo "")
        if [ "$earliest" = "$todaynum" ] \
                || { [ -n "$yestnum" ] && [ "$earliest" = "$yestnum" ]; }; then
            echo "newdb:${earliest}"
        else
            echo "missing:${earliest}"
        fi
    else
        echo "ok"
    fi
}

calc_percent() {
    local used_bytes=$1 limit_bytes
    limit_bytes=$(awk -v l="$LIMIT_GB" 'BEGIN{printf "%.0f", l*1000*1000*1000}')
    awk -v u="$used_bytes" -v l="$limit_bytes" \
        'BEGIN{ if (l<=0) print 0; else printf "%.1f", u/l*100 }'
}

stat_type_name() {
    case "${STAT_TYPE:-1}" in
        1) echo "总流量(上传+下载)" ;;
        2) echo "上传流量" ;;
        3) echo "下载流量" ;;
    esac
}

#===============================================================================
# Telegram 推送
#===============================================================================
tg_send() {
    local text=$1 i resp desc
    for i in 1 2 3; do
        resp=$(curl -sS -m 20 -X POST \
            "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHATID}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=HTML" 2>&1)
        if echo "$resp" | grep -q '"ok":true'; then
            return 0
        fi
        desc=$(echo "$resp" | jq -r '.description // empty' 2>/dev/null)
        log "WARN" "Telegram 推送第 ${i}/3 次失败: ${desc:-$(echo "$resp" | head -c 200)}"
        [ "$i" -lt 3 ] && sleep 2
    done
    return 1
}

build_report() {
    local used_bytes percent now_utc warn="" cover cov_earliest
    PARSE_ERROR=0
    used_bytes=$(get_cycle_bytes) || PARSE_ERROR=1
    if [ "$PARSE_ERROR" -eq 1 ]; then
        warn="\n⚠️ 数据解析异常，请登录检查"
    else
        cover=$(check_day_coverage "$(cycle_start_date)")
        case "$cover" in
            missing:*) 
                cov_earliest=${cover#missing:}
                warn="\nℹ️ 历史明细缺失(最早 ${cov_earliest:4:2}-${cov_earliest:6:2})，统计可能偏低"
                ;;
            newdb:*)   
                cov_earliest=${cover#newdb:}
                warn="\nℹ️ 新建库，数据自 ${cov_earliest:4:2}-${cov_earliest:6:2} 起"
                ;;
        esac
    fi
    percent=$(calc_percent "${used_bytes:-0}")
    now_utc=$(date -u '+%Y-%m-%d %H:%M')

    echo "📊 [$(html_escape "$SERVER_NAME")]每日流量日报"
    echo "━━━━━━━━━━━━━━━"
    echo "- 周期用量: $(human_bytes "${used_bytes:-0}") / $(html_escape "$LIMIT_GB") GB (${percent}%)"
    echo "- 统计时间: ${now_utc} (UTC)${warn}"
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
    check_root
    load_config || die "尚未安装配置，请先执行【1. 安装部署/修改配置】"
    validate_config
    
    print_section "测试发送"
    echo -e "正在生成并发送测试消息..."
    
    local used_bytes percent start now_bj now_utc status_msg cover cov_earliest
    PARSE_ERROR=0
    used_bytes=$(get_cycle_bytes) || PARSE_ERROR=1
    percent=$(calc_percent "${used_bytes:-0}")
    start=$(cycle_start_date)
    now_bj=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')
    now_utc=$(date -u '+%Y-%m-%d %H:%M')

    if [ "$PARSE_ERROR" -eq 1 ]; then
        status_msg="异常(无法解析)"
    else
        cover=$(check_day_coverage "$start")
        case "$cover" in
            missing:*) 
                cov_earliest=${cover#missing:}
                status_msg="历史明细缺失(最早 ${cov_earliest:4:2}-${cov_earliest:6:2}，可能偏低)" 
                ;;
            newdb:*)   
                cov_earliest=${cover#newdb:}
                status_msg="新建库(数据自 ${cov_earliest:4:2}-${cov_earliest:6:2} 起)" 
                ;;
            *)         status_msg="正常" ;;
        esac
    fi

    local msg="📊 [$(html_escape "$SERVER_NAME")]每日流量日报 (测试)
━━━━━━━━━━━━━━━
- 周期用量: $(human_bytes "${used_bytes:-0}") / $(html_escape "$LIMIT_GB") GB (${percent}%)
- 账单周期: ${start} 起 (UTC)
- 监控网口: $(html_escape "$IFACE") ($(stat_type_name))
- 统计时间: ${now_utc} (UTC) / ${now_bj} (北京)
- 数据库状态: ${status_msg}
✅ 这是一条测试消息"

    if tg_send "$msg"; then
        echo -e " \033[1;32m[✔] 测试推送成功，请到 Telegram 查收\033[0m"
        log "OK" "测试日报推送成功"
    else
        echo -e " \033[1;31m[✘] 测试推送失败（已重试 3 次），请检查 Token / Chat ID / 网络连通性\033[0m"
        log "ERROR" "测试日报推送失败"
    fi
}

#===============================================================================
# 阈值检查逻辑 (cron 调用)
#===============================================================================
cmd_check() {
    load_config || exit 0

    mkdir -p "$BASE_DIR" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then
        if exec 200>"${BASE_DIR}/check.lock" 2>/dev/null; then
            flock -n 200 || { log "INFO" "已有检查实例运行，跳过本次"; exit 0; }
        fi
    fi

    validate_config
    local used_bytes percent start
    PARSE_ERROR=0
    used_bytes=$(get_cycle_bytes) || PARSE_ERROR=1
    if [ "$PARSE_ERROR" -eq 1 ]; then
        log "ERROR" "阈值检查中止：周期流量数据解析失败，不执行任何推送/关机动作"
        exit 0
    fi
    percent=$(calc_percent "$used_bytes")
    start=$(cycle_start_date)

    # ---- 95% 关机报警 ----
    if awk -v p="$percent" 'BEGIN{exit !(p >= 95)}'; then
        if [ -f "$LOCK_SHUTDOWN" ] && grep -q "$start" "$LOCK_SHUTDOWN" 2>/dev/null; then
            log "WARN" "阈值 ${percent}% ≥95%，但本周期关机流程已触发过，跳过"
            exit 0
        fi
        log "WARN" "流量达到关机阈值: ${percent}% ($(human_bytes "$used_bytes")/${LIMIT_GB}GB)"
        echo "$start" > "$LOCK_SHUTDOWN"

        local msg="🚨 [$(html_escape "$SERVER_NAME")]关机警报 (95%)
━━━━━━━━━━━━━━━
- 周期用量: $(human_bytes "$used_bytes") / $(html_escape "$LIMIT_GB") GB (${percent}%)
- 统计时间: $(date -u '+%Y-%m-%d %H:%M') (UTC)
⚠️ 服务器将在 1 分钟后自动关机"
        
        if tg_send "$msg"; then
            log "OK" "关机报警推送成功"
        else
            log "ERROR" "关机报警推送失败（已重试 3 次），按预设流程继续执行关机"
        fi

        sleep 60

        used_bytes=$(get_cycle_bytes) || PARSE_ERROR=1
        if [ "$PARSE_ERROR" -eq 1 ]; then
            log "ERROR" "关机前二次确认失败：数据解析异常，取消关机"
            rm -f "$LOCK_SHUTDOWN"
            exit 0
        fi
        percent=$(calc_percent "$used_bytes")
        local new_start; new_start=$(cycle_start_date)

        if [ "$new_start" != "$start" ]; then
            log "INFO" "账单周期已切换 ($start → $new_start)，取消关机"
            rm -f "$LOCK_SHUTDOWN"
            exit 0
        fi

        if awk -v p="$percent" 'BEGIN{exit !(p >= 95)}'; then
            log "WARN" "二次确认通过（${percent}% ≥95%，周期 ${new_start}），执行关机命令"
            tg_send "⛔ [$(html_escape "$SERVER_NAME")] 确认 ${percent}% ≥95%，正在执行关机... ($(date -u '+%Y-%m-%d %H:%M') UTC)" >/dev/null 2>&1
            sync
            
            local shutdown_success=0
            if command -v shutdown >/dev/null 2>&1; then
                shutdown -h now "traffic-monitor: 流量达到 95% 阈值，自动关机" && shutdown_success=1
            elif command -v poweroff >/dev/null 2>&1; then
                poweroff && shutdown_success=1
            else
                systemctl poweroff && shutdown_success=1
            fi

            if [ "$shutdown_success" -eq 1 ]; then
                log "OK" "关机命令已下发"
                exit 0
            else
                log "ERROR" "关机命令执行失败，移除锁以便下分钟重试"
                rm -f "$LOCK_SHUTDOWN"
                exit 1
            fi
        else
            log "INFO" "二次确认未通过（当前 ${percent}%，周期 ${new_start}），取消关机"
            rm -f "$LOCK_SHUTDOWN"
        fi
        exit 0
    fi

    # ---- 90% 预警 ----
    if awk -v p="$percent" 'BEGIN{exit !(p >= 90)}'; then
        load_state
        if [ "$WARNED_CYCLE" != "$start" ]; then
            log "WARN" "流量达到预警阈值: ${percent}%，周期 ${start}，首次触发推送"
            local msg="⚠️ [$(html_escape "$SERVER_NAME")]流量预警 (90%)
━━━━━━━━━━━━━━━
- 周期用量: $(human_bytes "$used_bytes") / $(html_escape "$LIMIT_GB") GB (${percent}%)
- 统计时间: $(date -u '+%Y-%m-%d %H:%M') (UTC)"
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
# UI 模块
#===============================================================================
print_banner() {
    clear 2>/dev/null
    echo -e "\033[36m===================================================\033[0m"
    echo -e "  \033[1;37mvnStat 流量监控助手\033[0m  \033[33m${VERSION}\033[0m"
    echo -e "  \033[90mSystem: Debian 13 / vnStat 2.x\033[0m"
    echo -e "\033[36m===================================================\033[0m"
    echo -e "  \033[32m1.\033[0m 安装部署/修改配置"
    echo -e "  \033[32m2.\033[0m 测试发送每日流量推送"
    echo -e "  \033[32m3.\033[0m 查看当前流量数据"
    echo -e "  \033[32m4.\033[0m 从 GitHub 更新脚本"
    echo -e "  \033[32m5.\033[0m 重置 vnStat 数据库"
    echo -e "  \033[32m6.\033[0m 环境自检 (排障)"
    echo -e "  \033[32m7.\033[0m 卸载监控程序"
    echo -e "  \033[32m0.\033[0m 退出"
    echo -e "\033[36m===================================================\033[0m"
}

print_section() {
    echo ""
    echo -e "\033[36m--- $1 ---\033[0m"
}

prompt_input() {
    local tip=$1 def=${2:-} val
    if [ -n "$def" ]; then
        echo -ne " \033[32m?\033[0m $tip \033[33m[当前: $def]\033[0m (回车保留): "
        read -r val
        REPLY_VAL=${val:-$def}
    else
        while true; do
            echo -ne " \033[32m?\033[0m $tip: "
            read -r val
            [ -n "$val" ] && break
            echo -e " \033[31m✘\033[0m 不能为空，请重新输入"
        done
        REPLY_VAL=$val
    fi
}

#===============================================================================
# 依赖与环境配置
#===============================================================================
install_deps() {
    local missing=0 p
    for p in vnstat curl jq crontab; do
        command -v "$p" >/dev/null 2>&1 || missing=1
    done
    if [ "$missing" -eq 0 ]; then
        echo -e " \033[32m[✔]\033[0m 依赖已齐全，跳过安装"
        systemctl enable vnstat >/dev/null 2>&1
        systemctl start vnstat  >/dev/null 2>&1
        return
    fi
    echo -e " \033[33m[⏳]\033[0m 检查并安装依赖软件 (vnstat curl jq cron)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || echo -e " \033[33m[!] apt-get update 失败，尝试继续安装\033[0m"
    apt-get install -y vnstat curl jq cron ca-certificates >/dev/null 2>&1 \
        || die "依赖安装失败，请检查网络或 apt 源后重试"
    for p in vnstat curl jq crontab; do
        command -v "$p" >/dev/null 2>&1 || die "依赖 [$p] 安装后仍不可用"
    done
    systemctl enable vnstat >/dev/null 2>&1
    systemctl start vnstat  >/dev/null 2>&1
    echo -e " \033[32m[✔]\033[0m 依赖安装完成"
}

setup_timezone() {
    local tz
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
    if [ "$tz" = "Asia/Shanghai" ]; then
        echo -e " \033[32m[✔]\033[0m 当前时区已是 Asia/Shanghai"
        return
    fi
    if ! timedatectl set-timezone Asia/Shanghai 2>/dev/null; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true
        echo "Asia/Shanghai" > /etc/timezone 2>/dev/null || true
    fi
    echo -e " \033[32m[✔]\033[0m 系统时区已设置为 Asia/Shanghai"
}

setup_vnstat_utc() {
    echo -e " \033[33m[⏳]\033[0m 配置 vnStat UseUTC 1 (UTC0 基准)..."
    if [ ! -f "$VNSTAT_CONF" ]; then
        echo "UseUTC 1" > "$VNSTAT_CONF" || die "无法写入 $VNSTAT_CONF"
    elif grep -qE '^[#[:space:]]*UseUTC' "$VNSTAT_CONF"; then
        sed -i -E 's/^[#[:space:]]*UseUTC.*/UseUTC 1/' "$VNSTAT_CONF"
    else
        echo "UseUTC 1" >> "$VNSTAT_CONF"
    fi
    grep -qE '^UseUTC 1' "$VNSTAT_CONF" || die "vnStat UseUTC 配置写入失败"
    systemctl restart vnstat >/dev/null 2>&1
    echo -e " \033[32m[✔]\033[0m vnStat UseUTC=1 已生效"
}

choose_iface() {
    local ifaces=() i idx n ip
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        [ "$n" = "lo" ] && continue
        ifaces+=("$n")
    done
    [ ${#ifaces[@]} -gt 0 ] || die "未检测到任何可用网卡接口"
    echo -e "检测到网卡接口:"
    for i in "${!ifaces[@]}"; do
        ip=$(ip -4 addr show "${ifaces[i]}" 2>/dev/null | grep -oP '(?<=inet )[\d.]+' | head -n1)
        echo -e "   \033[32m$((i+1)))\033[0m ${ifaces[i]} \033[90m${ip:+(IP: $ip)}\033[0m"
    done
    if [ ${#ifaces[@]} -eq 1 ]; then
        prompt_input "仅检测到 [${ifaces[0]}]，确认使用？(Y/n)"
        case "$REPLY_VAL" in n|N) ;; *) REPLY_VAL="${ifaces[0]}"; return;; esac
    fi
    while true; do
        prompt_input "请选择监控网口编号" "${IFACE:-1}"
        idx=$REPLY_VAL
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le ${#ifaces[@]} ]; then
            REPLY_VAL="${ifaces[idx-1]}"; return
        fi
        for n in "${ifaces[@]}"; do
            [ "$idx" = "$n" ] && { REPLY_VAL="$n"; return; }
        done
        echo -e "\033[31m[✘]\033[0m 无效选择，请重新输入"
    done
}

interactive_config() {
    local is_update=0
    if load_config; then
        is_update=1
        echo -e " \033[33m[!]\033[0m 检测到已有配置，进入修改模式（回车保留原值）"
    else
        echo -e " \033[32m[✔]\033[0m 首次安装，进入配置向导"
    fi
    echo ""

    prompt_input "① 监控服务器名称" "$SERVER_NAME";   SERVER_NAME=$REPLY_VAL
    echo ""
    echo -e " ② 监控网口设置:"
    choose_iface;                                      IFACE=$REPLY_VAL
    echo ""
    prompt_input "③ 每月账单流量重置日 (1-31, UTC)" "$RESET_DAY"
    [[ "$REPLY_VAL" =~ ^[0-9]+$ ]] && [ "$REPLY_VAL" -ge 1 ] && [ "$REPLY_VAL" -le 31 ] \
        || die "重置日非法：$REPLY_VAL"
    RESET_DAY=$((10#$REPLY_VAL))
    echo ""
    echo -e " ④ 流量统计类型: \033[32m1\033[0m)总流量 \033[32m2\033[0m)上传 \033[32m3\033[0m)下载"
    prompt_input "请选择" "${STAT_TYPE:-1}"
    case "$REPLY_VAL" in 1|2|3) STAT_TYPE=$REPLY_VAL ;; *) die "统计类型非法" ;; esac
    echo ""
    prompt_input "⑤ Telegram Bot Token" "$TG_TOKEN";  TG_TOKEN=$REPLY_VAL
    prompt_input "⑥ Telegram Chat ID" "$TG_CHATID";   TG_CHATID=$REPLY_VAL
    echo ""
    prompt_input "⑦ 账单周期总流量 (GB)" "$LIMIT_GB"
    if ! [[ "$REPLY_VAL" =~ ^[0-9]+([.][0-9]+)?$ ]] \
            || ! awk -v l="$REPLY_VAL" 'BEGIN{exit !(l+0>0)}' 2>/dev/null; then
        die "流量总额非法：$REPLY_VAL"
    fi
    LIMIT_GB=$REPLY_VAL
    echo ""

    echo -e "\033[36m--- 配置预览 ---\033[0m"
    echo -e " 服务器名称 : \033[1;37m$SERVER_NAME\033[0m"
    echo -e " 监控网口   : \033[1;37m$IFACE\033[0m"
    echo -e " 账单重置日 : \033[1;37m每月 ${RESET_DAY} 日 (UTC0)\033[0m"
    echo -e " 统计类型   : \033[1;37m$(stat_type_name)\033[0m"
    echo -e " 流量总额   : \033[1;37m${LIMIT_GB} GB\033[0m"
    echo -e " TG Token   : \033[1;37m${TG_TOKEN:0:12}****\033[0m"
    echo -e " TG Chat ID : \033[1;37m$TG_CHATID\033[0m"
    echo ""
    
    prompt_input "确认保存配置？(Y/n)"
    case "$REPLY_VAL" in n|N) die "用户取消保存";; esac

    mkdir -p "$BASE_DIR"
    {
        echo "# traffic-monitor 配置文件 ($VERSION)"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf 'SERVER_NAME=%q\n' "$SERVER_NAME"
        printf 'IFACE=%q\n'       "$IFACE"
        printf 'RESET_DAY=%d\n'   "$RESET_DAY"
        printf 'STAT_TYPE=%d\n'   "$STAT_TYPE"
        printf 'TG_TOKEN=%q\n'    "$TG_TOKEN"
        printf 'TG_CHATID=%q\n'   "$TG_CHATID"
        printf 'LIMIT_GB=%q\n'    "$LIMIT_GB"
    } > "$CONF_FILE" || die "无法写入配置文件: $CONF_FILE"
    chmod 600 "$CONF_FILE"

    if [ "$is_update" -eq 1 ]; then
        rm -f "$STATE_FILE" "$LOCK_SHUTDOWN"
        echo -e "\n \033[32m[✔]\033[0m 配置文件已更新，旧状态已重置"
    else
        echo -e "\n \033[32m[✔]\033[0m 配置文件已创建"
    fi

    vnstat --add -i "$IFACE" >/dev/null 2>&1
    systemctl restart vnstat >/dev/null 2>&1
}

install_cron() {
    echo -e " \033[33m[⏳]\033[0m 创建/更新定时任务..."
    if [[ "$SCRIPT_PATH" =~ ^/proc/.*/fd/ ]] || [[ "$SCRIPT_PATH" =~ ^/dev/fd/ ]]; then
        die "脚本路径异常 ($SCRIPT_PATH)，无法配置定时任务！请保存为本地文件。"
    fi
    [ -x "$SCRIPT_PATH" ] || chmod +x "$SCRIPT_PATH" 2>/dev/null

    local tmp scmd lcmd
    tmp=$(mktemp)
    scmd="\"$SCRIPT_PATH\""
    lcmd="\"$LOG_FILE\""
    crontab -l 2>/dev/null | grep -v "# traffic-monitor" > "$tmp"
    echo "0 8 * * * $scmd daily >> $lcmd 2>&1 # traffic-monitor" >> "$tmp"
    echo "* * * * * $scmd check >> $lcmd 2>&1 # traffic-monitor" >> "$tmp"
    crontab "$tmp" || { rm -f "$tmp"; die "crontab 写入失败"; }
    rm -f "$tmp"
    restart_cron_service
    echo -e " \033[32m[✔]\033[0m 定时任务已生效"
}

cmd_install() {
    check_root
    print_section "安装部署 / 修改配置"
    install_deps
    setup_timezone
    setup_vnstat_utc
    echo ""
    interactive_config
    echo ""
    install_cron
    echo ""
    echo -e "\033[32m===================================================\033[0m"
    echo -e "  \033[1;32m全部完成！\033[0m"
    echo -e "  - 每日日报: 北京时间 08:00"
    echo -e "  - 阈值检查: 每分钟一次"
    echo -e "\033[32m===================================================\033[0m"
    echo ""
    
    prompt_input "是否立即发送一条测试日报？(Y/n)"
    case "$REPLY_VAL" in n|N) ;; *) cmd_test_push ;; esac
}

#===============================================================================
# 查看当前流量数据
#===============================================================================
cmd_show() {
    check_root
    load_config || die "尚未安装配置，请先执行【1. 安装部署/修改配置】"
    validate_config
    
    print_section "当前流量数据 — ${SERVER_NAME}"
    
    local used_bytes percent start cover cov_earliest all_bytes
    PARSE_ERROR=0
    used_bytes=$(get_cycle_bytes) || PARSE_ERROR=1
    percent=$(calc_percent "${used_bytes:-0}")
    start=$(cycle_start_date)
    
    echo -e " \033[36m➜\033[0m 监控网口 : \033[1;37m$IFACE\033[0m ($(stat_type_name))"
    echo -e " \033[36m➜\033[0m 账单周期 : \033[1;37m${start}\033[0m (UTC0) → 当前 $(date -u '+%Y-%m-%d %H:%M')"
    echo -e " \033[36m➜\033[0m 已用流量 : \033[1;33m$(human_bytes "${used_bytes:-0}")\033[0m / ${LIMIT_GB} GB (\033[1;32m${percent}%\033[0m)"
    echo -e " \033[36m➜\033[0m 阈值预警 : 90% (推送) / 95% (关机)"
    
    if [ "$PARSE_ERROR" -eq 1 ]; then
        echo -e " \033[31m[✘] 周期流量解析失败！请执行【6. 环境自检】\033[0m"
    elif [ "${used_bytes:-0}" -eq 0 ]; then
        all_bytes=$(vnstat_day_json | jq -r "$(jq_day_sum_filter '(.rx + .tx)' '')" 2>/dev/null)
        if awk -v v="${all_bytes:-0}" 'BEGIN{exit !(v+0>0)}' 2>/dev/null; then
            echo -e " \033[33m[!] 周期统计为 0，但 vnStat 存在历史流量，请核对日明细\033[0m"
        fi
    else
        cover=$(check_day_coverage "$start")
        case "$cover" in
            missing:*)
                cov_earliest=${cover#missing:}
                echo -e " \033[33m[!] 日明细最早仅到 ${cov_earliest:0:4}-${cov_earliest:4:2}-${cov_earliest:6:2}，统计可能偏低\033[0m"
                ;;
            newdb:*)
                cov_earliest=${cover#newdb:}
                echo -e " \033[32m[i] 日明细自 ${cov_earliest:0:4}-${cov_earliest:4:2}-${cov_earliest:6:2} 开始记录\033[0m"
                ;;
        esac
    fi
    
    echo -e "\033[36m---------------------------------------------------\033[0m"
    echo -e " vnStat 实时概况:"
    vnstat -i "$IFACE" 2>/dev/null | sed 's/^/    /' || echo -e "    \033[33m(暂无数据，等待守护进程采集...)\033[0m"
    echo -e "\033[36m---------------------------------------------------\033[0m"
}

#===============================================================================
# 环境自检
#===============================================================================
cmd_diag() {
    print_section "环境自检"
    [ "$(id -u)" -eq 0 ] \
        || echo -e " \033[33m提示：当前非 root 运行，可能无法读取部分配置\033[0m"
        
    echo -e " \033[36m[基础环境]\033[0m"
    echo -e " 脚本路径   : $SCRIPT_PATH"
    echo -e " 运行时间   : $(date '+%Y-%m-%d %H:%M:%S %Z') / UTC: $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo -e " 系统时区   : $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 未知)"
    echo -e " vnStat 版本: $(vnstat --version 2>/dev/null | head -n1 || echo 未安装)"
    echo -e " vnStat 服务: $(systemctl is-active vnstat 2>/dev/null || echo 未知)"
    echo -e " UseUTC 配置: $(grep -E '^UseUTC' "$VNSTAT_CONF" 2>/dev/null || echo "未找到")"
    echo -e " jq 版本    : $(jq --version 2>/dev/null || echo 未安装)"
    echo -e " curl 版本  : $(curl --version 2>/dev/null | head -n1 || echo 未安装)"
    
    if load_config; then
        echo -e "\n \033[36m[监控配置]\033[0m"
        echo -e " 服务器名称 : $SERVER_NAME"
        echo -e " 监控网口   : $IFACE (存在: $([ -d "/sys/class/net/$IFACE" ] && echo 是 || echo 否))"
        echo -e " 重置日/类型: $RESET_DAY / $STAT_TYPE | 总额: ${LIMIT_GB} GB"
        echo -e " TG 配置    : Token[$( [ -n "$TG_TOKEN" ] && echo 已填 || echo 空*)] ChatID[$( [ -n "$TG_CHATID" ] && echo 已填 || echo 空 )]"
        
        echo -e "\n \033[36m[vnStat 数据探测]\033[0m"
        local json start bytes
        json=$(vnstat_day_json)
        if [ -n "$json" ]; then
            echo -e " 顶层键     : $(echo "$json" | jq -r 'keys | join(", ")' 2>/dev/null || echo jq解析失败)"
            echo -e " 首条日明细 : $(echo "$json" | jq -c '[ .. | objects | select(has("day")) | select(.day|type=="array") | .day[] ] | first // "无"' 2>/dev/null | head -c 200)"
            
            echo -e "\n \033[36m[周期计算]\033[0m"
            start=$(cycle_start_date)
            echo -e " 周期起点   : $start (UTC)"
            PARSE_ERROR=0
            bytes=$(get_cycle_bytes) || PARSE_ERROR=1
            echo -e " 周期字节   : ${bytes:-0}  ($(human_bytes "${bytes:-0}"))"
            if [ "$PARSE_ERROR" -eq 1 ]; then
                echo -e " 解析状态   : \033[31m✘ 失败（详见 JSON 探测与日志）\033[0m"
            else
                echo -e " 解析状态   : \033[32m✔ 正常\033[0m"
                echo -e " 已用百分比 : $(calc_percent "$bytes")%"
                echo -e " 日明细覆盖 : $(check_day_coverage "$start")"
            fi
        else
            echo -e " \033[31m✘ vnstat --json d -i $IFACE 无输出！请手动执行排障\033[0m"
        fi
    else
        echo -e " \033[33m[!] 配置文件不存在或不可读，仅输出环境信息\033[0m"
    fi
    
    echo -e "\n \033[36m[定时任务]\033[0m"
    crontab -l 2>/dev/null | grep "# traffic-monitor" | sed 's/^/    /' || echo "    (无 traffic-monitor 任务)"
    echo -e "\n \033[36m[日志最近 5 行]\033[0m"
    tail -n 5 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || echo "    (无日志)"
    echo -e "\033[36m---------------------------------------------------\033[0m"
}

#===============================================================================
# 重置 vnStat 数据库
#===============================================================================
cmd_reset_db() {
    check_root
    load_config || die "尚未安装配置，请先执行【1. 安装部署/修改配置】"
    
    print_section "重置 vnStat 数据库"
    echo -e " \033[31m[!] 将删除网口 [$IFACE] 的全部历史流量数据！\033[0m"
    echo -e " \033[90m适用场景: 日/月明细口径错乱（如 UseUTC 切换导致历史数据不一致）\033[0m"
    echo ""
    prompt_input "确认重置？此操作不可恢复 (y/N)"
    case "$REPLY_VAL" in y|Y) ;; *) echo -e " \033[90m已取消\033[0m"; return;; esac
    
    echo -e " \033[33m[⏳]\033[0m 正在重置数据库..."
    systemctl stop vnstat >/dev/null 2>&1
    rm -f "${VNSTAT_DB_DIR}/${IFACE}" "${VNSTAT_DB_DIR}/${IFACE}.tmp" 2>/dev/null
    vnstat --add -i "$IFACE" >/dev/null 2>&1
    systemctl start vnstat >/dev/null 2>&1
    rm -f "$STATE_FILE" "$LOCK_SHUTDOWN"
    
    log "WARN" "已重置 vnStat 数据库: 网口=$IFACE，历史明细清空，预警/关机状态重置"
    echo -e " \033[32m[✔]\033[0m 已重置。流量约 1~2 分钟后重新累积，期间显示 0 属正常。"
}

#===============================================================================
# 从 GitHub 更新脚本
#===============================================================================
cmd_update() {
    check_root
    if [[ "$SCRIPT_PATH" =~ ^/proc/.*/fd/ ]] || [[ "$SCRIPT_PATH" =~ ^/dev/fd/ ]]; then
        die "当前处于临时管道执行模式，无法自动覆盖更新。请手动下载脚本！"
    fi

    print_section "更新脚本"
    echo -e " \033[33m[⏳]\033[0m 正在从 GitHub 拉取最新脚本..."
    local tmp url newver
    tmp=$(mktemp)
    url="${UPDATE_URL}?t=$(date +%s)$RANDOM"
    
    if ! curl -fsSL -m 60 \
            -H "Cache-Control: no-cache, no-store, must-revalidate" \
            -H "Pragma: no-cache" \
            "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "下载失败，请检查网络或仓库地址: $UPDATE_URL"
    fi
    
    [ -s "$tmp" ] || { rm -f "$tmp"; die "下载内容为空"; }
    head -n1 "$tmp" | grep -q '^#!' || { rm -f "$tmp"; die "下载内容不是有效脚本"; }
    bash -n "$tmp" || { rm -f "$tmp"; die "新脚本语法校验未通过，已放弃更新"; }
    
    cp -f "$tmp" "${SCRIPT_PATH}.new" && chmod +x "${SCRIPT_PATH}.new" && mv -f "${SCRIPT_PATH}.new" "$SCRIPT_PATH"
    rm -f "$tmp"
    
    newver=$(grep -m1 '^VERSION=' "$SCRIPT_PATH" | cut -d'"' -f2)
    echo -e " \033[32m[✔]\033[0m 脚本已更新至 ${newver:-未知} (原版本 $VERSION)"
    log "OK" "脚本已从 GitHub 更新: $VERSION → ${newver:-未知}"
    
    echo -e " \033[33m[⏳]\033[0m 正在重载新版本脚本..."
    sleep 1
    exec "$SCRIPT_PATH" "$@"
}

#===============================================================================
# 卸载
#===============================================================================
cmd_uninstall() {
    check_root
    print_section "卸载监控程序"
    echo -e " \033[33m将执行以下清理操作:\033[0m"
    echo -e "  1) 删除相关 cron 定时任务并重载"
    echo -e "  2) 删除配置/状态/日志目录: $BASE_DIR"
    echo -e "  3) 删除脚本文件: $SCRIPT_PATH"
    echo -e "  \033[90m(vnStat 本体及其数据库默认保留)\033[0m"
    echo ""
    prompt_input "确认卸载？(y/N)"
    case "$REPLY_VAL" in y|Y) ;; *) echo -e " \033[90m已取消卸载\033[0m"; return;; esac

    log "WARN" "开始执行卸载"
    local tmp; tmp=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# traffic-monitor" > "$tmp"
    if [ -s "$tmp" ]; then crontab "$tmp"; else crontab -r 2>/dev/null; fi
    rm -f "$tmp"
    restart_cron_service
    echo -e " \033[32m[✔]\033[0m 定时任务已清理"
    
    local bak="${HOME:-/root}/traffic-monitor-last.log"
    if [ -f "$LOG_FILE" ]; then
        if cp -f "$LOG_FILE" "$bak" 2>/dev/null; then
            echo -e " \033[32m[✔]\033[0m 日志已备份至: $bak"
        fi
    fi
    rm -rf "$BASE_DIR"
    echo -e " \033[32m[✔]\033[0m 配置/状态/日志已删除"
    rm -f "$SCRIPT_PATH"
    echo -e " \033[32m[✔]\033[0m 脚本文件已删除: $SCRIPT_PATH"
    echo ""
    echo -e "\033[32m 卸载完成！\033[0m"
    exit 0
}

#===============================================================================
# 主菜单
#===============================================================================
menu() {
    [ -t 0 ] || die "非交互终端环境，请使用子命令: daily|check|config|test|show|diag|update|uninstall|reset-db|version"
    while true; do
        print_banner
        echo -ne " \033[32m?\033[0m 请输入选项: "
        read -r choice
        case "$choice" in
            1) cmd_install ;;
            2) cmd_test_push ;;
            3) cmd_show ;;
            4) cmd_update ;;
            5) cmd_reset_db ;;
            6) cmd_diag ;;
            7) cmd_uninstall ;;
            0) echo -e "\n 再见！"; exit 0 ;;
            *) echo -e "\n\033[33m[!]\033[0m 无效选项，请重新输入"; sleep 1;;
        esac
        echo ""
        echo -e "\033[36m---------------------------------------------------\033[0m"
        echo -ne " 按回车键返回主菜单..."
        read -r _
    done
}

#===============================================================================
# 入口
#===============================================================================
main() {
    case "${1:-}" in
        daily)    cmd_daily ;;
        check)    cmd_check ;;
        config)   cmd_install ;;
        test)     cmd_test_push ;;
        show)     cmd_show ;;
        diag)     cmd_diag ;;
        update)   cmd_update ;;
        uninstall) cmd_uninstall ;;
        reset-db) cmd_reset_db ;;
        version)  echo "traffic-monitor $VERSION" ;;
        *)        menu ;;
    esac
}

main "$@"
