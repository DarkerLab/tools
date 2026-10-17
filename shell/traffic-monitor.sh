#!/usr/bin/env bash
#===============================================================================
# 脚本名称 : traffic-monitor.sh
# 版    本 : v1.5
# 适用系统 : Debian 13 (兼容 Debian 11/12、Ubuntu 20.04+)，依赖 vnStat 2.x
# 更新记录 :
#   v1.5 流量统计口径改为 1000 进制(SI)，与主流云服务商账单一致:
#        human_bytes 按 1000 分割(B/KB/MB/GB/TB/PB)；
#        calc_percent 的 LIMIT_GB 按 1000^3 换算字节(原 1024^3)。
#        （仅计算逻辑调整，不对用户额外展示口径提示）
#        同时修复 v1.4 遗留的"新库误报历史缺失"问题:
#        check_day_coverage 新增 newdb 状态(日明细最早=今天/昨天时判定为
#        新建或刚重置的库，属正常)，build_report/cmd_show 分支提示区分
#   v1.4 按代码审查意见全面修复:
#        [必修] cycle_start_date 短月末日判断错误(重置日>当月天数时)导致
#               周期起点算错、阈值误触发；配置文件写入未转义(含 " $ ` 会
#               破坏配置甚至 RCE)；install_cron 未确保脚本可执行位
#        [应修] 95% 关机命令失败后锁不释放导致本周期永不重试；cmd_check
#               未用 flock 保护并发(95% 分支 sleep 60 必然重叠)；cmd_show
#               缺口语义写反；install_deps 每次强制 apt update/重装
#        [改进] setup_vnstat_utc 删死代码；install_cron 路径加引号；
#               cmd_show 浮点比较改 awk；load_state source 失败兜底；
#               cmd_test_push/cmd_show 加 check_root，cmd_diag 软提示；
#               setup_timezone 回退路径检查写入结果；cmd_reset_db 补充说明；
#               tg_send 提取 Telegram 错误 description；关机二次确认加入
#               周期切换判断；validate_config 严格校验 LIMIT_GB 数值；
#               卸载日志备份从 /tmp 迁至 $HOME
#   v1.3 全面代码审查重写；新增环境自检(diag)与 vnStat 数据库重置；
#        账单周期日明细缺口检测提示；HTML 特殊字符转义；非 tty 防护；
#        兼容 cron 服务名差异(cron/crond)
#   v1.2 修复 vnStat 2.x JSON 结构(day 嵌套在 traffic 下)导致账单周期
#        流量恒为 0.00 B、90%/95% 阈值失效的解析缺陷；解析失败安全保护
#   v1.1 初始版本
# 功能说明 :
#   1. 基于 vnStat 的账单周期流量监控（自定义每月重置日，UTC0 时间基准）
#   2. Telegram 每日流量日报（北京时间 08:00 推送）
#   3. 流量达 90% 首次预警推送（每账单周期仅推送一次）
#   4. 流量达 95% 关机报警推送（失败自动重试 3 次），延迟 1 分钟并二次确认
#      阈值仍达标后执行关机，防止账单重置后误关机；解析失败绝不关机
#   5. 每分钟定时检查（cron），安装/修改配置后自动创建、更新并重载定时任务
#   6. 完整日志记录、权限检查、依赖检查、配置校验、中文交互提示
#   7. 流量单位按 1000 进制(SI)换算，与主流云服务商账单口径一致
# 更新地址 : https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh
#===============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C

VERSION="v1.5"
SCRIPT_PATH="$(readlink -f "$0")"
BASE_DIR="/etc/traffic-monitor"
CONF_FILE="${BASE_DIR}/config.conf"
STATE_FILE="${BASE_DIR}/state.conf"
LOG_FILE="${BASE_DIR}/monitor.log"
LOCK_SHUTDOWN="${BASE_DIR}/shutdown.lock"
UPDATE_URL="https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh"
VNSTAT_CONF="/etc/vnstat.conf"
VNSTAT_DB_DIR="/var/lib/vnstat"
MAX_LOG_SIZE=$((5*1024*1024))   # 日志超过 5MB 自动截断（文件大小仍用 1024 进制）

#===============================================================================
# 基础工具
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
    [ "$(id -u)" -eq 0 ] || die "请使用 root 权限运行本脚本（sudo bash $0）"
}

