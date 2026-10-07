#!/usr/bin/env bash
#
# traffic-monitor.sh
# Telegram 流量监控与自动化管理脚本（Debian 13 Trixie 深度优化 / v3）
#
# 【两套时区语义，互不影响】
#   1) 日报推送：固定每天「北京时间 08:00」推送。脚本自动把该时刻换算到
#      结算时区写入 Cron（例如结算时区为 UTC 时，Cron 为 00:00 UTC）。
#   2) 结算时区 TZ_NAME：仅用于流量重置边界与周期统计——
#      国外 VPS 商家通常按 UTC0 重置（填 UTC），国内按北京时间重置
#      （填 Asia/Shanghai）。
#
# 网卡模式：
#   auto  智能模式（默认，仅统计物理/上行网卡，排除 docker/veth/bridge/
#         wg/tun 等虚拟网卡，避免容器/隧道流量被重复计数）
#   all   统计 vnstat 数据库中的全部网卡
#   <名称> 仅统计指定网卡（如 eth0、ens3、ppp0）
#
set -u
set -o pipefail

###############################################################################
# 全局常量
###############################################################################
readonly CONFIG_DIR="/etc/traffic-monitor"
readonly CONFIG_FILE="${CONFIG_DIR}/config.conf"
readonly STATE_DIR="/var/lib/traffic-monitor"
readonly STATE_FILE="${STATE_DIR}/state.conf"
readonly INSTALL_DIR="/opt/traffic-monitor"
readonly INSTALL_SCRIPT="${INSTALL_DIR}/traffic-monitor.sh"
readonly LINK_PATH="/usr/local/bin/traffic"
readonly LOG_FILE="/var/log/traffic-monitor.log"
readonly VNSTAT_CONF="/etc/vnstat.conf"
readonly DAILY_DAYS_KEEP="62"     # vnstat 每日数据保留天数（覆盖最长 31 天周期）
readonly CRON_PATH_LINE="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
readonly PUSH_TZ="Asia/Shanghai"  # 推送统一使用的时区（北京时间）
readonly PUSH_HOUR="8"            # 推送时刻：北京时间 08:00（固定）
readonly PUSH_MIN="0"

SELF="$(readlink -f "$0")"

###############################################################################
# 通用工具函数
###############################################################################
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "该操作需要 root 权限，请使用 sudo 或切换到 root 后重试。"
    fi
}

# 是否为非负整数
is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# 是否为非负数（整数或小数，允许 0）
is_nonneg_number() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# 是否为正数（整数或小数）
is_positive_number() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$1" 'BEGIN { exit !(v+0 > 0) }'
}

# HTML 转义（& < >）
html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# 字节数 -> GiB（保留两位小数）
fmt_gib() {
    awk -v b="$1" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }'
}

# 字节数 -> 自适应单位（B/KB/MB/GB/TB）
fmt_auto() {
    awk -v b="${1:-0}" '{
        if ($1 >= 1099511627776) printf "%.2f TB", $1/1099511627776;
        else if ($1 >= 1073741824) printf "%.2f GB", $1/1073741824;
        else if ($1 >= 1048576) printf "%.2f MB", $1/1048576;
        else if ($1 >= 1024) printf "%.2f KB", $1/1024;
        else printf "%d B", $1;
    }'
}

# 交互式输入：ask_default <变量名> <提示语> <默认值>
ask_default() {
    local __var="$1"
    local __prompt="$2"
    local __default="$3"
    local __reply=""
    while :; do
        read -r -p "${__prompt} [默认: ${__default}]: " __reply || __reply=""
        __reply="${__reply:-$__default}"
        if [[ -n "$__reply" ]]; then
            printf -v "$__var" '%s' "$__reply"
            return 0
        fi
    done
}

###############################################################################
# 依赖检查与安装（apt / Debian）
###############################################################################
install_dependencies() {
    log "检查必要依赖（vnstat jq curl gawk cron iproute2）..."
    local pkgs=()
    local bin="" pkg=""

    for bin in vnstat jq curl gawk crontab ip; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            case "$bin" in
                crontab) pkg="cron" ;;
                ip)      pkg="iproute2" ;;
                *)       pkg="$bin" ;;
            esac
            pkgs+=("$pkg")
        fi
    done

    if [[ "${#pkgs[@]}" -gt 0 ]]; then
        log "需要安装: ${pkgs[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y || die "apt-get update 失败，请检查软件源与网络。"
        apt-get install -y --no-install-recommends "${pkgs[@]}" \
            || die "依赖安装失败: ${pkgs[*]}"
    else
        log "所有依赖均已安装。"
    fi

    # 确保 cron 服务运行
    systemctl enable cron.service >/dev/null 2>&1 || true
    systemctl restart cron.service >/dev/null 2>&1 || service cron restart >/dev/null 2>&1 || true
}

