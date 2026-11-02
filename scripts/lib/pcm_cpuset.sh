#!/usr/bin/env bash

if [[ -n "${NSM_OVS_PCM_CPUSET_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_PCM_CPUSET_SH_LOADED=1

PCM_CPUSET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${PCM_CPUSET_LIB_DIR}/log.sh"
# shellcheck source=/dev/null
source "${PCM_CPUSET_LIB_DIR}/paths.sh"
# shellcheck source=/dev/null
source "${PCM_CPUSET_LIB_DIR}/k8s.sh"
# shellcheck source=/dev/null
source "${PCM_CPUSET_LIB_DIR}/cpuset.sh"

pcm_cpuset_json_escape() {
    local value=${1:-}

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "${value}"
}

pcm_cpuset_discover_pod_on_node() {
    local namespace=$1
    local node_name=$2
    local selector=${3:-}
    local pod_name=""
    local kubectl_bin=${KUBECTL:-kubectl}

    if [[ -n "${selector}" ]]; then
        pod_name="$("${kubectl_bin}" get pods -n "${namespace}" -l "${selector}" -o jsonpath="{range .items[?(@.spec.nodeName=='${node_name}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null | sed -n '1p')"
    else
        pod_name="$("${kubectl_bin}" get pods -n "${namespace}" -o jsonpath="{range .items[?(@.spec.nodeName=='${node_name}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null | sed -n '1p')"
    fi

    printf '%s\n' "${pod_name}"
}

pcm_cpuset_resolve_input() {
    local direct_cpuset=${1:-}
    local cpuset_map_env=${2:-}
    local role_name=${3:-}
    local cpuset_var=$4
    local source_var=$5
    local resolved_spec="" source_label="" expanded_cpuset="" normalized_cpuset=""
    declare -A cpuset_map=()

    if [[ -n "${direct_cpuset}" ]]; then
        resolved_spec="$(platform_trim "${direct_cpuset}")"
        source_label='direct'
    elif [[ -n "${cpuset_map_env}" ]]; then
        [[ -f "${cpuset_map_env}" ]] || die "cpuset map env file not found: ${cpuset_map_env}"
        [[ -n "${role_name}" ]] || die "--role is required when --cpuset-map-env is used"
        platform_load_env_file "${cpuset_map_env}" cpuset_map
        resolved_spec="$(cpuset_map_role_field cpuset_map "${role_name}" CPUSET)"
        source_label="${cpuset_map_env}:${role_name}"
    else
        die "provide either --cpuset or --cpuset-map-env with --role"
    fi

    expanded_cpuset="$(cpuset_expand "${resolved_spec}" 2>/dev/null || true)"
    [[ -n "${expanded_cpuset}" ]] || die "invalid or empty cpuset input: ${resolved_spec:-<empty>}"
    normalized_cpuset="$(printf '%s\n' "${expanded_cpuset}" | cpuset_compact)"

    printf -v "${cpuset_var}" '%s' "${normalized_cpuset}"
    printf -v "${source_var}" '%s' "${source_label}"
}

pcm_cpuset_extract_csv_from_raw() {
    local raw_file=$1
    local csv_file=$2

    awk 'BEGIN { capture = 0 } /^Core,/ { capture = 1 } capture { print }' "${raw_file}" > "${csv_file}"
    [[ -s "${csv_file}" ]]
}

pcm_cpuset_filter_core_rows() {
    local csv_file=$1
    local core_rows_csv=$2
    local output_file=$3

    awk -F',' -v wanted="${core_rows_csv}" '
        BEGIN {
            split(wanted, rows, ",")
            for (idx in rows) {
                if (rows[idx] != "") {
                    keep[rows[idx]] = 1
                }
            }
        }
        NR == 1 {
            print
            next
        }
        ($1 in keep) {
            print
        }
    ' "${csv_file}" > "${output_file}"

    if [[ ! -s "${output_file}" ]]; then
        return 1
    fi

    [[ "$(wc -l < "${output_file}")" -gt 1 ]]
}
