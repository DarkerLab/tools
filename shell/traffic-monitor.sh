#!/usr/bin/env bash
#===============================================================================
# vnstat 流量监控助手 v2.9
#===============================================================================
set -u

VERSION="2.9"
REPO_URL="https://raw.githubusercontent.com/DarkerLab/tools/main/shell/traffic-monitor.sh"
MIN_VNSTAT_VER="2.7"
VNSTAT_FALLBACK_VER="2.12"
VNSTAT_SRC_BASE="https://humdi.net/vnstat"

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
INSTALL_PATH="/usr/local/bin/traffic-monitor.sh"
CONF_DIR="/etc/traffic-monitor"
CONF_FILE="${CONF_DIR}/config.conf"
STATE_DIR="/var/lib/traffic-monitor"
STATE_FILE="${STATE_DIR}/state.env"
LOG_DIR="/var/log/traffic-monitor"
LOG_FILE="${LOG_DIR}/monitor.log"
CRON_FILE="/etc/cron.d/traffic-monitor"
LOCK_FILE="/run/traffic-monitor.lock"
VNSTAT_CONF="/etc/vnstat.conf"

DEF_WARN_PCT=90
DEF_SHUTDOWN_PCT=95
DEF_CHECK_INTERVAL=1
DEF_REPORT_HOUR=8
DEF_REPORT_MIN=0

_log() {
    local level="$1"; shift
    local ts; ts="$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$LOG_DIR" 2>/dev/null
    echo "[${ts}] [${level}] $*" >> "$LOG_FILE" 2>/dev/null
}
log_info()  { _log "INFO " "$*"; }
log_warn()  { _log "WARN " "$*"; }
log_error() { _log "ERROR" "$*"; }

die() {
    echo -e "\033[31m[错误] $*\033[0m" >&2
    log_error "$*"
    exit 1
}

ok()   { echo -e "\033[32m[成功] $*\033[0m"; }
info() { echo -e "\033[36m[信息] $*\033[0m"; }
warn() { echo -e "\033[33m[警告] $*\033[0m"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 权限运行本脚本（sudo bash $0）"
    fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ver_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        split(a, x, "."); split(b, y, ".");
        exit !((x[1]+0 < y[1]+0) || (x[1]+0 == y[1]+0 && x[2]+0 < y[2]+0))
    }'
}

load_config() {
    if [ -f "$CONF_FILE" ]; then
        . "$CONF_FILE"
        return 0
    fi
    return 1
}

load_state() {
    WARN_PERIOD=""
    if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE"
    fi
}

save_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
WARN_PERIOD="${WARN_PERIOD:-}"
EOF
    chmod 600 "$STATE_FILE"
}

validate_config() {
    local missing=""
    [ -z "${SERVER_NAME:-}"     ] && missing="$missing SERVER_NAME"
    [ -z "${INTERFACES:-}"      ] && missing="$missing INTERFACES"
    [ -z "${BILLING_DAY:-}"     ] && missing="$missing BILLING_DAY"
    [ -z "${TRAFFIC_TYPE:-}"    ] && missing="$missing TRAFFIC_TYPE"
    [ -z "${TG_BOT_TOKEN:-}"    ] && missing="$missing TG_BOT_TOKEN"
    [ -z "${TG_CHAT_ID:-}"      ] && missing="$missing TG_CHAT_ID"
    [ -z "${MONTHLY_LIMIT_GB:-}" ] && missing="$missing MONTHLY_LIMIT_GB"
    if [ -n "$missing" ]; then
        die "配置缺失或不完整:${missing}，请先执行「安装部署/修改配置」"
    fi
    case "$TRAFFIC_TYPE" in 1|2|3) ;; *) die "TRAFFIC_TYPE 非法（应为 1/2/3）";; esac
    if ! awk -v v="$MONTHLY_LIMIT_GB" 'BEGIN{exit !(v>0)}'; then
        die "MONTHLY_LIMIT_GB 非法（应为大于 0 的数值）"
    fi
    if ! echo "$BILLING_DAY" | grep -qE '^[0-9]+$' || [ "$BILLING_DAY" -lt 1 ] || [ "$BILLING_DAY" -gt 28 ]; then
        die "BILLING_DAY 非法（应为 1-28 的整数）"
    fi
}

tg_send() {
    local text="$1" resp
    resp="$(curl -s -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "disable_web_page_preview=true" 2>/dev/null)"
    if printf '%s' "$resp" | grep -q '"ok":true'; then
        return 0
    fi
    log_error "Telegram 发送失败，API 返回: ${resp:0:300}"
    return 1
}

tg_send_retry() {
    local text="$1" retries="${2:-2}" i=1
    while [ "$i" -le $((retries + 1)) ]; do
        if tg_send "$text"; then
            log_info "Telegram 消息发送成功（第 ${i} 次尝试）"
            return 0
        fi
        log_warn "Telegram 消息发送失败（第 ${i}/$((retries + 1)) 次尝试）"
        [ "$i" -le "$retries" ] && sleep 3
        i=$((i + 1))
    done
    return 1
}

