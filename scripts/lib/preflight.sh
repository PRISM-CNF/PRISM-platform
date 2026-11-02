#!/usr/bin/env bash

if [[ -n "${NSM_OVS_PREFLIGHT_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_PREFLIGHT_SH_LOADED=1

declare -ga PREFLIGHT_SECTION_ORDER=()
declare -gA PREFLIGHT_SECTION_TITLE=()
declare -gA PREFLIGHT_SECTION_STATUS=()
declare -gA PREFLIGHT_SECTION_REASON=()
declare -gA PREFLIGHT_SECTION_EVIDENCE=()
declare -gA PREFLIGHT_SECTION_ACTIONS=()

preflight_init_report() {
    PREFLIGHT_SECTION_ORDER=()
    PREFLIGHT_SECTION_TITLE=()
    PREFLIGHT_SECTION_STATUS=()
    PREFLIGHT_SECTION_REASON=()
    PREFLIGHT_SECTION_EVIDENCE=()
    PREFLIGHT_SECTION_ACTIONS=()
}

preflight_register_section() {
    local section_key=$1
    local section_title=$2

    PREFLIGHT_SECTION_ORDER+=("${section_key}")
    PREFLIGHT_SECTION_TITLE["${section_key}"]="${section_title}"
}

preflight_severity_rank() {
    case "${1:-}" in
        pass) printf '0\n' ;;
        warn) printf '1\n' ;;
        fail) printf '2\n' ;;
        *) printf '3\n' ;;
    esac
}

preflight_set_section_status() {
    local section_key=$1
    local new_status=$2
    local new_reason=$3
    local current_status=${PREFLIGHT_SECTION_STATUS["${section_key}"]:-}
    local current_rank new_rank

    current_rank="$(preflight_severity_rank "${current_status:-pass}")"
    new_rank="$(preflight_severity_rank "${new_status}")"

    if [[ -z "${current_status}" || "${new_rank}" -gt "${current_rank}" ]]; then
        PREFLIGHT_SECTION_STATUS["${section_key}"]="${new_status}"
        PREFLIGHT_SECTION_REASON["${section_key}"]="${new_reason}"
    elif [[ "${current_status}" == "${new_status}" && -z "${PREFLIGHT_SECTION_REASON[${section_key}]:-}" ]]; then
        PREFLIGHT_SECTION_REASON["${section_key}"]="${new_reason}"
    fi
}

preflight_add_section_evidence() {
    local section_key=$1
    local message=$2

    PREFLIGHT_SECTION_EVIDENCE["${section_key}"]="${PREFLIGHT_SECTION_EVIDENCE[${section_key}]:-}${message}"$'\n'
}

preflight_add_section_action() {
    local section_key=$1
    local message=$2

    PREFLIGHT_SECTION_ACTIONS["${section_key}"]="${PREFLIGHT_SECTION_ACTIONS[${section_key}]:-}${message}"$'\n'
}

preflight_overall_status() {
    local overall=pass
    local section_key status

    for section_key in "${PREFLIGHT_SECTION_ORDER[@]}"; do
        status=${PREFLIGHT_SECTION_STATUS["${section_key}"]:-pass}
        case "${status}" in
            fail)
                printf 'fail\n'
                return 0
                ;;
            warn)
                overall=warn
                ;;
        esac
    done

    printf '%s\n' "${overall}"
}

preflight_print_multiline_block() {
    local content=$1
    local line

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        printf '  - %s\n' "${line}"
    done <<< "${content}"
}

preflight_print_report() {
    local overall_status section_key section_title section_status section_reason

    overall_status="$(preflight_overall_status)"

    printf 'Cluster Readiness Preflight\n'
    printf 'overall: %s\n' "${overall_status}"
    printf 'cluster-profile: %s\n' "${CLUSTER_PROFILE}"
    printf 'image-delivery-mode: %s\n' "${IMAGE_DELIVERY_MODE}"
    printf '\n'

    for section_key in "${PREFLIGHT_SECTION_ORDER[@]}"; do
        section_title=${PREFLIGHT_SECTION_TITLE["${section_key}"]}
        section_status=${PREFLIGHT_SECTION_STATUS["${section_key}"]:-pass}
        section_reason=${PREFLIGHT_SECTION_REASON["${section_key}"]:-}

        printf '[%s] %s\n' "${section_title}" "${section_status}"
        if [[ -n "${section_reason}" ]]; then
            printf 'reason: %s\n' "${section_reason}"
        fi
        if [[ -n "${PREFLIGHT_SECTION_EVIDENCE[${section_key}]:-}" ]]; then
            printf 'evidence:\n'
            preflight_print_multiline_block "${PREFLIGHT_SECTION_EVIDENCE[${section_key}]}"
        fi
        if [[ -n "${PREFLIGHT_SECTION_ACTIONS[${section_key}]:-}" ]]; then
            printf 'next-action:\n'
            preflight_print_multiline_block "${PREFLIGHT_SECTION_ACTIONS[${section_key}]}"
        fi
        printf '\n'
    done
}

preflight_exit_code() {
    if [[ "$(preflight_overall_status)" == "fail" ]]; then
        return 1
    fi

    return 0
}
