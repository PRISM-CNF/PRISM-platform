#!/usr/bin/env bash

if [[ -n "${NSM_OVS_VPN_STACK_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_VPN_STACK_SH_LOADED=1

VPN_STACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${VPN_STACK_LIB_DIR}/template_stack.sh"

vpn_stack_default_role_node() {
    local role_label=${1:-}

    case "${role_label}" in
        vnf|middle|vpn|*VNF*|*vnf*|*middle*|*vpn*)
            printf '%s\n' "${TEMPLATE_DEFAULT_VNF_NODE:-node01}"
            ;;
        client|*client*)
            printf '%s\n' "${TEMPLATE_DEFAULT_CLIENT_NODE:-node01}"
            ;;
        server|*server*)
            printf '%s\n' "${TEMPLATE_DEFAULT_SERVER_NODE:-node01}"
            ;;
        *)
            printf '%s\n' "${TEMPLATE_DEFAULT_VNF_NODE:-node01}"
            ;;
    esac
}

vpn_stack_name_suffix() {
    local stack_id=$1

    if [[ "${stack_id}" == vpn-* && "${stack_id#vpn-}" != "${stack_id}" ]]; then
        printf '%s\n' "${stack_id#vpn-}"
    else
        printf '%s\n' "${stack_id}"
    fi
}

vpn_stack_default_namespace() {
    local stack_id=$1
    printf 'exp-%s\n' "${stack_id}"
}

vpn_stack_default_network_service_name() {
    local stack_id=$1
    local suffix

    suffix="$(vpn_stack_name_suffix "${stack_id}")"
    printf 'nse-ovs-vpn-%s\n' "${suffix}"
}

vpn_stack_state_file() {
    local stack_id=$1
    printf '%s/%s.env\n' "${VPN_STACK_STATE_ROOT}" "${stack_id}"
}

vpn_stack_generated_dir_for() {
    local stack_id=$1
    printf '%s/%s\n' "${VPN_GENERATED_ROOT}" "${stack_id}"
}

vpn_stack_plan_dirs() {
    mkdir -p "${VPN_STACK_STATE_ROOT}" "${VPN_GENERATED_ROOT}"
}