get_used_bytes() {
    local json rx tx
    # 直接使用组合接口名称查询，不再拆分
    json="$(vnstat --json d -i "$INTERFACES" 2>/dev/null)" || return 1
    [ -z "$json" ] && return 1
    
    # 获取当前 UTC 年月日
    local cur_y cur_m cur_d
    read -r cur_y cur_m cur_d <<< "$(TZ=UTC date +'%Y %m %d')"
    cur_m=$((10#$cur_m)); cur_d=$((10#$cur_d))
    
    local start_y start_m
    if [ "$cur_d" -ge "$BILLING_DAY" ]; then
        start_y=$cur_y
        start_m=$cur_m
    else
        start_y=$cur_y
        start_m=$((cur_m - 1))
        if [ "$start_m" -eq 0 ]; then
            start_m=12
            start_y=$((start_y - 1))
        fi
    fi
    
    local start_date_str
    start_date_str=$(printf "%04d-%02d-%02d" "$start_y" "$start_m" "$BILLING_DAY")
    
    # 通过 jq 极强的兼容性处理：不管返回一个还是多个接口，自动扁平化；不管有没有 id，自动按日期拼接比对
    rx="$(echo "$json" | jq --arg s "$start_date_str" '
        [ .interfaces[]?.traffic.days[]? 
          | . as $d
          | (if $d.id then $d.id 
             else "\($d.date.year | tostring | if length < 4 then ("0000" + .)[-4:] else . end)-\($d.date.month | tostring | if length < 2 then ("0" + .)[-2:] else . end)-\($d.date.day | tostring | if length < 2 then ("0" + .)[-2:] else . end)" 
             end) as $dayid
          | select($dayid >= $s)
          | $d.rx // 0 
        ] | add // 0
    ' 2>/dev/null)"
    
    tx="$(echo "$json" | jq --arg s "$start_date_str" '
        [ .interfaces[]?.traffic.days[]? 
          | . as $d
          | (if $d.id then $d.id 
             else "\($d.date.year | tostring | if length < 4 then ("0000" + .)[-4:] else . end)-\($d.date.month | tostring | if length < 2 then ("0" + .)[-2:] else . end)-\($d.date.day | tostring | if length < 2 then ("0" + .)[-2:] else . end)" 
             end) as $dayid
          | select($dayid >= $s)
          | $d.tx // 0 
        ] | add // 0
    ' 2>/dev/null)"
    
    rx="${rx:-0}"; tx="${tx:-0}"
    RX_BYTES="$rx"; TX_BYTES="$tx"
    case "$TRAFFIC_TYPE" in
        1) echo $((rx + tx)) ;;
        2) echo "$tx" ;;
        3) echo "$rx" ;;
    esac
}

get_period_info() {
    local cur_y cur_m cur_d
    read -r cur_y cur_m cur_d <<< "$(TZ=UTC date +'%Y %m %d')"
    cur_m=$((10#$cur_m)); cur_d=$((10#$cur_d))
    
    local start_y start_m
    if [ "$cur_d" -ge "$BILLING_DAY" ]; then
        start_y=$cur_y
        start_m=$cur_m
    else
        start_y=$cur_y
        start_m=$((cur_m - 1))
        if [ "$start_m" -eq 0 ]; then
            start_m=12
            start_y=$((start_y - 1))
        fi
    fi
    PERIOD_ID="$(printf "%04d-%02d" "$start_y" "$start_m")"
    PERIOD_START="$(printf "%04d-%02d-%02d" "$start_y" "$start_m" "$BILLING_DAY")"
}

fmt_traffic() {
    local b="$1"
    awk -v b="$b" 'BEGIN{
        if (b < 1000) printf "%.2f B", b;
        else if (b < 1000000) printf "%.2f KB", b/1000;
        else if (b < 1000000000) printf "%.2f MB", b/1000000;
        else printf "%.2f GB", b/1000000000;
    }'
}

calc_pct() {
    awk -v u="$1" -v l="$2" 'BEGIN{
        limit = l * 1000000000;
        if (limit <= 0) { print "0.00"; exit }
        printf "%.2f", u/limit*100
    }'
}

pct_ge() { awk -v p="$1" -v t="$2" 'BEGIN{exit !(p >= t)}'; }

traffic_type_name() {
    case "$1" in
        1) echo "总流量(上传+下载)" ;;
        2) echo "上传流量" ;;
        3) echo "下载流量" ;;
        *) echo "未知" ;;
    esac
}

