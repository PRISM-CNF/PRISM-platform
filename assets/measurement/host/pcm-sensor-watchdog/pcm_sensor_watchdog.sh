#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '[pcm-sensor-watchdog] %s\n' "$*"
}

require_var() {
    local name=$1
    if [[ -z "${!name:-}" ]]; then
        log "missing required environment variable: ${name}"
        exit 1
    fi
}

health_check() {
    curl -fsS --max-time "${PCM_WATCHDOG_CURL_TIMEOUT_SEC}" "${PCM_METRICS_URL}" >/dev/null
}

wait_for_recovery() {
    local deadline=$(( $(date +%s) + PCM_WATCHDOG_RECOVERY_TIMEOUT_SEC ))
    while (( $(date +%s) <= deadline )); do
        if health_check; then
            return 0
        fi
        sleep 1
    done
    return 1
}

restart_pcm_service() {
    local active_state main_pid

    active_state="$(systemctl is-active "${PCM_SENSOR_SERVICE_NAME}" 2>/dev/null || true)"
    main_pid="$(systemctl show -p MainPID --value "${PCM_SENSOR_SERVICE_NAME}" 2>/dev/null || true)"
    log "metrics endpoint unavailable; restarting ${PCM_SENSOR_SERVICE_NAME} (active=${active_state} pid=${main_pid:-0})"

    systemctl restart "${PCM_SENSOR_SERVICE_NAME}"

    if wait_for_recovery; then
        log "metrics endpoint recovered after restarting ${PCM_SENSOR_SERVICE_NAME}"
        return 0
    fi

    log "metrics endpoint did not recover within ${PCM_WATCHDOG_RECOVERY_TIMEOUT_SEC}s after restarting ${PCM_SENSOR_SERVICE_NAME}"
    return 1
}

main() {
    local consecutive_failures=0
    local grace_until

    for cmd in curl systemctl; do
        command -v "${cmd}" >/dev/null 2>&1 || {
            log "required command not found: ${cmd}"
            exit 1
        }
    done

    require_var PCM_SENSOR_SERVICE_NAME
    require_var PCM_METRICS_URL
    require_var PCM_WATCHDOG_INTERVAL_SEC
    require_var PCM_WATCHDOG_CURL_TIMEOUT_SEC
    require_var PCM_WATCHDOG_FAILURE_THRESHOLD
    require_var PCM_WATCHDOG_RECOVERY_TIMEOUT_SEC
    require_var PCM_WATCHDOG_GRACE_SEC

    trap 'log "received stop signal"; exit 0' INT TERM

    grace_until=$(( $(date +%s) + PCM_WATCHDOG_GRACE_SEC ))
    log "starting watchdog for ${PCM_SENSOR_SERVICE_NAME} url=${PCM_METRICS_URL} interval=${PCM_WATCHDOG_INTERVAL_SEC}s threshold=${PCM_WATCHDOG_FAILURE_THRESHOLD}"

    while true; do
        if health_check; then
            consecutive_failures=0
        else
            consecutive_failures=$((consecutive_failures + 1))
            log "health check failed count=${consecutive_failures}/${PCM_WATCHDOG_FAILURE_THRESHOLD}"
            if (( $(date +%s) >= grace_until )) && (( consecutive_failures >= PCM_WATCHDOG_FAILURE_THRESHOLD )); then
                if restart_pcm_service; then
                    consecutive_failures=0
                    grace_until=$(( $(date +%s) + PCM_WATCHDOG_GRACE_SEC ))
                fi
            fi
        fi
        sleep "${PCM_WATCHDOG_INTERVAL_SEC}"
    done
}

main "$@"
