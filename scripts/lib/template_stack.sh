#!/usr/bin/env bash

if [[ -n "${NSM_OVS_TEMPLATE_STACK_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_TEMPLATE_STACK_SH_LOADED=1

TEMPLATE_STACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${TEMPLATE_STACK_LIB_DIR}/time.sh"

template_stack_validate_id() {
    local stack_id=$1

    [[ -n "${stack_id}" ]] || die "template stack id is empty"
    [[ ${#stack_id} -le 40 ]] || die "template stack id is too long (max 40): ${stack_id}"
    [[ "${stack_id}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid template stack id: ${stack_id}; use lowercase letters, digits, and hyphens"
}

template_stack_validate_k8s_name() {
    local value=$1
    local field_name=$2

    [[ -n "${value}" ]] || die "${field_name} is empty"
    [[ ${#value} -le 63 ]] || die "${field_name} is too long (max 63): ${value}"
    [[ "${value}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "invalid ${field_name}: ${value}"
}

template_stack_validate_node_name() {
    local value=$1
    local field_name=$2

    [[ -n "${value}" ]] || die "${field_name} is empty"
    [[ ${#value} -le 253 ]] || die "${field_name} is too long (max 253): ${value}"
    [[ "${value}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "invalid ${field_name}: ${value}"
}

template_stack_default_role_node() {
    local role_label=${1:-}

    case "${role_label}" in
        vnf|middle|template)
            printf '%s\n' "${TEMPLATE_DEFAULT_VNF_NODE:-node01}"
            ;;
        client)
            printf '%s\n' "${TEMPLATE_DEFAULT_CLIENT_NODE:-node01}"
            ;;
        server)
            printf '%s\n' "${TEMPLATE_DEFAULT_SERVER_NODE:-node01}"
            ;;
        *)
            printf '%s\n' "${TEMPLATE_DEFAULT_VNF_NODE:-node01}"
            ;;
    esac
}

template_stack_ipv4_to_int() {
    local ip=$1
    local octet_a octet_b octet_c octet_d

    IFS=. read -r octet_a octet_b octet_c octet_d <<< "${ip}"
    [[ -n "${octet_a:-}" && -n "${octet_b:-}" && -n "${octet_c:-}" && -n "${octet_d:-}" ]] || die "invalid IPv4 address: ${ip}"

    for octet in "${octet_a}" "${octet_b}" "${octet_c}" "${octet_d}"; do
        [[ "${octet}" =~ ^[0-9]+$ ]] || die "invalid IPv4 address: ${ip}"
        (( octet >= 0 && octet <= 255 )) || die "invalid IPv4 address: ${ip}"
    done

    printf '%u\n' "$(( (octet_a << 24) | (octet_b << 16) | (octet_c << 8) | octet_d ))"
}

template_stack_int_to_ipv4() {
    local value=$1

    printf '%d.%d.%d.%d\n' \
        $(( (value >> 24) & 255 )) \
        $(( (value >> 16) & 255 )) \
        $(( (value >> 8) & 255 )) \
        $(( value & 255 ))
}

template_stack_mask_for_prefix() {
    local prefix_len=$1

    (( prefix_len >= 0 && prefix_len <= 32 )) || die "invalid CIDR prefix length: ${prefix_len}"
    if (( prefix_len == 0 )); then
        printf '%u\n' 0
    else
        printf '%u\n' "$(( (0xFFFFFFFF << (32 - prefix_len)) & 0xFFFFFFFF ))"
    fi
}

template_stack_cidr_network_int() {
    local cidr=$1
    local ip_part=${cidr%/*}
    local prefix_len=${cidr#*/}
    local ip_int mask

    [[ "${cidr}" == */* ]] || die "invalid CIDR prefix: ${cidr}"
    [[ "${prefix_len}" =~ ^[0-9]+$ ]] || die "invalid CIDR prefix: ${cidr}"

    ip_int="$(template_stack_ipv4_to_int "${ip_part}")"
    mask="$(template_stack_mask_for_prefix "${prefix_len}")"
    printf '%u\n' "$(( ip_int & mask ))"
}

template_stack_cidr_range_start() {
    template_stack_cidr_network_int "$1"
}

template_stack_cidr_range_end() {
    local cidr=$1
    local prefix_len=${cidr#*/}
    local start size

    start="$(template_stack_cidr_network_int "${cidr}")"
    size=$(( 1 << (32 - prefix_len) ))
    printf '%u\n' "$(( start + size - 1 ))"
}

template_stack_validate_cidr_prefix() {
    local cidr=$1
    local ip_part=${cidr%/*}
    local prefix_len=${cidr#*/}
    local ip_int network_int

    [[ "${cidr}" == */* ]] || die "invalid CIDR prefix: ${cidr}"
    [[ "${prefix_len}" =~ ^[0-9]+$ ]] || die "invalid CIDR prefix: ${cidr}"
    (( prefix_len >= 0 && prefix_len <= 32 )) || die "invalid CIDR prefix: ${cidr}"

    ip_int="$(template_stack_ipv4_to_int "${ip_part}")"
    network_int="$(template_stack_cidr_network_int "${cidr}")"

    (( ip_int == network_int )) || die "CIDR prefix must use the network base address: ${cidr}"
}

template_stack_cidrs_overlap() {
    local cidr_a=$1
    local cidr_b=$2
    local start_a end_a start_b end_b

    start_a="$(template_stack_cidr_range_start "${cidr_a}")"
    end_a="$(template_stack_cidr_range_end "${cidr_a}")"
    start_b="$(template_stack_cidr_range_start "${cidr_b}")"
    end_b="$(template_stack_cidr_range_end "${cidr_b}")"

    if (( start_a <= end_b && start_b <= end_a )); then
        return 0
    fi

    return 1
}

template_stack_name_suffix() {
    local stack_id=$1

    if [[ "${stack_id}" == tpl-* && "${stack_id#tpl-}" != "${stack_id}" ]]; then
        printf '%s\n' "${stack_id#tpl-}"
    else
        printf '%s\n' "${stack_id}"
    fi
}

template_stack_default_namespace() {
    local stack_id=$1
    printf 'exp-%s\n' "${stack_id}"
}

template_stack_default_network_service_name() {
    local stack_id=$1
    local suffix

    suffix="$(template_stack_name_suffix "${stack_id}")"
    printf 'nse-ovs-template-%s\n' "${suffix}"
}

template_stack_cpu_pin_guaranteed_qos_enabled() {
    return 1
}

template_stack_cpu_pin_strict_affinity_enabled() {
    return 1
}

template_stack_cpu_pin_strict_affinity_state() {
    if template_stack_cpu_pin_strict_affinity_enabled; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

template_stack_cpu_pin_guaranteed_qos_state() {
    if template_stack_cpu_pin_guaranteed_qos_enabled; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

template_stack_append_resources_patch() {
    local target_file=$1
    local target_path=$2
    local cpu_value=$3
    local memory_value=$4

    cat >> "${target_file}" <<EOF
- op: add
  path: ${target_path}
  value:
    requests:
      cpu: "${cpu_value}"
      memory: "${memory_value}"
    limits:
      cpu: "${cpu_value}"
      memory: "${memory_value}"
EOF
}

template_stack_state_file() {
    local stack_id=$1
    printf '%s/%s.env\n' "${TEMPLATE_STACK_STATE_ROOT}" "${stack_id}"
}

template_stack_generated_dir_for() {
    local stack_id=$1
    printf '%s/%s\n' "${TEMPLATE_GENERATED_ROOT}" "${stack_id}"
}

template_stack_plan_dirs() {
    mkdir -p "${TEMPLATE_STACK_STATE_ROOT}" "${TEMPLATE_GENERATED_ROOT}"
}

template_stack_set_derived_values() {
    local name_suffix

    name_suffix="$(template_stack_name_suffix "${TEMPLATE_STACK_ID}")"

    TEMPLATE_STACK_LABEL_KEY='exp.nsm.ai/stack'
    TEMPLATE_ROLE_LABEL_KEY='exp.nsm.ai/role'
    TEMPLATE_STACK_LABEL_VALUE="${TEMPLATE_STACK_ID}"
    TEMPLATE_STACK_LABEL="${TEMPLATE_STACK_LABEL_KEY}=${TEMPLATE_STACK_LABEL_VALUE}"

    TEMPLATE_ROLE_CLIENT='client'
    TEMPLATE_ROLE_MIDDLE='middle'
    TEMPLATE_ROLE_SERVER='server'

    TEMPLATE_STACK_TEMPLATE_DEPLOYMENT_NAME="nse-ovs-template-${name_suffix}"
    TEMPLATE_STACK_SERVER_DEPLOYMENT_NAME="nse-ovs-server-${name_suffix}"
    TEMPLATE_STACK_CLIENT_DEPLOYMENT_NAME="nsc-ovs-client-${name_suffix}"

    TEMPLATE_STACK_TEMPLATE_POD_SELECTOR="${TEMPLATE_STACK_LABEL_KEY}=${TEMPLATE_STACK_ID},${TEMPLATE_ROLE_LABEL_KEY}=${TEMPLATE_ROLE_MIDDLE}"
    TEMPLATE_STACK_SERVER_POD_SELECTOR="${TEMPLATE_STACK_LABEL_KEY}=${TEMPLATE_STACK_ID},${TEMPLATE_ROLE_LABEL_KEY}=${TEMPLATE_ROLE_SERVER}"
    TEMPLATE_STACK_CLIENT_POD_SELECTOR="${TEMPLATE_STACK_LABEL_KEY}=${TEMPLATE_STACK_ID},${TEMPLATE_ROLE_LABEL_KEY}=${TEMPLATE_ROLE_CLIENT}"

    TEMPLATE_STACK_TEMPLATE_NSM_LABELS="${TEMPLATE_STACK_LABEL_KEY}:${TEMPLATE_STACK_ID},${TEMPLATE_ROLE_LABEL_KEY}:${TEMPLATE_ROLE_MIDDLE}"
    TEMPLATE_STACK_SERVER_NSM_LABELS="${TEMPLATE_STACK_LABEL_KEY}:${TEMPLATE_STACK_ID},${TEMPLATE_ROLE_LABEL_KEY}:${TEMPLATE_ROLE_SERVER}"
    TEMPLATE_STACK_CLIENT_NETWORK_SERVICES="kernel://${TEMPLATE_STACK_NETWORK_SERVICE_NAME}/nsm-1"
    TEMPLATE_STACK_SERVER_IPV4="${TEMPLATE_STACK_SERVICE_CIDR%%/*}"

    TEMPLATE_STACK_STATE_FILE="$(template_stack_state_file "${TEMPLATE_STACK_ID}")"
    TEMPLATE_STACK_GENERATED_DIR="$(template_stack_generated_dir_for "${TEMPLATE_STACK_ID}")"
    TEMPLATE_STACK_PATCH_DIR="${TEMPLATE_STACK_GENERATED_DIR}/patches"
    TEMPLATE_STACK_RESOLVED_VALUES_FILE="${TEMPLATE_STACK_GENERATED_DIR}/resolved-values.env"
}

template_stack_resolve_role_node() {
    local role_label=$1
    local requested_value=$2
    local persisted_value=$3
    local persisted_origin_source=$4
    local target_value_name=$5
    local target_source_name=$6
    local target_origin_name=$7
    local resolved_value resolved_source resolved_origin

    if [[ -n "${requested_value}" ]]; then
        resolved_value="${requested_value}"
        resolved_source='override'
        resolved_origin='override'
        if [[ "${persisted_value}" != "${requested_value}" ]]; then
            TEMPLATE_STACK_STATE_NEEDS_WRITE='true'
        fi
    elif [[ -n "${persisted_value}" ]]; then
        resolved_value="${persisted_value}"
        resolved_source='persisted'
        resolved_origin="${persisted_origin_source:-persisted}"
    else
        resolved_value="$(template_stack_default_role_node "${role_label}")"
        resolved_source='default'
        resolved_origin='default'
        TEMPLATE_STACK_STATE_NEEDS_WRITE='true'
    fi

    template_stack_validate_node_name "${resolved_value}" "${role_label} node"
    printf -v "${target_value_name}" '%s' "${resolved_value}"
    printf -v "${target_source_name}" '%s' "${resolved_source}"
    printf -v "${target_origin_name}" '%s' "${resolved_origin}"
}

template_stack_load_state() {
    local stack_id=$1
    local state_file
    local -A state_map=()

    state_file="$(template_stack_state_file "${stack_id}")"
    [[ -f "${state_file}" ]] || return 1

    platform_load_env_file "${state_file}" state_map

    TEMPLATE_STACK_ID="${state_map[STACK_ID]:-${stack_id}}"
    TEMPLATE_STACK_NAMESPACE="${state_map[STACK_NAMESPACE]:-}"
    TEMPLATE_STACK_NAMESPACE_SOURCE='persisted'
    TEMPLATE_STACK_NAMESPACE_ORIGIN_SOURCE="${state_map[STACK_NAMESPACE_ORIGIN_SOURCE]:-persisted}"
    TEMPLATE_STACK_NETWORK_SERVICE_NAME="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
    TEMPLATE_STACK_NETWORK_SERVICE_NAME_SOURCE='persisted'
    TEMPLATE_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE="${state_map[STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE]:-persisted}"
    TEMPLATE_STACK_SERVICE_CIDR="${state_map[STACK_SERVICE_CIDR]:-}"
    TEMPLATE_STACK_SERVICE_CIDR_SOURCE='persisted'
    TEMPLATE_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${state_map[STACK_SERVICE_CIDR_ORIGIN_SOURCE]:-persisted}"
    TEMPLATE_STACK_VNF_NODE_PERSISTED="${state_map[STACK_VNF_NODE]:-}"
    TEMPLATE_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_VNF_NODE_ORIGIN_SOURCE]:-persisted}"
    TEMPLATE_STACK_CLIENT_NODE_PERSISTED="${state_map[STACK_CLIENT_NODE]:-}"
    TEMPLATE_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_CLIENT_NODE_ORIGIN_SOURCE]:-persisted}"
    TEMPLATE_STACK_SERVER_NODE_PERSISTED="${state_map[STACK_SERVER_NODE]:-}"
    TEMPLATE_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_SERVER_NODE_ORIGIN_SOURCE]:-persisted}"
    TEMPLATE_STACK_CIDR_POOL="${state_map[STACK_CIDR_POOL]:-${TEMPLATE_CIDR_POOL}}"
    TEMPLATE_STACK_CIDR_PREFIX_LEN="${state_map[STACK_CIDR_PREFIX_LEN]:-${TEMPLATE_CIDR_PREFIX_LEN}}"
    TEMPLATE_STACK_STATE_CREATED_AT="${state_map[STACK_STATE_CREATED_AT]:-}"
    TEMPLATE_STACK_STATE_CREATED_AT_LOCAL="${state_map[STACK_STATE_CREATED_AT_LOCAL]:-}"
    TEMPLATE_STACK_STATE_CREATED_AT_EPOCH_MS="${state_map[STACK_STATE_CREATED_AT_EPOCH_MS]:-}"

    if [[ -z "${TEMPLATE_STACK_STATE_CREATED_AT_LOCAL}" && -n "${TEMPLATE_STACK_STATE_CREATED_AT}" ]]; then
        TEMPLATE_STACK_STATE_CREATED_AT_LOCAL="$(platform_rfc3339_to_local_iso8601 "${TEMPLATE_STACK_STATE_CREATED_AT}")"
    fi

    if [[ -z "${TEMPLATE_STACK_STATE_CREATED_AT_EPOCH_MS}" && -n "${TEMPLATE_STACK_STATE_CREATED_AT}" ]]; then
        TEMPLATE_STACK_STATE_CREATED_AT_EPOCH_MS="$(platform_rfc3339_to_epoch_ms "${TEMPLATE_STACK_STATE_CREATED_AT}")"
    fi

    [[ -n "${TEMPLATE_STACK_NAMESPACE}" ]] || die "persisted template stack namespace missing in ${state_file}"
    [[ -n "${TEMPLATE_STACK_NETWORK_SERVICE_NAME}" ]] || die "persisted template stack network service missing in ${state_file}"
    [[ -n "${TEMPLATE_STACK_SERVICE_CIDR}" ]] || die "persisted template stack service CIDR missing in ${state_file}"

    template_stack_set_derived_values
    return 0
}

template_stack_require_state_match() {
    local field_name=$1
    local requested_value=$2
    local persisted_value=$3

    [[ -n "${requested_value}" ]] || return 0
    [[ "${requested_value}" == "${persisted_value}" ]] || die "template stack ${TEMPLATE_STACK_ID} already persisted ${field_name}=${persisted_value}; override ${requested_value} is not allowed"
}

template_stack_each_other_state() {
    local current_stack_id=$1
    local state_file

    shopt -s nullglob
    for state_file in "${TEMPLATE_STACK_STATE_ROOT}"/*.env; do
        [[ "${state_file}" == "$(template_stack_state_file "${current_stack_id}")" ]] && continue
        printf '%s\n' "${state_file}"
    done
    shopt -u nullglob
}

template_stack_collect_other_state_details() {
    local current_state_file=$1
    local files_name=$2
    local stack_ids_name=$3
    local namespaces_name=$4
    local network_services_name=$5
    local cidrs_name=$6
    local state_file other_stack_id other_namespace other_network_service other_cidr
    local raw_line key value
    local -n files_ref="${files_name}"
    local -n stack_ids_ref="${stack_ids_name}"
    local -n namespaces_ref="${namespaces_name}"
    local -n network_services_ref="${network_services_name}"
    local -n cidrs_ref="${cidrs_name}"

    files_ref=()
    stack_ids_ref=()
    namespaces_ref=()
    network_services_ref=()
    cidrs_ref=()

    shopt -s nullglob
    for state_file in "${STACK_STATE_ROOT}"/*.env; do
        [[ "${state_file}" == "${current_state_file}" ]] && continue

        other_stack_id=''
        other_namespace=''
        other_network_service=''
        other_cidr=''

        while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
            [[ -n "${raw_line}" ]] || continue
            [[ "${raw_line}" == \#* ]] && continue
            [[ "${raw_line}" == *=* ]] || continue

            key=${raw_line%%=*}
            value=${raw_line#*=}
            value=${value%$'\r'}

            case "${key}" in
                STACK_ID)
                    other_stack_id="${value}"
                    ;;
                STACK_NAMESPACE)
                    other_namespace="${value}"
                    ;;
                STACK_NETWORK_SERVICE_NAME)
                    other_network_service="${value}"
                    ;;
                STACK_SERVICE_CIDR)
                    other_cidr="${value}"
                    ;;
            esac
        done < "${state_file}"

        if [[ -z "${other_stack_id}" ]]; then
            other_stack_id="$(basename "${state_file}" .env)"
        fi

        files_ref+=("${state_file}")
        stack_ids_ref+=("${other_stack_id}")
        namespaces_ref+=("${other_namespace}")
        network_services_ref+=("${other_network_service}")
        cidrs_ref+=("${other_cidr}")
    done
    shopt -u nullglob
}

template_stack_assert_no_conflicts() {
    local state_file other_stack_id other_namespace other_network_service other_cidr
    local -A state_map=()

    for state_file in $(template_stack_each_other_state "${TEMPLATE_STACK_ID}"); do
        state_map=()
        platform_load_env_file "${state_file}" state_map
        other_stack_id="${state_map[STACK_ID]:-$(basename "${state_file}" .env)}"
        other_namespace="${state_map[STACK_NAMESPACE]:-}"
        other_network_service="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
        other_cidr="${state_map[STACK_SERVICE_CIDR]:-}"

        [[ -n "${other_namespace}" ]] || continue

        if [[ "${TEMPLATE_STACK_NAMESPACE}" == "${other_namespace}" ]]; then
            die "template namespace ${TEMPLATE_STACK_NAMESPACE} is already allocated to stack ${other_stack_id}"
        fi

        if [[ "${TEMPLATE_STACK_NETWORK_SERVICE_NAME}" == "${other_network_service}" ]]; then
            die "template network service ${TEMPLATE_STACK_NETWORK_SERVICE_NAME} is already allocated to stack ${other_stack_id}"
        fi

        if [[ -n "${other_cidr}" ]] && template_stack_cidrs_overlap "${TEMPLATE_STACK_SERVICE_CIDR}" "${other_cidr}"; then
            die "template service CIDR ${TEMPLATE_STACK_SERVICE_CIDR} overlaps stack ${other_stack_id} CIDR ${other_cidr}"
        fi
    done
}

template_stack_allocate_cidr() {
    local pool_cidr=$1
    local target_prefix_len=$2
    local pool_prefix_len=${pool_cidr#*/}
    local pool_network_int candidate_network_int candidate_cidr
    local candidate_end_int subnet_size subnet_count index other_cidr range_index
    local conflict
    local -a other_state_files=() other_stack_ids=() other_namespaces=() other_network_services=() other_cidrs=()
    local -a other_range_starts=() other_range_ends=()

    template_stack_validate_cidr_prefix "${pool_cidr}"
    [[ "${target_prefix_len}" =~ ^[0-9]+$ ]] || die "invalid template CIDR prefix len: ${target_prefix_len}"
    (( target_prefix_len >= pool_prefix_len && target_prefix_len <= 32 )) || die "template CIDR prefix len ${target_prefix_len} is incompatible with pool ${pool_cidr}"

    pool_network_int="$(template_stack_cidr_network_int "${pool_cidr}")"
    subnet_size=$(( 1 << (32 - target_prefix_len) ))
    subnet_count=$(( 1 << (target_prefix_len - pool_prefix_len) ))

    template_stack_collect_other_state_details \
        "$(template_stack_state_file "${TEMPLATE_STACK_ID}")" \
        other_state_files other_stack_ids other_namespaces other_network_services other_cidrs

    for other_cidr in "${other_cidrs[@]}"; do
        [[ -n "${other_cidr}" ]] || continue
        other_range_starts+=("$(template_stack_cidr_range_start "${other_cidr}")")
        other_range_ends+=("$(template_stack_cidr_range_end "${other_cidr}")")
    done

    for (( index = 0; index < subnet_count; index++ )); do
        candidate_network_int=$(( pool_network_int + index * subnet_size ))
        candidate_cidr="$(template_stack_int_to_ipv4 "${candidate_network_int}")/${target_prefix_len}"
        candidate_end_int=$(( candidate_network_int + subnet_size - 1 ))
        conflict=false

        for (( range_index = 0; range_index < ${#other_range_starts[@]}; range_index++ )); do
            if (( candidate_network_int <= other_range_ends[range_index] && other_range_starts[range_index] <= candidate_end_int )); then
                conflict=true
                break
            fi
        done

        if [[ "${conflict}" == "false" ]]; then
            printf '%s\n' "${candidate_cidr}"
            return 0
        fi
    done

    die "no free template service CIDR left in pool ${pool_cidr} with prefix len ${target_prefix_len}"
}

template_stack_write_state() {
    local created_at created_at_local created_at_epoch_ms

    created_at_local="${TEMPLATE_STACK_STATE_CREATED_AT_LOCAL:-}"
    created_at="${TEMPLATE_STACK_STATE_CREATED_AT:-}"
    created_at_epoch_ms="${TEMPLATE_STACK_STATE_CREATED_AT_EPOCH_MS:-}"

    if [[ -n "${created_at}" ]]; then
        if [[ -z "${created_at_local}" ]]; then
            created_at_local="$(platform_rfc3339_to_local_iso8601 "${created_at}")"
        fi
        if [[ -z "${created_at_epoch_ms}" ]]; then
            created_at_epoch_ms="$(platform_rfc3339_to_epoch_ms "${created_at}")"
        fi
    fi

    if [[ -z "${created_at}" ]]; then
        created_at_local="$(platform_now_local_iso8601)"
        created_at="$(platform_now_utc_iso8601)"
        created_at_epoch_ms="$(platform_now_epoch_ms)"
    fi

    cat > "${TEMPLATE_STACK_STATE_FILE}" <<EOF
STACK_ID=${TEMPLATE_STACK_ID}
STACK_NAMESPACE=${TEMPLATE_STACK_NAMESPACE}
STACK_NAMESPACE_ORIGIN_SOURCE=${TEMPLATE_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${TEMPLATE_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${TEMPLATE_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${TEMPLATE_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${TEMPLATE_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_VNF_NODE=${TEMPLATE_STACK_VNF_NODE}
STACK_VNF_NODE_ORIGIN_SOURCE=${TEMPLATE_STACK_VNF_NODE_ORIGIN_SOURCE}
STACK_CLIENT_NODE=${TEMPLATE_STACK_CLIENT_NODE}
STACK_CLIENT_NODE_ORIGIN_SOURCE=${TEMPLATE_STACK_CLIENT_NODE_ORIGIN_SOURCE}
STACK_SERVER_NODE=${TEMPLATE_STACK_SERVER_NODE}
STACK_SERVER_NODE_ORIGIN_SOURCE=${TEMPLATE_STACK_SERVER_NODE_ORIGIN_SOURCE}
STACK_CIDR_POOL=${TEMPLATE_STACK_CIDR_POOL}
STACK_CIDR_PREFIX_LEN=${TEMPLATE_STACK_CIDR_PREFIX_LEN}
STACK_STATE_CREATED_AT=${created_at}
STACK_STATE_CREATED_AT_LOCAL=${created_at_local}
STACK_STATE_CREATED_AT_EPOCH_MS=${created_at_epoch_ms}
EOF
    TEMPLATE_STACK_STATE_CREATED_AT="${created_at}"
    TEMPLATE_STACK_STATE_CREATED_AT_LOCAL="${created_at_local}"
    TEMPLATE_STACK_STATE_CREATED_AT_EPOCH_MS="${created_at_epoch_ms}"
}

template_stack_require_id() {
    TEMPLATE_STACK_ID="${TEMPLATE_STACK_ID_INPUT:-}"
    [[ -n "${TEMPLATE_STACK_ID}" ]] || die "missing required --stack-id for template stack operation"
    [[ "${PLATFORM_VALUE_SOURCE[TEMPLATE_STACK_ID_INPUT]}" == "cli" ]] || die "template stack operation requires an explicit --stack-id"
    template_stack_validate_id "${TEMPLATE_STACK_ID}"
}

template_stack_prepare_plan() {
    local requested_namespace requested_network_service requested_cidr
    local requested_vnf_node requested_client_node requested_server_node

    template_stack_plan_dirs
    template_stack_require_id

    requested_namespace="${TEMPLATE_NAMESPACE_OVERRIDE_INPUT:-}"
    requested_network_service="${TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT:-}"
    requested_cidr="${TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT:-}"
    requested_vnf_node="${TEMPLATE_VNF_NODE_INPUT:-}"
    requested_client_node="${TEMPLATE_CLIENT_NODE_INPUT:-}"
    requested_server_node="${TEMPLATE_SERVER_NODE_INPUT:-}"
    TEMPLATE_STACK_STATE_NEEDS_WRITE='false'

    if [[ -n "${requested_namespace}" ]]; then
        template_stack_validate_k8s_name "${requested_namespace}" "template namespace override"
    fi
    if [[ -n "${requested_network_service}" ]]; then
        template_stack_validate_k8s_name "${requested_network_service}" "template network service override"
    fi
    if [[ -n "${requested_cidr}" ]]; then
        template_stack_validate_cidr_prefix "${requested_cidr}"
    fi
    if [[ -n "${requested_vnf_node}" ]]; then
        template_stack_validate_node_name "${requested_vnf_node}" "template VNF node override"
    fi
    if [[ -n "${requested_client_node}" ]]; then
        template_stack_validate_node_name "${requested_client_node}" "template client node override"
    fi
    if [[ -n "${requested_server_node}" ]]; then
        template_stack_validate_node_name "${requested_server_node}" "template server node override"
    fi

    if template_stack_load_state "${TEMPLATE_STACK_ID}"; then
        template_stack_require_state_match "namespace" "${requested_namespace}" "${TEMPLATE_STACK_NAMESPACE}"
        template_stack_require_state_match "network_service_name" "${requested_network_service}" "${TEMPLATE_STACK_NETWORK_SERVICE_NAME}"
        template_stack_require_state_match "service_cidr" "${requested_cidr}" "${TEMPLATE_STACK_SERVICE_CIDR}"
        template_stack_resolve_role_node "template VNF" "${requested_vnf_node}" "${TEMPLATE_STACK_VNF_NODE_PERSISTED:-}" "${TEMPLATE_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" TEMPLATE_STACK_VNF_NODE TEMPLATE_STACK_VNF_NODE_SOURCE TEMPLATE_STACK_VNF_NODE_ORIGIN_SOURCE
        template_stack_resolve_role_node "template client" "${requested_client_node}" "${TEMPLATE_STACK_CLIENT_NODE_PERSISTED:-}" "${TEMPLATE_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" TEMPLATE_STACK_CLIENT_NODE TEMPLATE_STACK_CLIENT_NODE_SOURCE TEMPLATE_STACK_CLIENT_NODE_ORIGIN_SOURCE
        template_stack_resolve_role_node "template server" "${requested_server_node}" "${TEMPLATE_STACK_SERVER_NODE_PERSISTED:-}" "${TEMPLATE_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" TEMPLATE_STACK_SERVER_NODE TEMPLATE_STACK_SERVER_NODE_SOURCE TEMPLATE_STACK_SERVER_NODE_ORIGIN_SOURCE
        if [[ "${TEMPLATE_STACK_STATE_NEEDS_WRITE}" == "true" ]]; then
            template_stack_write_state
        fi
        return 0
    fi

    TEMPLATE_STACK_NAMESPACE="${requested_namespace:-$(template_stack_default_namespace "${TEMPLATE_STACK_ID}")}"
    TEMPLATE_STACK_NAMESPACE_SOURCE='default'
    TEMPLATE_STACK_NAMESPACE_ORIGIN_SOURCE='default'
    if [[ -n "${requested_namespace}" ]]; then
        TEMPLATE_STACK_NAMESPACE_SOURCE='override'
        TEMPLATE_STACK_NAMESPACE_ORIGIN_SOURCE='override'
    fi

    TEMPLATE_STACK_NETWORK_SERVICE_NAME="${requested_network_service:-$(template_stack_default_network_service_name "${TEMPLATE_STACK_ID}")}"
    TEMPLATE_STACK_NETWORK_SERVICE_NAME_SOURCE='default'
    TEMPLATE_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='default'
    if [[ -n "${requested_network_service}" ]]; then
        TEMPLATE_STACK_NETWORK_SERVICE_NAME_SOURCE='override'
        TEMPLATE_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='override'
    fi

    TEMPLATE_STACK_CIDR_POOL="${TEMPLATE_CIDR_POOL}"
    TEMPLATE_STACK_CIDR_PREFIX_LEN="${TEMPLATE_CIDR_PREFIX_LEN}"
    if [[ -n "${requested_cidr}" ]]; then
        TEMPLATE_STACK_SERVICE_CIDR="${requested_cidr}"
        TEMPLATE_STACK_SERVICE_CIDR_SOURCE='override'
        TEMPLATE_STACK_SERVICE_CIDR_ORIGIN_SOURCE='override'
    else
        TEMPLATE_STACK_SERVICE_CIDR="$(template_stack_allocate_cidr "${TEMPLATE_STACK_CIDR_POOL}" "${TEMPLATE_STACK_CIDR_PREFIX_LEN}")"
        TEMPLATE_STACK_SERVICE_CIDR_SOURCE='allocated'
        TEMPLATE_STACK_SERVICE_CIDR_ORIGIN_SOURCE='allocated'
    fi

    template_stack_validate_k8s_name "${TEMPLATE_STACK_NAMESPACE}" "template namespace"
    template_stack_validate_k8s_name "${TEMPLATE_STACK_NETWORK_SERVICE_NAME}" "template network service name"
    template_stack_resolve_role_node "template VNF" "${requested_vnf_node}" "" "" TEMPLATE_STACK_VNF_NODE TEMPLATE_STACK_VNF_NODE_SOURCE TEMPLATE_STACK_VNF_NODE_ORIGIN_SOURCE
    template_stack_resolve_role_node "template client" "${requested_client_node}" "" "" TEMPLATE_STACK_CLIENT_NODE TEMPLATE_STACK_CLIENT_NODE_SOURCE TEMPLATE_STACK_CLIENT_NODE_ORIGIN_SOURCE
    template_stack_resolve_role_node "template server" "${requested_server_node}" "" "" TEMPLATE_STACK_SERVER_NODE TEMPLATE_STACK_SERVER_NODE_SOURCE TEMPLATE_STACK_SERVER_NODE_ORIGIN_SOURCE
    template_stack_set_derived_values
    template_stack_assert_no_conflicts
    template_stack_write_state
}

template_stack_require_existing_state() {
    local state_file

    template_stack_require_id
    state_file="$(template_stack_state_file "${TEMPLATE_STACK_ID}")"
    [[ -f "${state_file}" ]] || die "template stack state not found: ${state_file}; run ./bin/nsm-ovs-lab show-template-plan --stack-id ${TEMPLATE_STACK_ID} or deploy-template --stack-id ${TEMPLATE_STACK_ID} first"
}

template_stack_write_resolved_values() {
    cat > "${TEMPLATE_STACK_RESOLVED_VALUES_FILE}" <<EOF
STACK_ID=${TEMPLATE_STACK_ID}
STACK_NAMESPACE=${TEMPLATE_STACK_NAMESPACE}
STACK_NAMESPACE_SOURCE=${TEMPLATE_STACK_NAMESPACE_SOURCE}
STACK_NAMESPACE_ORIGIN_SOURCE=${TEMPLATE_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${TEMPLATE_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_SOURCE=${TEMPLATE_STACK_NETWORK_SERVICE_NAME_SOURCE}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${TEMPLATE_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${TEMPLATE_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_SOURCE=${TEMPLATE_STACK_SERVICE_CIDR_SOURCE}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${TEMPLATE_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_LABEL=${TEMPLATE_STACK_LABEL}
STACK_LABEL_KEY=${TEMPLATE_STACK_LABEL_KEY}
STACK_LABEL_VALUE=${TEMPLATE_STACK_LABEL_VALUE}
ROLE_LABEL_KEY=${TEMPLATE_ROLE_LABEL_KEY}
ROLE_CLIENT=${TEMPLATE_ROLE_CLIENT}
ROLE_MIDDLE=${TEMPLATE_ROLE_MIDDLE}
ROLE_SERVER=${TEMPLATE_ROLE_SERVER}
TEMPLATE_DEPLOYMENT_NAME=${TEMPLATE_STACK_TEMPLATE_DEPLOYMENT_NAME}
SERVER_DEPLOYMENT_NAME=${TEMPLATE_STACK_SERVER_DEPLOYMENT_NAME}
CLIENT_DEPLOYMENT_NAME=${TEMPLATE_STACK_CLIENT_DEPLOYMENT_NAME}
TEMPLATE_POD_SELECTOR=${TEMPLATE_STACK_TEMPLATE_POD_SELECTOR}
SERVER_POD_SELECTOR=${TEMPLATE_STACK_SERVER_POD_SELECTOR}
CLIENT_POD_SELECTOR=${TEMPLATE_STACK_CLIENT_POD_SELECTOR}
TEMPLATE_NSM_LABELS=${TEMPLATE_STACK_TEMPLATE_NSM_LABELS}
SERVER_NSM_LABELS=${TEMPLATE_STACK_SERVER_NSM_LABELS}
CLIENT_NETWORK_SERVICES=${TEMPLATE_STACK_CLIENT_NETWORK_SERVICES}
SERVER_IPV4=${TEMPLATE_STACK_SERVER_IPV4}
VNF_NODE=${TEMPLATE_STACK_VNF_NODE}
VNF_NODE_SOURCE=${TEMPLATE_STACK_VNF_NODE_SOURCE}
VNF_NODE_ORIGIN_SOURCE=${TEMPLATE_STACK_VNF_NODE_ORIGIN_SOURCE}
CLIENT_NODE=${TEMPLATE_STACK_CLIENT_NODE}
CLIENT_NODE_SOURCE=${TEMPLATE_STACK_CLIENT_NODE_SOURCE}
CLIENT_NODE_ORIGIN_SOURCE=${TEMPLATE_STACK_CLIENT_NODE_ORIGIN_SOURCE}
SERVER_NODE=${TEMPLATE_STACK_SERVER_NODE}
SERVER_NODE_SOURCE=${TEMPLATE_STACK_SERVER_NODE_SOURCE}
SERVER_NODE_ORIGIN_SOURCE=${TEMPLATE_STACK_SERVER_NODE_ORIGIN_SOURCE}
STATE_FILE=${TEMPLATE_STACK_STATE_FILE}
GENERATED_DIR=${TEMPLATE_STACK_GENERATED_DIR}
CIDR_POOL=${TEMPLATE_STACK_CIDR_POOL}
CIDR_PREFIX_LEN=${TEMPLATE_STACK_CIDR_PREFIX_LEN}
PCM_DEPLOYMENT_MODE=${PCM_DEPLOYMENT_MODE:-in-cluster}
CPU_PIN_MODE=${CPU_PIN_MODE:-off}
CPU_PIN_GUARANTEED_QOS_ENABLED=$(template_stack_cpu_pin_guaranteed_qos_state)
CPU_PIN_STRICT_AFFINITY_ENABLED=$(template_stack_cpu_pin_strict_affinity_state)
EOF
}

template_stack_write_kustomization() {
    cat > "${TEMPLATE_STACK_GENERATED_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${TEMPLATE_STACK_NAMESPACE}

resources:
  - ../../../assets/template/k8s

patches:
  - path: patches/00-namespace.yaml
    target:
      kind: Namespace
      name: nse-ovs-template
  - path: patches/10-networkservice.yaml
    target:
      group: networkservicemesh.io
      version: v1
      kind: NetworkService
      name: nse-ovs-template
  - path: patches/20-nse-ovs-template.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-template
  - path: patches/30-nse-ovs-server.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-server
  - path: patches/40-nsc-ovs-client.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nsc-ovs-client
EOF
}

template_stack_write_namespace_patch() {
    cat > "${TEMPLATE_STACK_PATCH_DIR}/00-namespace.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${TEMPLATE_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
EOF
}

template_stack_write_networkservice_patch() {
    cat > "${TEMPLATE_STACK_PATCH_DIR}/10-networkservice.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${TEMPLATE_STACK_NETWORK_SERVICE_NAME}
- op: replace
  path: /metadata/namespace
  value: ${TEMPLATE_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/matches
  value:
    - source_selector:
        ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
        ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_MIDDLE}
      routes:
        - destination_selector:
            ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
            ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_SERVER}
    - routes:
        - destination_selector:
            ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
            ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_MIDDLE}
EOF
}

template_stack_write_template_patch() {
    local patch_file="${TEMPLATE_STACK_PATCH_DIR}/20-nse-ovs-template.yaml"

    cat > "${patch_file}" <<EOF
- op: replace
  path: /metadata/name
  value: ${TEMPLATE_STACK_TEMPLATE_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${TEMPLATE_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${TEMPLATE_STACK_TEMPLATE_DEPLOYMENT_NAME}
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_MIDDLE}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${TEMPLATE_STACK_TEMPLATE_DEPLOYMENT_NAME}
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_MIDDLE}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${TEMPLATE_STACK_TEMPLATE_DEPLOYMENT_NAME}
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_MIDDLE}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${TEMPLATE_STACK_VNF_NODE}
- op: replace
  path: /spec/template/spec/containers/0/env
  value:
    - name: SPIFFE_ENDPOINT_SOCKET
      value: unix:///run/spire/sockets/agent.sock
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: NSM_NAME
      value: "\$(POD_NAME)"
    - name: NSM_SERVICE_NAME
      value: ${TEMPLATE_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_LABELS
      value: ${TEMPLATE_STACK_TEMPLATE_NSM_LABELS}
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
EOF

    if template_stack_cpu_pin_guaranteed_qos_enabled; then
        template_stack_append_resources_patch "${patch_file}" "/spec/template/spec/containers/0/resources" "1" "512Mi"
    fi
}

template_stack_write_server_patch() {
    local patch_file="${TEMPLATE_STACK_PATCH_DIR}/30-nse-ovs-server.yaml"

    cat > "${patch_file}" <<EOF
- op: replace
  path: /metadata/name
  value: ${TEMPLATE_STACK_SERVER_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${TEMPLATE_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${TEMPLATE_STACK_SERVER_DEPLOYMENT_NAME}
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_SERVER}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${TEMPLATE_STACK_SERVER_DEPLOYMENT_NAME}
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_SERVER}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${TEMPLATE_STACK_SERVER_DEPLOYMENT_NAME}
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_SERVER}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${TEMPLATE_STACK_SERVER_NODE}
- op: replace
  path: /spec/template/spec/containers/0/env
  value:
    - name: SPIFFE_ENDPOINT_SOCKET
      value: unix:///run/spire/sockets/agent.sock
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: NSM_NAME
      value: "\$(POD_NAME)"
    - name: NSM_CIDR_PREFIX
      value: ${TEMPLATE_STACK_SERVICE_CIDR}
    - name: NSM_SERVICE_NAMES
      value: ${TEMPLATE_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_REGISTER_SERVICE
      value: "false"
    - name: NSM_LABELS
      value: ${TEMPLATE_STACK_SERVER_NSM_LABELS}
    - name: NSM_LOG_LEVEL
      value: INFO
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
    - name: IPERF3_PORT
      value: "5201"
EOF

    if template_stack_cpu_pin_guaranteed_qos_enabled; then
        template_stack_append_resources_patch "${patch_file}" "/spec/template/spec/containers/0/resources" "1" "512Mi"
    fi
}

template_stack_write_client_patch() {
    local patch_file="${TEMPLATE_STACK_PATCH_DIR}/40-nsc-ovs-client.yaml"

    cat > "${patch_file}" <<EOF
- op: replace
  path: /metadata/name
  value: ${TEMPLATE_STACK_CLIENT_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${TEMPLATE_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${TEMPLATE_STACK_CLIENT_DEPLOYMENT_NAME}
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_CLIENT}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${TEMPLATE_STACK_CLIENT_DEPLOYMENT_NAME}
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_CLIENT}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${TEMPLATE_STACK_CLIENT_DEPLOYMENT_NAME}
    ${TEMPLATE_STACK_LABEL_KEY}: ${TEMPLATE_STACK_ID}
    ${TEMPLATE_ROLE_LABEL_KEY}: ${TEMPLATE_ROLE_CLIENT}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${TEMPLATE_STACK_CLIENT_NODE}
- op: replace
  path: /spec/template/spec/initContainers/0/env
  value:
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: SPIFFE_ENDPOINT_SOCKET
      value: unix:///run/spire/sockets/agent.sock
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    - name: NSM_NETWORK_SERVICES
      value: ${TEMPLATE_STACK_CLIENT_NETWORK_SERVICES}
    - name: NSM_NAME
      value: "\$(POD_NAME)-\$(POD_UID)"
- op: replace
  path: /spec/template/spec/containers/1/env
  value:
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_LIVENESS_CHECK_ENABLED
      value: "false"
    - name: SPIFFE_ENDPOINT_SOCKET
      value: unix:///run/spire/sockets/agent.sock
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    - name: NSM_NETWORK_SERVICES
      value: ${TEMPLATE_STACK_CLIENT_NETWORK_SERVICES}
    - name: NSM_NAME
      value: "\$(POD_NAME)-\$(POD_UID)"
EOF

    if template_stack_cpu_pin_guaranteed_qos_enabled; then
        template_stack_append_resources_patch "${patch_file}" "/spec/template/spec/initContainers/0/resources" "1" "256Mi"
        template_stack_append_resources_patch "${patch_file}" "/spec/template/spec/containers/0/resources" "1" "512Mi"
        template_stack_append_resources_patch "${patch_file}" "/spec/template/spec/containers/1/resources" "1" "256Mi"
    fi
}

template_stack_render() {
    rm -rf "${TEMPLATE_STACK_GENERATED_DIR}"
    mkdir -p "${TEMPLATE_STACK_PATCH_DIR}"

    template_stack_write_kustomization
    template_stack_write_namespace_patch
    template_stack_write_networkservice_patch
    template_stack_write_template_patch
    template_stack_write_server_patch
    template_stack_write_client_patch
    template_stack_write_resolved_values
}

template_stack_apply_runtime_context() {
    TEMPLATE_RUNTIME_ROOT="${TEMPLATE_STACK_GENERATED_DIR}"
    TEMPLATE_K8S_DIR="${TEMPLATE_STACK_GENERATED_DIR}"
    TEMPLATE_VERIFY_SCRIPT="${TEMPLATE_VERIFY_ASSET_SCRIPT}"
    TEMPLATE_NAMESPACE="${TEMPLATE_STACK_NAMESPACE}"
    TEMPLATE_NETWORK_SERVICE_NAME="${TEMPLATE_STACK_NETWORK_SERVICE_NAME}"
    TEMPLATE_DEPLOYMENT_NAME="${TEMPLATE_STACK_TEMPLATE_DEPLOYMENT_NAME}"
    TEMPLATE_SERVER_DEPLOYMENT_NAME="${TEMPLATE_STACK_SERVER_DEPLOYMENT_NAME}"
    TEMPLATE_CLIENT_DEPLOYMENT_NAME="${TEMPLATE_STACK_CLIENT_DEPLOYMENT_NAME}"
    TEMPLATE_SERVICE_NAME="${TEMPLATE_STACK_NETWORK_SERVICE_NAME}"
    TEMPLATE_SERVER_CIDR_PREFIX="${TEMPLATE_STACK_SERVICE_CIDR}"
    TEMPLATE_SERVER_IPV4="${TEMPLATE_STACK_SERVER_IPV4}"
    TEMPLATE_MIDDLE_POD_SELECTOR="${TEMPLATE_STACK_TEMPLATE_POD_SELECTOR}"
    TEMPLATE_SERVER_POD_SELECTOR="${TEMPLATE_STACK_SERVER_POD_SELECTOR}"
    TEMPLATE_CLIENT_POD_SELECTOR="${TEMPLATE_STACK_CLIENT_POD_SELECTOR}"
}

template_stack_prepare_rendered_runtime() {
    template_init_runtime_context
    template_require_runtime_assets
    template_stack_prepare_plan
    template_stack_render
    template_stack_apply_runtime_context
}

template_stack_prepare_existing_rendered_runtime() {
    template_init_runtime_context
    template_require_runtime_assets
    template_stack_require_existing_state
    template_stack_prepare_plan
    template_stack_render
    template_stack_apply_runtime_context
}

template_stack_print_plan() {
    printf 'stack_id: %s [source=cli]\n' "${TEMPLATE_STACK_ID}"
    printf 'state file: %s\n' "${TEMPLATE_STACK_STATE_FILE}"
    printf 'generated dir: %s\n' "${TEMPLATE_STACK_GENERATED_DIR}"
    printf 'namespace: %s [source=%s origin=%s]\n' "${TEMPLATE_STACK_NAMESPACE}" "${TEMPLATE_STACK_NAMESPACE_SOURCE}" "${TEMPLATE_STACK_NAMESPACE_ORIGIN_SOURCE}"
    printf 'network_service_name: %s [source=%s origin=%s]\n' "${TEMPLATE_STACK_NETWORK_SERVICE_NAME}" "${TEMPLATE_STACK_NETWORK_SERVICE_NAME_SOURCE}" "${TEMPLATE_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}"
    printf 'service_cidr: %s [source=%s origin=%s]\n' "${TEMPLATE_STACK_SERVICE_CIDR}" "${TEMPLATE_STACK_SERVICE_CIDR_SOURCE}" "${TEMPLATE_STACK_SERVICE_CIDR_ORIGIN_SOURCE}"
    printf 'stack_label: %s [source=derived]\n' "${TEMPLATE_STACK_LABEL}"
    printf 'role_label.client: %s=%s [source=derived]\n' "${TEMPLATE_ROLE_LABEL_KEY}" "${TEMPLATE_ROLE_CLIENT}"
    printf 'role_label.middle: %s=%s [source=derived]\n' "${TEMPLATE_ROLE_LABEL_KEY}" "${TEMPLATE_ROLE_MIDDLE}"
    printf 'role_label.server: %s=%s [source=derived]\n' "${TEMPLATE_ROLE_LABEL_KEY}" "${TEMPLATE_ROLE_SERVER}"
    printf 'template deployment: %s [source=derived]\n' "${TEMPLATE_STACK_TEMPLATE_DEPLOYMENT_NAME}"
    printf 'server deployment: %s [source=derived]\n' "${TEMPLATE_STACK_SERVER_DEPLOYMENT_NAME}"
    printf 'client deployment: %s [source=derived]\n' "${TEMPLATE_STACK_CLIENT_DEPLOYMENT_NAME}"
    printf 'vnf_node: %s [source=%s origin=%s]\n' "${TEMPLATE_STACK_VNF_NODE}" "${TEMPLATE_STACK_VNF_NODE_SOURCE}" "${TEMPLATE_STACK_VNF_NODE_ORIGIN_SOURCE}"
    printf 'client_node: %s [source=%s origin=%s]\n' "${TEMPLATE_STACK_CLIENT_NODE}" "${TEMPLATE_STACK_CLIENT_NODE_SOURCE}" "${TEMPLATE_STACK_CLIENT_NODE_ORIGIN_SOURCE}"
    printf 'server_node: %s [source=%s origin=%s]\n' "${TEMPLATE_STACK_SERVER_NODE}" "${TEMPLATE_STACK_SERVER_NODE_SOURCE}" "${TEMPLATE_STACK_SERVER_NODE_ORIGIN_SOURCE}"
    printf 'template env.NSM_SERVICE_NAME: %s [source=derived]\n' "${TEMPLATE_STACK_NETWORK_SERVICE_NAME}"
    printf 'template env.NSM_LABELS: %s [source=derived]\n' "${TEMPLATE_STACK_TEMPLATE_NSM_LABELS}"
    printf 'server env.NSM_SERVICE_NAMES: %s [source=derived]\n' "${TEMPLATE_STACK_NETWORK_SERVICE_NAME}"
    printf 'server env.NSM_CIDR_PREFIX: %s [source=derived]\n' "${TEMPLATE_STACK_SERVICE_CIDR}"
    printf 'server env.NSM_LABELS: %s [source=derived]\n' "${TEMPLATE_STACK_SERVER_NSM_LABELS}"
    printf 'client env.NSM_NETWORK_SERVICES: %s [source=derived]\n' "${TEMPLATE_STACK_CLIENT_NETWORK_SERVICES}"
    printf 'cidr pool: %s [source=%s]\n' "${TEMPLATE_STACK_CIDR_POOL}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_POOL]}"
    printf 'cidr prefix len: %s [source=%s]\n' "${TEMPLATE_STACK_CIDR_PREFIX_LEN}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_PREFIX_LEN]}"
    printf 'pcm_deployment_mode: %s [source=%s]\n' "${PCM_DEPLOYMENT_MODE:-in-cluster}" "${PLATFORM_VALUE_SOURCE[PCM_DEPLOYMENT_MODE]}"
    if [[ "${PCM_DEPLOYMENT_MODE:-in-cluster}" == "host-transition" ]]; then
        printf 'measurement_backend: %s [source=derived:PCM_DEPLOYMENT_MODE]\n' "node01-host-managed"
    else
        printf 'measurement_backend: %s [source=derived:PCM_DEPLOYMENT_MODE]\n' "cluster-vm"
    fi
    printf 'cpu_pin_mode: %s [source=%s]\n' "${CPU_PIN_MODE:-off}" "${PLATFORM_VALUE_SOURCE[CPU_PIN_MODE]}"
    printf 'cpu_pin_guaranteed_qos_enabled: %s [source=derived]\n' "$(template_stack_cpu_pin_guaranteed_qos_state)"
    printf 'cpu_pin_strict_affinity_enabled: %s [source=derived]\n' "$(template_stack_cpu_pin_strict_affinity_state)"
}