now_beijing() { TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S'; }

build_report_msg() {
    local used="$1" pct="$2"
    cat <<EOF
📊 每日流量报告
━━━━━━━━━━━━━━━
🖥 服务器：${SERVER_NAME}
📶 计费流量：$(fmt_traffic "$used") / ${MONTHLY_LIMIT_GB} GB（${pct}%）
🔼 上传：$(fmt_traffic "${TX_BYTES:-0}")   🔽 下载：$(fmt_traffic "${RX_BYTES:-0}")
📋 统计类型：$(traffic_type_name "$TRAFFIC_TYPE")
🗓 账单周期：${PERIOD_START}（UTC0）起 至当前
🌐 监控网口：${INTERFACES}
🕗 时间：$(now_beijing)（北京时间）
EOF
}

build_warn_msg() {
    local used="$1" pct="$2"
    cat <<EOF
⚠️ 流量预警通知（已达 ${pct}%）
━━━━━━━━━━━━━━━
🖥 服务器：${SERVER_NAME}
📶 计费流量：$(fmt_traffic "$used") / ${MONTHLY_LIMIT_GB} GB（${pct}%）
🚨 预警阈值：${WARN_PCT}%（已触发）  关机阈值：${SHUTDOWN_PCT}%
🗓 账单周期：${PERIOD_START}（UTC0）起 至当前
请尽快处理，达到 ${SHUTDOWN_PCT}% 将自动关机！
🕗 时间：$(now_beijing)（北京时间）
EOF
}

build_shutdown_msg() {
    local used="$1" pct="$2"
    cat <<EOF
🛑 流量超限关机通知（已达 ${pct}%）
━━━━━━━━━━━━━━━
🖥 服务器：${SERVER_NAME}
📶 计费流量：$(fmt_traffic "$used") / ${MONTHLY_LIMIT_GB} GB（${pct}%）
🚨 已触达关机阈值 ${SHUTDOWN_PCT}%，服务器将在 30 秒后执行自动关机！
🗓 账单周期：${PERIOD_START}（UTC0）起 至当前
🕗 时间：$(now_beijing)（北京时间）
EOF
}

install_deps() {
    info "检查并安装软件依赖（vnstat curl jq cron tzdata）..."
    log_info "开始安装依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >>"$LOG_FILE" 2>&1 || warn "apt-get update 出现告警，继续尝试安装"
    local pkgs=""
    have_cmd vnstat || pkgs="$pkgs vnstat"
    have_cmd curl   || pkgs="$pkgs curl"
    have_cmd jq     || pkgs="$pkgs jq"
    have_cmd cron 2>/dev/null || [ -d /etc/cron.d ] || pkgs="$pkgs cron"
    pkgs="$pkgs tzdata"
    apt-get install -y $pkgs >>"$LOG_FILE" 2>&1 || die "依赖安装失败，请检查网络或 apt 源，详见 $LOG_FILE"
    have_cmd vnstat || die "vnstat 安装失败"
    have_cmd curl   || die "curl 安装失败"
    have_cmd jq     || die "jq 安装失败，请检查网络"
    local ver
    ver="$(vnstat --version 2>/dev/null | head -n1)"
    info "依赖就绪：${ver}"
    log_info "依赖安装完成：${ver}"
}

set_timezone() {
    local cur=""
    if have_cmd timedatectl; then cur="$(timedatectl show -p Timezone --value 2>/dev/null)"; fi
    [ -z "$cur" ] && [ -f /etc/timezone ] && cur="$(tr -d '[:space:]' < /etc/timezone)"
    if [ "$cur" = "Asia/Shanghai" ]; then
        info "系统时区已是 Asia/Shanghai，跳过设置"
        log_info "系统时区已是 Asia/Shanghai，跳过"
        return 0
    fi
    info "设置系统时区为 Asia/Shanghai（当前：${cur:-未知}）..."
    if have_cmd timedatectl; then
        timedatectl set-timezone Asia/Shanghai || die "时区设置失败"
    else
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
    fi
    ok "系统时区已设置为 Asia/Shanghai"
    log_info "系统时区已设置为 Asia/Shanghai（原：${cur:-未知}）"
}

set_vnstat_conf() {
    local key="$1" val="$2"
    if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$VNSTAT_CONF" 2>/dev/null; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" "$VNSTAT_CONF"
    else
        echo "${key} ${val}" >> "$VNSTAT_CONF"
    fi
}

detect_interfaces() {
    ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|veth|br-|virbr|vmnet|tun[0-9]*$)' | tr '\n' ' '
}

prompt_config() {
    local detected def val
    detected="$(detect_interfaces)"
    echo
    echo "─────────────── 参数配置（直接回车保留默认/原值） ───────────────"

    def="${SERVER_NAME:-$(hostname)}"
    read -r -p "服务器名称 [${def}]: " val
    SERVER_NAME="${val:-$def}"

    echo "检测到可用网卡：${detected:-无}"
    def="${INTERFACES:-$(echo "$detected" | awk '{print $1}')}"
    read -r -p "监控网口（多网口用 + 连接，如 ens18+ens19）[${def}]: " val
    INTERFACES="${val:-$def}"
    INTERFACES="$(echo "$INTERFACES" | sed 's/，/+/g; s/、/+/g; s/[[:space:],]+*/+/g; s/++*/+/g; s/^+//; s/+$//')"
    [ -z "$INTERFACES" ] && die "监控网口不能为空"
    local IFS_SAVE="$IFS" iface
    IFS='+'
    for iface in $INTERFACES; do
        [ -d "/sys/class/net/${iface}" ] || die "网卡 ${iface} 不存在，请重新配置"
    done
    IFS="$IFS_SAVE"

    def="${BILLING_DAY:-1}"
    while true; do
        read -r -p "每月账单流量重置日（1-28，UTC0 零点重置）[${def}]: " val
        BILLING_DAY="${val:-$def}"
        if echo "$BILLING_DAY" | grep -qE '^[0-9]+$' && [ "$BILLING_DAY" -ge 1 ] && [ "$BILLING_DAY" -le 28 ]; then
            break
        fi
        warn "重置日必须为 1-28 的整数，请重新输入"
    done

    def="${TRAFFIC_TYPE:-1}"
    while true; do
        echo "流量统计类型：1=总流量(上传+下载)  2=上传流量  3=下载流量"
        read -r -p "请选择 [${def}]: " val
        TRAFFIC_TYPE="${val:-$def}"
        case "$TRAFFIC_TYPE" in 1|2|3) break ;; esac
        warn "只能输入 1、2 或 3，请重新输入"
    done

    def="${TG_BOT_TOKEN:-}"
    while true; do
        if [ -n "$def" ]; then
            read -r -p "Telegram Bot Token [已配置，回车保留]: " val
            TG_BOT_TOKEN="${val:-$def}"
        else
            read -r -p "Telegram Bot Token: " TG_BOT_TOKEN
        fi
        [ -n "$TG_BOT_TOKEN" ] && break
        warn "Token 不能为空"
    done

    def="${TG_CHAT_ID:-}"
    while true; do
        if [ -n "$def" ]; then
            read -r -p "Telegram Chat ID [已配置，回车保留]: " val
            TG_CHAT_ID="${val:-$def}"
        else
            read -r -p "Telegram Chat ID: " TG_CHAT_ID
        fi
        [ -n "$TG_CHAT_ID" ] && break
        warn "Chat ID 不能为空"
    done

    def="${MONTHLY_LIMIT_GB:-}"
    while true; do
        read -r -p "每月总流量限额（GB）[${def:-必填}]: " val
        MONTHLY_LIMIT_GB="${val:-$def}"
        if [ -n "$MONTHLY_LIMIT_GB" ] && awk -v v="$MONTHLY_LIMIT_GB" 'BEGIN{exit !(v>0)}'; then
            break
        fi
        warn "限额必须为大于 0 的数值，请重新输入"
    done

    WARN_PCT="${WARN_PCT:-$DEF_WARN_PCT}"
    SHUTDOWN_PCT="${SHUTDOWN_PCT:-$DEF_SHUTDOWN_PCT}"
    CHECK_INTERVAL="${CHECK_INTERVAL:-$DEF_CHECK_INTERVAL}"

    echo "────────────────────────────────────────────────────────────────"
    info "配置预览：服务器=${SERVER_NAME} 网口=${INTERFACES} 重置日=${BILLING_DAY}(UTC0) 类型=$(traffic_type_name "$TRAFFIC_TYPE")"
    info "          限额=${MONTHLY_LIMIT_GB}GB 预警=${WARN_PCT}% 关机=${SHUTDOWN_PCT}% 检查间隔=${CHECK_INTERVAL}分钟"
}