vpn_stack_each_other_state() {
    local current_stack_id=$1
    local state_file

    shopt -s nullglob
    for state_file in "${STACK_STATE_ROOT}"/*.env; do
        [[ "${state_file}" == "$(vpn_stack_state_file "${current_stack_id}")" ]] && continue
        printf '%s\n' "${state_file}"
    done
    shopt -u nullglob
}

vpn_stack_assert_no_conflicts() {
    local state_file other_stack_id other_namespace other_network_service other_cidr
    local -A state_map=()

    for state_file in $(vpn_stack_each_other_state "${VPN_STACK_ID}"); do
        state_map=()
        platform_load_env_file "${state_file}" state_map
        other_stack_id="${state_map[STACK_ID]:-$(basename "${state_file}" .env)}"
        other_namespace="${state_map[STACK_NAMESPACE]:-}"
        other_network_service="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
        other_cidr="${state_map[STACK_SERVICE_CIDR]:-}"

        [[ -n "${other_namespace}" ]] || continue

        if [[ "${VPN_STACK_NAMESPACE}" == "${other_namespace}" ]]; then
            die "vpn namespace ${VPN_STACK_NAMESPACE} is already allocated to stack ${other_stack_id}"
        fi

        if [[ "${VPN_STACK_NETWORK_SERVICE_NAME}" == "${other_network_service}" ]]; then
            die "vpn network service ${VPN_STACK_NETWORK_SERVICE_NAME} is already allocated to stack ${other_stack_id}"
        fi

        if [[ -n "${other_cidr}" ]] && template_stack_cidrs_overlap "${VPN_STACK_SERVICE_CIDR}" "${other_cidr}"; then
            die "vpn service CIDR ${VPN_STACK_SERVICE_CIDR} overlaps stack ${other_stack_id} CIDR ${other_cidr}"
        fi
    done
}

vpn_stack_allocate_cidr() {
    local pool_cidr=$1
    local target_prefix_len=$2
    local pool_prefix_len=${pool_cidr#*/}
    local pool_network_int candidate_network_int candidate_cidr
    local candidate_end_int pool_end_int subnet_size subnet_count index state_file other_cidr
    local -A state_map=()
    local -a other_range_starts=()
    local -a other_range_ends=()
    local range_index conflict highest_used_end fast_candidate_int fast_candidate_end last_range_index

    template_stack_validate_cidr_prefix "${pool_cidr}"
    [[ "${target_prefix_len}" =~ ^[0-9]+$ ]] || die "invalid vpn CIDR prefix len: ${target_prefix_len}"
    (( target_prefix_len >= pool_prefix_len && target_prefix_len <= 32 )) || die "vpn CIDR prefix len ${target_prefix_len} is incompatible with pool ${pool_cidr}"

    pool_network_int="$(template_stack_cidr_network_int "${pool_cidr}")"
    subnet_size=$(( 1 << (32 - target_prefix_len) ))
    subnet_count=$(( 1 << (target_prefix_len - pool_prefix_len) ))
    pool_end_int=$(( pool_network_int + subnet_size * subnet_count - 1 ))
    highest_used_end=$(( pool_network_int - 1 ))

    for state_file in $(vpn_stack_each_other_state "${VPN_STACK_ID}"); do
        state_map=()
        platform_load_env_file "${state_file}" state_map
        other_cidr="${state_map[STACK_SERVICE_CIDR]:-}"
        [[ -n "${other_cidr}" ]] || continue
        other_range_starts+=("$(template_stack_cidr_range_start "${other_cidr}")")
        other_range_ends+=("$(template_stack_cidr_range_end "${other_cidr}")")
        last_range_index=$(( ${#other_range_starts[@]} - 1 ))

        if (( other_range_starts[last_range_index] <= pool_end_int && other_range_ends[last_range_index] >= pool_network_int && other_range_ends[last_range_index] > highest_used_end )); then
            highest_used_end=${other_range_ends[last_range_index]}
        fi
    done

    if (( highest_used_end >= pool_network_int )); then
        fast_candidate_int=$(( ((highest_used_end + 1 + subnet_size - 1) / subnet_size) * subnet_size ))
        if (( fast_candidate_int < pool_network_int )); then
            fast_candidate_int=${pool_network_int}
        fi

        fast_candidate_end=$(( fast_candidate_int + subnet_size - 1 ))
        if (( fast_candidate_end <= pool_end_int )); then
            conflict=false
            for (( range_index = 0; range_index < ${#other_range_starts[@]}; range_index++ )); do
                if (( fast_candidate_int <= other_range_ends[range_index] && other_range_starts[range_index] <= fast_candidate_end )); then
                    conflict=true
                    break
                fi
            done

            if [[ "${conflict}" == "false" ]]; then
                candidate_cidr="$(template_stack_int_to_ipv4 "${fast_candidate_int}")/${target_prefix_len}"
                printf '%s\n' "${candidate_cidr}"
                return 0
            fi
        fi
    fi

    for (( index = 0; index < subnet_count; index++ )); do
        candidate_network_int=$(( pool_network_int + index * subnet_size ))
        candidate_end_int=$(( candidate_network_int + subnet_size - 1 ))
        conflict=false

        for (( range_index = 0; range_index < ${#other_range_starts[@]}; range_index++ )); do
            if (( candidate_network_int <= other_range_ends[range_index] && other_range_starts[range_index] <= candidate_end_int )); then
                conflict=true
                break
            fi
        done

        if [[ "${conflict}" == "false" ]]; then
            candidate_cidr="$(template_stack_int_to_ipv4 "${candidate_network_int}")/${target_prefix_len}"
            printf '%s\n' "${candidate_cidr}"
            return 0
        fi
    done

    die "no free vpn service CIDR left in pool ${pool_cidr} with prefix len ${target_prefix_len}"
}

vpn_stack_assert_same_node() {
    if [[ "${VPN_STACK_VNF_NODE}" != "${VPN_STACK_CLIENT_NODE}" || "${VPN_STACK_VNF_NODE}" != "${VPN_STACK_SERVER_NODE}" ]]; then
        if vpn_stack_xnode_mode_enabled; then
            return 0
        fi
        die "vpn stack currently supports same-node only; got vnf=${VPN_STACK_VNF_NODE} client=${VPN_STACK_CLIENT_NODE} server=${VPN_STACK_SERVER_NODE}; rerun with --vpn-xnode-mode exploratory to allow xnode trial"
    fi
}

vpn_stack_xnode_mode_enabled() {
    [[ "${VPN_XNODE_MODE:-disabled}" == "exploratory" ]]
}

vpn_stack_set_derived_values() {
    local name_suffix

    name_suffix="$(vpn_stack_name_suffix "${VPN_STACK_ID}")"

    VPN_STACK_LABEL_KEY='exp.nsm.ai/stack'
    VPN_ROLE_LABEL_KEY='exp.nsm.ai/role'
    VPN_STACK_LABEL_VALUE="${VPN_STACK_ID}"
    VPN_STACK_LABEL="${VPN_STACK_LABEL_KEY}=${VPN_STACK_LABEL_VALUE}"

    VPN_ROLE_CLIENT='client'
    VPN_ROLE_ENCRYPT='encrypt'
    VPN_ROLE_DECRYPT='decrypt'
    VPN_ROLE_SERVER='server'

    VPN_STACK_ENCRYPT_DEPLOYMENT_NAME="nse-ovs-vpn-encrypt-${name_suffix}"
    VPN_STACK_DECRYPT_DEPLOYMENT_NAME="nse-ovs-vpn-decrypt-${name_suffix}"
    VPN_STACK_SERVER_DEPLOYMENT_NAME="nse-ovs-server-${name_suffix}"
    VPN_STACK_CLIENT_DEPLOYMENT_NAME="nsc-ovs-client-${name_suffix}"

    VPN_STACK_ENCRYPT_POD_SELECTOR="${VPN_STACK_LABEL_KEY}=${VPN_STACK_ID},${VPN_ROLE_LABEL_KEY}=${VPN_ROLE_ENCRYPT}"
    VPN_STACK_DECRYPT_POD_SELECTOR="${VPN_STACK_LABEL_KEY}=${VPN_STACK_ID},${VPN_ROLE_LABEL_KEY}=${VPN_ROLE_DECRYPT}"
    VPN_STACK_SERVER_POD_SELECTOR="${VPN_STACK_LABEL_KEY}=${VPN_STACK_ID},${VPN_ROLE_LABEL_KEY}=${VPN_ROLE_SERVER}"
    VPN_STACK_CLIENT_POD_SELECTOR="${VPN_STACK_LABEL_KEY}=${VPN_STACK_ID},${VPN_ROLE_LABEL_KEY}=${VPN_ROLE_CLIENT}"

    VPN_STACK_CLIENT_NETWORK_SERVICES="kernel://${VPN_STACK_NETWORK_SERVICE_NAME}/nsm-1"
    VPN_STACK_ENCRYPT_NSM_LABELS='app:vpn-encrypt'
    VPN_STACK_DECRYPT_NSM_LABELS='app:vpn-decrypt'
    VPN_STACK_SERVER_NSM_LABELS='app:server'
    VPN_STACK_SERVER_IPV4="${VPN_STACK_SERVICE_CIDR%%/*}"
    VPN_STACK_TARGET_IPV4="${VPN_STACK_SERVER_IPV4}"
    VPN_STACK_PROXY_PORT='5201'
    VPN_STACK_WG_LISTEN_PORT='51820'
    VPN_STACK_INTERFACE_NAME='wg0'

    VPN_STACK_STATE_FILE="$(vpn_stack_state_file "${VPN_STACK_ID}")"
    VPN_STACK_GENERATED_DIR="$(vpn_stack_generated_dir_for "${VPN_STACK_ID}")"
    VPN_STACK_PATCH_DIR="${VPN_STACK_GENERATED_DIR}/patches"
    VPN_STACK_RESOLVED_VALUES_FILE="${VPN_STACK_GENERATED_DIR}/resolved-values.env"
}

vpn_stack_resolve_role_node() {
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
        resolved_value="$(vpn_stack_default_role_node "${role_label}")"
        resolved_source='default'
        resolved_origin='default'
    fi

    template_stack_validate_node_name "${resolved_value}" "${role_label} node"
    printf -v "${target_value_name}" '%s' "${resolved_value}"
    printf -v "${target_source_name}" '%s' "${resolved_source}"
    printf -v "${target_origin_name}" '%s' "${resolved_origin}"
}

vpn_stack_load_state() {
    local stack_id=$1
    local state_file
    local -A state_map=()

    state_file="$(vpn_stack_state_file "${stack_id}")"
    [[ -f "${state_file}" ]] || return 1

    platform_load_env_file "${state_file}" state_map

    VPN_STACK_ID="${state_map[STACK_ID]:-${stack_id}}"
    VPN_STACK_NAMESPACE="${state_map[STACK_NAMESPACE]:-}"
    VPN_STACK_NAMESPACE_SOURCE='persisted'
    VPN_STACK_NAMESPACE_ORIGIN_SOURCE="${state_map[STACK_NAMESPACE_ORIGIN_SOURCE]:-persisted}"
    VPN_STACK_NETWORK_SERVICE_NAME="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
    VPN_STACK_NETWORK_SERVICE_NAME_SOURCE='persisted'
    VPN_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE="${state_map[STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE]:-persisted}"
    VPN_STACK_SERVICE_CIDR="${state_map[STACK_SERVICE_CIDR]:-}"
    VPN_STACK_SERVICE_CIDR_SOURCE='persisted'
    VPN_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${state_map[STACK_SERVICE_CIDR_ORIGIN_SOURCE]:-persisted}"
    VPN_STACK_VNF_NODE_PERSISTED="${state_map[STACK_VNF_NODE]:-}"
    VPN_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_VNF_NODE_ORIGIN_SOURCE]:-persisted}"
    VPN_STACK_CLIENT_NODE_PERSISTED="${state_map[STACK_CLIENT_NODE]:-}"
    VPN_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_CLIENT_NODE_ORIGIN_SOURCE]:-persisted}"
    VPN_STACK_SERVER_NODE_PERSISTED="${state_map[STACK_SERVER_NODE]:-}"
    VPN_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_SERVER_NODE_ORIGIN_SOURCE]:-persisted}"
    VPN_STACK_CIDR_POOL="${state_map[STACK_CIDR_POOL]:-${TEMPLATE_CIDR_POOL}}"
    VPN_STACK_CIDR_PREFIX_LEN="${state_map[STACK_CIDR_PREFIX_LEN]:-30}"
    VPN_STACK_STATE_CREATED_AT="${state_map[STACK_STATE_CREATED_AT]:-}"
    VPN_STACK_STATE_CREATED_AT_LOCAL="${state_map[STACK_STATE_CREATED_AT_LOCAL]:-}"
    VPN_STACK_STATE_CREATED_AT_EPOCH_MS="${state_map[STACK_STATE_CREATED_AT_EPOCH_MS]:-}"

    [[ -n "${VPN_STACK_NAMESPACE}" ]] || die "persisted vpn stack namespace missing in ${state_file}"
    [[ -n "${VPN_STACK_NETWORK_SERVICE_NAME}" ]] || die "persisted vpn stack network service missing in ${state_file}"
    [[ -n "${VPN_STACK_SERVICE_CIDR}" ]] || die "persisted vpn stack service CIDR missing in ${state_file}"

    vpn_stack_set_derived_values
    return 0
}

vpn_stack_write_state() {
    local created_at created_at_local created_at_epoch_ms

    created_at_local="${VPN_STACK_STATE_CREATED_AT_LOCAL:-}"
    created_at="${VPN_STACK_STATE_CREATED_AT:-}"
    created_at_epoch_ms="${VPN_STACK_STATE_CREATED_AT_EPOCH_MS:-}"

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

    cat > "${VPN_STACK_STATE_FILE}" <<EOF
STACK_KIND=vpn
STACK_ID=${VPN_STACK_ID}
STACK_NAMESPACE=${VPN_STACK_NAMESPACE}
STACK_NAMESPACE_ORIGIN_SOURCE=${VPN_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${VPN_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${VPN_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${VPN_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${VPN_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_VNF_NODE=${VPN_STACK_VNF_NODE}
STACK_VNF_NODE_ORIGIN_SOURCE=${VPN_STACK_VNF_NODE_ORIGIN_SOURCE}
STACK_CLIENT_NODE=${VPN_STACK_CLIENT_NODE}
STACK_CLIENT_NODE_ORIGIN_SOURCE=${VPN_STACK_CLIENT_NODE_ORIGIN_SOURCE}
STACK_SERVER_NODE=${VPN_STACK_SERVER_NODE}
STACK_SERVER_NODE_ORIGIN_SOURCE=${VPN_STACK_SERVER_NODE_ORIGIN_SOURCE}
STACK_CIDR_POOL=${VPN_STACK_CIDR_POOL}
STACK_CIDR_PREFIX_LEN=${VPN_STACK_CIDR_PREFIX_LEN}
STACK_STATE_CREATED_AT=${created_at}
STACK_STATE_CREATED_AT_LOCAL=${created_at_local}
STACK_STATE_CREATED_AT_EPOCH_MS=${created_at_epoch_ms}
EOF
    VPN_STACK_STATE_CREATED_AT="${created_at}"
    VPN_STACK_STATE_CREATED_AT_LOCAL="${created_at_local}"
    VPN_STACK_STATE_CREATED_AT_EPOCH_MS="${created_at_epoch_ms}"
}

vpn_stack_require_id() {
    VPN_STACK_ID="${TEMPLATE_STACK_ID_INPUT:-}"
    [[ -n "${VPN_STACK_ID}" ]] || die "missing required --stack-id for vpn stack operation"
    [[ "${PLATFORM_VALUE_SOURCE[TEMPLATE_STACK_ID_INPUT]}" == "cli" ]] || die "vpn stack operation requires an explicit --stack-id"
    template_stack_validate_id "${VPN_STACK_ID}"
}

vpn_stack_prepare_plan() {
    local requested_namespace requested_network_service requested_cidr
    local requested_vnf_node requested_client_node requested_server_node

    vpn_stack_plan_dirs
    vpn_stack_require_id

    requested_namespace="${TEMPLATE_NAMESPACE_OVERRIDE_INPUT:-}"
    requested_network_service="${TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT:-}"
    requested_cidr="${TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT:-}"
    requested_vnf_node="${TEMPLATE_VNF_NODE_INPUT:-}"
    requested_client_node="${TEMPLATE_CLIENT_NODE_INPUT:-}"
    requested_server_node="${TEMPLATE_SERVER_NODE_INPUT:-}"

    if [[ -n "${requested_namespace}" ]]; then
        template_stack_validate_k8s_name "${requested_namespace}" "vpn namespace override"
    fi
    if [[ -n "${requested_network_service}" ]]; then
        template_stack_validate_k8s_name "${requested_network_service}" "vpn network service override"
    fi
    if [[ -n "${requested_cidr}" ]]; then
        template_stack_validate_cidr_prefix "${requested_cidr}"
    fi
    if [[ -n "${requested_vnf_node}" ]]; then
        template_stack_validate_node_name "${requested_vnf_node}" "vpn VNF node override"
    fi
    if [[ -n "${requested_client_node}" ]]; then
        template_stack_validate_node_name "${requested_client_node}" "vpn client node override"
    fi
    if [[ -n "${requested_server_node}" ]]; then
        template_stack_validate_node_name "${requested_server_node}" "vpn server node override"
    fi

    if vpn_stack_load_state "${VPN_STACK_ID}"; then
        template_stack_require_state_match "namespace" "${requested_namespace}" "${VPN_STACK_NAMESPACE}"
        template_stack_require_state_match "network_service_name" "${requested_network_service}" "${VPN_STACK_NETWORK_SERVICE_NAME}"
        template_stack_require_state_match "service_cidr" "${requested_cidr}" "${VPN_STACK_SERVICE_CIDR}"
        template_stack_require_state_match "vnf_node" "${requested_vnf_node}" "${VPN_STACK_VNF_NODE_PERSISTED:-}"
        template_stack_require_state_match "client_node" "${requested_client_node}" "${VPN_STACK_CLIENT_NODE_PERSISTED:-}"
        template_stack_require_state_match "server_node" "${requested_server_node}" "${VPN_STACK_SERVER_NODE_PERSISTED:-}"
        vpn_stack_resolve_role_node "vpn VNF" "${requested_vnf_node}" "${VPN_STACK_VNF_NODE_PERSISTED:-}" "${VPN_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" VPN_STACK_VNF_NODE VPN_STACK_VNF_NODE_SOURCE VPN_STACK_VNF_NODE_ORIGIN_SOURCE
        vpn_stack_resolve_role_node "vpn client" "${requested_client_node}" "${VPN_STACK_CLIENT_NODE_PERSISTED:-}" "${VPN_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" VPN_STACK_CLIENT_NODE VPN_STACK_CLIENT_NODE_SOURCE VPN_STACK_CLIENT_NODE_ORIGIN_SOURCE
        vpn_stack_resolve_role_node "vpn server" "${requested_server_node}" "${VPN_STACK_SERVER_NODE_PERSISTED:-}" "${VPN_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" VPN_STACK_SERVER_NODE VPN_STACK_SERVER_NODE_SOURCE VPN_STACK_SERVER_NODE_ORIGIN_SOURCE
        vpn_stack_assert_same_node
        return 0
    fi

    VPN_STACK_NAMESPACE="${requested_namespace:-$(vpn_stack_default_namespace "${VPN_STACK_ID}")}"
    VPN_STACK_NAMESPACE_SOURCE='default'
    VPN_STACK_NAMESPACE_ORIGIN_SOURCE='default'
    if [[ -n "${requested_namespace}" ]]; then
        VPN_STACK_NAMESPACE_SOURCE='override'
        VPN_STACK_NAMESPACE_ORIGIN_SOURCE='override'
    fi

    VPN_STACK_NETWORK_SERVICE_NAME="${requested_network_service:-$(vpn_stack_default_network_service_name "${VPN_STACK_ID}")}"
    VPN_STACK_NETWORK_SERVICE_NAME_SOURCE='default'
    VPN_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='default'
    if [[ -n "${requested_network_service}" ]]; then
        VPN_STACK_NETWORK_SERVICE_NAME_SOURCE='override'
        VPN_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='override'
    fi

    VPN_STACK_CIDR_POOL="${TEMPLATE_CIDR_POOL}"
    VPN_STACK_CIDR_PREFIX_LEN='30'
    if [[ -n "${requested_cidr}" ]]; then
        VPN_STACK_SERVICE_CIDR="${requested_cidr}"
        VPN_STACK_SERVICE_CIDR_SOURCE='override'
        VPN_STACK_SERVICE_CIDR_ORIGIN_SOURCE='override'
    else
        VPN_STACK_SERVICE_CIDR="$(vpn_stack_allocate_cidr "${VPN_STACK_CIDR_POOL}" "${VPN_STACK_CIDR_PREFIX_LEN}")"
        VPN_STACK_SERVICE_CIDR_SOURCE='allocated'
        VPN_STACK_SERVICE_CIDR_ORIGIN_SOURCE='allocated'
    fi

    template_stack_validate_k8s_name "${VPN_STACK_NAMESPACE}" "vpn namespace"
    template_stack_validate_k8s_name "${VPN_STACK_NETWORK_SERVICE_NAME}" "vpn network service name"
    vpn_stack_resolve_role_node "vpn VNF" "${requested_vnf_node}" "" "" VPN_STACK_VNF_NODE VPN_STACK_VNF_NODE_SOURCE VPN_STACK_VNF_NODE_ORIGIN_SOURCE
    vpn_stack_resolve_role_node "vpn client" "${requested_client_node}" "" "" VPN_STACK_CLIENT_NODE VPN_STACK_CLIENT_NODE_SOURCE VPN_STACK_CLIENT_NODE_ORIGIN_SOURCE
    vpn_stack_resolve_role_node "vpn server" "${requested_server_node}" "" "" VPN_STACK_SERVER_NODE VPN_STACK_SERVER_NODE_SOURCE VPN_STACK_SERVER_NODE_ORIGIN_SOURCE
    vpn_stack_assert_same_node
    vpn_stack_set_derived_values
    vpn_stack_assert_no_conflicts
    vpn_stack_write_state
}

vpn_stack_require_existing_state() {
    local state_file

    vpn_stack_require_id
    state_file="$(vpn_stack_state_file "${VPN_STACK_ID}")"
    [[ -f "${state_file}" ]] || die "vpn stack state not found: ${state_file}; run ./bin/nsm-ovs-lab show-vpn-plan --stack-id ${VPN_STACK_ID} or deploy-vpn --stack-id ${VPN_STACK_ID} first"
}

vpn_stack_write_resolved_values() {
    cat > "${VPN_STACK_RESOLVED_VALUES_FILE}" <<EOF
STACK_ID=${VPN_STACK_ID}
STACK_NAMESPACE=${VPN_STACK_NAMESPACE}
STACK_NAMESPACE_SOURCE=${VPN_STACK_NAMESPACE_SOURCE}
STACK_NAMESPACE_ORIGIN_SOURCE=${VPN_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${VPN_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_SOURCE=${VPN_STACK_NETWORK_SERVICE_NAME_SOURCE}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${VPN_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
SERVICE_CIDR=${VPN_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR=${VPN_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_SOURCE=${VPN_STACK_SERVICE_CIDR_SOURCE}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${VPN_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_LABEL=${VPN_STACK_LABEL}
STACK_LABEL_KEY=${VPN_STACK_LABEL_KEY}
STACK_LABEL_VALUE=${VPN_STACK_LABEL_VALUE}
ROLE_LABEL_KEY=${VPN_ROLE_LABEL_KEY}
ROLE_CLIENT=${VPN_ROLE_CLIENT}
ROLE_ENCRYPT=${VPN_ROLE_ENCRYPT}
ROLE_DECRYPT=${VPN_ROLE_DECRYPT}
ROLE_SERVER=${VPN_ROLE_SERVER}
VPN_ENCRYPT_DEPLOYMENT_NAME=${VPN_STACK_ENCRYPT_DEPLOYMENT_NAME}
VPN_DECRYPT_DEPLOYMENT_NAME=${VPN_STACK_DECRYPT_DEPLOYMENT_NAME}
SERVER_DEPLOYMENT_NAME=${VPN_STACK_SERVER_DEPLOYMENT_NAME}
CLIENT_DEPLOYMENT_NAME=${VPN_STACK_CLIENT_DEPLOYMENT_NAME}
VPN_ENCRYPT_POD_SELECTOR=${VPN_STACK_ENCRYPT_POD_SELECTOR}
VPN_DECRYPT_POD_SELECTOR=${VPN_STACK_DECRYPT_POD_SELECTOR}
SERVER_POD_SELECTOR=${VPN_STACK_SERVER_POD_SELECTOR}
CLIENT_POD_SELECTOR=${VPN_STACK_CLIENT_POD_SELECTOR}
VPN_ENCRYPT_NSM_LABELS=${VPN_STACK_ENCRYPT_NSM_LABELS}
VPN_DECRYPT_NSM_LABELS=${VPN_STACK_DECRYPT_NSM_LABELS}
SERVER_NSM_LABELS=${VPN_STACK_SERVER_NSM_LABELS}
CLIENT_NETWORK_SERVICES=${VPN_STACK_CLIENT_NETWORK_SERVICES}
SERVER_IPV4=${VPN_STACK_SERVER_IPV4}
TARGET_IPV4=${VPN_STACK_TARGET_IPV4}
PROXY_PORT=${VPN_STACK_PROXY_PORT}
WG_LISTEN_PORT=${VPN_STACK_WG_LISTEN_PORT}
WG_INTERFACE_NAME=${VPN_STACK_INTERFACE_NAME}
VNF_NODE=${VPN_STACK_VNF_NODE}
VNF_NODE_SOURCE=${VPN_STACK_VNF_NODE_SOURCE}
VNF_NODE_ORIGIN_SOURCE=${VPN_STACK_VNF_NODE_ORIGIN_SOURCE}
CLIENT_NODE=${VPN_STACK_CLIENT_NODE}
CLIENT_NODE_SOURCE=${VPN_STACK_CLIENT_NODE_SOURCE}
CLIENT_NODE_ORIGIN_SOURCE=${VPN_STACK_CLIENT_NODE_ORIGIN_SOURCE}
SERVER_NODE=${VPN_STACK_SERVER_NODE}
SERVER_NODE_SOURCE=${VPN_STACK_SERVER_NODE_SOURCE}
SERVER_NODE_ORIGIN_SOURCE=${VPN_STACK_SERVER_NODE_ORIGIN_SOURCE}
STATE_FILE=${VPN_STACK_STATE_FILE}
GENERATED_DIR=${VPN_STACK_GENERATED_DIR}
CIDR_POOL=${VPN_STACK_CIDR_POOL}
CIDR_PREFIX_LEN=${VPN_STACK_CIDR_PREFIX_LEN}
VPN_XNODE_MODE=${VPN_XNODE_MODE}
VPN_XNODE_MODE_SOURCE=${PLATFORM_VALUE_SOURCE[VPN_XNODE_MODE]}
EOF
}

vpn_stack_write_kustomization() {
    cat > "${VPN_STACK_GENERATED_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${VPN_STACK_NAMESPACE}

resources:
  - ../../../assets/vpn/k8s

patches:
  - path: patches/00-namespace.yaml
    target:
      kind: Namespace
      name: nse-ovs-vpn
  - path: patches/10-networkservice.yaml
    target:
      group: networkservicemesh.io
      version: v1
      kind: NetworkService
      name: nse-ovs-vpn
  - path: patches/20-nse-ovs-vpn-encrypt.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-vpn-encrypt
  - path: patches/25-nse-ovs-vpn-decrypt.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-vpn-decrypt
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

vpn_stack_write_namespace_patch() {
    cat > "${VPN_STACK_PATCH_DIR}/00-namespace.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${VPN_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
EOF
}

vpn_stack_write_networkservice_patch() {
    cat > "${VPN_STACK_PATCH_DIR}/10-networkservice.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${VPN_STACK_NETWORK_SERVICE_NAME}
- op: replace
  path: /metadata/namespace
  value: ${VPN_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
EOF
}

vpn_stack_write_encrypt_patch() {
    cat > "${VPN_STACK_PATCH_DIR}/20-nse-ovs-vpn-encrypt.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${VPN_STACK_ENCRYPT_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${VPN_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: vpn-encrypt
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_ENCRYPT}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: vpn-encrypt
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_ENCRYPT}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: vpn-encrypt
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_ENCRYPT}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${VPN_STACK_VNF_NODE}
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
      value: ${VPN_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_LABELS
      value: ${VPN_STACK_ENCRYPT_NSM_LABELS}
    - name: NSM_VPN_ROLE
      value: encrypt
    - name: NSM_VPN_TARGET_IP
      value: ${VPN_STACK_TARGET_IPV4}
    - name: NSM_VPN_PROXY_PORT
      value: "${VPN_STACK_PROXY_PORT}"
    - name: NSM_VPN_LISTEN_PORT
      value: "${VPN_STACK_WG_LISTEN_PORT}"
    - name: NSM_VPN_INTERFACE_NAME
      value: ${VPN_STACK_INTERFACE_NAME}
    - name: NSM_VPN_PRIVATE_KEY_PATH
      value: /etc/wireguard/keys/privatekey
    - name: NSM_VPN_PEER_PUBLIC_KEY_PATH
      value: /etc/wireguard/keys/peer_publickey
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
EOF
}

vpn_stack_write_decrypt_patch() {
    cat > "${VPN_STACK_PATCH_DIR}/25-nse-ovs-vpn-decrypt.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${VPN_STACK_DECRYPT_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${VPN_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: vpn-decrypt
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_DECRYPT}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: vpn-decrypt
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_DECRYPT}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: vpn-decrypt
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_DECRYPT}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${VPN_STACK_VNF_NODE}
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
      value: ${VPN_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_LABELS
      value: ${VPN_STACK_DECRYPT_NSM_LABELS}
    - name: NSM_VPN_ROLE
      value: decrypt
    - name: NSM_VPN_TARGET_IP
      value: ${VPN_STACK_TARGET_IPV4}
    - name: NSM_VPN_PROXY_PORT
      value: "${VPN_STACK_PROXY_PORT}"
    - name: NSM_VPN_LISTEN_PORT
      value: "${VPN_STACK_WG_LISTEN_PORT}"
    - name: NSM_VPN_INTERFACE_NAME
      value: ${VPN_STACK_INTERFACE_NAME}
    - name: NSM_VPN_PRIVATE_KEY_PATH
      value: /etc/wireguard/keys/privatekey
    - name: NSM_VPN_PEER_PUBLIC_KEY_PATH
      value: /etc/wireguard/keys/peer_publickey
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
EOF
}

vpn_stack_write_server_patch() {
    cat > "${VPN_STACK_PATCH_DIR}/30-nse-ovs-server.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${VPN_STACK_SERVER_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${VPN_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: server
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_SERVER}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: server
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_SERVER}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: server
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_SERVER}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${VPN_STACK_SERVER_NODE}
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
      value: ${VPN_STACK_SERVICE_CIDR}
    - name: NSM_SERVICE_NAMES
      value: ${VPN_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_REGISTER_SERVICE
      value: "false"
    - name: NSM_LABELS
      value: ${VPN_STACK_SERVER_NSM_LABELS}
    - name: NSM_LOG_LEVEL
      value: INFO
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
    - name: IPERF3_PORT
      value: "${VPN_STACK_PROXY_PORT}"
EOF
}

vpn_stack_write_client_patch() {
    cat > "${VPN_STACK_PATCH_DIR}/40-nsc-ovs-client.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${VPN_STACK_CLIENT_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${VPN_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: nsc-ovs-client
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_CLIENT}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: nsc-ovs-client
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_CLIENT}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: nsc-ovs-client
    ${VPN_STACK_LABEL_KEY}: ${VPN_STACK_ID}
    ${VPN_ROLE_LABEL_KEY}: ${VPN_ROLE_CLIENT}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${VPN_STACK_CLIENT_NODE}
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
      value: ${VPN_STACK_CLIENT_NETWORK_SERVICES}
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
      value: ${VPN_STACK_CLIENT_NETWORK_SERVICES}
    - name: NSM_NAME
      value: "\$(POD_NAME)-\$(POD_UID)"
EOF
}

vpn_stack_render() {
    rm -rf "${VPN_STACK_GENERATED_DIR}"
    mkdir -p "${VPN_STACK_PATCH_DIR}"

    vpn_stack_write_kustomization
    vpn_stack_write_namespace_patch
    vpn_stack_write_networkservice_patch
    vpn_stack_write_encrypt_patch
    vpn_stack_write_decrypt_patch
    vpn_stack_write_server_patch
    vpn_stack_write_client_patch
    vpn_stack_write_resolved_values
}

vpn_stack_apply_runtime_context() {
    VPN_RUNTIME_ROOT="${VPN_STACK_GENERATED_DIR}"
    VPN_K8S_DIR="${VPN_STACK_GENERATED_DIR}"
    VPN_VERIFY_SCRIPT="${VPN_VERIFY_ASSET_SCRIPT}"
    VPN_CLEANUP_SCRIPT="${VPN_CLEANUP_ASSET_SCRIPT}"
    VPN_NAMESPACE="${VPN_STACK_NAMESPACE}"
    VPN_NETWORK_SERVICE_NAME="${VPN_STACK_NETWORK_SERVICE_NAME}"
    VPN_SERVICE_NAME="${VPN_STACK_NETWORK_SERVICE_NAME}"
    VPN_ENCRYPT_DEPLOYMENT_NAME="${VPN_STACK_ENCRYPT_DEPLOYMENT_NAME}"
    VPN_DECRYPT_DEPLOYMENT_NAME="${VPN_STACK_DECRYPT_DEPLOYMENT_NAME}"
    VPN_SERVER_DEPLOYMENT_NAME="${VPN_STACK_SERVER_DEPLOYMENT_NAME}"
    VPN_CLIENT_DEPLOYMENT_NAME="${VPN_STACK_CLIENT_DEPLOYMENT_NAME}"
    VPN_SERVER_CIDR_PREFIX="${VPN_STACK_SERVICE_CIDR}"
    VPN_SERVER_IPV4="${VPN_STACK_SERVER_IPV4}"
    VPN_TARGET_IPV4="${VPN_STACK_TARGET_IPV4}"
    VPN_ENCRYPT_POD_SELECTOR="${VPN_STACK_ENCRYPT_POD_SELECTOR}"
    VPN_DECRYPT_POD_SELECTOR="${VPN_STACK_DECRYPT_POD_SELECTOR}"
    VPN_SERVER_POD_SELECTOR="${VPN_STACK_SERVER_POD_SELECTOR}"
    VPN_CLIENT_POD_SELECTOR="${VPN_STACK_CLIENT_POD_SELECTOR}"
}

vpn_stack_prepare_rendered_runtime() {
    vpn_init_runtime_context
    vpn_require_runtime_assets
    vpn_stack_prepare_plan
    vpn_stack_render
    vpn_stack_apply_runtime_context
}

vpn_stack_prepare_existing_rendered_runtime() {
    vpn_init_runtime_context
    vpn_require_runtime_assets
    vpn_stack_require_existing_state
    vpn_stack_prepare_plan
    vpn_stack_render
    vpn_stack_apply_runtime_context
}

vpn_stack_print_plan() {
    local same_node_only='true'
    local topology_support_source="${PLATFORM_VALUE_SOURCE[VPN_XNODE_MODE]}"

    if vpn_stack_xnode_mode_enabled; then
        same_node_only='false'
    fi

    printf 'stack_id: %s [source=cli]\n' "${VPN_STACK_ID}"
    printf 'state file: %s\n' "${VPN_STACK_STATE_FILE}"
    printf 'generated dir: %s\n' "${VPN_STACK_GENERATED_DIR}"
    printf 'namespace: %s [source=%s origin=%s]\n' "${VPN_STACK_NAMESPACE}" "${VPN_STACK_NAMESPACE_SOURCE}" "${VPN_STACK_NAMESPACE_ORIGIN_SOURCE}"
    printf 'network_service_name: %s [source=%s origin=%s]\n' "${VPN_STACK_NETWORK_SERVICE_NAME}" "${VPN_STACK_NETWORK_SERVICE_NAME_SOURCE}" "${VPN_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}"
    printf 'service_cidr: %s [source=%s origin=%s]\n' "${VPN_STACK_SERVICE_CIDR}" "${VPN_STACK_SERVICE_CIDR_SOURCE}" "${VPN_STACK_SERVICE_CIDR_ORIGIN_SOURCE}"
    printf 'vpn_xnode_mode: %s [source=%s]\n' "${VPN_XNODE_MODE}" "${PLATFORM_VALUE_SOURCE[VPN_XNODE_MODE]}"
    printf 'same_node_only: %s [source=%s]\n' "${same_node_only}" "${topology_support_source}"
    printf 'stack_label: %s [source=derived]\n' "${VPN_STACK_LABEL}"
    printf 'role_label.client: %s=%s [source=derived]\n' "${VPN_ROLE_LABEL_KEY}" "${VPN_ROLE_CLIENT}"
    printf 'role_label.encrypt: %s=%s [source=derived]\n' "${VPN_ROLE_LABEL_KEY}" "${VPN_ROLE_ENCRYPT}"
    printf 'role_label.decrypt: %s=%s [source=derived]\n' "${VPN_ROLE_LABEL_KEY}" "${VPN_ROLE_DECRYPT}"
    printf 'role_label.server: %s=%s [source=derived]\n' "${VPN_ROLE_LABEL_KEY}" "${VPN_ROLE_SERVER}"
    printf 'vpn encrypt deployment: %s [source=derived]\n' "${VPN_STACK_ENCRYPT_DEPLOYMENT_NAME}"
    printf 'vpn decrypt deployment: %s [source=derived]\n' "${VPN_STACK_DECRYPT_DEPLOYMENT_NAME}"
    printf 'server deployment: %s [source=derived]\n' "${VPN_STACK_SERVER_DEPLOYMENT_NAME}"
    printf 'client deployment: %s [source=derived]\n' "${VPN_STACK_CLIENT_DEPLOYMENT_NAME}"
    printf 'vpn middle image reuse: encrypt/decrypt share source pinned image [source=asset-base]\n'
    printf 'target_ipv4: %s [source=derived]\n' "${VPN_STACK_TARGET_IPV4}"
    printf 'proxy_port: %s [source=derived]\n' "${VPN_STACK_PROXY_PORT}"
    printf 'wg_listen_port: %s [source=derived]\n' "${VPN_STACK_WG_LISTEN_PORT}"
    printf 'vnf_node: %s [source=%s origin=%s]\n' "${VPN_STACK_VNF_NODE}" "${VPN_STACK_VNF_NODE_SOURCE}" "${VPN_STACK_VNF_NODE_ORIGIN_SOURCE}"
    printf 'client_node: %s [source=%s origin=%s]\n' "${VPN_STACK_CLIENT_NODE}" "${VPN_STACK_CLIENT_NODE_SOURCE}" "${VPN_STACK_CLIENT_NODE_ORIGIN_SOURCE}"
    printf 'server_node: %s [source=%s origin=%s]\n' "${VPN_STACK_SERVER_NODE}" "${VPN_STACK_SERVER_NODE_SOURCE}" "${VPN_STACK_SERVER_NODE_ORIGIN_SOURCE}"
    printf 'vpn encrypt env.NSM_SERVICE_NAME: %s [source=derived]\n' "${VPN_STACK_NETWORK_SERVICE_NAME}"
    printf 'vpn encrypt env.NSM_LABELS: %s [source=source-vpn]\n' "${VPN_STACK_ENCRYPT_NSM_LABELS}"
    printf 'vpn decrypt env.NSM_SERVICE_NAME: %s [source=derived]\n' "${VPN_STACK_NETWORK_SERVICE_NAME}"
    printf 'vpn decrypt env.NSM_LABELS: %s [source=source-vpn]\n' "${VPN_STACK_DECRYPT_NSM_LABELS}"
    printf 'server env.NSM_SERVICE_NAMES: %s [source=derived]\n' "${VPN_STACK_NETWORK_SERVICE_NAME}"
    printf 'server env.NSM_CIDR_PREFIX: %s [source=derived]\n' "${VPN_STACK_SERVICE_CIDR}"
    printf 'server env.NSM_LABELS: %s [source=source-vpn]\n' "${VPN_STACK_SERVER_NSM_LABELS}"
    printf 'client env.NSM_NETWORK_SERVICES: %s [source=derived]\n' "${VPN_STACK_CLIENT_NETWORK_SERVICES}"
    printf 'cidr pool: %s [source=%s]\n' "${VPN_STACK_CIDR_POOL}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_POOL]}"
    printf 'cidr prefix len: %s [source=hardcoded]\n' "${VPN_STACK_CIDR_PREFIX_LEN}"
}
