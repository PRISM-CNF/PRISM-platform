#!/usr/bin/env bash

if [[ -n "${NSM_OVS_NAT_STACK_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_NAT_STACK_SH_LOADED=1

NAT_STACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${NAT_STACK_LIB_DIR}/template_stack.sh"

nat_stack_default_role_node() {
    local role_label=${1:-}

    case "${role_label}" in
        vnf|middle|nat)
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

nat_stack_name_suffix() {
    local stack_id=$1

    if [[ "${stack_id}" == nat-* && "${stack_id#nat-}" != "${stack_id}" ]]; then
        printf '%s\n' "${stack_id#nat-}"
    else
        printf '%s\n' "${stack_id}"
    fi
}

nat_stack_default_namespace() {
    local stack_id=$1
    printf 'exp-%s\n' "${stack_id}"
}

nat_stack_default_network_service_name() {
    local stack_id=$1
    local suffix

    suffix="$(nat_stack_name_suffix "${stack_id}")"
    printf 'nse-ovs-nat-%s\n' "${suffix}"
}

nat_stack_state_file() {
    local stack_id=$1
    printf '%s/%s.env\n' "${NAT_STACK_STATE_ROOT}" "${stack_id}"
}

nat_stack_generated_dir_for() {
    local stack_id=$1
    printf '%s/%s\n' "${NAT_GENERATED_ROOT}" "${stack_id}"
}

nat_stack_plan_dirs() {
    mkdir -p "${NAT_STACK_STATE_ROOT}" "${NAT_GENERATED_ROOT}"
}

nat_stack_calculate_virtual_ipv4() {
    local backend_ipv4=$1
    local backend_int virtual_int

    backend_int="$(template_stack_ipv4_to_int "${backend_ipv4}")"
    virtual_int=$((backend_int + 10))
    template_stack_int_to_ipv4 "${virtual_int}"
}

nat_stack_virtual_cidr() {
    local virtual_ipv4=$1
    printf '%s/32\n' "${virtual_ipv4}"
}

nat_stack_state_conflict_cidrs() {
    local state_file=$1
    local other_service_cidr other_backend_cidr other_virtual_ipv4
    local raw_line key value

    other_service_cidr=''
    other_backend_cidr=''
    other_virtual_ipv4=''

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        [[ -n "${raw_line}" ]] || continue
        [[ "${raw_line}" == \#* ]] && continue
        [[ "${raw_line}" == *=* ]] || continue

        key=${raw_line%%=*}
        value=${raw_line#*=}
        value=${value%$'\r'}

        case "${key}" in
            STACK_SERVICE_CIDR)
                other_service_cidr="${value}"
                ;;
            STACK_BACKEND_CIDR)
                other_backend_cidr="${value}"
                ;;
            STACK_VIRTUAL_IPV4)
                other_virtual_ipv4="${value}"
                ;;
        esac
    done < "${state_file}"

    if [[ -n "${other_service_cidr}" ]]; then
        printf '%s\n' "${other_service_cidr}"
    fi

    if [[ -n "${other_backend_cidr}" && "${other_backend_cidr}" != "${other_service_cidr}" ]]; then
        printf '%s\n' "${other_backend_cidr}"
    fi

    if [[ -n "${other_virtual_ipv4}" ]]; then
        nat_stack_virtual_cidr "${other_virtual_ipv4}"
    fi
}

nat_stack_set_derived_values() {
    local name_suffix

    name_suffix="$(nat_stack_name_suffix "${NAT_STACK_ID}")"

    NAT_STACK_LABEL_KEY='exp.nsm.ai/stack'
    NAT_ROLE_LABEL_KEY='exp.nsm.ai/role'
    NAT_STACK_LABEL_VALUE="${NAT_STACK_ID}"
    NAT_STACK_LABEL="${NAT_STACK_LABEL_KEY}=${NAT_STACK_LABEL_VALUE}"

    NAT_ROLE_CLIENT='client'
    NAT_ROLE_MIDDLE='middle'
    NAT_ROLE_SERVER='server'

    NAT_STACK_MIDDLE_DEPLOYMENT_NAME="nse-ovs-nat-${name_suffix}"
    NAT_STACK_SERVER_DEPLOYMENT_NAME="nse-ovs-server-${name_suffix}"
    NAT_STACK_CLIENT_DEPLOYMENT_NAME="nsc-ovs-client-${name_suffix}"
    NAT_STACK_RULES_CONFIGMAP_NAME='nse-ovs-nat-rules'
    NAT_STACK_RULES_TUPLE_PATCH_ENABLED='true'

    NAT_STACK_MIDDLE_POD_SELECTOR="${NAT_STACK_LABEL_KEY}=${NAT_STACK_ID},${NAT_ROLE_LABEL_KEY}=${NAT_ROLE_MIDDLE}"
    NAT_STACK_SERVER_POD_SELECTOR="${NAT_STACK_LABEL_KEY}=${NAT_STACK_ID},${NAT_ROLE_LABEL_KEY}=${NAT_ROLE_SERVER}"
    NAT_STACK_CLIENT_POD_SELECTOR="${NAT_STACK_LABEL_KEY}=${NAT_STACK_ID},${NAT_ROLE_LABEL_KEY}=${NAT_ROLE_CLIENT}"

    NAT_STACK_MIDDLE_NSM_LABELS="${NAT_STACK_LABEL_KEY}:${NAT_STACK_ID},${NAT_ROLE_LABEL_KEY}:${NAT_ROLE_MIDDLE}"
    NAT_STACK_SERVER_NSM_LABELS="${NAT_STACK_LABEL_KEY}:${NAT_STACK_ID},${NAT_ROLE_LABEL_KEY}:${NAT_ROLE_SERVER}"
    NAT_STACK_CLIENT_NETWORK_SERVICES="kernel://${NAT_STACK_NETWORK_SERVICE_NAME}/nsm-1"

    if [[ -z "${NAT_STACK_BACKEND_CIDR:-}" ]]; then
        NAT_STACK_BACKEND_CIDR="${NAT_STACK_SERVICE_CIDR}"
        NAT_STACK_BACKEND_CIDR_SOURCE="${NAT_STACK_SERVICE_CIDR_SOURCE:-derived}"
        NAT_STACK_BACKEND_CIDR_ORIGIN_SOURCE="${NAT_STACK_SERVICE_CIDR_ORIGIN_SOURCE:-derived}"
    fi

    if [[ -z "${NAT_STACK_SERVICE_CIDR:-}" ]]; then
        NAT_STACK_SERVICE_CIDR="${NAT_STACK_BACKEND_CIDR}"
        NAT_STACK_SERVICE_CIDR_SOURCE="${NAT_STACK_BACKEND_CIDR_SOURCE:-derived}"
        NAT_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${NAT_STACK_BACKEND_CIDR_ORIGIN_SOURCE:-derived}"
    fi

    NAT_STACK_SERVER_IPV4="${NAT_STACK_BACKEND_CIDR%%/*}"
    NAT_STACK_BACKEND_IPV4="${NAT_STACK_SERVER_IPV4}"
    NAT_STACK_VIRTUAL_IPV4="$(nat_stack_calculate_virtual_ipv4 "${NAT_STACK_BACKEND_IPV4}")"
    NAT_STACK_VIRTUAL_CIDR="$(nat_stack_virtual_cidr "${NAT_STACK_VIRTUAL_IPV4}")"
    NAT_STACK_VIRTUAL_PORT='8080'
    NAT_STACK_BACKEND_PORT='5201'

    NAT_STACK_STATE_FILE="$(nat_stack_state_file "${NAT_STACK_ID}")"
    NAT_STACK_GENERATED_DIR="$(nat_stack_generated_dir_for "${NAT_STACK_ID}")"
    NAT_STACK_PATCH_DIR="${NAT_STACK_GENERATED_DIR}/patches"
    NAT_STACK_RESOLVED_VALUES_FILE="${NAT_STACK_GENERATED_DIR}/resolved-values.env"
}

nat_stack_each_other_state() {
    local current_stack_id=$1
    local state_file

    shopt -s nullglob
    for state_file in "${STACK_STATE_ROOT}"/*.env; do
        [[ "${state_file}" == "$(nat_stack_state_file "${current_stack_id}")" ]] && continue
        printf '%s\n' "${state_file}"
    done
    shopt -u nullglob
}

nat_stack_assert_no_conflicts() {
    local state_file other_stack_id other_namespace other_network_service other_cidr
    local -A state_map=()

    for state_file in $(nat_stack_each_other_state "${NAT_STACK_ID}"); do
        state_map=()
        platform_load_env_file "${state_file}" state_map
        other_stack_id="${state_map[STACK_ID]:-$(basename "${state_file}" .env)}"
        other_namespace="${state_map[STACK_NAMESPACE]:-}"
        other_network_service="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"

        [[ -n "${other_namespace}" ]] || continue

        if [[ "${NAT_STACK_NAMESPACE}" == "${other_namespace}" ]]; then
            die "nat namespace ${NAT_STACK_NAMESPACE} is already allocated to stack ${other_stack_id}"
        fi

        if [[ "${NAT_STACK_NETWORK_SERVICE_NAME}" == "${other_network_service}" ]]; then
            die "nat network service ${NAT_STACK_NETWORK_SERVICE_NAME} is already allocated to stack ${other_stack_id}"
        fi

        while IFS= read -r other_cidr; do
            [[ -n "${other_cidr}" ]] || continue

            if template_stack_cidrs_overlap "${NAT_STACK_SERVICE_CIDR}" "${other_cidr}"; then
                die "nat service CIDR ${NAT_STACK_SERVICE_CIDR} overlaps stack ${other_stack_id} CIDR ${other_cidr}"
            fi

            if template_stack_cidrs_overlap "${NAT_STACK_VIRTUAL_CIDR}" "${other_cidr}"; then
                die "nat virtual CIDR ${NAT_STACK_VIRTUAL_CIDR} overlaps stack ${other_stack_id} CIDR ${other_cidr}"
            fi
        done < <(nat_stack_state_conflict_cidrs "${state_file}")
    done
}

nat_stack_allocate_cidr() {
    local pool_cidr=$1
    local target_prefix_len=$2
    local pool_prefix_len=${pool_cidr#*/}
    local pool_network_int candidate_network_int candidate_cidr candidate_virtual_cidr
    local candidate_end_int candidate_virtual_start_int candidate_virtual_end_int
    local subnet_size subnet_count index state_file other_cidr range_index
    local conflict
    local -a other_range_starts=() other_range_ends=()

    template_stack_validate_cidr_prefix "${pool_cidr}"
    [[ "${target_prefix_len}" =~ ^[0-9]+$ ]] || die "invalid nat CIDR prefix len: ${target_prefix_len}"
    (( target_prefix_len >= pool_prefix_len && target_prefix_len <= 32 )) || die "nat CIDR prefix len ${target_prefix_len} is incompatible with pool ${pool_cidr}"

    pool_network_int="$(template_stack_cidr_network_int "${pool_cidr}")"
    subnet_size=$(( 1 << (32 - target_prefix_len) ))
    subnet_count=$(( 1 << (target_prefix_len - pool_prefix_len) ))

    for state_file in $(nat_stack_each_other_state "${NAT_STACK_ID}"); do
        while IFS= read -r other_cidr; do
            [[ -n "${other_cidr}" ]] || continue
            other_range_starts+=("$(template_stack_cidr_range_start "${other_cidr}")")
            other_range_ends+=("$(template_stack_cidr_range_end "${other_cidr}")")
        done < <(nat_stack_state_conflict_cidrs "${state_file}")
    done

    for (( index = 0; index < subnet_count; index++ )); do
        candidate_network_int=$(( pool_network_int + index * subnet_size ))
        candidate_cidr="$(template_stack_int_to_ipv4 "${candidate_network_int}")/${target_prefix_len}"
        candidate_virtual_cidr="$(nat_stack_virtual_cidr "$(nat_stack_calculate_virtual_ipv4 "${candidate_cidr%%/*}")")"
        candidate_end_int=$(( candidate_network_int + subnet_size - 1 ))
        candidate_virtual_start_int="$(template_stack_cidr_range_start "${candidate_virtual_cidr}")"
        candidate_virtual_end_int="$(template_stack_cidr_range_end "${candidate_virtual_cidr}")"
        conflict=false

        for (( range_index = 0; range_index < ${#other_range_starts[@]}; range_index++ )); do
            if (( candidate_network_int <= other_range_ends[range_index] && other_range_starts[range_index] <= candidate_end_int )); then
                conflict=true
                break
            fi

            if (( candidate_virtual_start_int <= other_range_ends[range_index] && other_range_starts[range_index] <= candidate_virtual_end_int )); then
                conflict=true
                break
            fi
        done

        if [[ "${conflict}" == "false" ]]; then
            printf '%s\n' "${candidate_cidr}"
            return 0
        fi
    done

    die "no free nat service CIDR left in pool ${pool_cidr} with prefix len ${target_prefix_len}"
}

nat_stack_resolve_role_node() {
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
    elif [[ -n "${persisted_value}" ]]; then
        resolved_value="${persisted_value}"
        resolved_source='persisted'
        resolved_origin="${persisted_origin_source:-persisted}"
    else
        resolved_value="$(nat_stack_default_role_node "${role_label}")"
        resolved_source='default'
        resolved_origin='default'
    fi

    template_stack_validate_node_name "${resolved_value}" "${role_label} node"
    printf -v "${target_value_name}" '%s' "${resolved_value}"
    printf -v "${target_source_name}" '%s' "${resolved_source}"
    printf -v "${target_origin_name}" '%s' "${resolved_origin}"
}

nat_stack_load_state() {
    local stack_id=$1
    local state_file
    local -A state_map=()

    state_file="$(nat_stack_state_file "${stack_id}")"
    [[ -f "${state_file}" ]] || return 1

    platform_load_env_file "${state_file}" state_map

    NAT_STACK_ID="${state_map[STACK_ID]:-${stack_id}}"
    NAT_STACK_NAMESPACE="${state_map[STACK_NAMESPACE]:-}"
    NAT_STACK_NAMESPACE_SOURCE='persisted'
    NAT_STACK_NAMESPACE_ORIGIN_SOURCE="${state_map[STACK_NAMESPACE_ORIGIN_SOURCE]:-persisted}"
    NAT_STACK_NETWORK_SERVICE_NAME="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
    NAT_STACK_NETWORK_SERVICE_NAME_SOURCE='persisted'
    NAT_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE="${state_map[STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE]:-persisted}"
    NAT_STACK_SERVICE_CIDR="${state_map[STACK_SERVICE_CIDR]:-}"
    NAT_STACK_SERVICE_CIDR_SOURCE='persisted'
    NAT_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${state_map[STACK_SERVICE_CIDR_ORIGIN_SOURCE]:-persisted}"
    NAT_STACK_BACKEND_CIDR="${state_map[STACK_BACKEND_CIDR]:-${NAT_STACK_SERVICE_CIDR}}"
    NAT_STACK_BACKEND_CIDR_SOURCE='persisted'
    NAT_STACK_BACKEND_CIDR_ORIGIN_SOURCE="${state_map[STACK_BACKEND_CIDR_ORIGIN_SOURCE]:-${NAT_STACK_SERVICE_CIDR_ORIGIN_SOURCE:-persisted}}"
    NAT_STACK_VIRTUAL_IPV4_PERSISTED="${state_map[STACK_VIRTUAL_IPV4]:-}"
    NAT_STACK_VNF_NODE_PERSISTED="${state_map[STACK_VNF_NODE]:-}"
    NAT_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_VNF_NODE_ORIGIN_SOURCE]:-persisted}"
    NAT_STACK_CLIENT_NODE_PERSISTED="${state_map[STACK_CLIENT_NODE]:-}"
    NAT_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_CLIENT_NODE_ORIGIN_SOURCE]:-persisted}"
    NAT_STACK_SERVER_NODE_PERSISTED="${state_map[STACK_SERVER_NODE]:-}"
    NAT_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_SERVER_NODE_ORIGIN_SOURCE]:-persisted}"
    NAT_STACK_CIDR_POOL="${state_map[STACK_CIDR_POOL]:-${TEMPLATE_CIDR_POOL}}"
    NAT_STACK_CIDR_PREFIX_LEN="${state_map[STACK_CIDR_PREFIX_LEN]:-${TEMPLATE_CIDR_PREFIX_LEN}}"
    NAT_STACK_STATE_CREATED_AT="${state_map[STACK_STATE_CREATED_AT]:-}"
    NAT_STACK_STATE_CREATED_AT_LOCAL="${state_map[STACK_STATE_CREATED_AT_LOCAL]:-}"
    NAT_STACK_STATE_CREATED_AT_EPOCH_MS="${state_map[STACK_STATE_CREATED_AT_EPOCH_MS]:-}"

    [[ -n "${NAT_STACK_NAMESPACE}" ]] || die "persisted nat stack namespace missing in ${state_file}"
    [[ -n "${NAT_STACK_NETWORK_SERVICE_NAME}" ]] || die "persisted nat stack network service missing in ${state_file}"
    [[ -n "${NAT_STACK_SERVICE_CIDR}" ]] || die "persisted nat stack service CIDR missing in ${state_file}"

    nat_stack_set_derived_values
    if [[ -n "${NAT_STACK_VIRTUAL_IPV4_PERSISTED}" && "${NAT_STACK_VIRTUAL_IPV4_PERSISTED}" != "${NAT_STACK_VIRTUAL_IPV4}" ]]; then
        die "persisted nat virtual IP ${NAT_STACK_VIRTUAL_IPV4_PERSISTED} does not match derived value ${NAT_STACK_VIRTUAL_IPV4} in ${state_file}"
    fi
    return 0
}