save_config() {
    mkdir -p "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"
    cat > "$CONF_FILE" <<EOF
# vnstat 流量监控助手配置文件
# 由 traffic-monitor.sh 自动生成于 $(now_beijing)（北京时间），请勿手工破坏格式
SERVER_NAME="${SERVER_NAME}"
INTERFACES="${INTERFACES}"
BILLING_DAY="${BILLING_DAY}"
TRAFFIC_TYPE="${TRAFFIC_TYPE}"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
MONTHLY_LIMIT_GB="${MONTHLY_LIMIT_GB}"
WARN_PCT="${WARN_PCT}"
SHUTDOWN_PCT="${SHUTDOWN_PCT}"
CHECK_INTERVAL="${CHECK_INTERVAL}"
EOF
    chmod 600 "$CONF_FILE"
    ok "配置已保存至 ${CONF_FILE}"
    log_info "配置已保存：网口=${INTERFACES} 重置日=${BILLING_DAY} 类型=${TRAFFIC_TYPE} 限额=${MONTHLY_LIMIT_GB}GB 预警=${WARN_PCT}% 关机=${SHUTDOWN_PCT}%"
}

vnstat_get_ver() {
    have_cmd vnstat || { echo ""; return 1; }
    vnstat --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1
}

upgrade_vnstat() {
    info "准备源码编译安装 vnstat 新版本（需 build-essential，约 1-3 分钟）..."
    log_info "开始源码编译升级 vnstat"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y build-essential >>"$LOG_FILE" 2>&1; then
        log_error "编译依赖 build-essential 安装失败"
        return 1
    fi

    local ver=""
    if have_cmd jq; then
        ver="$(curl -fsSL -m 20 https://api.github.com/repos/vergoh/vnstat/releases/latest 2>/dev/null \
            | jq -r '.tag_name // empty' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
    fi
    [ -z "$ver" ] && ver="$VNSTAT_FALLBACK_VER"
    info "目标版本：vnstat ${ver}"
    log_info "升级目标版本：${ver}"

    local workdir tarball srcdir
    workdir="$(mktemp -d /tmp/vnstat-build.XXXXXX)"
    tarball="${workdir}/vnstat-${ver}.tar.gz"
    if ! curl -fsSL --connect-timeout 15 --max-time 300 "${VNSTAT_SRC_BASE}/vnstat-${ver}.tar.gz" -o "$tarball"; then
        rm -rf "$workdir"; log_error "vnstat ${ver} 源码包下载失败（${VNSTAT_SRC_BASE}）"; return 1
    fi
    if ! tar -xzf "$tarball" -C "$workdir"; then
        rm -rf "$workdir"; log_error "vnstat 源码包解压失败"; return 1
    fi
    srcdir="$(find "$workdir" -maxdepth 1 -type d -name 'vnstat-*' | head -n1)"
    if [ -z "$srcdir" ] || [ ! -f "${srcdir}/configure" ]; then
        rm -rf "$workdir"; log_error "源码目录结构异常，未找到 configure"; return 1
    fi

    local rc=0
    (
        cd "$srcdir" || exit 1
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var || exit 1
        make -j"$(nproc 2>/dev/null || echo 2)" || exit 1
        systemctl stop vnstat >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get remove -y vnstat >/dev/null 2>&1 || true
        make install || exit 1
    ) >>"$LOG_FILE" 2>&1 || rc=1

    if [ "$rc" -eq 0 ] && [ -f "${srcdir}/examples/systemd/vnstat.service" ]; then
        cp -f "${srcdir}/examples/systemd/vnstat.service" /etc/systemd/system/vnstat.service
    fi
    rm -rf "$workdir"
    systemctl daemon-reload 2>/dev/null || true

    if [ "$rc" -ne 0 ]; then
        log_error "vnstat 编译/安装失败，详见 ${LOG_FILE}"
        warn "编译安装失败（详见 ${LOG_FILE}），若系统vnstat已被卸载请重新执行安装流程"
        if ! have_cmd vnstat; then
            warn "检测到 vnstat 已缺失，尝试恢复 apt 源版本..."
            apt-get install -y vnstat >>"$LOG_FILE" 2>&1 || true
        fi
        return 1
    fi

    local newver; newver="$(vnstat_get_ver)"
    if [ -n "$newver" ] && ! ver_lt "$newver" "$MIN_VNSTAT_VER"; then
        ok "vnstat 已升级至 ${newver}（支持 UseUTC），流量数据库与配置已保留"
        log_info "vnstat 源码编译升级成功：${newver}"
        return 0
    fi
    log_error "升级后 vnstat 版本为 ${newver:-未知}，仍低于 ${MIN_VNSTAT_VER}"
    return 1
}