human_bytes() {
    # 1000 进制（SI）：B/KB/MB/GB/TB/PB，与主流云服务商账单口径一致
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB PB", u, " ");
        i = 1;
        while (b >= 1000 && i < 6) { b /= 1000; i++ }
        printf "%.2f %s", b, u[i];
    }'
}

html_escape() {
    # Telegram parse_mode=HTML：用户自定义字段须转义 & < >
    # 注意不用 ${var//repl}：bash5.2 patsub_replacement 会把 & 当匹配文本
    printf '%s' "${1-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

restart_cron_service() {
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null \
        || service cron restart 2>/dev/null || service crond restart 2>/dev/null \
        || c_yellow "  ! 无法自动重载 cron，请确认 cron 服务已运行"
}

#===============================================================================
# 配置读写与校验
#===============================================================================
load_config() {
    [ -f "$CONF_FILE" ] || return 1
    # shellcheck disable=SC1090
    . "$CONF_FILE" || return 1
    return 0
}

load_state() {
    # source 失败时也保证 WARNED_CYCLE 为空，避免沿用错误状态
    WARNED_CYCLE=""
    if [ -r "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE" 2>/dev/null || WARNED_CYCLE=""
    fi
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

validate_config() {
    local err=0
    [ -n "$SERVER_NAME" ] || { c_red "  × 服务器名称为空"; err=1; }
    if [ -z "$IFACE" ] || [ ! -d "/sys/class/net/$IFACE" ]; then
        c_red "  × 监控网口 [$IFACE] 不存在"; err=1
    fi
    if ! [[ "$RESET_DAY" =~ ^[0-9]+$ ]] || [ "$RESET_DAY" -lt 1 ] || [ "$RESET_DAY" -gt 31 ]; then
        c_red "  × 账单重置日 [$RESET_DAY] 非法（应为 1-31）"; err=1
    fi
    case "${STAT_TYPE:-}" in 1|2|3) ;; *) c_red "  × 流量统计类型 [$STAT_TYPE] 非法（应为 1/2/3）"; err=1;; esac
    [ -n "$TG_TOKEN" ]  || { c_red "  × Telegram Bot Token 为空";  err=1; }
    [ -n "$TG_CHATID" ] || { c_red "  × Telegram Chat ID 为空";    err=1; }
    # 严格数字校验，避免 "10abc" 被 awk 前缀解析成合法值
    if ! [[ "${LIMIT_GB:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] \
            || ! awk -v l="$LIMIT_GB" 'BEGIN{exit !(l+0>0)}' 2>/dev/null; then
        c_red "  × 流量总额 [$LIMIT_GB] 非法（应为大于 0 的数字，单位 GB）"; err=1
    fi
    [ "$err" -eq 0 ] || die "配置校验失败，请重新执行【安装部署/修改配置】"
}

#===============================================================================
# vnStat 数据采集（核心）
# 回归要点: v1.1 用 .interface[0].day[] 解析 vnStat 2.x 必失败(恒为0)，
#           v1.2+ 改为结构无关的递归定位并显式区分"解析失败"与"真实 0"
#===============================================================================
PARSE_ERROR=0

# 计算当前账单周期起始日期（UTC）
# 关键: 重置日超出当月天数时必须按"当月有效日=min(rd, 当月天数)"计算，
#       否则 rd=31 遇 2 月 28 日时会把上月最后一天当作本月起点，误统计旧流量
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

# 拉取该网口按日明细 JSON（供解析与自检复用）
vnstat_day_json() {
    vnstat --json d -i "$IFACE" 2>/dev/null
}

# 结构无关的 day 数组求和过滤器（兼容 1.x interface[0] / 2.x interfaces[0]）
jq_day_sum_filter() {
    # $1=字段表达式 (.rx+.tx / .tx / .rx) $2=起始日 yyyymmdd（空则统计全部）
    local field=$1 startnum=${2:-} cond=""
    [ -n "$startnum" ] && cond='| select((.date.year*10000 + .date.month*100 + .date.day) >= ($sn | tonumber))'
    echo '[ .. | objects
          | select(has("day")) | select(.day | type == "array")
          | .day[]
          | select(has("date") and has("rx") and has("tx"))
          '"$cond"'
          | '"$field"' ] | add // 0'
}

# 获取当前账单周期已用流量（字节，UTC 基准）；失败置 PARSE_ERROR 并 return 1
get_cycle_bytes() {
    PARSE_ERROR=0
    local start startnum field json sum
    start=$(cycle_start_date)
    startnum=${start//-/}
    case "${STAT_TYPE:-1}" in
        1) field='(.rx + .tx)' ;;   # 总流量
        2) field='.tx' ;;           # 上传
        3) field='.rx' ;;           # 下载
    esac
    json=$(vnstat_day_json)
    if [ -z "$json" ]; then
        PARSE_ERROR=1
        log "ERROR" "vnStat 无 JSON 输出（接口 [$IFACE] 可能未加入监控或守护进程未运行）"
        echo 0; return 1
    fi
    # 顶层结构探测：不认识的结构必须报错，绝不静默返回 0
    if ! echo "$json" | jq -e 'has("interface") or has("interfaces") or has("traffic")' >/dev/null 2>&1; then
        PARSE_ERROR=1
        log "ERROR" "vnStat JSON 结构无法识别，顶层键: [$(echo "$json" | jq -r 'keys | join(",")' 2>/dev/null)]"
        echo 0; return 1
    fi
    sum=$(echo "$json" | jq -r --arg sn "$startnum" "$(jq_day_sum_filter "$field" "$startnum")" 2>/dev/null)
    if ! [[ "$sum" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        PARSE_ERROR=1
        log "ERROR" "vnStat JSON 周期流量解析失败，原始值: [$sum]"
        echo 0; return 1
    fi
    printf "%.0f" "$sum"
}

# 日明细最早日期（yyyymmdd 数字），用于检测历史缺口；无法获取时输出 unknown
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

# 周期起点与日明细最早日比较
# 输出: ok / newdb / unknown / missing:<yyyymmdd>
#   ok      : 日明细覆盖到周期起点或更早，统计完整
#   newdb   : 日明细从今天/昨天才开始 → 新建库或刚重置，属正常，不报缺失
#   missing : 日明细早于今天/昨天，但晚于周期起点 → 真正存在历史缺口
check_day_coverage() {
    # $1=周期起始日期 YYYY-MM-DD
    local startnum earliest todaynum yestnum
    startnum=${1//-/}
    earliest=$(day_coverage_earliest)
    [ "$earliest" = "unknown" ] && { echo "unknown"; return; }
    if [ "$earliest" -gt "$startnum" ]; then
        todaynum=$(date -u +%Y%m%d)
        # 用 date -u -d yesterday 而非 todaynum-1：避免跨月(20261001-1=20261000)
        yestnum=$(date -u -d "yesterday" +%Y%m%d 2>/dev/null || echo "")
        if [ "$earliest" = "$todaynum" ] \
                || { [ -n "$yestnum" ] && [ "$earliest" = "$yestnum" ]; }; then
            echo "newdb"
        else
            echo "missing:${earliest}"
        fi
    else
        echo "ok"
    fi
}

calc_percent() {
    # 1000 进制：LIMIT_GB × 1000^3 字节，与云服务商账单口径一致
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
    # $1=消息文本；成功返回 0，失败(已重试 3 次)返回 1
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
        # 优先展示 Telegram 返回的 description 字段，便于定位 Token/Chat ID 问题
        desc=$(echo "$resp" | jq -r '.description // empty' 2>/dev/null)
        log "WARN" "Telegram 推送第 ${i}/3 次失败: ${desc:-$(echo "$resp" | head -c 200)}"
        [ "$i" -lt 3 ] && sleep 2
    done
    return 1
}

#===============================================================================
# 日报 / 测试推送
#===============================================================================
build_report() {
    local used_bytes percent start now_bj now_utc warn="" cover cov_earliest
    PARSE_ERROR=0
    used_bytes=$(get_cycle_bytes) || PARSE_ERROR=1
    if [ "$PARSE_ERROR" -eq 1 ]; then
        warn="
⚠️ <b>数据解析异常</b>：未能从 vnStat 读取账单周期流量，数值不可信，请登录服务器使用【环境自检】检查"
    fi
    percent=$(calc_percent "${used_bytes:-0}")
    start=$(cycle_start_date)
    now_bj=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')
    now_utc=$(date -u '+%Y-%m-%d %H:%M')
    if [ "$PARSE_ERROR" -eq 0 ]; then
        cover=$(check_day_coverage "$start")
        case "$cover" in
            missing:*)
                cov_earliest=${cover#missing:}
                warn="${warn}
ℹ️ vnStat 日明细最早仅到 ${cov_earliest:0:4}-${cov_earliest:4:2}-${cov_earliest:6:2}，早于此的周期流量无法统计（历史明细缺失），可用【重置 vnStat 数据库】获得干净口径"
                ;;
            newdb)
                warn="${warn}
ℹ️ vnStat 数据库为新建/刚重置，日明细从今日起记录，周期统计从今天开始累积（属正常）"
                ;;
        esac
    fi
    cat <<EOF
📊 <b>Traffic Daily Report</b>
━━━━━━━━━━━━━━━
🖥 服务器: <b>$(html_escape "$SERVER_NAME")</b>
📡 网口: $(html_escape "$IFACE") | 类型: $(stat_type_name)
📈 已用: <b>$(human_bytes "${used_bytes:-0}")</b> / $(html_escape "$LIMIT_GB") GB (<b>${percent}%</b>)
🔄 账单周期: ${start} 起 (UTC)
⏰ 时间: ${now_bj} (北京时间) / ${now_utc} (UTC)${warn}
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
    check_root
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
# 每分钟阈值检查（cron）
#===============================================================================
cmd_check() {
    load_config || exit 0

    # 并发保护：95% 分支会 sleep 60，若不互斥会出现两条关机告警
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

        local msg="🚨 <b>关机警报</b>
━━━━━━━━━━━━━━━
🖥 服务器: <b>$(html_escape "$SERVER_NAME")</b>
📈 已用: <b>$(human_bytes "$used_bytes")</b> / $(html_escape "$LIMIT_GB") GB (<b>${percent}%</b>)
⚠️ 已达 95% 关机阈值，服务器将在 <b>1 分钟</b> 后自动关机！
⏰ $(date -u '+%Y-%m-%d %H:%M') UTC"
        if tg_send "$msg"; then
            log "OK" "关机报警推送成功"
        else
            log "ERROR" "关机报警推送失败（已重试 3 次），按预设流程继续执行关机"
        fi

        # 延迟 1 分钟
        sleep 60

        # 关机前二次确认：防止账单重置误关机；解析失败一律不关机
        used_bytes=$(get_cycle_bytes) || PARSE_ERROR=1
        if [ "$PARSE_ERROR" -eq 1 ]; then
            log "ERROR" "关机前二次确认失败：数据解析异常，取消关机"
            rm -f "$LOCK_SHUTDOWN"
            exit 0
        fi
        percent=$(calc_percent "$used_bytes")
        local new_start; new_start=$(cycle_start_date)

        # 周期已切换 → 说明已进入新账单周期，必须取消关机（避免新周期高额度误杀）
        if [ "$new_start" != "$start" ]; then
            log "INFO" "账单周期已切换 ($start → $new_start)，取消关机"
            rm -f "$LOCK_SHUTDOWN"
            exit 0
        fi

        if awk -v p="$percent" 'BEGIN{exit !(p >= 95)}'; then
            log "WARN" "二次确认通过（${percent}% ≥95%，周期 ${new_start}），执行关机命令"
            tg_send "⛔ 服务器 <b>$(html_escape "$SERVER_NAME")</b> 二次确认 ${percent}% ≥95%，正在执行关机... $(date -u '+%Y-%m-%d %H:%M') UTC" >/dev/null 2>&1
            sync
            if shutdown -h now "traffic-monitor: 流量达到 95% 阈值，自动关机"; then
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

    # ---- 90% 预警（每周期仅首次触发） ----
    if awk -v p="$percent" 'BEGIN{exit !(p >= 90)}'; then
        load_state
        if [ "$WARNED_CYCLE" != "$start" ]; then
            log "WARN" "流量达到预警阈值: ${percent}%，周期 ${start}，首次触发推送"
            local msg="⚠️ <b>流量预警</b>
━━━━━━━━━━━━━━━
🖥 服务器: <b>$(html_escape "$SERVER_NAME")</b>
📈 已用: <b>$(human_bytes "$used_bytes")</b> / $(html_escape "$LIMIT_GB") GB (<b>${percent}%</b>)
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
# 依赖安装 / 时区 / vnStat 基础配置
#===============================================================================
install_deps() {
    # 智能跳过：依赖已齐全时不再 apt update/重装，避免改配置也要等网络
    local missing=0 p
    for p in vnstat curl jq crontab; do
        command -v "$p" >/dev/null 2>&1 || missing=1
    done
    if [ "$missing" -eq 0 ]; then
        c_green "✔ 依赖已齐全，跳过安装: $(vnstat --version 2>/dev/null | head -n1)"
        log "INFO" "依赖已齐全，跳过安装"
        systemctl enable vnstat >/dev/null 2>&1
        systemctl start vnstat  >/dev/null 2>&1
        return
    fi
    echo "→ 检查并安装依赖软件 (vnstat curl jq cron) ..."
    log "INFO" "开始安装依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || c_yellow "  ! apt-get update 失败，尝试继续安装"
    apt-get install -y vnstat curl jq cron ca-certificates >/dev/null 2>&1 \
        || die "依赖安装失败，请检查网络或 apt 源后重试"
    for p in vnstat curl jq crontab; do
        command -v "$p" >/dev/null 2>&1 || die "依赖 [$p] 安装后仍不可用"
    done
    systemctl enable vnstat >/dev/null 2>&1
    systemctl start vnstat  >/dev/null 2>&1
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
    if ! timedatectl set-timezone Asia/Shanghai 2>/dev/null; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
            || c_yellow "  ! 无法创建 /etc/localtime 符号链接"
        echo "Asia/Shanghai" > /etc/timezone 2>/dev/null \
            || c_yellow "  ! 无法写入 /etc/timezone，请手动确认时区"
    fi
    c_green "✔ 系统时区已设置为 Asia/Shanghai（原时区: ${tz:-未知}）"
    log "INFO" "系统时区由 [$tz] 改为 Asia/Shanghai"
}

setup_vnstat_utc() {
    echo "→ 配置 vnStat 使用 UTC0 时间基准 (UseUTC 1) ..."
    if [ ! -f "$VNSTAT_CONF" ]; then
        echo "UseUTC 1" > "$VNSTAT_CONF" || die "无法写入 $VNSTAT_CONF"
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
# 交互式配置（首次=安装配置；再次=读旧配置为默认值更新）
#===============================================================================
prompt_input() {
    # $1=提示语 $2=默认值；结果写入 REPLY_VAL
    local tip=$1 def=${2:-} val
    if [ -n "$def" ]; then
        read -rp "$(c_blue "$tip [当前: $def，回车保留]: ")" val
        REPLY_VAL=${val:-$def}
    else
        while true; do
            read -rp "$(c_blue "$tip: ")" val
            [ -n "$val" ] && break
            c_yellow "  ! 不能为空，请重新输入"
        done
        REPLY_VAL=$val
    fi
}

choose_iface() {
    local ifaces=() i idx n ip
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        [ "$n" = "lo" ] && continue
        ifaces+=("$n")
    done
    [ ${#ifaces[@]} -gt 0 ] || die "未检测到任何可用网卡接口"
    echo "检测到以下网卡接口:"
    for i in "${!ifaces[@]}"; do
        ip=$(ip -4 addr show "${ifaces[i]}" 2>/dev/null | grep -oP '(?<=inet )[\d.]+' | head -n1)
        echo "  $((i+1))) ${ifaces[i]} ${ip:+(IP: $ip)}"
    done
    if [ ${#ifaces[@]} -eq 1 ]; then
        read -rp "$(c_blue "仅检测到一个网口，使用 [${ifaces[0]}]？(Y/n): ")" REPLY_VAL
        case "$REPLY_VAL" in n|N) ;; *) REPLY_VAL="${ifaces[0]}"; return;; esac
    fi
    while true; do
        read -rp "$(c_blue "请选择监控网口编号 [默认: ${IFACE:-1}]: ")" idx
        idx=${idx:-1}
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le ${#ifaces[@]} ]; then
            REPLY_VAL="${ifaces[idx-1]}"; return
        fi
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

    prompt_input "① 监控服务器名称" "$SERVER_NAME";   SERVER_NAME=$REPLY_VAL
    echo
    echo "② 监控网口设置:"
    choose_iface;                                      IFACE=$REPLY_VAL
    echo
    prompt_input "③ 每月账单流量重置日 (1-31, UTC 基准)" "$RESET_DAY"
    [[ "$REPLY_VAL" =~ ^[0-9]+$ ]] && [ "$REPLY_VAL" -ge 1 ] && [ "$REPLY_VAL" -le 31 ] \
        || die "重置日非法：$REPLY_VAL"
    RESET_DAY=$((10#$REPLY_VAL))
    echo
    echo "④ 流量统计类型: 1)总流量(上传+下载)  2)上传流量  3)下载流量"
    prompt_input "   请选择" "${STAT_TYPE:-1}"
    case "$REPLY_VAL" in 1|2|3) STAT_TYPE=$REPLY_VAL ;; *) die "统计类型非法：$REPLY_VAL" ;; esac
    echo
    prompt_input "⑤ Telegram Bot Token" "$TG_TOKEN";  TG_TOKEN=$REPLY_VAL
    prompt_input "⑥ Telegram Chat ID" "$TG_CHATID";   TG_CHATID=$REPLY_VAL
    echo
    prompt_input "⑦ 账单周期总流量 (GB, 支持小数)" "$LIMIT_GB"
    # 严格数字校验，拒绝 "10abc" 这类看似合法但实际无效的输入
    if ! [[ "$REPLY_VAL" =~ ^[0-9]+([.][0-9]+)?$ ]] \
            || ! awk -v l="$REPLY_VAL" 'BEGIN{exit !(l+0>0)}' 2>/dev/null; then
        die "流量总额非法：$REPLY_VAL"
    fi
    LIMIT_GB=$REPLY_VAL
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

    # 使用 printf %q 转义，避免 SERVER_NAME 含 " $ ` 破坏配置文件或形成 RCE
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
    # 确保脚本有执行位（用户可能以 bash script.sh 方式启动，文件本身无 x 位）
    [ -x "$SCRIPT_PATH" ] || chmod +x "$SCRIPT_PATH" 2>/dev/null

    local tmp scmd lcmd
    tmp=$(mktemp)
    # 路径加双引号，避免包含空格时 cron 无法执行
    scmd="\"$SCRIPT_PATH\""
    lcmd="\"$LOG_FILE\""
    crontab -l 2>/dev/null | grep -v "# traffic-monitor" > "$tmp"
    # 每日日报：服务器时区已设为 Asia/Shanghai，即北京时间 08:00
    echo "0 8 * * * $scmd daily >> $lcmd 2>&1 # traffic-monitor" >> "$tmp"
    # 每分钟阈值检查
    echo "* * * * * $scmd check >> $lcmd 2>&1 # traffic-monitor" >> "$tmp"
    crontab "$tmp" || { rm -f "$tmp"; die "crontab 写入失败"; }
    rm -f "$tmp"
    restart_cron_service
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
    check_root
    load_config || die "尚未安装配置，请先执行【1. 安装部署/修改配置】"
    validate_config
    local used_bytes percent start cover cov_earliest all_bytes
    PARSE_ERROR=0
    used_bytes=$(get_cycle_bytes) || PARSE_ERROR=1
    percent=$(calc_percent "${used_bytes:-0}")
    start=$(cycle_start_date)
    echo "==============================================="
    echo "  当前流量数据 — ${SERVER_NAME}  [$VERSION]"
    echo "==============================================="
    echo "  监控网口   : $IFACE"
    echo "  统计类型   : $(stat_type_name)"
    echo "  账单周期   : ${start} 起 (UTC0) → 当前 $(date -u '+%Y-%m-%d %H:%M') UTC"
    echo "  已用流量   : $(human_bytes "${used_bytes:-0}") / ${LIMIT_GB} GB (${percent}%)"
    echo "  预警阈值   : 90% (首次触发推送) / 95% (报警并关机)"
    if [ "$PARSE_ERROR" -eq 1 ]; then
        c_red "  ⚠ 周期流量解析失败！请执行【6. 环境自检】或查看日志: $LOG_FILE"
    elif [ "${used_bytes:-0}" -eq 0 ]; then
        all_bytes=$(vnstat_day_json | jq -r "$(jq_day_sum_filter '(.rx + .tx)' '')" 2>/dev/null)
        # 用 awk 判浮点，避免上游返回小数时 [ -gt ] 报错
        if awk -v v="${all_bytes:-0}" 'BEGIN{exit !(v+0>0)}' 2>/dev/null; then
            c_yellow "  ⚠ 本账单周期统计为 0，但 vnStat 存在其他时段流量，请核对日明细"
        fi
    else
        cover=$(check_day_coverage "$start")
        case "$cover" in
            missing:*)
                cov_earliest=${cover#missing:}
                c_yellow "  ⚠ 日明细最早仅到 ${cov_earliest:0:4}-${cov_earliest:4:2}-${cov_earliest:6:2}（晚于周期起点），此前的周期流量无法统计"
                c_yellow "    历史数据口径错乱可用【7. 重置 vnStat 数据库】解决"
                ;;
            newdb)
                c_green "  ℹ 日明细从今日开始记录（新建库/刚重置），周期统计从今天起累积"
                ;;
        esac
    fi
    echo "-----------------------------------------------"
    echo "  vnStat 实时概况:"
    vnstat -i "$IFACE" 2>/dev/null | sed 's/^/    /' || c_yellow "  (vnStat 暂无该网口数据，等待守护进程采集，约需几分钟)"
    echo "==============================================="
}

#===============================================================================
# 环境自检（远程排障用）
#===============================================================================
cmd_diag() {
    # diag 目的是排障，非 root 也允许进入，但需明确告知可能读不到配置
    [ "$(id -u)" -eq 0 ] \
        || c_yellow "提示：当前非 root 运行，可能无法读取配置文件 ($CONF_FILE)，完整自检建议 sudo 运行"
    echo "================ 环境自检 ($VERSION) ================"
    echo "脚本路径   : $SCRIPT_PATH"
    echo "运行时间   : $(date '+%Y-%m-%d %H:%M:%S %Z') / UTC: $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "系统时区   : $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 未知)"
    echo "vnStat 版本: $(vnstat --version 2>/dev/null | head -n1 || echo 未安装)"
    echo "vnStat 服务: $(systemctl is-active vnstat 2>/dev/null || echo 未知)"
    echo "UseUTC 配置: $(grep -E '^UseUTC' "$VNSTAT_CONF" 2>/dev/null || echo "未找到($VNSTAT_CONF)")"
    echo "jq 版本    : $(jq --version 2>/dev/null || echo 未安装)"
    echo "curl 版本  : $(curl --version 2>/dev/null | head -n1 || echo 未安装)"
    if load_config; then
        echo "--- 配置 ---"
        echo "服务器名称 : $SERVER_NAME"
        echo "监控网口   : $IFACE (存在: $([ -d "/sys/class/net/$IFACE" ] && echo 是 || echo 否))"
        echo "重置日/类型: $RESET_DAY / $STAT_TYPE | 总额: ${LIMIT_GB} GB"
        echo "TG 配置    : Token[$( [ -n "$TG_TOKEN" ] && echo 已填 || echo 空*)] ChatID[$( [ -n "$TG_CHATID" ] && echo 已填 || echo 空 )]"
        echo "--- vnStat JSON 探测 ---"
        local json
        json=$(vnstat_day_json)
        if [ -n "$json" ]; then
            echo "顶层键     : $(echo "$json" | jq -r 'keys | join(", ")' 2>/dev/null || echo jq解析失败)"
            echo "首条日明细 : $(echo "$json" | jq -c '[ .. | objects | select(has("day")) | select(.day|type=="array") | .day[] ] | first // "无"' 2>/dev/null | head -c 200)"
            echo "--- 周期计算 ---"
            local start bytes
            start=$(cycle_start_date)
            echo "周期起点   : $start (UTC)"
            PARSE_ERROR=0
            bytes=$(get_cycle_bytes) || PARSE_ERROR=1
            echo "周期字节   : ${bytes:-0}  ($(human_bytes "${bytes:-0}"))"
            if [ "$PARSE_ERROR" -eq 1 ]; then
                c_red "解析状态   : ✘ 失败（详见上方 JSON 探测与日志）"
            else
                echo "解析状态   : ✔ 正常"
                echo "已用百分比 : $(calc_percent "$bytes")%"
                echo "日明细覆盖 : $(check_day_coverage "$start")"
            fi
        else
            c_red "vnstat --json d -i $IFACE 无输出！请在服务器手动执行该命令排障"
        fi
    else
        c_yellow "配置文件不存在或不可读（尚未安装 / 无读取权限 / 已被清理），仅输出环境信息"
    fi
    echo "--- 定时任务 ---"
    crontab -l 2>/dev/null | grep "# traffic-monitor" | sed 's/^/    /' || echo "    (无 traffic-monitor 任务)"
    echo "--- 日志最近 10 行 ---"
    tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || echo "    (无日志)"
    echo "===================================================="
}

#===============================================================================
# 重置 vnStat 数据库（清除该网口全部历史明细，重头统计）
#===============================================================================
cmd_reset_db() {
    check_root
    load_config || die "尚未安装配置，请先执行【1. 安装部署/修改配置】"
    c_yellow "将删除网口 [$IFACE] 的 vnStat 全部历史流量数据，从当前时刻重新统计！"
    c_yellow "适用场景: 日/月明细口径错乱（如 UseUTC 切换、建库时间错位导致的历史数据不一致）"
    read -rp "$(c_blue "确认重置？此操作不可恢复 (y/N): ")" REPLY_VAL
    case "$REPLY_VAL" in y|Y) ;; *) echo "已取消"; return;; esac
    systemctl stop vnstat >/dev/null 2>&1
    rm -f "${VNSTAT_DB_DIR}/${IFACE}" "${VNSTAT_DB_DIR}/${IFACE}.tmp" 2>/dev/null
    vnstat --add -i "$IFACE" >/dev/null 2>&1
    systemctl start vnstat >/dev/null 2>&1
    # 重置周期状态，允许新数据重新触发预警
    rm -f "$STATE_FILE" "$LOCK_SHUTDOWN"
    log "WARN" "已重置 vnStat 数据库: 网口=$IFACE，历史明细清空，预警/关机状态重置"
    c_green "✔ 已重置。流量约 1~2 分钟后开始重新累积，期间【查看当前流量】显示 0 属正常"
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
    [ -s "$tmp" ] || { rm -f "$tmp"; die "下载内容为空"; }
    head -n1 "$tmp" | grep -q '^#!' || { rm -f "$tmp"; c_red "下载内容不是有效脚本（可能是 GitHub 404 页面）"; head -n3 "$tmp"; die "已放弃更新"; }
    bash -n "$tmp" || { rm -f "$tmp"; die "新脚本语法校验未通过，已放弃更新"; }
    cp -f "$tmp" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    rm -f "$tmp"
    local newver; newver=$(grep -m1 '^VERSION=' "$SCRIPT_PATH" | cut -d'"' -f2)
    c_green "✔ 脚本已更新至 ${newver:-未知}（原版本 $VERSION）: $SCRIPT_PATH"
    log "OK" "脚本已从 GitHub 更新: $VERSION → ${newver:-未知}"
    echo "  提示: 建议执行【6. 环境自检】确认新版本生效"
}

#===============================================================================
# 卸载
#===============================================================================
cmd_uninstall() {
    check_root
    echo "==============================================="
    echo "  卸载 traffic-monitor ($VERSION)"
    echo "==============================================="
    c_yellow "将执行以下清理操作:"
    echo "  1) 删除相关 cron 定时任务并重载"
    echo "  2) 删除配置/状态/日志目录: $BASE_DIR"
    echo "  3) 删除脚本文件: $SCRIPT_PATH"
    echo "  （vnStat 本体及其流量数据库默认保留，如需卸载可自行 apt purge vnstat）"
    read -rp "$(c_blue "确认卸载？(y/N): ")" REPLY_VAL
    case "$REPLY_VAL" in y|Y) ;; *) echo "已取消卸载"; return;; esac

    log "WARN" "开始执行卸载"
    local tmp; tmp=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# traffic-monitor" > "$tmp"
    if [ -s "$tmp" ]; then crontab "$tmp"; else crontab -r 2>/dev/null; fi
    rm -f "$tmp"
    restart_cron_service
    c_green "✔ 定时任务已清理"
    # 备份日志到 $HOME，避免 /tmp 重启丢失或 noexec/nosuid 挂载问题
    local bak="${HOME:-/root}/traffic-monitor-last.log"
    if [ -f "$LOG_FILE" ]; then
        if cp -f "$LOG_FILE" "$bak" 2>/dev/null; then
            c_green "✔ 日志已备份至: $bak"
        else
            c_yellow "  ! 日志备份失败，请手动备份: $LOG_FILE"
        fi
    fi
    rm -rf "$BASE_DIR"
    c_green "✔ 配置/状态/日志已删除"
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
    echo "  6. 环境自检（排障）"
    echo "  7. 重置 vnStat 数据库"
    echo "  0. 退出"
    echo "==============================================="
}

menu() {
    # 非交互环境（管道/误配 cron）拒绝进入菜单，避免死循环
    [ -t 0 ] || die "非交互终端环境，请使用子命令: daily|check|config|test|show|diag|update|uninstall|reset-db|version"
    while true; do
        print_banner
        read -rp "$(c_blue '请输入选项: ')" choice
        case "$choice" in
            1) cmd_install ;;
            2) cmd_test_push ;;
            3) cmd_show ;;
            4) cmd_update ;;
            5) cmd_uninstall ;;
            6) cmd_diag ;;
            7) cmd_reset_db ;;
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
        daily)    cmd_daily ;;        # cron: 每日日报
        check)    cmd_check ;;        # cron: 每分钟阈值检查
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
