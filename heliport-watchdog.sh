#!/bin/bash
#
# heliport-watchdog —— HeliPort(itlwm) 网络看门狗
#
# 周期性 ping 指定远端地址；连续失败达到阈值后，自动把 HeliPort 的
# Wi-Fi 关闭一段时间再打开（经由 HeliPort 菜单栏图标的 Wi-Fi 开关），
# 以恢复 itlwm 网络畅通。
#
# 注意: 控制 HeliPort 菜单依赖辅助功能权限：首次使用需在
#       「系统设置 → 隐私与安全性 → 辅助功能」中，为运行本脚本的
#       终端程序授权。
#

set -u
PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

REMOTE_IP="192.168.100.1"
DOWN_THRESHOLD=10
PING_INTERVAL=1
OFF_DURATION=1

# ---------------- 日志配色 ----------------
# 失败类（WARN/ERROR）红色，成功/通知类（INFO）绿色。
# 默认 auto：仅当输出为终端时上色；-no-color 或 NO_COLOR=1 强制关闭。

COLOR_MODE="auto"
C_RED=""
C_GREEN=""
C_RESET=""

setup_colors() {
    C_RED=""
    C_GREEN=""
    C_RESET=""
    case "$COLOR_MODE" in
        never) return 0 ;;
        always) ;;
        auto)
            if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
                return 0
            fi
            ;;
    esac
    C_RED=$(printf '\033[0;31m')
    C_GREEN=$(printf '\033[0;32m')
    C_RESET=$(printf '\033[0m')
}

setup_colors

log() {
    # $1=级别, $2=内容
    local color
    case "$1" in
        ERROR) color="$C_RED" ;;
        WARN)  color="$C_RED" ;;
        INFO)  color="$C_GREEN" ;;
        *)     color="" ;;
    esac
    printf '%s[%s] [%s] %s%s\n' "$color" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" "$C_RESET"
}

die() {
    log ERROR "$1" >&2
    usage >&2
    exit 2
}

usage() {
    cat <<'USAGE'
heliport-watchdog —— HeliPort(itlwm) 网络看门狗

用法:
  heliport-watchdog.sh [选项]

选项:
  -ip <地址>           用于判断网络畅通的远端 IP（默认 192.168.100.1）
  -down <秒>           连续 ping 失败多少秒判定网络不通（默认 10）
  -interval <秒>       ping 探测间隔（默认 1）
  -off <秒>            判定不通后 Wi-Fi 关闭多少秒再重开（默认 1）
  -probe               只做一次 ping 探测并退出（调试用）
  -set-power <on|off>  直接设置 HeliPort Wi-Fi 开关状态并退出（调试用）
  -color <auto|always|never>
                       日志配色方式（默认 auto：仅终端输出时上色）
  -no-color            关闭日志配色（等价于 -color never）
  -h, --help           显示本帮助

日志配色:
  失败类日志（WARN/ERROR）显示为红色，成功/通知类（INFO）显示为绿色。

注意:
  控制 HeliPort 菜单依赖辅助功能权限：首次使用需在
  「系统设置 → 隐私与安全性 → 辅助功能」中，为运行本脚本的
  终端程序授权。
USAGE
}

parse_seconds() {
    # 正整数秒，允许尾部带 s（如 "10s"）
    local v="${1%s}"
    case "$v" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$v" -gt 0 ] && [ "$v" -lt 86400 ]
}

# ---------------- 参数解析 ----------------