ensure_vnstat_version() {
    local vnum; vnum="$(vnstat_get_ver)"
    if [ -z "$vnum" ]; then
        warn "无法检测 vnstat 版本号，跳过版本检测"
        return 0
    fi
    if ! ver_lt "$vnum" "$MIN_VNSTAT_VER"; then
        info "vnstat 版本 ${vnum} ≥ ${MIN_VNSTAT_VER}，支持 UseUTC，无需升级"
        log_info "vnstat 版本检测通过：${vnum}（≥${MIN_VNSTAT_VER}）"
        return 0
    fi
    warn "vnstat 版本 ${vnum} 过低（< ${MIN_VNSTAT_VER}），不支持 UseUTC 参数"
    echo "    升级：源码编译安装新版（保留流量数据库与配置），UTC0 账单口径更规范"
    echo "    不升级：自动改用 systemd 注入 TZ=UTC 方案（同样满足 UTC0 口径）"
    local ans=""
    read -r -p "  是否现在升级 vnstat？[Y/n]: " ans
    if [ "$ans" != "n" ] && [ "$ans" != "N" ]; then
        if upgrade_vnstat; then
            return 0
        fi
        warn "升级失败，将自动改用 TZ=UTC 降级方案，监控功能不受影响"
        log_warn "vnstat 升级失败，回退 TZ=UTC 方案"
    else
        info "已跳过升级，将使用 TZ=UTC 降级方案"
        log_info "用户跳过 vnstat 升级，使用 TZ=UTC 降级方案"
    fi
    return 0
}

setup_vnstat() {
    info "配置 vnstat（UTC0 时间基准，禁用 MonthRotate）..."
    [ -f "$VNSTAT_CONF" ] || die "未找到 ${VNSTAT_CONF}，vnstat 可能未正确安装"

    local vnum="" use_utc=1
    vnum="$(vnstat_get_ver)"
    if [ -n "$vnum" ] && ver_lt "$vnum" "$MIN_VNSTAT_VER"; then
        use_utc=0
        warn "vnstat 版本 ${vnum} 不支持 UseUTC 参数（需 ≥${MIN_VNSTAT_VER}），改用 systemd 注入 TZ=UTC 实现 UTC0 口径"
        log_warn "vnstat ${vnum} < ${MIN_VNSTAT_VER}，UseUTC 不可用，降级为 systemd TZ=UTC 方案"
    fi

    if [ "$use_utc" = "1" ]; then
        set_vnstat_conf "UseUTC" "1"
        rm -f /etc/systemd/system/vnstat.service.d/utc.conf
    else
        sed -i -E '/^[[:space:]]*UseUTC[[:space:]]/d' "$VNSTAT_CONF"
        mkdir -p /etc/systemd/system/vnstat.service.d
        printf '[Service]\nEnvironment="TZ=UTC"\n' > /etc/systemd/system/vnstat.service.d/utc.conf
        log_info "已写入 systemd drop-in：/etc/systemd/system/vnstat.service.d/utc.conf (TZ=UTC)"
    fi
    
    sed -i -E '/^[[:space:]]*MonthRotate[[:space:]]/d' "$VNSTAT_CONF"
    set_vnstat_conf "KeepDays" "62"
    
    local conf_interfaces="${INTERFACES//+/ }"
    set_vnstat_conf "Interface" "\"${conf_interfaces}\""

    if vnstat --help 2>&1 | grep -q -- '--configtest'; then
        if ! vnstat --configtest >>"$LOG_FILE" 2>&1; then
            warn "vnstat 配置自检未通过，请检查 ${VNSTAT_CONF}（详见日志）"
            log_warn "vnstat --configtest 未通过"
        fi
    fi

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable vnstat >>"$LOG_FILE" 2>&1 || true
    if ! systemctl restart vnstat >>"$LOG_FILE" 2>&1; then
        journalctl -u vnstat --no-pager -n 20 >>"$LOG_FILE" 2>&1 || true
        echo "----- vnstat 最近日志（排查用） -----"
        journalctl -u vnstat --no-pager -n 20 2>/dev/null || true
        echo "------------------------------------"
        die "vnstat 服务启动失败，完整日志见 ${LOG_FILE}"
    fi
    sleep 3
    if ! systemctl is-active --quiet vnstat; then
        journalctl -u vnstat --no-pager -n 20 >>"$LOG_FILE" 2>&1 || true
        echo "----- vnstat 最近日志（排查用） -----"
        journalctl -u vnstat --no-pager -n 20 2>/dev/null || true
        echo "------------------------------------"
        die "vnstat 服务未处于运行状态，完整日志见 ${LOG_FILE}"
    fi

    local IFS_SAVE="$IFS" iface
    IFS='+'
    for iface in $INTERFACES; do
        vnstat --add -i "$iface" >/dev/null 2>&1 || true
        log_info "vnstat 添加监控网口：${iface}"
    done
    IFS="$IFS_SAVE"

    ok "vnstat 已配置并运行（UseUTC=${use_utc}, 脚本按天智能截取账期）"
    log_info "vnstat 配置完成并重启：UseUTC=${use_utc} 网口=${INTERFACES}"
    if [ "$use_utc" = "1" ]; then
        warn "注意：启用 UseUTC 后，vnstat 历史数据的日/月边界将按 UTC 解释；切换当日数据可能有最多 8 小时的归属偏移，属正常现象"
    fi
}