nat_stack_write_state() {
    local created_at created_at_local created_at_epoch_ms

    created_at_local="${NAT_STACK_STATE_CREATED_AT_LOCAL:-}"
    created_at="${NAT_STACK_STATE_CREATED_AT:-}"
    created_at_epoch_ms="${NAT_STACK_STATE_CREATED_AT_EPOCH_MS:-}"

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

    cat > "${NAT_STACK_STATE_FILE}" <<EOF
STACK_KIND=nat
STACK_ID=${NAT_STACK_ID}
STACK_NAMESPACE=${NAT_STACK_NAMESPACE}
STACK_NAMESPACE_ORIGIN_SOURCE=${NAT_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${NAT_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${NAT_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${NAT_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${NAT_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_BACKEND_CIDR=${NAT_STACK_BACKEND_CIDR}
STACK_BACKEND_CIDR_ORIGIN_SOURCE=${NAT_STACK_BACKEND_CIDR_ORIGIN_SOURCE}
STACK_VIRTUAL_IPV4=${NAT_STACK_VIRTUAL_IPV4}
STACK_VNF_NODE=${NAT_STACK_VNF_NODE}
STACK_VNF_NODE_ORIGIN_SOURCE=${NAT_STACK_VNF_NODE_ORIGIN_SOURCE}
STACK_CLIENT_NODE=${NAT_STACK_CLIENT_NODE}
STACK_CLIENT_NODE_ORIGIN_SOURCE=${NAT_STACK_CLIENT_NODE_ORIGIN_SOURCE}
STACK_SERVER_NODE=${NAT_STACK_SERVER_NODE}
STACK_SERVER_NODE_ORIGIN_SOURCE=${NAT_STACK_SERVER_NODE_ORIGIN_SOURCE}
STACK_CIDR_POOL=${NAT_STACK_CIDR_POOL}
STACK_CIDR_PREFIX_LEN=${NAT_STACK_CIDR_PREFIX_LEN}
STACK_STATE_CREATED_AT=${created_at}
STACK_STATE_CREATED_AT_LOCAL=${created_at_local}
STACK_STATE_CREATED_AT_EPOCH_MS=${created_at_epoch_ms}
EOF
    NAT_STACK_STATE_CREATED_AT="${created_at}"
    NAT_STACK_STATE_CREATED_AT_LOCAL="${created_at_local}"
    NAT_STACK_STATE_CREATED_AT_EPOCH_MS="${created_at_epoch_ms}"
}

nat_stack_require_id() {
    NAT_STACK_ID="${TEMPLATE_STACK_ID_INPUT:-}"
    [[ -n "${NAT_STACK_ID}" ]] || die "missing required --stack-id for nat stack operation"
    [[ "${PLATFORM_VALUE_SOURCE[TEMPLATE_STACK_ID_INPUT]}" == "cli" ]] || die "nat stack operation requires an explicit --stack-id"
    template_stack_validate_id "${NAT_STACK_ID}"
}

nat_stack_prepare_plan() {
    local requested_namespace requested_network_service requested_cidr
    local requested_vnf_node requested_client_node requested_server_node

    nat_stack_plan_dirs
    nat_stack_require_id

    requested_namespace="${TEMPLATE_NAMESPACE_OVERRIDE_INPUT:-}"
    requested_network_service="${TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT:-}"
    requested_cidr="${TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT:-}"
    requested_vnf_node="${TEMPLATE_VNF_NODE_INPUT:-}"
    requested_client_node="${TEMPLATE_CLIENT_NODE_INPUT:-}"
    requested_server_node="${TEMPLATE_SERVER_NODE_INPUT:-}"

    if [[ -n "${requested_namespace}" ]]; then
        template_stack_validate_k8s_name "${requested_namespace}" "nat namespace override"
    fi
    if [[ -n "${requested_network_service}" ]]; then
        template_stack_validate_k8s_name "${requested_network_service}" "nat network service override"
    fi
    if [[ -n "${requested_cidr}" ]]; then
        template_stack_validate_cidr_prefix "${requested_cidr}"
    fi
    if [[ -n "${requested_vnf_node}" ]]; then
        template_stack_validate_node_name "${requested_vnf_node}" "nat VNF node override"
    fi
    if [[ -n "${requested_client_node}" ]]; then
        template_stack_validate_node_name "${requested_client_node}" "nat client node override"
    fi
    if [[ -n "${requested_server_node}" ]]; then
        template_stack_validate_node_name "${requested_server_node}" "nat server node override"
    fi

    if nat_stack_load_state "${NAT_STACK_ID}"; then
        template_stack_require_state_match "namespace" "${requested_namespace}" "${NAT_STACK_NAMESPACE}"
        template_stack_require_state_match "network_service_name" "${requested_network_service}" "${NAT_STACK_NETWORK_SERVICE_NAME}"
        template_stack_require_state_match "backend_cidr" "${requested_cidr}" "${NAT_STACK_BACKEND_CIDR}"
        template_stack_require_state_match "vnf_node" "${requested_vnf_node}" "${NAT_STACK_VNF_NODE_PERSISTED:-}"
        template_stack_require_state_match "client_node" "${requested_client_node}" "${NAT_STACK_CLIENT_NODE_PERSISTED:-}"
        template_stack_require_state_match "server_node" "${requested_server_node}" "${NAT_STACK_SERVER_NODE_PERSISTED:-}"
        nat_stack_resolve_role_node "nat VNF" "${requested_vnf_node}" "${NAT_STACK_VNF_NODE_PERSISTED:-}" "${NAT_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" NAT_STACK_VNF_NODE NAT_STACK_VNF_NODE_SOURCE NAT_STACK_VNF_NODE_ORIGIN_SOURCE
        nat_stack_resolve_role_node "nat client" "${requested_client_node}" "${NAT_STACK_CLIENT_NODE_PERSISTED:-}" "${NAT_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" NAT_STACK_CLIENT_NODE NAT_STACK_CLIENT_NODE_SOURCE NAT_STACK_CLIENT_NODE_ORIGIN_SOURCE
        nat_stack_resolve_role_node "nat server" "${requested_server_node}" "${NAT_STACK_SERVER_NODE_PERSISTED:-}" "${NAT_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" NAT_STACK_SERVER_NODE NAT_STACK_SERVER_NODE_SOURCE NAT_STACK_SERVER_NODE_ORIGIN_SOURCE
        return 0
    fi

    NAT_STACK_NAMESPACE="${requested_namespace:-$(nat_stack_default_namespace "${NAT_STACK_ID}")}"
    NAT_STACK_NAMESPACE_SOURCE='default'
    NAT_STACK_NAMESPACE_ORIGIN_SOURCE='default'
    if [[ -n "${requested_namespace}" ]]; then
        NAT_STACK_NAMESPACE_SOURCE='override'
        NAT_STACK_NAMESPACE_ORIGIN_SOURCE='override'
    fi

    NAT_STACK_NETWORK_SERVICE_NAME="${requested_network_service:-$(nat_stack_default_network_service_name "${NAT_STACK_ID}")}"
    NAT_STACK_NETWORK_SERVICE_NAME_SOURCE='default'
    NAT_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='default'
    if [[ -n "${requested_network_service}" ]]; then
        NAT_STACK_NETWORK_SERVICE_NAME_SOURCE='override'
        NAT_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='override'
    fi

    NAT_STACK_CIDR_POOL="${TEMPLATE_CIDR_POOL}"
    NAT_STACK_CIDR_PREFIX_LEN="${TEMPLATE_CIDR_PREFIX_LEN}"
    if [[ -n "${requested_cidr}" ]]; then
        NAT_STACK_BACKEND_CIDR="${requested_cidr}"
        NAT_STACK_BACKEND_CIDR_SOURCE='override'
        NAT_STACK_BACKEND_CIDR_ORIGIN_SOURCE='override'
    else
        NAT_STACK_BACKEND_CIDR="$(nat_stack_allocate_cidr "${NAT_STACK_CIDR_POOL}" "${NAT_STACK_CIDR_PREFIX_LEN}")"
        NAT_STACK_BACKEND_CIDR_SOURCE='allocated'
        NAT_STACK_BACKEND_CIDR_ORIGIN_SOURCE='allocated'
    fi
    NAT_STACK_SERVICE_CIDR="${NAT_STACK_BACKEND_CIDR}"
    NAT_STACK_SERVICE_CIDR_SOURCE="${NAT_STACK_BACKEND_CIDR_SOURCE}"
    NAT_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${NAT_STACK_BACKEND_CIDR_ORIGIN_SOURCE}"

    template_stack_validate_k8s_name "${NAT_STACK_NAMESPACE}" "nat namespace"
    template_stack_validate_k8s_name "${NAT_STACK_NETWORK_SERVICE_NAME}" "nat network service name"
    nat_stack_resolve_role_node "nat VNF" "${requested_vnf_node}" "" "" NAT_STACK_VNF_NODE NAT_STACK_VNF_NODE_SOURCE NAT_STACK_VNF_NODE_ORIGIN_SOURCE
    nat_stack_resolve_role_node "nat client" "${requested_client_node}" "" "" NAT_STACK_CLIENT_NODE NAT_STACK_CLIENT_NODE_SOURCE NAT_STACK_CLIENT_NODE_ORIGIN_SOURCE
    nat_stack_resolve_role_node "nat server" "${requested_server_node}" "" "" NAT_STACK_SERVER_NODE NAT_STACK_SERVER_NODE_SOURCE NAT_STACK_SERVER_NODE_ORIGIN_SOURCE
    nat_stack_set_derived_values
    nat_stack_assert_no_conflicts
    nat_stack_write_state
}

nat_stack_require_existing_state() {
    local state_file

    nat_stack_require_id
    state_file="$(nat_stack_state_file "${NAT_STACK_ID}")"
    [[ -f "${state_file}" ]] || die "nat stack state not found: ${state_file}; run ./bin/nsm-ovs-lab show-nat-plan --stack-id ${NAT_STACK_ID} or deploy-nat --stack-id ${NAT_STACK_ID} first"
}

nat_stack_write_resolved_values() {
    cat > "${NAT_STACK_RESOLVED_VALUES_FILE}" <<EOF
STACK_ID=${NAT_STACK_ID}
STACK_NAMESPACE=${NAT_STACK_NAMESPACE}
STACK_NAMESPACE_SOURCE=${NAT_STACK_NAMESPACE_SOURCE}
STACK_NAMESPACE_ORIGIN_SOURCE=${NAT_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${NAT_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_SOURCE=${NAT_STACK_NETWORK_SERVICE_NAME_SOURCE}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${NAT_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
SERVICE_CIDR=${NAT_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR=${NAT_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_SOURCE=${NAT_STACK_SERVICE_CIDR_SOURCE}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${NAT_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
BACKEND_CIDR=${NAT_STACK_BACKEND_CIDR}
BACKEND_CIDR_SOURCE=${NAT_STACK_BACKEND_CIDR_SOURCE}
BACKEND_CIDR_ORIGIN_SOURCE=${NAT_STACK_BACKEND_CIDR_ORIGIN_SOURCE}
STACK_LABEL=${NAT_STACK_LABEL}
STACK_LABEL_KEY=${NAT_STACK_LABEL_KEY}
STACK_LABEL_VALUE=${NAT_STACK_LABEL_VALUE}
ROLE_LABEL_KEY=${NAT_ROLE_LABEL_KEY}
ROLE_CLIENT=${NAT_ROLE_CLIENT}
ROLE_MIDDLE=${NAT_ROLE_MIDDLE}
ROLE_SERVER=${NAT_ROLE_SERVER}
NAT_DEPLOYMENT_NAME=${NAT_STACK_MIDDLE_DEPLOYMENT_NAME}
SERVER_DEPLOYMENT_NAME=${NAT_STACK_SERVER_DEPLOYMENT_NAME}
CLIENT_DEPLOYMENT_NAME=${NAT_STACK_CLIENT_DEPLOYMENT_NAME}
RULES_CONFIGMAP_NAME=${NAT_STACK_RULES_CONFIGMAP_NAME}
RULES_TUPLE_PATCH_ENABLED=${NAT_STACK_RULES_TUPLE_PATCH_ENABLED}
NAT_POD_SELECTOR=${NAT_STACK_MIDDLE_POD_SELECTOR}
SERVER_POD_SELECTOR=${NAT_STACK_SERVER_POD_SELECTOR}
CLIENT_POD_SELECTOR=${NAT_STACK_CLIENT_POD_SELECTOR}
NAT_NSM_LABELS=${NAT_STACK_MIDDLE_NSM_LABELS}
SERVER_NSM_LABELS=${NAT_STACK_SERVER_NSM_LABELS}
CLIENT_NETWORK_SERVICES=${NAT_STACK_CLIENT_NETWORK_SERVICES}
SERVER_IPV4=${NAT_STACK_SERVER_IPV4}
BACKEND_IPV4=${NAT_STACK_BACKEND_IPV4}
BACKEND_PORT=${NAT_STACK_BACKEND_PORT}
VIRTUAL_IPV4=${NAT_STACK_VIRTUAL_IPV4}
VIRTUAL_PORT=${NAT_STACK_VIRTUAL_PORT}
NAT_STEERING_MODE=${NAT_STEERING_MODE}
NAT_STEERING_MODE_SOURCE=${PLATFORM_VALUE_SOURCE[NAT_STEERING_MODE]}
VNF_NODE=${NAT_STACK_VNF_NODE}
VNF_NODE_SOURCE=${NAT_STACK_VNF_NODE_SOURCE}
VNF_NODE_ORIGIN_SOURCE=${NAT_STACK_VNF_NODE_ORIGIN_SOURCE}
CLIENT_NODE=${NAT_STACK_CLIENT_NODE}
CLIENT_NODE_SOURCE=${NAT_STACK_CLIENT_NODE_SOURCE}
CLIENT_NODE_ORIGIN_SOURCE=${NAT_STACK_CLIENT_NODE_ORIGIN_SOURCE}
SERVER_NODE=${NAT_STACK_SERVER_NODE}
SERVER_NODE_SOURCE=${NAT_STACK_SERVER_NODE_SOURCE}
SERVER_NODE_ORIGIN_SOURCE=${NAT_STACK_SERVER_NODE_ORIGIN_SOURCE}
STATE_FILE=${NAT_STACK_STATE_FILE}
GENERATED_DIR=${NAT_STACK_GENERATED_DIR}
CIDR_POOL=${NAT_STACK_CIDR_POOL}
CIDR_PREFIX_LEN=${NAT_STACK_CIDR_PREFIX_LEN}
EOF
}

nat_stack_write_kustomization() {
    cat > "${NAT_STACK_GENERATED_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${NAT_STACK_NAMESPACE}

resources:
  - ../../../assets/nat/k8s

patches:
  - path: patches/00-namespace.yaml
    target:
      kind: Namespace
      name: nse-ovs-nat
  - path: patches/10-networkservice.yaml
    target:
      group: networkservicemesh.io
      version: v1
      kind: NetworkService
      name: nse-ovs-nat
  - path: patches/15-nat-rules.yaml
    target:
      version: v1
      kind: ConfigMap
      name: nse-ovs-nat-rules
  - path: patches/20-nse-ovs-nat.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-nat
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

nat_stack_write_namespace_patch() {
    cat > "${NAT_STACK_PATCH_DIR}/00-namespace.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${NAT_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
EOF
}

nat_stack_write_networkservice_patch() {
    cat > "${NAT_STACK_PATCH_DIR}/10-networkservice.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${NAT_STACK_NETWORK_SERVICE_NAME}
- op: replace
  path: /metadata/namespace
  value: ${NAT_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/matches
  value:
    - source_selector:
        ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
        ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_MIDDLE}
      routes:
        - destination_selector:
            ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
            ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_SERVER}
    - routes:
        - destination_selector:
            ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
            ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_MIDDLE}
EOF
}

nat_stack_write_rules_patch() {
    cat > "${NAT_STACK_PATCH_DIR}/15-nat-rules.yaml" <<EOF
- op: replace
  path: /metadata/namespace
  value: ${NAT_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /data/rules.yaml
  value: |-
    mode: static_port_map
    virtual_ip: ${NAT_STACK_VIRTUAL_IPV4}
    virtual_port: ${NAT_STACK_VIRTUAL_PORT}
    backend_ip: ${NAT_STACK_BACKEND_IPV4}
    backend_port: ${NAT_STACK_BACKEND_PORT}
EOF
}

nat_stack_write_nat_patch() {
    cat > "${NAT_STACK_PATCH_DIR}/20-nse-ovs-nat.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${NAT_STACK_MIDDLE_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${NAT_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${NAT_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_MIDDLE}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${NAT_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_MIDDLE}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${NAT_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_MIDDLE}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${NAT_STACK_VNF_NODE}
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
      value: ${NAT_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_LABELS
      value: ${NAT_STACK_MIDDLE_NSM_LABELS}
    - name: NSM_NAT_RULES_PATH
      value: /etc/nse-nat/rules.yaml
    - name: NSM_NAT_RULE_POLL_INTERVAL
      value: 2s
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
EOF
}

nat_stack_write_server_patch() {
    cat > "${NAT_STACK_PATCH_DIR}/30-nse-ovs-server.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${NAT_STACK_SERVER_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${NAT_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${NAT_STACK_SERVER_DEPLOYMENT_NAME}
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_SERVER}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${NAT_STACK_SERVER_DEPLOYMENT_NAME}
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_SERVER}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${NAT_STACK_SERVER_DEPLOYMENT_NAME}
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_SERVER}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${NAT_STACK_SERVER_NODE}
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
      value: ${NAT_STACK_BACKEND_CIDR}
    - name: NSM_SERVICE_NAMES
      value: ${NAT_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_REGISTER_SERVICE
      value: "false"
    - name: NSM_LABELS
      value: ${NAT_STACK_SERVER_NSM_LABELS}
    - name: NSM_LOG_LEVEL
      value: INFO
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
    - name: IPERF3_PORT
      value: "${NAT_STACK_BACKEND_PORT}"
EOF
}

nat_stack_write_client_patch() {
    cat > "${NAT_STACK_PATCH_DIR}/40-nsc-ovs-client.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${NAT_STACK_CLIENT_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${NAT_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${NAT_STACK_CLIENT_DEPLOYMENT_NAME}
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_CLIENT}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${NAT_STACK_CLIENT_DEPLOYMENT_NAME}
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_CLIENT}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${NAT_STACK_CLIENT_DEPLOYMENT_NAME}
    ${NAT_STACK_LABEL_KEY}: ${NAT_STACK_ID}
    ${NAT_ROLE_LABEL_KEY}: ${NAT_ROLE_CLIENT}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${NAT_STACK_CLIENT_NODE}
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
      value: ${NAT_STACK_CLIENT_NETWORK_SERVICES}
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
      value: ${NAT_STACK_CLIENT_NETWORK_SERVICES}
    - name: NSM_NAME
      value: "\$(POD_NAME)-\$(POD_UID)"
EOF
}

nat_stack_render() {
    rm -rf "${NAT_STACK_GENERATED_DIR}"
    mkdir -p "${NAT_STACK_PATCH_DIR}"

    nat_stack_write_kustomization
    nat_stack_write_namespace_patch
    nat_stack_write_networkservice_patch
    nat_stack_write_rules_patch
    nat_stack_write_nat_patch
    nat_stack_write_server_patch
    nat_stack_write_client_patch
    nat_stack_write_resolved_values
}

nat_stack_apply_runtime_context() {
    NAT_RUNTIME_ROOT="${NAT_STACK_GENERATED_DIR}"
    NAT_K8S_DIR="${NAT_STACK_GENERATED_DIR}"
    NAT_VERIFY_SCRIPT="${NAT_VERIFY_ASSET_SCRIPT}"
    NAT_NAMESPACE="${NAT_STACK_NAMESPACE}"
    NAT_NETWORK_SERVICE_NAME="${NAT_STACK_NETWORK_SERVICE_NAME}"
    NAT_DEPLOYMENT_NAME="${NAT_STACK_MIDDLE_DEPLOYMENT_NAME}"
    NAT_SERVER_DEPLOYMENT_NAME="${NAT_STACK_SERVER_DEPLOYMENT_NAME}"
    NAT_CLIENT_DEPLOYMENT_NAME="${NAT_STACK_CLIENT_DEPLOYMENT_NAME}"
    NAT_SERVICE_NAME="${NAT_STACK_NETWORK_SERVICE_NAME}"
    NAT_SERVER_CIDR_PREFIX="${NAT_STACK_BACKEND_CIDR}"
    NAT_SERVER_IPV4="${NAT_STACK_SERVER_IPV4}"
    NAT_BACKEND_IPV4="${NAT_STACK_BACKEND_IPV4}"
    NAT_BACKEND_PORT="${NAT_STACK_BACKEND_PORT}"
    NAT_VIRTUAL_IPV4="${NAT_STACK_VIRTUAL_IPV4}"
    NAT_VIRTUAL_PORT="${NAT_STACK_VIRTUAL_PORT}"
    NAT_MIDDLE_POD_SELECTOR="${NAT_STACK_MIDDLE_POD_SELECTOR}"
    NAT_SERVER_POD_SELECTOR="${NAT_STACK_SERVER_POD_SELECTOR}"
    NAT_CLIENT_POD_SELECTOR="${NAT_STACK_CLIENT_POD_SELECTOR}"
}

nat_stack_prepare_rendered_runtime() {
    nat_init_runtime_context
    nat_require_runtime_assets
    nat_stack_prepare_plan
    nat_stack_render
    nat_stack_apply_runtime_context
}

nat_stack_prepare_existing_rendered_runtime() {
    nat_init_runtime_context
    nat_require_runtime_assets
    nat_stack_require_existing_state
    nat_stack_prepare_plan
    nat_stack_render
    nat_stack_apply_runtime_context
}

nat_stack_print_plan() {
    printf 'stack_id: %s [source=cli]\n' "${NAT_STACK_ID}"
    printf 'state file: %s\n' "${NAT_STACK_STATE_FILE}"
    printf 'generated dir: %s\n' "${NAT_STACK_GENERATED_DIR}"
    printf 'namespace: %s [source=%s origin=%s]\n' "${NAT_STACK_NAMESPACE}" "${NAT_STACK_NAMESPACE_SOURCE}" "${NAT_STACK_NAMESPACE_ORIGIN_SOURCE}"
    printf 'network_service_name: %s [source=%s origin=%s]\n' "${NAT_STACK_NETWORK_SERVICE_NAME}" "${NAT_STACK_NETWORK_SERVICE_NAME_SOURCE}" "${NAT_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}"
    printf 'service_cidr: %s [source=%s origin=%s]\n' "${NAT_STACK_SERVICE_CIDR}" "${NAT_STACK_SERVICE_CIDR_SOURCE}" "${NAT_STACK_SERVICE_CIDR_ORIGIN_SOURCE}"
    printf 'backend_cidr: %s [source=%s origin=%s]\n' "${NAT_STACK_BACKEND_CIDR}" "${NAT_STACK_BACKEND_CIDR_SOURCE}" "${NAT_STACK_BACKEND_CIDR_ORIGIN_SOURCE}"
    printf 'virtual_ip: %s [source=derived]\n' "${NAT_STACK_VIRTUAL_IPV4}"
    printf 'virtual_port: %s [source=derived]\n' "${NAT_STACK_VIRTUAL_PORT}"
    printf 'backend_ip: %s [source=derived]\n' "${NAT_STACK_BACKEND_IPV4}"
    printf 'backend_port: %s [source=derived]\n' "${NAT_STACK_BACKEND_PORT}"
    printf 'stack_label: %s [source=derived]\n' "${NAT_STACK_LABEL}"
    printf 'role_label.client: %s=%s [source=derived]\n' "${NAT_ROLE_LABEL_KEY}" "${NAT_ROLE_CLIENT}"
    printf 'role_label.middle: %s=%s [source=derived]\n' "${NAT_ROLE_LABEL_KEY}" "${NAT_ROLE_MIDDLE}"
    printf 'role_label.server: %s=%s [source=derived]\n' "${NAT_ROLE_LABEL_KEY}" "${NAT_ROLE_SERVER}"
    printf 'nat deployment: %s [source=derived]\n' "${NAT_STACK_MIDDLE_DEPLOYMENT_NAME}"
    printf 'server deployment: %s [source=derived]\n' "${NAT_STACK_SERVER_DEPLOYMENT_NAME}"
    printf 'client deployment: %s [source=derived]\n' "${NAT_STACK_CLIENT_DEPLOYMENT_NAME}"
    printf 'rules configmap: %s [source=derived]\n' "${NAT_STACK_RULES_CONFIGMAP_NAME}"
    printf 'rules tuple patch: %s [source=derived]\n' "${NAT_STACK_RULES_TUPLE_PATCH_ENABLED}"
    printf 'nat steering mode: %s [source=%s]\n' "${NAT_STEERING_MODE}" "${PLATFORM_VALUE_SOURCE[NAT_STEERING_MODE]}"
    printf 'vnf_node: %s [source=%s origin=%s]\n' "${NAT_STACK_VNF_NODE}" "${NAT_STACK_VNF_NODE_SOURCE}" "${NAT_STACK_VNF_NODE_ORIGIN_SOURCE}"
    printf 'client_node: %s [source=%s origin=%s]\n' "${NAT_STACK_CLIENT_NODE}" "${NAT_STACK_CLIENT_NODE_SOURCE}" "${NAT_STACK_CLIENT_NODE_ORIGIN_SOURCE}"
    printf 'server_node: %s [source=%s origin=%s]\n' "${NAT_STACK_SERVER_NODE}" "${NAT_STACK_SERVER_NODE_SOURCE}" "${NAT_STACK_SERVER_NODE_ORIGIN_SOURCE}"
    printf 'nat env.NSM_SERVICE_NAME: %s [source=derived]\n' "${NAT_STACK_NETWORK_SERVICE_NAME}"
    printf 'nat env.NSM_LABELS: %s [source=derived]\n' "${NAT_STACK_MIDDLE_NSM_LABELS}"
    printf 'server env.NSM_SERVICE_NAMES: %s [source=derived]\n' "${NAT_STACK_NETWORK_SERVICE_NAME}"
    printf 'server env.NSM_CIDR_PREFIX: %s [source=derived]\n' "${NAT_STACK_BACKEND_CIDR}"
    printf 'client env.NSM_NETWORK_SERVICES: %s [source=derived]\n' "${NAT_STACK_CLIENT_NETWORK_SERVICES}"
    printf 'cidr pool: %s [source=%s]\n' "${NAT_STACK_CIDR_POOL}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_POOL]}"
    printf 'cidr prefix len: %s [source=%s]\n' "${NAT_STACK_CIDR_PREFIX_LEN}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_PREFIX_LEN]}"
}