PROBE_ONLY=0
SET_POWER=""
FAIL_COUNT=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|-help)
            usage
            exit 0
            ;;
        -ip|--ip)
            [ $# -ge 2 ] || die "参数 $1 需要 IP 地址"
            REMOTE_IP="$2"
            shift 2
            ;;
        -down|--down|-threshold|--threshold)
            [ $# -ge 2 ] || die "参数 $1 需要正整数秒，如 10"
            parse_seconds "$2" || die "参数 $1 需要正整数秒，如 10"
            DOWN_THRESHOLD="${2%s}"
            shift 2
            ;;
        -interval|--interval)
            [ $# -ge 2 ] || die "参数 $1 需要正整数秒，如 1"
            parse_seconds "$2" || die "参数 $1 需要正整数秒，如 1"
            PING_INTERVAL="${2%s}"
            shift 2
            ;;
        -off|--off)
            [ $# -ge 2 ] || die "参数 $1 需要正整数秒，如 1"
            parse_seconds "$2" || die "参数 $1 需要正整数秒，如 1"
            OFF_DURATION="${2%s}"
            shift 2
            ;;
        -probe|--probe)
            PROBE_ONLY=1
            shift
            ;;
        -color|--color)
            [ $# -ge 2 ] || die "参数 $1 需要 auto、always 或 never"
            case "$2" in
                auto|always|never) COLOR_MODE="$2" ;;
                *) die "参数 $1 需要 auto、always 或 never" ;;
            esac
            shift 2
            ;;
        -no-color|--no-color)
            COLOR_MODE="never"
            shift
            ;;
        -set-power|--set-power)
            [ $# -ge 2 ] || die "参数 $1 需要 on 或 off"
            case "$2" in
                on)  SET_POWER="1" ;;
                off) SET_POWER="0" ;;
                *)   die "参数 -set-power 只接受 on 或 off" ;;
            esac
            shift 2
            ;;
        *)
            die "未知参数：$1"
            ;;
    esac
done

# ---------------- HeliPort 控制 ----------------
#
# HeliPort 没有命令行接口，Wi-Fi 电源开关是其菜单栏菜单第一项里的
# NSSwitch（checkbox），只能通过 System Events 辅助功能自动化点击。
# 菜单位于扩展菜单栏区（menu bar 1 或 2 因系统版本而异），因此遍历
# 该进程所有 menu bar 的 menu bar item，在展开的菜单里查找第一个
# checkbox 进行操作。
#
# 脚本约定:
#   - 入参: $1 为目标状态，"1"=开 Wi-Fi，"0"=关 Wi-Fi
#   - 成功输出 "ok"
#   - 失败输出 "error:not-running" / "error:not-found" / "error:unreachable-state"

APPLESCRIPT=$(cat <<'EOF'
on run argv
    set targetOn to (item 1 of argv) as string
    repeat 4 times
        set r to attemptSet(targetOn)
        if r is "ok" then return "ok"
        if r starts with "error:" then return r
        delay 0.8
    end repeat
    return "error:unreachable-state"
end run

on attemptSet(targetOn)
    tell application "System Events"
        if not (exists process "HeliPort") then return "error:not-running"
        key code 53
        delay 0.25
        repeat with mb in menu bars of process "HeliPort"
            repeat with sbi in menu bar items of mb
                set r to my tryMenu(sbi, targetOn)
                if r is "ok" then
                    key code 53
                    return "ok"
                else if r starts with "error:" then
                    return r
                else if r is "retry" then
                    return "retry"
                end if
            end repeat
        end repeat
        key code 53
    end tell
    return "error:not-found"
end attemptSet

on tryMenu(sbi, targetOn)
    tell application "System Events"
        try
            click sbi
        end try
        delay 0.4
        try
            set cb to my findSwitch(menu 1 of sbi)
        on error
            return "next"
        end try
        try
            set current to (value of cb) as string
            if current is targetOn then return "ok"
            click cb
            delay 1
            set afterClick to (value of cb) as string
            if afterClick is targetOn then return "ok"
            return "retry"
        on error
            return "retry"
        end try
    end tell
end tryMenu

on findSwitch(menuRef)
    tell application "System Events"
        repeat with mi in menu items of menuRef
            try
                return checkbox 1 of mi
            end try
            try
                return button 1 of mi
            end try
            try
                return checkbox 1 of UI element 1 of mi
            end try
            try
                return button 1 of UI element 1 of mi
            end try
        end repeat
        error "switch-not-found"
    end tell
end findSwitch
EOF
)

# 设置 Wi-Fi 电源状态（幂等：已处于目标状态则不点击）
# $1: "1"=开, "0"=关
heliport_set_power() {
    local target="$1"
    local out rc
    out=$(printf '%s\n' "$APPLESCRIPT" | osascript - "$target" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "ok" ]; then
        return 0
    fi
    case "$out" in
        *assistive*|*Assistive*)
            log ERROR "缺少辅助功能权限，无法操作 HeliPort 菜单"
            log ERROR "请在「系统设置 → 隐私与安全性 → 辅助功能」中，为运行本脚本的终端程序（或脚本本体）授权后重试"
            exit 1
            ;;
        "error:not-running")
            log ERROR "HeliPort 未运行，请先启动 HeliPort"
            ;;
        "error:not-found"|"error:unreachable-state")
            log ERROR "未能在 HeliPort 菜单中找到 Wi-Fi 开关（HeliPort 版本可能不兼容）"
            ;;
        *)
            log ERROR "AppleScript 执行失败：$out"
            ;;
    esac
    return 1
}