install_script() {
    mkdir -p "$(dirname "$INSTALL_PATH")"
    if [ "$SCRIPT_PATH" != "$INSTALL_PATH" ]; then
        cp -f "$SCRIPT_PATH" "$INSTALL_PATH"
    fi
    chmod +x "$INSTALL_PATH"
    ok "脚本已安装至 ${INSTALL_PATH}"
    log_info "脚本已安装至 ${INSTALL_PATH}（版本 ${VERSION}）"
}

setup_cron() {
    info "创建/更新定时任务（每分钟检查 + 每天 ${DEF_REPORT_HOUR}:$(printf '%02d' $DEF_REPORT_MIN) 报告）..."
    cat > "$CRON_FILE" <<EOF
# vnstat 流量监控助手定时任务（自动生成，请勿手工修改）
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${CHECK_INTERVAL} * * * * root ${INSTALL_PATH} check >/dev/null 2>&1
${DEF_REPORT_MIN} ${DEF_REPORT_HOUR} * * * root ${INSTALL_PATH} report >/dev/null 2>&1
EOF
    chmod 0644 "$CRON_FILE"
    systemctl enable cron >>"$LOG_FILE" 2>&1 || true
    systemctl restart cron >>"$LOG_FILE" 2>&1 || service cron restart >>"$LOG_FILE" 2>&1 \
        || die "cron 服务重载失败"
    ok "定时任务已创建并重载（${CRON_FILE}）"
    log_info "定时任务已更新：check 每 ${CHECK_INTERVAL} 分钟；report 每天北京时间 ${DEF_REPORT_HOUR}:$(printf '%02d' $DEF_REPORT_MIN)"
}

tg_connectivity_test() {
    info "测试 Telegram 连通性..."
    if tg_send "✅ vnstat 流量监控助手 v${VERSION} 配置完成测试消息
服务器：${SERVER_NAME}
时间：$(now_beijing)（北京时间）"; then
        ok "Telegram 测试消息发送成功，请在机器人会话中查收"
        log_info "安装完成后 Telegram 连通性测试成功"
    else
        warn "Telegram 测试消息发送失败！请检查 Token / Chat ID / 服务器到 api.telegram.org 的网络连通性"
        log_error "安装完成后 Telegram 连通性测试失败"
    fi
}

do_install() {
    check_root
    local mode="首次安装部署"
    if load_config; then
        mode="修改配置（已加载现有配置作为默认值，本次为更新模式）"
        info "检测到已有配置 ${CONF_FILE}，进入更新模式"
    fi
    info "===== ${mode} ====="
    log_info "===== 开始${mode} ====="

    install_deps
    ensure_vnstat_version
    set_timezone
    prompt_config
    setup_vnstat
    save_config
    install_script
    setup_cron
    tg_connectivity_test

    echo
    ok "===== ${mode}完成 ====="
    info "建议执行「测试发送每日流量推送」验证日报格式；vnstat 需要一段时间积累数据"
    log_info "===== ${mode}完成 ====="
}

do_report() {
    load_config || die "未找到配置文件，请先执行安装部署"
    validate_config
    have_cmd vnstat || die "vnstat 未安装"
    have_cmd jq || die "jq 未安装"

    get_period_info || true
    local used pct msg
    used="$(get_used_bytes)" || die "读取 vnstat 流量数据失败"
    pct="$(calc_pct "$used" "$MONTHLY_LIMIT_GB")"
    msg="$(build_report_msg "$used" "$pct")"

    log_info "每日报告：服务器=${SERVER_NAME} 周期=${PERIOD_ID}(${PERIOD_START} UTC) 已用=$(fmt_traffic "$used")/${MONTHLY_LIMIT_GB}GB (${pct}%)"
    if tg_send_retry "$msg"; then
        ok "每日流量报告已推送"
    else
        log_error "每日流量报告推送失败（已重试），本次放弃"
        warn "每日流量报告推送失败（已重试），详见 ${LOG_FILE}"
        return 1
    fi
}