###############################################################################
# 智能网卡发现：排除虚拟网卡，兜底默认路由网卡
# 输出：每行一个物理/上行网卡名
###############################################################################
get_smart_interfaces() {
    local out=() n="" def=""
    for sys_path in /sys/class/net/*; do
        [[ -e "$sys_path" ]] || continue
        n="$(basename "$sys_path")"
        # 排除回环、容器、网桥、隧道、VPN、K8s 等虚拟接口
        if [[ "$n" =~ ^(lo|docker[0-9]*|veth[0-9a-fA-F]*|br-[0-9a-fA-F]+|cni[0-9]*|flannel[0-9]*|virbr[0-9]*|tun[0-9]*|tap[0-9]*|wg[0-9a-zA-Z_-]*|tailscale[0-9]*|zt[0-9a-zA-Z]*|kube[0-9a-zA-Z]*|dummy[0-9]*|sit[0-9]*|ip6tnl[0-9]*)$ ]]; then
            continue
        fi
        out+=("$n")
    done

    # 确保默认路由的出口网卡在列表中
    def="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    if [[ -n "$def" ]]; then
        local present=0 x=""
        if [[ "${#out[@]}" -gt 0 ]]; then
            for x in "${out[@]}"; do
                [[ "$x" == "$def" ]] && present=1
            done
        fi
        [[ "$present" -eq 0 ]] && out+=("$def")
    fi

    if [[ "${#out[@]}" -gt 0 ]]; then
        printf '%s\n' "${out[@]}"
    fi
}

###############################################################################
# vnstat 准备：每日数据保留、守护进程、网卡加入
###############################################################################
prepare_vnstat() {
    local target="$1"

    # 1) 保证每日数据保留足够长（默认仅 30 天，最长周期可能 31 天）
    if [[ -f "$VNSTAT_CONF" ]]; then
        if grep -qE '^[[:space:]]*#?[[:space:]]*DailyDays[[:space:]]+[0-9]+' "$VNSTAT_CONF"; then
            sed -i -E "s/^[[:space:]]*#?[[:space:]]*DailyDays[[:space:]]+[0-9]+[[:space:]]*$/DailyDays ${DAILY_DAYS_KEEP}/" "$VNSTAT_CONF"
        else
            printf '\nDailyDays %s\n' "$DAILY_DAYS_KEEP" >> "$VNSTAT_CONF"
        fi
    fi

    # 2) 启用并启动 vnstatd
    systemctl enable vnstat.service >/dev/null 2>&1 || true
    systemctl restart vnstat.service >/dev/null 2>&1 || true

    # 3) 确保被监控网卡已加入数据库
    local iface=""
    if [[ "$target" == "auto" ]]; then
        while IFS= read -r iface; do
            [[ -n "$iface" ]] && vnstat -i "$iface" --add >/dev/null 2>&1 || true
        done < <(get_smart_interfaces)
    elif [[ "$target" == "all" ]]; then
        :   # 由 vnstatd 自动发现
    else
        vnstat -i "$target" --add >/dev/null 2>&1 || vnstat --add -i "$target" >/dev/null 2>&1 || true
    fi
}

###############################################################################
# 配置默认值（同时用于加载与向导预填）
###############################################################################
set_config_defaults() {
    TG_TOKEN=""
    TG_CHAT=""
    SERVER_NAME="$(hostname 2>/dev/null || echo 'VPS-Server')"
    LIMIT_GB="1000"
    WARN_PCT="90"
    SHUTDOWN_PCT="95"
    IFACE="auto"
    RESET_DAY="1"
    TZ_NAME="UTC"
    CHECK_INTERVAL="5"
}

###############################################################################
# 配置加载（严格校验）
###############################################################################
load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "未找到配置文件 ${CONFIG_FILE}，请先执行: traffic --config"

    set_config_defaults
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"

    local key=""
    local missing=0
    for key in TG_TOKEN TG_CHAT SERVER_NAME LIMIT_GB WARN_PCT SHUTDOWN_PCT IFACE RESET_DAY TZ_NAME; do
        if ! declare -p "$key" >/dev/null 2>&1 || [[ -z "${!key:-}" ]]; then
            printf '配置项缺失或为空: %s\n' "$key" >&2
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || die "配置不完整，请重新执行: traffic --config"

    [[ -f "/usr/share/zoneinfo/${TZ_NAME}" ]] || die "结算时区无效: ${TZ_NAME}"
    if ! check_tz_integrity "$TZ_NAME"; then
        printf '警告: %s 的时区文件与标准偏移不符（可能损坏）；常用时区将按标准偏移计算。可执行 apt-get install --reinstall tzdata 修复。\n' "$TZ_NAME" >&2
    fi
    is_nonneg_number "$LIMIT_GB" || die "每月流量上限必须为非负数字(0=无限制): ${LIMIT_GB}"
    is_uint "$WARN_PCT" || die "预警百分比必须为整数: ${WARN_PCT}"
    is_uint "$SHUTDOWN_PCT" || die "关机百分比必须为整数: ${SHUTDOWN_PCT}"
    is_uint "$RESET_DAY" || die "重置日必须为整数: ${RESET_DAY}"
    (( RESET_DAY >= 1 && RESET_DAY <= 28 )) || die "重置日必须在 1-28 之间: ${RESET_DAY}"
    (( SHUTDOWN_PCT > WARN_PCT )) || die "关机百分比(${SHUTDOWN_PCT}%)必须大于预警百分比(${WARN_PCT}%)"
    is_uint "$CHECK_INTERVAL" || die "检查间隔必须为整数分钟: ${CHECK_INTERVAL}"
    (( CHECK_INTERVAL >= 1 && CHECK_INTERVAL <= 59 )) || die "检查间隔需在 1-59 分钟之间: ${CHECK_INTERVAL}"

    # 网卡合法性
    if [[ "$IFACE" != "auto" && "$IFACE" != "all" && ! -d "/sys/class/net/${IFACE}" ]]; then
        die "监控网卡不存在: ${IFACE}"
    fi
}

###############################################################################
# 结算周期计算（基于重置日与「结算时区」）
# 结果：START_NUM / END_NUM（YYYYMMDD 整数），START_HUMAN / END_HUMAN
###############################################################################
calc_period() {
    local eff y m d
    eff="$(effective_tz "$TZ_NAME")"
    y="$(TZ="$eff" date +%Y)"
    m="$(TZ="$eff" date +%-m)"
    d="$(TZ="$eff" date +%-d)"

    if (( d >= RESET_DAY )); then
        START_NUM="$(TZ="$eff" date -d "${y}-${m}-${RESET_DAY}" +%Y%m%d)"
    else
        START_NUM="$(TZ="$eff" date -d "${y}-${m}-${RESET_DAY} -1 month" +%Y%m%d)"
    fi
    END_NUM="$(TZ="$eff" date +%Y%m%d)"

    START_HUMAN="$(TZ="$eff" date -d "$START_NUM" +%Y-%m-%d)"
    END_HUMAN="$(TZ="$eff" date -d "$END_NUM" +%Y-%m-%d)"
}

###############################################################################
# 时区健壮性处理
#
# tz_posix_spec <tz>：返回 glibc POSIX 时区串（不依赖 /usr/share/zoneinfo
#   文件，内置解析，避免时区文件损坏时静默回退本地时区）。仅覆盖常见的
#   固定偏移结算时区；其余返回空串，调用方回退到 IANA 文件方式。
###############################################################################
tz_posix_spec() {
    case "$1" in
        UTC|Etc/UTC|Universal|Zulu|GMT|Etc/GMT)
            printf 'UTC0'
            ;;
        Asia/Shanghai|Asia/Hong_Kong|Asia/Macau|Asia/Taipei)
            printf 'CST-8'
            ;;
        Asia/Tokyo|Asia/Seoul|Asia/Pyongyang)
            # 首尔/东京 +9（平壤为 +8:30，极少用于结算，忽略）
            [[ "$1" == "Asia/Pyongyang" ]] && printf 'KST-8:30' || printf 'JST-9'
            ;;
        *)
            printf ''
            ;;
    esac
}

# 实际用于 date 调用的时区标识（优先 POSIX 串）
effective_tz() {
    local spec
    spec="$(tz_posix_spec "$1")"
    printf '%s' "${spec:-$1}"
}

# 时区完整性自检：对比「时区文件」与「POSIX 内置串」的偏移，不一致说明
# /usr/share/zoneinfo 中的该时区文件可能损坏。返回 0=正常，1=异常。
check_tz_integrity() {
    local tz="$1" spec file_z posix_z
    spec="$(tz_posix_spec "$tz")"
    [[ -z "$spec" ]] && return 0    # 非常见固定偏移时区，无法独立校验
    file_z="$(TZ="$tz" date +%z 2>/dev/null || printf '????')"
    posix_z="$(TZ="$spec" date +%z 2>/dev/null || printf '????')"
    [[ "$file_z" == "$posix_z" ]]
}

###############################################################################
# 推送时刻换算：固定北京时间 08:00，换算到结算时区的 Cron 时分
# 输出："分 时"（UTC -> "0 0"，上海 -> "0 8"，东京 -> "0 9"）
# 常见固定偏移时区直接精确给出（不依赖时区文件）；其余时区通过 date 换算。
# 注：若结算时区使用带夏令时的时区，DST 切换前后可能有 1 小时偏差，
# 建议结算时区使用 UTC 或 Asia/Shanghai（均无 DST）。
###############################################################################
get_push_cron_hm() {
    case "$TZ_NAME" in
        UTC|Etc/UTC|Universal|Zulu|GMT|Etc/GMT)
            printf '0 0'      # 北京 08:00 = UTC 00:00
            return ;;
        Asia/Shanghai|Asia/Hong_Kong|Asia/Macau|Asia/Taipei)
            printf '0 8'
            return ;;
        Asia/Tokyo|Asia/Seoul)
            printf '0 9'
            return ;;
    esac

    local eff bj_epoch h m
    eff="$(effective_tz "$TZ_NAME")"
    bj_epoch="$(TZ="$PUSH_TZ" date -d "today ${PUSH_HOUR}:${PUSH_MIN}" +%s)"
    h="$(TZ="$eff" date -d "@$bj_epoch" +%-H)"
    m="$(TZ="$eff" date -d "@$bj_epoch" +%-M)"
    printf '%s %s' "$m" "$h"
}

###############################################################################
# 流量读取：对 vnstat 每日数据按周期求和（兼容新旧 JSON 字段 day/days）
# 用法：get_period_usage <auto|all|iface> <start YYYYMMDD> <end YYYYMMDD>
# 输出：字节数（rx+tx）
###############################################################################
get_period_usage() {
    local __target="$1"
    local __start="$2"
    local __end="$3"
    local __json="" __out=""

    if [[ "$__target" == "all" || "$__target" == "auto" ]]; then
        __json="$(vnstat --json 2>/dev/null)" || __json=""
    else
        __json="$(vnstat -i "$__target" --json 2>/dev/null)" || __json=""
    fi

    if [[ -z "$__json" ]]; then
        printf '0\n'
        return 0
    fi

    # 网卡选择器（片段为内置静态字符串；网卡名已校验存在）
    local __ifsel="true"
    local -a __jargs=()
    local __list="" __list_json=""

    case "$__target" in
        all)
            __ifsel="true"
            ;;
        auto)
            __list="$(get_smart_interfaces)"
            if [[ -z "$__list" ]]; then
                printf '0\n'
                return 0
            fi
            __list_json="$(printf '%s\n' "$__list" | jq -R -s 'split("\n") | map(select(length > 0))')"
            __ifsel='(.name as $n | $ilist | index($n) != null)'
            __jargs+=(--argjson ilist "$__list_json")
            ;;
        *)
            __ifsel='(.name == $iname or .id == $iname)'
            __jargs+=(--arg iname "$__target")
            ;;
    esac

    local __program
    __program='
        [ (.interfaces // [])[]
          | select('"${__ifsel}"')
          | ((.traffic.day // .traffic.days) // [])[]
          | select(
                (.date.year * 10000 + .date.month * 100 + .date.day) >= $s
            and (.date.year * 10000 + .date.month * 100 + .date.day) <= $e)
          | ((.rx // 0) + (.tx // 0))
        ] | add // 0'

    __out="$(printf '%s' "$__json" | jq -r \
        --argjson s "$__start" \
        --argjson e "$__end" \
        "${__jargs[@]}" \
        "$__program" 2>/dev/null)" || __out="0"

    if [[ "$__out" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$__out"
    else
        printf '0\n'
    fi
}

###############################################################################
# 状态锁（按结算周期自动重置：重启不丢、跨周期自动清零）
###############################################################################
state_init() {
    STATE_PERIOD=""
    STATE_WARNED=0
    STATE_SHUT=0

    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE" || true
    fi

    if [[ "${STATE_PERIOD:-}" != "$START_NUM" ]]; then
        STATE_PERIOD="$START_NUM"
        STATE_WARNED=0
        STATE_SHUT=0
        state_save
    fi
}

state_save() {
    mkdir -p "$STATE_DIR"
    {
        printf 'STATE_PERIOD="%s"\n' "$STATE_PERIOD"
        printf 'STATE_WARNED="%s"\n' "$STATE_WARNED"
        printf 'STATE_SHUT="%s"\n' "$STATE_SHUT"
    } > "$STATE_FILE"
}

###############################################################################
# Telegram 发送（成功返回 0）
###############################################################################
tg_send() {
    local __text="$1"
    curl -sS --fail --max-time 20 \
        --data-urlencode "chat_id=${TG_CHAT}" \
        --data-urlencode "text=${__text}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "disable_web_page_preview=true" \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        >/dev/null 2>&1
}

###############################################################################
# 限额与百分比
###############################################################################
get_limit_bytes() {
    awk -v g="$LIMIT_GB" 'BEGIN { printf "%.0f", g * 1024 * 1024 * 1024 }'
}

get_pct() {
    local __used="$1"
    local __limit_bytes="$2"
    awk -v u="$__used" -v l="$__limit_bytes" \
        'BEGIN { if (l <= 0) print "0.00"; else printf "%.2f", u * 100 / l }'
}

# auto 模式下实际参与统计的网卡，逗号分隔
get_resolved_ifaces_text() {
    if [[ "$IFACE" == "auto" ]]; then
        printf '%s' "$(get_smart_interfaces | paste -sd, -)"
    else
        printf '%s' "$IFACE"
    fi
}

# 统一的时间标注行：北京时间始终显示；结算时区不同则追加显示
time_lines() {
    local bj now_tz eff
    bj="$(TZ="$PUSH_TZ" date '+%Y-%m-%d %H:%M:%S')"
    printf '🕗 北京时间：%s\n' "$bj"
    if [[ "$TZ_NAME" != "$PUSH_TZ" ]]; then
        eff="$(effective_tz "$TZ_NAME")"
        now_tz="$(TZ="$eff" date '+%Y-%m-%d %H:%M:%S %Z')"
        printf '🕒 结算时区时间（%s）：%s\n' "$TZ_NAME" "$now_tz"
    fi
}

###############################################################################
# 消息构建
###############################################################################
build_report() {
    local __used="$1"
    local __pct="$2"
    local __limit_bytes="$3"
    local __name __resolved
    __name="$(html_escape "$SERVER_NAME")"
    __resolved="$(html_escape "$(get_resolved_ifaces_text)")"

    echo "📊 <b>服务器流量日报</b>
🖥 服务器：<b>${__name}</b>
📅 结算周期：<b>${START_HUMAN} ~ ${END_HUMAN}</b>（结算时区 ${TZ_NAME}，每月 ${RESET_DAY} 日重置）
🔌 监控网卡：<b>${IFACE}</b>（${__resolved}）"

    if (( __limit_bytes <= 0 )); then
        echo "📈 当前已用：<b>$(fmt_auto "$__used")</b>（未设置月度限额）
📊 使用比例：—"
    else
        echo "📈 当前已用：<b>$(fmt_auto "$__used")</b> / $(fmt_gib "$__limit_bytes") GB
📊 使用比例：<b>${__pct}%</b>"
    fi

    echo "⚠️ 预警阈值：${WARN_PCT}%　🛑 关机阈值：${SHUTDOWN_PCT}%"
    time_lines
}

build_warn_text() {
    local __used="$1"
    local __pct="$2"
    local __limit_bytes="$3"
    local __name __resolved
    __name="$(html_escape "$SERVER_NAME")"
    __resolved="$(html_escape "$(get_resolved_ifaces_text)")"

    cat <<EOF
⚠️ <b>流量预警通知</b>
🖥 服务器：<b>${__name}</b>
📅 结算周期：${START_HUMAN} ~ ${END_HUMAN}（结算时区 ${TZ_NAME}，每月 ${RESET_DAY} 日重置）
🔌 监控网卡：${IFACE}（${__resolved}）
📈 当前已用：<b>$(fmt_auto "$__used")</b> / $(fmt_gib "$__limit_bytes") GB
📊 使用比例：<b>${__pct}%</b>（已达预警线 ${WARN_PCT}%）
🛑 关机线：${SHUTDOWN_PCT}%，达到后将自动关机，请及时处理！
EOF
    time_lines
}

build_shutdown_text() {
    local __used="$1"
    local __pct="$2"
    local __limit_bytes="$3"
    local __name __resolved
    __name="$(html_escape "$SERVER_NAME")"
    __resolved="$(html_escape "$(get_resolved_ifaces_text)")"

    cat <<EOF
🛑 <b>紧急：流量超限，服务器即将关机！</b>
🖥 服务器：<b>${__name}</b>
📅 结算周期：${START_HUMAN} ~ ${END_HUMAN}（结算时区 ${TZ_NAME}，每月 ${RESET_DAY} 日重置）
🔌 监控网卡：${IFACE}（${__resolved}）
📈 当前已用：<b>$(fmt_auto "$__used")</b> / $(fmt_gib "$__limit_bytes") GB
📊 使用比例：<b>${__pct}%</b>（已达关机线 ${SHUTDOWN_PCT}%）
⏳ 系统将在 5 秒后自动关机，以避免产生超额流量费用！
EOF
    time_lines
}

###############################################################################
# 日报
###############################################################################
cmd_report() {
    load_config
    calc_period

    local used limit_bytes pct
    used="$(get_period_usage "$IFACE" "$START_NUM" "$END_NUM")"
    limit_bytes="$(get_limit_bytes)"
    pct="$(get_pct "$used" "$limit_bytes")"

    local msg
    msg="$(build_report "$used" "$pct" "$limit_bytes")"

    printf '%s\n' "$msg"
    if tg_send "$msg"; then
        log "日报已发送至 Telegram（北京时间 08:00 统一推送）。"
    else
        log "Telegram 日报发送失败（将在下次定时任务重试）。"
    fi
}

###############################################################################
# 阈值检查（预警 / 关机）
###############################################################################
cmd_check() {
    load_config
    calc_period

    # 无限制模式：不做阈值检查
    if awk -v v="$LIMIT_GB" 'BEGIN { exit !(v+0 == 0) }'; then
        log "月度限额为 0（无限制），跳过阈值检查。"
        return 0
    fi

    state_init

    local used limit_bytes pct
    used="$(get_period_usage "$IFACE" "$START_NUM" "$END_NUM")"
    limit_bytes="$(get_limit_bytes)"

    if (( limit_bytes <= 0 )); then
        log "流量限额配置异常(<=0)，跳过本次检查。"
        return 0
    fi

    pct="$(get_pct "$used" "$limit_bytes")"
    log "周期 ${START_HUMAN}~${END_HUMAN}(${TZ_NAME}) 已用 $(fmt_auto "$used")，占比 ${pct}%"

    local msg=""

    # 预警线（状态锁防重复；发送失败不落锁，下周期重试）
    if awk -v p="$pct" -v t="$WARN_PCT" 'BEGIN { exit !(p + 0 >= t + 0) }'; then
        if [[ "$STATE_WARNED" -eq 0 ]]; then
            msg="$(build_warn_text "$used" "$pct" "$limit_bytes")"
            if tg_send "$msg"; then
                STATE_WARNED=1
                state_save
                log "已达预警线 ${WARN_PCT}%，预警通知已发送。"
            else
                log "预警通知发送失败，下个检查周期将重试。"
            fi
        fi
    fi

    # 关机线（紧急通知一次；无论通知是否成功都执行关机保护）
    if awk -v p="$pct" -v t="$SHUTDOWN_PCT" 'BEGIN { exit !(p + 0 >= t + 0) }'; then
        if [[ "$STATE_SHUT" -eq 0 ]]; then
            msg="$(build_shutdown_text "$used" "$pct" "$limit_bytes")"
            tg_send "$msg" || log "紧急通知发送失败，仍将执行关机。"
            STATE_SHUT=1
            state_save
        fi

        log "已达关机线 ${SHUTDOWN_PCT}%，5 秒后执行关机！"
        sync
        sleep 5

        if command -v systemctl >/dev/null 2>&1; then
            systemctl poweroff || shutdown -h now
        else
            shutdown -h now
        fi
    fi
}

###############################################################################
# 程序自安装（复制到 /opt 并创建软链接；mv 切换 inode，避免运行中截断）
###############################################################################
self_install() {
    mkdir -p "$INSTALL_DIR"
    if [[ "$SELF" != "$INSTALL_SCRIPT" ]]; then
        cp "$SELF" "${INSTALL_DIR}/.traffic-monitor.sh.new"
        chmod 0755 "${INSTALL_DIR}/.traffic-monitor.sh.new"
        mv -f "${INSTALL_DIR}/.traffic-monitor.sh.new" "$INSTALL_SCRIPT"
    fi
    chmod 0755 "$INSTALL_SCRIPT"
    ln -sfn "$INSTALL_SCRIPT" "$LINK_PATH"
    log "程序已安装至 ${INSTALL_SCRIPT}，快捷命令: ${LINK_PATH}"
}

###############################################################################
# Cron 管理
###############################################################################
cron_remove() {
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v 'TRAFFIC_MONITOR' > "$tmp" || true
    crontab "$tmp" 2>/dev/null || true
    rm -f "$tmp"
}

cron_install() {
    cron_remove

    local hm ch cm
    hm="$(get_push_cron_hm)"
    cm="${hm%% *}"   # 分
    ch="${hm##* }"   # 时

    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null > "$tmp" || true
    cat >> "$tmp" <<EOF
# TRAFFIC_MONITOR env
${CRON_PATH_LINE}
# TRAFFIC_MONITOR report - 北京时间每天 08:00 推送日报（结算时区 ${TZ_NAME} 下 ${ch}:${cm} 触发）
${cm} ${ch} * * * ${LINK_PATH} --cron-report >> ${LOG_FILE} 2>&1
# TRAFFIC_MONITOR check - 每 ${CHECK_INTERVAL} 分钟检查阈值
*/${CHECK_INTERVAL} * * * * ${LINK_PATH} --cron-check >> ${LOG_FILE} 2>&1
EOF
    crontab "$tmp" || die "crontab 安装失败。"
    rm -f "$tmp"
    log "Cron 已安装：日报固定北京时间 08:00（结算时区 ${TZ_NAME} 下 ${ch}:${cm} 触发）/ 阈值检查每 ${CHECK_INTERVAL} 分钟。"
}