# 关 Wi-Fi -> 等待 OFF_DURATION 秒 -> 开 Wi-Fi
heliport_toggle() {
    heliport_set_power 0 || return 1
    sleep "$OFF_DURATION"
    local i
    for i in 1 2 3; do
        if heliport_set_power 1; then
            return 0
        fi
        sleep 1
    done
    log ERROR "恢复 Wi-Fi 连续 3 次失败，Wi-Fi 可能仍处于关闭状态，请手动检查 HeliPort"
    return 1
}

setup_colors

# ---------------- 调试模式 ----------------

if [ "$PROBE_ONLY" -eq 1 ]; then
    if ping -c 1 -W 1000 -t 2 "$REMOTE_IP" >/dev/null 2>&1; then
        log INFO "probe $REMOTE_IP: OK（畅通）"
        exit 0
    else
        log INFO "probe $REMOTE_IP: FAIL（不通）"
        exit 1
    fi
fi

if [ -n "$SET_POWER" ]; then
    if heliport_set_power "$SET_POWER"; then
        log INFO "HeliPort Wi-Fi 开关已处于 $([ "$SET_POWER" = "1" ] && echo on || echo off) 状态"
        exit 0
    else
        exit 1
    fi
fi

# ---------------- 看门狗主循环 ----------------

log INFO "heliport-watchdog 启动：远端 IP=${REMOTE_IP}，判定时长=${DOWN_THRESHOLD}s，探测间隔=${PING_INTERVAL}s，断网时长=${OFF_DURATION}s"

trap 'log INFO "heliport-watchdog 退出"; exit 0' INT TERM

FAILURE_START=""
SUPPRESS_UNTIL=0
FAIL_COUNT=0

while true; do
    if ping -c 1 -W 1000 -t 2 "$REMOTE_IP" >/dev/null 2>&1; then
        if [ "$FAIL_COUNT" -gt 0 ]; then
            log INFO "网络恢复：ping $REMOTE_IP 成功（连续失败计数 ${FAIL_COUNT} 已清零）"
        fi
        FAILURE_START=""
        SUPPRESS_UNTIL=0
        FAIL_COUNT=0
    else
        NOW=$(date +%s)
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        if [ "$SUPPRESS_UNTIL" -gt 0 ] && [ "$NOW" -lt "$SUPPRESS_UNTIL" ]; then
            log WARN "ping $REMOTE_IP 失败（连续失败 ${FAIL_COUNT} 次，修复后宽限期内，忽略）"
        elif [ "$SUPPRESS_UNTIL" -gt 0 ]; then
            log INFO "宽限期结束，重新开始统计连续失败时长（连续失败 ${FAIL_COUNT} 次）"
            SUPPRESS_UNTIL=0
            FAILURE_START=""
        else
            if [ -z "$FAILURE_START" ]; then
                FAILURE_START="$NOW"
            fi
            DOWN=$(( NOW - FAILURE_START ))
            log WARN "ping $REMOTE_IP 失败（连续失败 ${FAIL_COUNT} 次，已持续 ${DOWN}s）"

            if [ "$DOWN" -ge "$DOWN_THRESHOLD" ]; then
                log WARN "连续 ${DOWN}s ping 不通（连续失败 ${FAIL_COUNT} 次），重启 HeliPort 网络：关闭 ${OFF_DURATION}s 后重开"
                if heliport_toggle; then
                    log INFO "HeliPort 网络重启完成，等待重连"
                else
                    log ERROR "HeliPort 网络重启失败（稍后自动重试）"
                fi
                FAILURE_START=""
                FAIL_COUNT=0
                GRACE=$(( DOWN_THRESHOLD * 2 ))
                [ "$GRACE" -lt 30 ] && GRACE=30
                SUPPRESS_UNTIL=$(( $(date +%s) + GRACE ))
            fi
        fi
    fi
    sleep "$PING_INTERVAL"
done