do_check() {
    exec 9>"$LOCK_FILE" 2>/dev/null || true
    if have_cmd flock; then
        flock -n 9 || exit 0
    fi

    load_config || { log_error "check：配置文件缺失，跳过"; exit 1; }
    validate_config
    have_cmd vnstat || { log_error "check：vnstat 未安装"; exit 1; }
    have_cmd jq || { log_error "check：jq 未安装"; exit 1; }

    get_period_info || true
    local used pct
    used="$(get_used_bytes)" || { log_error "check：读取流量数据失败，本轮跳过"; exit 1; }
    pct="$(calc_pct "$used" "$MONTHLY_LIMIT_GB")"

    if pct_ge "$pct" "$SHUTDOWN_PCT"; then
        log_warn "触发关机阈值：周期=${PERIOD_ID} 已用=$(fmt_traffic "$used")/${MONTHLY_LIMIT_GB}GB (${pct}%) >= ${SHUTDOWN_PCT}%"
        local msg; msg="$(build_shutdown_msg "$used" "$pct")"
        if tg_send_retry "$msg" 2; then
            log_info "关机通知发送成功"
        else
            log_error "关机通知发送失败（已重试 2 次），按策略仍继续执行关机"
        fi

        sleep 2
        get_period_info || true
        local used2 pct2
        if ! used2="$(get_used_bytes)"; then
            log_error "关机前复核失败（无法读取流量数据），为安全起见中止本次关机，等待下轮检查"
            exit 1
        fi
        pct2="$(calc_pct "$used2" "$MONTHLY_LIMIT_GB")"
        if ! pct_ge "$pct2" "$SHUTDOWN_PCT"; then
            log_warn "关机前复核：当前 ${pct2}% 未达 ${SHUTDOWN_PCT}%（账单周期可能已重置），中止关机"
            if tg_send "ℹ️ 关机已中止
服务器：${SERVER_NAME}
复核流量：$(fmt_traffic "$used2") / ${MONTHLY_LIMIT_GB}GB（${pct2}%），未达关机阈值 ${SHUTDOWN_PCT}%（账单周期可能已重置）。
时间：$(now_beijing)（北京时间）"; then
                log_info "关机中止通知发送成功"
            fi
            exit 0
        fi
        log_warn "关机前复核通过：${pct2}% >= ${SHUTDOWN_PCT}%，30 秒后执行关机"
        tg_send_retry "⏳ 关机复核通过（${pct2}%），服务器 ${SERVER_NAME} 将在 30 秒后关机。时间：$(now_beijing)" 1 || true
        sync
        sleep 30
        if ! used2="$(get_used_bytes)" || ! pct_ge "$(calc_pct "$used2" "$MONTHLY_LIMIT_GB")" "$SHUTDOWN_PCT"; then
            log_warn "最终确认未达关机阈值，中止关机"
            exit 0
        fi
        log_warn "===== 执行关机命令（poweroff）====="
        _log "INFO" "关机指令下发：$(now_beijing)"
        sync
        if have_cmd systemctl; then
            systemctl poweroff -i
        else
            shutdown -h now || poweroff -f
        fi
        exit 0
    fi

    if pct_ge "$pct" "$WARN_PCT"; then
        load_state
        if [ "${WARN_PERIOD:-}" = "${PERIOD_ID}" ]; then
            log_info "已达预警阈值 ${pct}%（周期 ${PERIOD_ID} 已推送过预警，跳过）"
            exit 0
        fi
        log_warn "触发预警阈值：周期=${PERIOD_ID} 已用=$(fmt_traffic "$used")/${MONTHLY_LIMIT_GB}GB (${pct}%) >= ${WARN_PCT}%"
        local msg; msg="$(build_warn_msg "$used" "$pct")"
        if tg_send_retry "$msg" 2; then
            WARN_PERIOD="$PERIOD_ID"
            save_state
            log_info "预警通知发送成功，已记录周期 ${PERIOD_ID}，本周期不再重复推送"
        else
            log_error "预警通知发送失败（已重试），下轮检查将再次尝试"
        fi
        exit 0
    fi

    log_info "阈值检查正常：周期=${PERIOD_ID} 已用=$(fmt_traffic "$used")/${MONTHLY_LIMIT_GB}GB (${pct}%)"
}

do_status() {
    load_config || die "未找到配置文件，请先执行安装部署"
    validate_config
    get_period_info || true
    local used pct remain
    
    used="$(get_used_bytes)" || die "读取 vnstat 流量数据失败（vnstatd 可能刚启动，请稍后再试）"
    pct="$(calc_pct "$used" "$MONTHLY_LIMIT_GB")"
    
    remain="$(awk -v u="$used" -v l="$MONTHLY_LIMIT_GB" 'BEGIN{
        r=l*1000000000-u; if(r<0)r=0; 
        if (r < 1000000000 && r > 0) printf "%.2f MB", r/1000000; 
        else printf "%.2f GB", r/1000000000 
    }')"

    echo
    echo "════════════ 当前流量数据 ════════════"
    echo "  服务器名称 ：${SERVER_NAME}"
    echo "  监控网口   ：${INTERFACES}"
    echo "  账单周期   ：${PERIOD_ID}（自 ${PERIOD_START} UTC0 起，重置日：每月 ${BILLING_DAY} 日）"
    echo "  统计类型   ：$(traffic_type_name "$TRAFFIC_TYPE")"
    echo "  已用流量   ：$(fmt_traffic "$used") / ${MONTHLY_LIMIT_GB} GB（${pct}%）"
    echo "  剩余流量   ：${remain}"
    echo "  上传/下载  ：$(fmt_traffic "${TX_BYTES:-0}") / $(fmt_traffic "${RX_BYTES:-0}")"
    echo "  预警阈值   ：${WARN_PCT}%    关机阈值：${SHUTDOWN_PCT}%"
    echo "═════════════════════════════════════"
    echo
    info "vnstat 原始日数据（脚本已按账单周期截取累加，以下天级数据供核对）："
    vnstat -d -i "$INTERFACES" 2>/dev/null || warn "vnstat 查询失败"
}