###############################################################################
# 交互式配置向导（回显当前值，回车保持不变）
###############################################################################
cmd_config() {
    require_root

    echo "==========================================================="
    echo "  Telegram 流量监控 - 交互式配置向导（Debian 13 Trixie）"
    echo "==========================================================="

    install_dependencies

    # 预填已有配置（首次安装则使用内置默认值）
    set_config_defaults
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE" || true
        echo "检测到已有配置，直接回车可保持当前值。"
    fi

    local cur_token="$TG_TOKEN" cur_chat="$TG_CHAT"
    local token="$cur_token" chat="$cur_chat"
    local sname="$SERVER_NAME" limit_gb="$LIMIT_GB"
    local wpct="$WARN_PCT" spct="$SHUTDOWN_PCT"
    local iface="$IFACE" rday="$RESET_DAY" tzname="$TZ_NAME"
    local cint="$CHECK_INTERVAL"

    local smart_list="" all_list="" item="" input="" shown=""
    smart_list="$(get_smart_interfaces | paste -sd, -)"
    smart_list="${smart_list:-未检测到物理网卡}"
    for item in /sys/class/net/*; do
        item="$(basename "$item")"
        [[ "$item" == "lo" ]] && continue
        all_list="${all_list}${all_list:+,}${item}"
    done
    all_list="${all_list:-无}"

    # 1) Bot Token
    if [[ -n "$cur_token" ]]; then
        shown="${cur_token:0:8}****"
        read -r -p "1) Telegram Bot Token [当前: ${shown}，回车保持]: " input || input=""
        [[ -n "$input" ]] && token="$input"
    else
        while :; do
            read -r -p "1) Telegram Bot Token（向 @BotFather 创建机器人获取）: " input || input=""
            if [[ -n "$input" ]]; then token="$input"; break; fi
            echo "   Bot Token 不能为空。"
        done
    fi

    # 2) Chat ID
    if [[ -n "$cur_chat" ]]; then
        read -r -p "2) Telegram Chat ID [当前: ${cur_chat}，回车保持]: " input || input=""
        [[ -n "$input" ]] && chat="$input"
    else
        while :; do
            read -r -p "2) Telegram Chat ID（私聊为数字ID，频道形如 -100xxxxxxxxxx）: " input || input=""
            if [[ -n "$input" ]]; then chat="$input"; break; fi
            echo "   Chat ID 不能为空。"
        done
    fi

    # 3) 服务器名称
    ask_default sname "3) 服务器名称（报告中显示）" "$sname"

    # 4) 每月流量上限（0 = 无限制）
    while :; do
        ask_default limit_gb "4) 每月流量上限（GB，可小数；0=无限制）" "$limit_gb"
        if is_nonneg_number "$limit_gb"; then break; fi
        echo "   请输入非负数字。"
    done

    # 5) 预警百分比
    while :; do
        ask_default wpct "5) 预警百分比（1-99 的整数）" "$wpct"
        if is_uint "$wpct" && (( wpct >= 1 && wpct <= 99 )); then break; fi
        echo "   请输入 1-99 之间的整数。"
    done

    # 6) 关机百分比
    while :; do
        ask_default spct "6) 关机百分比（须大于预警值，最大 100）" "$spct"
        if is_uint "$spct" && (( spct > wpct && spct <= 100 )); then break; fi
        echo "   请输入大于 ${wpct} 且不超过 100 的整数。"
    done

    # 7) 监控网卡
    echo "   智能识别物理网卡: ${smart_list}"
    echo "   系统全部网卡    : ${all_list}"
    while :; do
        ask_default iface "7) 监控网卡（auto=智能物理网卡 / all=全部 / 或指定名称）" "$iface"
        if [[ "$iface" == "auto" || "$iface" == "all" || -d "/sys/class/net/${iface}" ]]; then break; fi
        echo "   网卡 ${iface} 不存在，请重新输入。"
    done

    # 8) 重置日
    while :; do
        ask_default rday "8) 每月流量重置日（1-28 的整数）" "$rday"
        if is_uint "$rday" && (( rday >= 1 && rday <= 28 )); then break; fi
        echo "   请输入 1-28 之间的整数。"
    done

    # 9) 结算时区（仅决定流量重置边界）
    echo "   说明：结算时区只决定流量重置边界；日报固定北京时间 08:00 推送，与此无关。"
    echo "        国外 VPS（商家按 UTC0 重置）通常填 UTC；国内填 Asia/Shanghai。"
    while :; do
        ask_default tzname "9) 结算时区（IANA 名称）" "$tzname"
        if [[ ! -f "/usr/share/zoneinfo/${tzname}" ]]; then
            echo "   时区 ${tzname} 不存在，例如 UTC、Asia/Shanghai、Asia/Tokyo。"
            continue
        fi
        if ! check_tz_integrity "$tzname"; then
            echo "   ⚠️ 警告：系统中 ${tzname} 的时区文件异常（与标准偏移不符，可能已损坏）。"
            echo "      本脚本对该常用时区将按标准偏移直接计算，不影响使用；如需彻底修复可执行："
            echo "      apt-get install --reinstall tzdata"
        fi
        break
    done

    # 10) 检查间隔
    while :; do
        ask_default cint "10) 阈值检查间隔（分钟，建议 1/2/5/10/15）" "$cint"
        if is_uint "$cint" && (( cint >= 1 && cint <= 59 )); then break; fi
        echo "    请输入 1-59 之间的整数。"
    done

    # 写入配置文件
    mkdir -p "$CONFIG_DIR" "$STATE_DIR"
    cat > "$CONFIG_FILE" <<EOF
# Telegram 流量监控配置（由 --config 向导生成）
TG_TOKEN="${token}"
TG_CHAT="${chat}"
SERVER_NAME="${sname}"
LIMIT_GB="${limit_gb}"
WARN_PCT="${wpct}"
SHUTDOWN_PCT="${spct}"
IFACE="${iface}"
RESET_DAY="${rday}"
TZ_NAME="${tzname}"
CHECK_INTERVAL="${cint}"
EOF
    chmod 0600 "$CONFIG_FILE"
    log "配置已写入 ${CONFIG_FILE}（权限 0600）。"

    # vnstat 准备、自安装、Cron
    prepare_vnstat "$iface"
    self_install
    cron_install

    # 测试消息
    local test_msg
    test_msg="✅ <b>流量监控部署成功</b>
🖥 服务器：<b>$(html_escape "$sname")</b>
📅 结算时区 ${tzname}，每月 ${rday} 日重置，限额 ${limit_gb} GB（0=无限制）
⚠️ 预警 ${wpct}%　🛑 关机 ${spct}%
🔌 监控网卡：${iface}
⏰ 日报固定北京时间 08:00 推送，每 ${cint} 分钟检查阈值"
    if tg_send "$test_msg"; then
        log "Telegram 连接测试成功，部署消息已发送。"
    else
        log "Telegram 测试消息发送失败，请检查 Bot Token 与 Chat ID 后重新运行 --config。"
    fi

    echo "==========================================================="
    echo "  部署完成！常用命令："
    echo "    traffic --status    查看状态"
    echo "    traffic --report    立即发送日报"
    echo "    traffic --check     立即检查阈值"
    echo "    traffic --uninstall 卸载"
    echo "==========================================================="
}

###############################################################################
# 状态查看
###############################################################################
cmd_status() {
    load_config
    calc_period

    local used limit_bytes pct vnstat_active resolved push_hm
    used="$(get_period_usage "$IFACE" "$START_NUM" "$END_NUM")"
    limit_bytes="$(get_limit_bytes)"
    pct="$(get_pct "$used" "$limit_bytes")"
    vnstat_active="$(systemctl is-active vnstat.service 2>/dev/null || echo unknown)"
    resolved="$(get_resolved_ifaces_text)"
    push_hm="$(get_push_cron_hm)"

    echo "==========================================================="
    echo "  Telegram 流量监控 - 运行状态"
    echo "==========================================================="
    printf '配置文件      : %s\n' "$CONFIG_FILE"
    printf '服务器名称    : %s\n' "$SERVER_NAME"
    printf '监控网卡模式  : %s\n' "$IFACE"
    printf '实际统计网卡  : %s\n' "$resolved"
    printf '结算时区      : %s（仅用于流量重置边界）\n' "$TZ_NAME"
    printf '每月重置日    : %s 日（按结算时区）\n' "$RESET_DAY"
    printf '当前结算周期  : %s ~ %s\n' "$START_HUMAN" "$END_HUMAN"
    if (( limit_bytes <= 0 )); then
        printf '每月流量上限  : 无限制\n'
        printf '当前已用      : %s\n' "$(fmt_auto "$used")"
    else
        printf '每月流量上限  : %s GB\n' "$LIMIT_GB"
        printf '当前已用      : %s (%s%%)\n' "$(fmt_auto "$used")" "$pct"
    fi
    printf '预警/关机阈值 : %s%% / %s%%\n' "$WARN_PCT" "$SHUTDOWN_PCT"
    printf '日报推送      : 固定北京时间 08:00（结算时区 %s 下 %s 触发）\n' "$TZ_NAME" "${push_hm// /:}"
    printf '阈值检查间隔  : 每 %s 分钟\n' "$CHECK_INTERVAL"
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE" || true
    fi
    printf '预警已发送    : %s\n' "$([[ "${STATE_WARNED:-0}" -eq 1 ]] && echo 是 || echo 否)"
    printf '关机警报已发送: %s\n' "$([[ "${STATE_SHUT:-0}" -eq 1 ]] && echo 是 || echo 否)"
    printf 'vnstat 服务   : %s\n' "$vnstat_active"
    printf '日志文件      : %s\n' "$LOG_FILE"
    echo "-----------------------------------------------------------"
    echo "Cron 定时任务:"
    if crontab -l 2>/dev/null | grep -q 'TRAFFIC_MONITOR'; then
        crontab -l 2>/dev/null | grep 'TRAFFIC_MONITOR' | sed 's/^/  /'
    else
        echo "  (未配置)"
    fi
    echo "==========================================================="
}

###############################################################################
# 卸载
###############################################################################
uninstall_perform() {
    echo "即将卸载 Telegram 流量监控。"
    local reply=""

    read -r -p "确认卸载？输入 y 继续: " reply || reply=""
    [[ "$reply" == "y" ]] || { echo "已取消卸载。"; exit 0; }

    cron_remove
    rm -f "$LINK_PATH"
    echo "已移除 Cron 任务与软链接 ${LINK_PATH}。"

    read -r -p "是否删除配置与状态数据（${CONFIG_DIR}、${STATE_DIR}、${LOG_FILE}）？[y/N]: " reply || reply=""
    if [[ "$reply" == "y" ]]; then
        rm -rf "$CONFIG_DIR" "$STATE_DIR" "$LOG_FILE"
        echo "配置与状态数据已删除。"
    fi

    read -r -p "是否删除程序目录 ${INSTALL_DIR}？[Y/n]: " reply || reply=""
    if [[ "$reply" != "n" ]]; then
        rm -rf "$INSTALL_DIR"
        echo "程序目录已删除。"
    fi

    read -r -p "是否通过 apt 卸载 vnstat/jq/curl/gawk/cron（如其他程序需要请选 n）？[y/N]: " reply || reply=""
    if [[ "$reply" == "y" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y vnstat jq curl gawk cron iproute2 || true
        apt-get autoremove -y || true
        echo "相关软件包已卸载。"
    fi

    rm -f /tmp/.traffic-monitor-uninstall.sh
    echo "卸载完成。"
}

cmd_uninstall() {
    require_root
    # 若正从安装目录运行，复制到 /tmp 再执行，避免删除自身导致异常
    if [[ "$SELF" == "${INSTALL_DIR}/"* ]]; then
        cp "$SELF" /tmp/.traffic-monitor-uninstall.sh
        chmod 0755 /tmp/.traffic-monitor-uninstall.sh
        exec /tmp/.traffic-monitor-uninstall.sh --uninstall-perform
    fi
    uninstall_perform
}

###############################################################################
# 帮助
###############################################################################
usage() {
    cat <<'EOF'
Telegram 流量监控与自动化管理脚本（Debian 13 Trixie）

时区语义:
  - 日报推送：固定每天「北京时间 08:00」，自动换算到结算时区写入 Cron
  - 结算时区 TZ_NAME：仅决定流量重置边界（国外 VPS 填 UTC，国内填 Asia/Shanghai）

网卡模式:
  auto     智能模式（默认，仅物理/上行网卡，排除 docker/veth/bridge/wg/tun）
  all      vnstat 数据库中的全部网卡
  <名称>   指定单网卡（如 eth0、ens3、ppp0）

用法:
  traffic --config       交互式配置向导（保留当前值，回车跳过）
  traffic --status       查看配置、周期用量、阈值与定时任务状态
  traffic --report       立即生成并发送一次 HTML 日报
  traffic --check        立即执行一次阈值检查（预警/关机）
  traffic --cron-report  Cron 调用：日报（输出写日志）
  traffic --cron-check   Cron 调用：阈值检查（输出写日志）
  traffic --uninstall    一键卸载清理
  traffic -h, --help     显示本帮助
EOF
}

###############################################################################
# 入口
###############################################################################
case "${1:-}" in
    ""|-h|--help)
        usage
        ;;
    --config)
        cmd_config
        ;;
    --status)
        require_root
        cmd_status
        ;;
    --report)
        require_root
        cmd_report
        ;;
    --check)
        require_root
        cmd_check
        ;;
    --cron-report)
        require_root
        cmd_report
        ;;
    --cron-check)
        require_root
        cmd_check
        ;;
    --uninstall)
        cmd_uninstall
        ;;
    --uninstall-perform)
        require_root
        uninstall_perform
        ;;
    *)
        printf '未知参数: %s\n\n' "$1" >&2
        usage
        exit 1
        ;;
esac
