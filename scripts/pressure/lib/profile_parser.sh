#!/usr/bin/env bash

if [[ -n "${NSM_OVS_PRESSURE_PROFILE_PARSER_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_PRESSURE_PROFILE_PARSER_SH_LOADED=1

pressure_profile_reset() {
    PRESSURE_PROFILE_ENTRY_COUNT=0
    PRESSURE_PROFILE_PLUGINS=()
    PRESSURE_PROFILE_INTENSITIES=()
    PRESSURE_PROFILE_CPUSETS=()
    PRESSURE_PROFILE_TAGS=()
    PRESSURE_PROFILE_PARAMS=()
}

pressure_profile_require_reset() {
    if [[ -z "${PRESSURE_PROFILE_ENTRY_COUNT+x}" ]]; then
        pressure_profile_reset
    fi
}

pressure_profile_add_entry() {
    local plugin=$1
    local intensity=$2
    local cpuset=$3
    local tag=${4:-}
    local params=${5:-}

    pressure_profile_require_reset

    [[ -n "${plugin}" ]] || die "pressure profile entry plugin is empty"
    [[ -n "${intensity}" ]] || die "pressure profile entry intensity is empty"
    [[ "${intensity}" =~ ^[0-9]+$ ]] || die "pressure intensity must be an integer, got: ${intensity}"
    [[ -n "${cpuset}" ]] || die "pressure profile entry cpuset is empty"

    PRESSURE_PROFILE_PLUGINS+=("${plugin}")
    PRESSURE_PROFILE_INTENSITIES+=("${intensity}")
    PRESSURE_PROFILE_CPUSETS+=("${cpuset}")
    PRESSURE_PROFILE_TAGS+=("${tag}")
    PRESSURE_PROFILE_PARAMS+=("${params}")
    PRESSURE_PROFILE_ENTRY_COUNT=${#PRESSURE_PROFILE_PLUGINS[@]}
}

pressure_profile_parse_spec() {
    local spec=$1
    local default_cpuset=${2:-}
    local default_tag=${3:-}
    local plugin=''
    local body=''
    local intensity=''
    local cpuset="${default_cpuset}"
    local tag="${default_tag}"
    local params=''
    local token key value

    [[ -n "${spec}" ]] || die "pressure spec is empty"

    if [[ "${spec}" == *:* ]]; then
        plugin="${spec%%:*}"
        body="${spec#*:}"
    else
        plugin="${spec}"
        body=''
    fi

    [[ -n "${plugin}" ]] || die "pressure spec plugin is empty: ${spec}"

    if [[ -n "${body}" ]]; then
        IFS=',' read -r -a pressure_tokens <<< "${body}"
        for token in "${pressure_tokens[@]}"; do
            [[ -n "${token}" ]] || continue
            if [[ "${token}" != *=* ]]; then
                die "invalid pressure token (expected key=value): ${token}"
            fi
            key="${token%%=*}"
            value="${token#*=}"
            case "${key}" in
                intensity)
                    intensity="${value}"
                    ;;
                cpuset)
                    cpuset="${value}"
                    ;;
                tag)
                    tag="${value}"
                    ;;
                *)
                    if [[ -n "${params}" ]]; then
                        params+=","
                    fi
                    params+="${key}=${value}"
                    ;;
            esac
        done
    fi

    [[ -n "${intensity}" ]] || die "pressure spec missing intensity: ${spec}"
    [[ -n "${cpuset}" ]] || die "pressure spec missing cpuset and no default provided: ${spec}"
    pressure_profile_add_entry "${plugin}" "${intensity}" "${cpuset}" "${tag}" "${params}"
}

pressure_profile_write_env() {
    local output_file=$1
    local index=0

    pressure_profile_require_reset
    mkdir -p "$(dirname "${output_file}")"

    {
        printf 'PRESSURE_PROFILE_ENTRY_COUNT=%s\n' "${PRESSURE_PROFILE_ENTRY_COUNT}"
        for (( index = 0; index < PRESSURE_PROFILE_ENTRY_COUNT; index++ )); do
            printf 'PRESSURE_PROFILE_ENTRY_%d_PLUGIN=%s\n' "$((index + 1))" "${PRESSURE_PROFILE_PLUGINS[${index}]}"
            printf 'PRESSURE_PROFILE_ENTRY_%d_INTENSITY=%s\n' "$((index + 1))" "${PRESSURE_PROFILE_INTENSITIES[${index}]}"
            printf 'PRESSURE_PROFILE_ENTRY_%d_CPUSET=%s\n' "$((index + 1))" "${PRESSURE_PROFILE_CPUSETS[${index}]}"
            printf 'PRESSURE_PROFILE_ENTRY_%d_TAG=%s\n' "$((index + 1))" "${PRESSURE_PROFILE_TAGS[${index}]}"
            printf 'PRESSURE_PROFILE_ENTRY_%d_PARAMS=%s\n' "$((index + 1))" "${PRESSURE_PROFILE_PARAMS[${index}]}"
        done
    } > "${output_file}"
}

pressure_profile_load_env() {
    local input_file=$1
    local entry_count=0
    local index=0
    local plugin intensity cpuset tag params

    [[ -f "${input_file}" ]] || die "pressure profile file not found: ${input_file}"

    pressure_profile_reset
    # shellcheck source=/dev/null
    source "${input_file}"

    entry_count="${PRESSURE_PROFILE_ENTRY_COUNT:-0}"
    [[ "${entry_count}" =~ ^[0-9]+$ ]] || die "invalid pressure profile entry count in ${input_file}: ${entry_count}"

    for (( index = 1; index <= entry_count; index++ )); do
        plugin="$(eval "printf '%s' \"\${PRESSURE_PROFILE_ENTRY_${index}_PLUGIN:-}\"")"
        intensity="$(eval "printf '%s' \"\${PRESSURE_PROFILE_ENTRY_${index}_INTENSITY:-}\"")"
        cpuset="$(eval "printf '%s' \"\${PRESSURE_PROFILE_ENTRY_${index}_CPUSET:-}\"")"
        tag="$(eval "printf '%s' \"\${PRESSURE_PROFILE_ENTRY_${index}_TAG:-}\"")"
        params="$(eval "printf '%s' \"\${PRESSURE_PROFILE_ENTRY_${index}_PARAMS:-}\"")"
        pressure_profile_add_entry "${plugin}" "${intensity}" "${cpuset}" "${tag}" "${params}"
    done
}