do_update() {
    check_root
    info "从仓库强制拉取最新脚本（附加时间戳破缓存）..."
    log_info "开始在线更新脚本，源：${REPO_URL}"
    local tmp; tmp="$(mktemp /tmp/traffic-monitor.XXXXXX)"
    local url="${REPO_URL}?t=$(date +%s)"
    
    if ! curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$tmp"; then
        rm -f "$tmp"
        log_error "更新失败：下载脚本出错（网络或仓库地址问题）"
        die "下载失败，请检查网络或仓库地址是否可访问"
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"; die "下载内容为空，更新中止"
    fi
    if ! head -n1 "$tmp" | grep -qE '^#!.*bash'; then
        rm -f "$tmp"; die "下载内容不是有效的 bash 脚本（可能被 CDN/代理污染），更新中止"
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"; die "新脚本语法校验未通过，更新中止（保留当前版本）"
    fi
    local new_ver
    new_ver="$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)"
    cp -f "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    if [ "$SCRIPT_PATH" != "$INSTALL_PATH" ] && [ -w "$SCRIPT_PATH" ] && [[ "$SCRIPT_PATH" != /tmp/* ]]; then
        cp -f "$tmp" "$SCRIPT_PATH" 2>/dev/null || true
    fi
    rm -f "$tmp"
    
    echo
    if [ "$new_ver" = "$VERSION" ]; then
        warn "拉取的版本与当前版本相同（v${VERSION}），GitHub CDN 可能还没刷新，请稍后再试。"
    else
        ok "脚本已更新：v${VERSION} → v${new_ver:-未知}（${INSTALL_PATH}）"
        log_info "脚本更新成功：v${VERSION} → v${new_ver:-未知}"
    fi
    info "正在自动重新加载最新版本..."
    sleep 2
    exec bash "$INSTALL_PATH"
}

do_uninstall() {
    check_root
    echo
    warn "即将卸载 vnstat 流量监控助手，将清理：定时任务、配置文件、状态文件、日志与脚本本体"
    read -r -p "确认卸载？输入 yes 继续: " ans
    [ "$ans" = "yes" ] || { info "已取消卸载"; return 0; }

    log_warn "===== 开始卸载 ====="
    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE"
        systemctl reload cron >>"$LOG_FILE" 2>&1 || systemctl restart cron >>"$LOG_FILE" 2>&1 || service cron restart >>"$LOG_FILE" 2>&1 || true
        ok "定时任务已清理（${CRON_FILE}）"
    fi
    rm -rf "$CONF_DIR" "$STATE_DIR" "$LOCK_FILE"
    if [ -f /etc/systemd/system/vnstat.service.d/utc.conf ]; then
        rm -f /etc/systemd/system/vnstat.service.d/utc.conf
        rmdir /etc/systemd/system/vnstat.service.d 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        ok "vnstat 的 systemd TZ=UTC drop-in 已清理"
    fi
    ok "配置文件与状态文件已清理"
    read -r -p "是否同时卸载 vnstat 本体及其流量数据库？[y/N]: " ans2
    if [ "$ans2" = "y" ] || [ "$ans2" = "Y" ]; then
        systemctl disable --now vnstat >>"$LOG_FILE" 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get remove -y vnstat >>"$LOG_FILE" 2>&1 || true
        rm -rf /var/lib/vnstat
        ok "vnstat 已卸载，数据库已删除"
        log_warn "vnstat 本体与数据库已卸载"
    else
        info "保留 vnstat 本体与流量数据库（/var/lib/vnstat）"
    fi
    rm -rf "$LOG_DIR"
    if [ -f "$INSTALL_PATH" ]; then
        rm -f "$INSTALL_PATH"
        ok "脚本 ${INSTALL_PATH} 已删除"
    fi
    echo
    ok "===== 卸载完成 ====="
    echo "（日志目录已一并删除；如脚本从其他路径运行，请手动删除该副本：${SCRIPT_PATH}）"
}

show_menu() {
    clear 2>/dev/null || true
    local cfg_tip="未配置"
    if [ -f "$CONF_FILE" ]; then
        cfg_tip="$(. "$CONF_FILE"; echo "${SERVER_NAME:-?} | ${INTERFACES:-?} | 限额${MONTHLY_LIMIT_GB:-?}GB")"
    fi
    cat <<EOF

  ╔══════════════════════════════════════════╗
  ║       vnstat 流量监控助手  v${VERSION}          ║
  ╚══════════════════════════════════════════╝
  当前配置：${cfg_tip}

   1. 安装部署/修改配置
   2. 测试发送每日流量推送
   3. 查看当前流量数据
   4. 从 GitHub 更新脚本
   5. 卸载监控程序
   0. 退出

EOF
}

main_menu() {
    while true; do
        show_menu
        read -r -p "  请选择操作 [0-5]: " choice
        case "$choice" in
            1) do_install ;;
            2) info "测试发送每日流量推送..."; do_report ;;
            3) do_status ;;
            4) do_update ;;
            5) do_uninstall; break ;;
            0) info "再见！"; exit 0 ;;
            *) warn "无效选项，请重新输入" ;;
        esac
        echo
        read -r -p "  按回车键返回菜单..." _
    done
}

main() {
    case "${1:-menu}" in
        install|config)  shift || true; do_install ;;
        check)           shift || true; do_check ;;
        report)          shift || true; do_report ;;
        status|show)     shift || true; do_status ;;
        test)            shift || true; do_report ;;
        update|upgrade)  shift || true; do_update ;;
        vnstat-upgrade)
            shift || true
            check_root
            ensure_vnstat_version
            if load_config; then
                setup_vnstat
                ok "vnstat 配置已按当前版本重新应用（UseUTC）"
            fi
            ;;
        uninstall|remove) shift || true; do_uninstall ;;
        version|-v|--version) echo "traffic-monitor v${VERSION}" ;;
        help|-h|--help)
            sed -n '2,30p' "$SCRIPT_PATH" | grep -E '^#' | sed 's/^# \{0,1\}//'
            ;;
        menu|"")  main_menu ;;
        *)        die "未知参数：$1（可用：install/check/report/status/test/update/uninstall/version/help）" ;;
    esac
}

main "$@"
