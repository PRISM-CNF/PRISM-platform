#!/usr/bin/env bash

if [[ -n "${NSM_OVS_TIME_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_TIME_SH_LOADED=1

platform_time_human_timezone() {
    printf '%s\n' "${NSM_OVS_HUMAN_TIMEZONE:-${HUMAN_TIMEZONE:-Asia/Shanghai}}"
}

platform_time_has_value() {
    local value=${1-}

    [[ -n "${value}" && "${value}" != "0" && "${value}" != "0.000" ]]
}

platform_now_local_iso8601() {
    local tz

    tz="$(platform_time_human_timezone)"
    TZ="${tz}" date '+%Y-%m-%dT%H:%M:%S%:z'
}

platform_now_local_file_token() {
    local tz token offset sign digits

    tz="$(platform_time_human_timezone)"
    token="$(TZ="${tz}" date '+%Y%m%dt%H%M%S' | tr '[:upper:]' '[:lower:]')"
    offset="$(TZ="${tz}" date '+%z')"
    sign="${offset:0:1}"
    digits="${offset:1}"

    case "${sign}" in
        +) sign='p' ;;
        -) sign='m' ;;
        *) sign='z'; digits="${offset}" ;;
    esac

    printf '%s-tz%s%s\n' "${token}" "${sign}" "${digits}"
}

platform_now_utc_iso8601() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

platform_now_epoch_ms() {
    date '+%s%3N'
}

platform_rfc3339_to_epoch_ms() {
    local value=${1-}

    [[ -n "${value}" ]] || return 0
    date -d "${value}" '+%s%3N'
}

platform_rfc3339_to_local_iso8601() {
    local value=${1-}
    local tz

    [[ -n "${value}" ]] || return 0
    tz="$(platform_time_human_timezone)"
    TZ="${tz}" date -d "${value}" '+%Y-%m-%dT%H:%M:%S%:z'
}

platform_epoch_seconds_to_epoch_ms() {
    local value=${1-}

    platform_time_has_value "${value}" || return 0
    awk -v value="${value}" 'BEGIN { printf "%.0f\n", value * 1000 }'
}

platform_epoch_ms_to_local_iso8601() {
    local value=${1-}
    local seconds tz

    platform_time_has_value "${value}" || return 0
    seconds="$(awk -v value="${value}" 'BEGIN { printf "%.3f\n", value / 1000 }')"
    tz="$(platform_time_human_timezone)"
    TZ="${tz}" date -d "@${seconds}" '+%Y-%m-%dT%H:%M:%S%:z'
}

platform_epoch_ms_to_utc_iso8601() {
    local value=${1-}
    local seconds

    platform_time_has_value "${value}" || return 0
    seconds="$(awk -v value="${value}" 'BEGIN { printf "%.3f\n", value / 1000 }')"
    date -u -d "@${seconds}" '+%Y-%m-%dT%H:%M:%SZ'
}

platform_epoch_seconds_to_local_iso8601() {
    local value=${1-}
    local epoch_ms

    epoch_ms="$(platform_epoch_seconds_to_epoch_ms "${value}")"
    platform_epoch_ms_to_local_iso8601 "${epoch_ms}"
}

platform_epoch_ms_to_vm_unix_s() {
    local value=${1-}

    platform_time_has_value "${value}" || return 0
    awk -v value="${value}" 'BEGIN { printf "%.3f\n", value / 1000 }'
}
