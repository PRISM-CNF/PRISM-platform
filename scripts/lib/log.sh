#!/usr/bin/env bash

if [[ -n "${NSM_OVS_LOG_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_LOG_SH_LOADED=1

LOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${LOG_LIB_DIR}/time.sh"

if [[ -t 1 ]]; then
    NSM_OVS_COLOR_RED=$'\033[0;31m'
    NSM_OVS_COLOR_GREEN=$'\033[0;32m'
    NSM_OVS_COLOR_YELLOW=$'\033[1;33m'
    NSM_OVS_COLOR_BLUE=$'\033[0;34m'
    NSM_OVS_COLOR_RESET=$'\033[0m'
else
    NSM_OVS_COLOR_RED=''
    NSM_OVS_COLOR_GREEN=''
    NSM_OVS_COLOR_YELLOW=''
    NSM_OVS_COLOR_BLUE=''
    NSM_OVS_COLOR_RESET=''
fi

log_timestamp() {
    platform_now_local_iso8601
}

log_info() {
    printf '%s %s[INFO]%s %s\n' "$(log_timestamp)" "${NSM_OVS_COLOR_BLUE}" "${NSM_OVS_COLOR_RESET}" "$*"
}

log_success() {
    printf '%s %s[OK]%s %s\n' "$(log_timestamp)" "${NSM_OVS_COLOR_GREEN}" "${NSM_OVS_COLOR_RESET}" "$*"
}

log_warn() {
    printf '%s %s[WARN]%s %s\n' "$(log_timestamp)" "${NSM_OVS_COLOR_YELLOW}" "${NSM_OVS_COLOR_RESET}" "$*"
}

log_error() {
    printf '%s %s[ERROR]%s %s\n' "$(log_timestamp)" "${NSM_OVS_COLOR_RED}" "${NSM_OVS_COLOR_RESET}" "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

require_command() {
    local command_name=$1
    command -v "${command_name}" >/dev/null 2>&1 || die "required command not found: ${command_name}"
}
