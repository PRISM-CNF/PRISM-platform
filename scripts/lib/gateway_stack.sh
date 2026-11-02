#!/usr/bin/env bash

if [[ -n "${NSM_OVS_GATEWAY_STACK_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_GATEWAY_STACK_SH_LOADED=1

GATEWAY_STACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${GATEWAY_STACK_LIB_DIR}/template_stack.sh"

gateway_stack_default_role_node() {
    local role_label=${1:-}

    case "${role_label}" in
        vnf|middle|gateway)
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

gateway_stack_name_suffix() {
    local stack_id=$1

    if [[ "${stack_id}" == gw-* && "${stack_id#gw-}" != "${stack_id}" ]]; then
        printf '%s\n' "${stack_id#gw-}"
    else
        printf '%s\n' "${stack_id}"
    fi
}

gateway_stack_default_namespace() {
    local stack_id=$1
    printf 'exp-%s\n' "${stack_id}"
}

gateway_stack_default_network_service_name() {
    local stack_id=$1
    local suffix

    suffix="$(gateway_stack_name_suffix "${stack_id}")"
    printf 'nse-ovs-gateway-%s\n' "${suffix}"
}

gateway_stack_state_file() {
    local stack_id=$1
    printf '%s/%s.env\n' "${GATEWAY_STACK_STATE_ROOT}" "${stack_id}"
}

gateway_stack_generated_dir_for() {
    local stack_id=$1
    printf '%s/%s\n' "${GATEWAY_GENERATED_ROOT}" "${stack_id}"
}

gateway_stack_plan_dirs() {
    mkdir -p "${GATEWAY_STACK_STATE_ROOT}" "${GATEWAY_GENERATED_ROOT}"
}

gateway_stack_set_derived_values() {
    local name_suffix

    name_suffix="$(gateway_stack_name_suffix "${GATEWAY_STACK_ID}")"

    GATEWAY_STACK_LABEL_KEY='exp.nsm.ai/stack'
    GATEWAY_ROLE_LABEL_KEY='exp.nsm.ai/role'
    GATEWAY_STACK_LABEL_VALUE="${GATEWAY_STACK_ID}"
    GATEWAY_STACK_LABEL="${GATEWAY_STACK_LABEL_KEY}=${GATEWAY_STACK_LABEL_VALUE}"

    GATEWAY_ROLE_CLIENT='client'
    GATEWAY_ROLE_MIDDLE='middle'
    GATEWAY_ROLE_SERVER='server'

    GATEWAY_STACK_MIDDLE_DEPLOYMENT_NAME="nse-ovs-gateway-${name_suffix}"
    GATEWAY_STACK_SERVER_DEPLOYMENT_NAME="nse-ovs-server-${name_suffix}"
    GATEWAY_STACK_CLIENT_DEPLOYMENT_NAME="nsc-ovs-client-${name_suffix}"
    GATEWAY_STACK_RULES_CONFIGMAP_NAME='nse-ovs-gateway-rules'

    GATEWAY_STACK_MIDDLE_POD_SELECTOR="${GATEWAY_STACK_LABEL_KEY}=${GATEWAY_STACK_ID},${GATEWAY_ROLE_LABEL_KEY}=${GATEWAY_ROLE_MIDDLE}"
    GATEWAY_STACK_SERVER_POD_SELECTOR="${GATEWAY_STACK_LABEL_KEY}=${GATEWAY_STACK_ID},${GATEWAY_ROLE_LABEL_KEY}=${GATEWAY_ROLE_SERVER}"
    GATEWAY_STACK_CLIENT_POD_SELECTOR="${GATEWAY_STACK_LABEL_KEY}=${GATEWAY_STACK_ID},${GATEWAY_ROLE_LABEL_KEY}=${GATEWAY_ROLE_CLIENT}"

    GATEWAY_STACK_MIDDLE_NSM_LABELS="${GATEWAY_STACK_LABEL_KEY}:${GATEWAY_STACK_ID},${GATEWAY_ROLE_LABEL_KEY}:${GATEWAY_ROLE_MIDDLE}"
    GATEWAY_STACK_SERVER_NSM_LABELS="${GATEWAY_STACK_LABEL_KEY}:${GATEWAY_STACK_ID},${GATEWAY_ROLE_LABEL_KEY}:${GATEWAY_ROLE_SERVER}"
    GATEWAY_STACK_CLIENT_NETWORK_SERVICES="kernel://${GATEWAY_STACK_NETWORK_SERVICE_NAME}/nsm-1"
    GATEWAY_STACK_SERVER_IPV4="${GATEWAY_STACK_SERVICE_CIDR%%/*}"

    GATEWAY_STACK_STATE_FILE="$(gateway_stack_state_file "${GATEWAY_STACK_ID}")"
    GATEWAY_STACK_GENERATED_DIR="$(gateway_stack_generated_dir_for "${GATEWAY_STACK_ID}")"
    GATEWAY_STACK_PATCH_DIR="${GATEWAY_STACK_GENERATED_DIR}/patches"
    GATEWAY_STACK_RESOLVED_VALUES_FILE="${GATEWAY_STACK_GENERATED_DIR}/resolved-values.env"
}

gateway_stack_each_other_state() {
    local current_stack_id=$1
    local state_file

    shopt -s nullglob
    for state_file in "${STACK_STATE_ROOT}"/*.env; do
        [[ "${state_file}" == "$(gateway_stack_state_file "${current_stack_id}")" ]] && continue
        printf '%s\n' "${state_file}"
    done
    shopt -u nullglob
}

gateway_stack_assert_no_conflicts() {
    local other_stack_id other_namespace other_network_service other_cidr
    local range_index
    local -a other_state_files=() other_stack_ids=() other_namespaces=() other_network_services=() other_cidrs=()

    template_stack_collect_other_state_details \
        "$(gateway_stack_state_file "${GATEWAY_STACK_ID}")" \
        other_state_files other_stack_ids other_namespaces other_network_services other_cidrs

    for (( range_index = 0; range_index < ${#other_state_files[@]}; range_index++ )); do
        other_stack_id="${other_stack_ids[range_index]}"
        other_namespace="${other_namespaces[range_index]}"
        other_network_service="${other_network_services[range_index]}"
        other_cidr="${other_cidrs[range_index]}"

        [[ -n "${other_namespace}" ]] || continue

        if [[ "${GATEWAY_STACK_NAMESPACE}" == "${other_namespace}" ]]; then
            die "gateway namespace ${GATEWAY_STACK_NAMESPACE} is already allocated to stack ${other_stack_id}"
        fi

        if [[ "${GATEWAY_STACK_NETWORK_SERVICE_NAME}" == "${other_network_service}" ]]; then
            die "gateway network service ${GATEWAY_STACK_NETWORK_SERVICE_NAME} is already allocated to stack ${other_stack_id}"
        fi

        if [[ -n "${other_cidr}" ]] && template_stack_cidrs_overlap "${GATEWAY_STACK_SERVICE_CIDR}" "${other_cidr}"; then
            die "gateway service CIDR ${GATEWAY_STACK_SERVICE_CIDR} overlaps stack ${other_stack_id} CIDR ${other_cidr}"
        fi
    done
}

gateway_stack_allocate_cidr() {
    local pool_cidr=$1
    local target_prefix_len=$2
    local pool_prefix_len=${pool_cidr#*/}
    local pool_network_int candidate_network_int candidate_cidr
    local candidate_end_int pool_end_int subnet_size subnet_count index other_cidr
    local range_index conflict highest_used_end fast_candidate_int fast_candidate_end last_range_index
    local -a other_state_files=() other_stack_ids=() other_namespaces=() other_network_services=() other_cidrs=()
    local -a other_range_starts=() other_range_ends=()

    template_stack_validate_cidr_prefix "${pool_cidr}"
    [[ "${target_prefix_len}" =~ ^[0-9]+$ ]] || die "invalid gateway CIDR prefix len: ${target_prefix_len}"
    (( target_prefix_len >= pool_prefix_len && target_prefix_len <= 32 )) || die "gateway CIDR prefix len ${target_prefix_len} is incompatible with pool ${pool_cidr}"

    pool_network_int="$(template_stack_cidr_network_int "${pool_cidr}")"
    subnet_size=$(( 1 << (32 - target_prefix_len) ))
    subnet_count=$(( 1 << (target_prefix_len - pool_prefix_len) ))
    pool_end_int=$(( pool_network_int + subnet_size * subnet_count - 1 ))
    highest_used_end=$(( pool_network_int - 1 ))

    template_stack_collect_other_state_details \
        "$(gateway_stack_state_file "${GATEWAY_STACK_ID}")" \
        other_state_files other_stack_ids other_namespaces other_network_services other_cidrs

    for other_cidr in "${other_cidrs[@]}"; do
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

    die "no free gateway service CIDR left in pool ${pool_cidr} with prefix len ${target_prefix_len}"
}

gateway_stack_resolve_role_node() {
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
        resolved_value="$(gateway_stack_default_role_node "${role_label}")"
        resolved_source='default'
        resolved_origin='default'
    fi

    template_stack_validate_node_name "${resolved_value}" "${role_label} node"
    printf -v "${target_value_name}" '%s' "${resolved_value}"
    printf -v "${target_source_name}" '%s' "${resolved_source}"
    printf -v "${target_origin_name}" '%s' "${resolved_origin}"
}

gateway_stack_load_state() {
    local stack_id=$1
    local state_file
    local -A state_map=()

    state_file="$(gateway_stack_state_file "${stack_id}")"
    [[ -f "${state_file}" ]] || return 1

    platform_load_env_file "${state_file}" state_map

    GATEWAY_STACK_ID="${state_map[STACK_ID]:-${stack_id}}"
    GATEWAY_STACK_NAMESPACE="${state_map[STACK_NAMESPACE]:-}"
    GATEWAY_STACK_NAMESPACE_SOURCE='persisted'
    GATEWAY_STACK_NAMESPACE_ORIGIN_SOURCE="${state_map[STACK_NAMESPACE_ORIGIN_SOURCE]:-persisted}"
    GATEWAY_STACK_NETWORK_SERVICE_NAME="${state_map[STACK_NETWORK_SERVICE_NAME]:-}"
    GATEWAY_STACK_NETWORK_SERVICE_NAME_SOURCE='persisted'
    GATEWAY_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE="${state_map[STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE]:-persisted}"
    GATEWAY_STACK_SERVICE_CIDR="${state_map[STACK_SERVICE_CIDR]:-}"
    GATEWAY_STACK_SERVICE_CIDR_SOURCE='persisted'
    GATEWAY_STACK_SERVICE_CIDR_ORIGIN_SOURCE="${state_map[STACK_SERVICE_CIDR_ORIGIN_SOURCE]:-persisted}"
    GATEWAY_STACK_VNF_NODE_PERSISTED="${state_map[STACK_VNF_NODE]:-}"
    GATEWAY_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_VNF_NODE_ORIGIN_SOURCE]:-persisted}"
    GATEWAY_STACK_CLIENT_NODE_PERSISTED="${state_map[STACK_CLIENT_NODE]:-}"
    GATEWAY_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_CLIENT_NODE_ORIGIN_SOURCE]:-persisted}"
    GATEWAY_STACK_SERVER_NODE_PERSISTED="${state_map[STACK_SERVER_NODE]:-}"
    GATEWAY_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE="${state_map[STACK_SERVER_NODE_ORIGIN_SOURCE]:-persisted}"
    GATEWAY_STACK_CIDR_POOL="${state_map[STACK_CIDR_POOL]:-${TEMPLATE_CIDR_POOL}}"
    GATEWAY_STACK_CIDR_PREFIX_LEN="${state_map[STACK_CIDR_PREFIX_LEN]:-${TEMPLATE_CIDR_PREFIX_LEN}}"
    GATEWAY_STACK_STATE_CREATED_AT="${state_map[STACK_STATE_CREATED_AT]:-}"
    GATEWAY_STACK_STATE_CREATED_AT_LOCAL="${state_map[STACK_STATE_CREATED_AT_LOCAL]:-}"
    GATEWAY_STACK_STATE_CREATED_AT_EPOCH_MS="${state_map[STACK_STATE_CREATED_AT_EPOCH_MS]:-}"

    [[ -n "${GATEWAY_STACK_NAMESPACE}" ]] || die "persisted gateway stack namespace missing in ${state_file}"
    [[ -n "${GATEWAY_STACK_NETWORK_SERVICE_NAME}" ]] || die "persisted gateway stack network service missing in ${state_file}"
    [[ -n "${GATEWAY_STACK_SERVICE_CIDR}" ]] || die "persisted gateway stack service CIDR missing in ${state_file}"

    gateway_stack_set_derived_values
    return 0
}

gateway_stack_write_state() {
    local created_at created_at_local created_at_epoch_ms

    created_at_local="${GATEWAY_STACK_STATE_CREATED_AT_LOCAL:-}"
    created_at="${GATEWAY_STACK_STATE_CREATED_AT:-}"
    created_at_epoch_ms="${GATEWAY_STACK_STATE_CREATED_AT_EPOCH_MS:-}"

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

    cat > "${GATEWAY_STACK_STATE_FILE}" <<EOF
STACK_ID=${GATEWAY_STACK_ID}
STACK_NAMESPACE=${GATEWAY_STACK_NAMESPACE}
STACK_NAMESPACE_ORIGIN_SOURCE=${GATEWAY_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${GATEWAY_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${GATEWAY_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${GATEWAY_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${GATEWAY_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_VNF_NODE=${GATEWAY_STACK_VNF_NODE}
STACK_VNF_NODE_ORIGIN_SOURCE=${GATEWAY_STACK_VNF_NODE_ORIGIN_SOURCE}
STACK_CLIENT_NODE=${GATEWAY_STACK_CLIENT_NODE}
STACK_CLIENT_NODE_ORIGIN_SOURCE=${GATEWAY_STACK_CLIENT_NODE_ORIGIN_SOURCE}
STACK_SERVER_NODE=${GATEWAY_STACK_SERVER_NODE}
STACK_SERVER_NODE_ORIGIN_SOURCE=${GATEWAY_STACK_SERVER_NODE_ORIGIN_SOURCE}
STACK_CIDR_POOL=${GATEWAY_STACK_CIDR_POOL}
STACK_CIDR_PREFIX_LEN=${GATEWAY_STACK_CIDR_PREFIX_LEN}
STACK_STATE_CREATED_AT=${created_at}
STACK_STATE_CREATED_AT_LOCAL=${created_at_local}
STACK_STATE_CREATED_AT_EPOCH_MS=${created_at_epoch_ms}
EOF
    GATEWAY_STACK_STATE_CREATED_AT="${created_at}"
    GATEWAY_STACK_STATE_CREATED_AT_LOCAL="${created_at_local}"
    GATEWAY_STACK_STATE_CREATED_AT_EPOCH_MS="${created_at_epoch_ms}"
}

gateway_stack_require_id() {
    GATEWAY_STACK_ID="${TEMPLATE_STACK_ID_INPUT:-}"
    [[ -n "${GATEWAY_STACK_ID}" ]] || die "missing required --stack-id for gateway stack operation"
    [[ "${PLATFORM_VALUE_SOURCE[TEMPLATE_STACK_ID_INPUT]}" == "cli" ]] || die "gateway stack operation requires an explicit --stack-id"
    template_stack_validate_id "${GATEWAY_STACK_ID}"
}

gateway_stack_prepare_plan() {
    local requested_namespace requested_network_service requested_cidr
    local requested_vnf_node requested_client_node requested_server_node

    gateway_stack_plan_dirs
    gateway_stack_require_id

    requested_namespace="${TEMPLATE_NAMESPACE_OVERRIDE_INPUT:-}"
    requested_network_service="${TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT:-}"
    requested_cidr="${TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT:-}"
    requested_vnf_node="${TEMPLATE_VNF_NODE_INPUT:-}"
    requested_client_node="${TEMPLATE_CLIENT_NODE_INPUT:-}"
    requested_server_node="${TEMPLATE_SERVER_NODE_INPUT:-}"

    if [[ -n "${requested_namespace}" ]]; then
        template_stack_validate_k8s_name "${requested_namespace}" "gateway namespace override"
    fi
    if [[ -n "${requested_network_service}" ]]; then
        template_stack_validate_k8s_name "${requested_network_service}" "gateway network service override"
    fi
    if [[ -n "${requested_cidr}" ]]; then
        template_stack_validate_cidr_prefix "${requested_cidr}"
    fi
    if [[ -n "${requested_vnf_node}" ]]; then
        template_stack_validate_node_name "${requested_vnf_node}" "gateway VNF node override"
    fi
    if [[ -n "${requested_client_node}" ]]; then
        template_stack_validate_node_name "${requested_client_node}" "gateway client node override"
    fi
    if [[ -n "${requested_server_node}" ]]; then
        template_stack_validate_node_name "${requested_server_node}" "gateway server node override"
    fi

    if gateway_stack_load_state "${GATEWAY_STACK_ID}"; then
        template_stack_require_state_match "namespace" "${requested_namespace}" "${GATEWAY_STACK_NAMESPACE}"
        template_stack_require_state_match "network_service_name" "${requested_network_service}" "${GATEWAY_STACK_NETWORK_SERVICE_NAME}"
        template_stack_require_state_match "service_cidr" "${requested_cidr}" "${GATEWAY_STACK_SERVICE_CIDR}"
        template_stack_require_state_match "vnf_node" "${requested_vnf_node}" "${GATEWAY_STACK_VNF_NODE_PERSISTED:-}"
        template_stack_require_state_match "client_node" "${requested_client_node}" "${GATEWAY_STACK_CLIENT_NODE_PERSISTED:-}"
        template_stack_require_state_match "server_node" "${requested_server_node}" "${GATEWAY_STACK_SERVER_NODE_PERSISTED:-}"
        gateway_stack_resolve_role_node "gateway VNF" "${requested_vnf_node}" "${GATEWAY_STACK_VNF_NODE_PERSISTED:-}" "${GATEWAY_STACK_VNF_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" GATEWAY_STACK_VNF_NODE GATEWAY_STACK_VNF_NODE_SOURCE GATEWAY_STACK_VNF_NODE_ORIGIN_SOURCE
        gateway_stack_resolve_role_node "gateway client" "${requested_client_node}" "${GATEWAY_STACK_CLIENT_NODE_PERSISTED:-}" "${GATEWAY_STACK_CLIENT_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" GATEWAY_STACK_CLIENT_NODE GATEWAY_STACK_CLIENT_NODE_SOURCE GATEWAY_STACK_CLIENT_NODE_ORIGIN_SOURCE
        gateway_stack_resolve_role_node "gateway server" "${requested_server_node}" "${GATEWAY_STACK_SERVER_NODE_PERSISTED:-}" "${GATEWAY_STACK_SERVER_NODE_PERSISTED_ORIGIN_SOURCE:-persisted}" GATEWAY_STACK_SERVER_NODE GATEWAY_STACK_SERVER_NODE_SOURCE GATEWAY_STACK_SERVER_NODE_ORIGIN_SOURCE
        return 0
    fi

    GATEWAY_STACK_NAMESPACE="${requested_namespace:-$(gateway_stack_default_namespace "${GATEWAY_STACK_ID}")}"
    GATEWAY_STACK_NAMESPACE_SOURCE='default'
    GATEWAY_STACK_NAMESPACE_ORIGIN_SOURCE='default'
    if [[ -n "${requested_namespace}" ]]; then
        GATEWAY_STACK_NAMESPACE_SOURCE='override'
        GATEWAY_STACK_NAMESPACE_ORIGIN_SOURCE='override'
    fi

    GATEWAY_STACK_NETWORK_SERVICE_NAME="${requested_network_service:-$(gateway_stack_default_network_service_name "${GATEWAY_STACK_ID}")}"
    GATEWAY_STACK_NETWORK_SERVICE_NAME_SOURCE='default'
    GATEWAY_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='default'
    if [[ -n "${requested_network_service}" ]]; then
        GATEWAY_STACK_NETWORK_SERVICE_NAME_SOURCE='override'
        GATEWAY_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE='override'
    fi

    GATEWAY_STACK_CIDR_POOL="${TEMPLATE_CIDR_POOL}"
    GATEWAY_STACK_CIDR_PREFIX_LEN="${TEMPLATE_CIDR_PREFIX_LEN}"
    if [[ -n "${requested_cidr}" ]]; then
        GATEWAY_STACK_SERVICE_CIDR="${requested_cidr}"
        GATEWAY_STACK_SERVICE_CIDR_SOURCE='override'
        GATEWAY_STACK_SERVICE_CIDR_ORIGIN_SOURCE='override'
    else
        GATEWAY_STACK_SERVICE_CIDR="$(gateway_stack_allocate_cidr "${GATEWAY_STACK_CIDR_POOL}" "${GATEWAY_STACK_CIDR_PREFIX_LEN}")"
        GATEWAY_STACK_SERVICE_CIDR_SOURCE='allocated'
        GATEWAY_STACK_SERVICE_CIDR_ORIGIN_SOURCE='allocated'
    fi

    template_stack_validate_k8s_name "${GATEWAY_STACK_NAMESPACE}" "gateway namespace"
    template_stack_validate_k8s_name "${GATEWAY_STACK_NETWORK_SERVICE_NAME}" "gateway network service name"
    gateway_stack_resolve_role_node "gateway VNF" "${requested_vnf_node}" "" "" GATEWAY_STACK_VNF_NODE GATEWAY_STACK_VNF_NODE_SOURCE GATEWAY_STACK_VNF_NODE_ORIGIN_SOURCE
    gateway_stack_resolve_role_node "gateway client" "${requested_client_node}" "" "" GATEWAY_STACK_CLIENT_NODE GATEWAY_STACK_CLIENT_NODE_SOURCE GATEWAY_STACK_CLIENT_NODE_ORIGIN_SOURCE
    gateway_stack_resolve_role_node "gateway server" "${requested_server_node}" "" "" GATEWAY_STACK_SERVER_NODE GATEWAY_STACK_SERVER_NODE_SOURCE GATEWAY_STACK_SERVER_NODE_ORIGIN_SOURCE
    gateway_stack_set_derived_values
    gateway_stack_assert_no_conflicts
    gateway_stack_write_state
}

gateway_stack_require_existing_state() {
    local state_file

    gateway_stack_require_id
    state_file="$(gateway_stack_state_file "${GATEWAY_STACK_ID}")"
    [[ -f "${state_file}" ]] || die "gateway stack state not found: ${state_file}; run ./bin/nsm-ovs-lab show-gateway-plan --stack-id ${GATEWAY_STACK_ID} or deploy-gateway --stack-id ${GATEWAY_STACK_ID} first"
}

gateway_stack_write_resolved_values() {
    cat > "${GATEWAY_STACK_RESOLVED_VALUES_FILE}" <<EOF
STACK_ID=${GATEWAY_STACK_ID}
STACK_NAMESPACE=${GATEWAY_STACK_NAMESPACE}
STACK_NAMESPACE_SOURCE=${GATEWAY_STACK_NAMESPACE_SOURCE}
STACK_NAMESPACE_ORIGIN_SOURCE=${GATEWAY_STACK_NAMESPACE_ORIGIN_SOURCE}
STACK_NETWORK_SERVICE_NAME=${GATEWAY_STACK_NETWORK_SERVICE_NAME}
STACK_NETWORK_SERVICE_NAME_SOURCE=${GATEWAY_STACK_NETWORK_SERVICE_NAME_SOURCE}
STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE=${GATEWAY_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}
STACK_SERVICE_CIDR=${GATEWAY_STACK_SERVICE_CIDR}
STACK_SERVICE_CIDR_SOURCE=${GATEWAY_STACK_SERVICE_CIDR_SOURCE}
STACK_SERVICE_CIDR_ORIGIN_SOURCE=${GATEWAY_STACK_SERVICE_CIDR_ORIGIN_SOURCE}
STACK_LABEL=${GATEWAY_STACK_LABEL}
STACK_LABEL_KEY=${GATEWAY_STACK_LABEL_KEY}
STACK_LABEL_VALUE=${GATEWAY_STACK_LABEL_VALUE}
ROLE_LABEL_KEY=${GATEWAY_ROLE_LABEL_KEY}
ROLE_CLIENT=${GATEWAY_ROLE_CLIENT}
ROLE_MIDDLE=${GATEWAY_ROLE_MIDDLE}
ROLE_SERVER=${GATEWAY_ROLE_SERVER}
GATEWAY_DEPLOYMENT_NAME=${GATEWAY_STACK_MIDDLE_DEPLOYMENT_NAME}
SERVER_DEPLOYMENT_NAME=${GATEWAY_STACK_SERVER_DEPLOYMENT_NAME}
CLIENT_DEPLOYMENT_NAME=${GATEWAY_STACK_CLIENT_DEPLOYMENT_NAME}
RULES_CONFIGMAP_NAME=${GATEWAY_STACK_RULES_CONFIGMAP_NAME}
GATEWAY_POD_SELECTOR=${GATEWAY_STACK_MIDDLE_POD_SELECTOR}
SERVER_POD_SELECTOR=${GATEWAY_STACK_SERVER_POD_SELECTOR}
CLIENT_POD_SELECTOR=${GATEWAY_STACK_CLIENT_POD_SELECTOR}
GATEWAY_NSM_LABELS=${GATEWAY_STACK_MIDDLE_NSM_LABELS}
SERVER_NSM_LABELS=${GATEWAY_STACK_SERVER_NSM_LABELS}
CLIENT_NETWORK_SERVICES=${GATEWAY_STACK_CLIENT_NETWORK_SERVICES}
SERVER_IPV4=${GATEWAY_STACK_SERVER_IPV4}
VNF_NODE=${GATEWAY_STACK_VNF_NODE}
VNF_NODE_SOURCE=${GATEWAY_STACK_VNF_NODE_SOURCE}
VNF_NODE_ORIGIN_SOURCE=${GATEWAY_STACK_VNF_NODE_ORIGIN_SOURCE}
CLIENT_NODE=${GATEWAY_STACK_CLIENT_NODE}
CLIENT_NODE_SOURCE=${GATEWAY_STACK_CLIENT_NODE_SOURCE}
CLIENT_NODE_ORIGIN_SOURCE=${GATEWAY_STACK_CLIENT_NODE_ORIGIN_SOURCE}
SERVER_NODE=${GATEWAY_STACK_SERVER_NODE}
SERVER_NODE_SOURCE=${GATEWAY_STACK_SERVER_NODE_SOURCE}
SERVER_NODE_ORIGIN_SOURCE=${GATEWAY_STACK_SERVER_NODE_ORIGIN_SOURCE}
STATE_FILE=${GATEWAY_STACK_STATE_FILE}
GENERATED_DIR=${GATEWAY_STACK_GENERATED_DIR}
CIDR_POOL=${GATEWAY_STACK_CIDR_POOL}
CIDR_PREFIX_LEN=${GATEWAY_STACK_CIDR_PREFIX_LEN}
EOF
}

gateway_stack_write_kustomization() {
    cat > "${GATEWAY_STACK_GENERATED_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${GATEWAY_STACK_NAMESPACE}

resources:
  - ../../../assets/gateway/k8s

patches:
  - path: patches/00-namespace.yaml
    target:
      kind: Namespace
      name: nse-ovs-gateway
  - path: patches/10-networkservice.yaml
    target:
      group: networkservicemesh.io
      version: v1
      kind: NetworkService
      name: nse-ovs-gateway
  - path: patches/15-gateway-rules.yaml
    target:
      version: v1
      kind: ConfigMap
      name: nse-ovs-gateway-rules
  - path: patches/20-nse-ovs-gateway.yaml
    target:
      group: apps
      version: v1
      kind: Deployment
      name: nse-ovs-gateway
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

gateway_stack_write_namespace_patch() {
    cat > "${GATEWAY_STACK_PATCH_DIR}/00-namespace.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${GATEWAY_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
EOF
}

gateway_stack_write_networkservice_patch() {
    cat > "${GATEWAY_STACK_PATCH_DIR}/10-networkservice.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${GATEWAY_STACK_NETWORK_SERVICE_NAME}
- op: replace
  path: /metadata/namespace
  value: ${GATEWAY_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/matches
  value:
    - source_selector:
        ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
        ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_MIDDLE}
      routes:
        - destination_selector:
            ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
            ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_SERVER}
    - routes:
        - destination_selector:
            ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
            ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_MIDDLE}
EOF
}

gateway_stack_write_rules_patch() {
    cat > "${GATEWAY_STACK_PATCH_DIR}/15-gateway-rules.yaml" <<EOF
- op: replace
  path: /metadata/namespace
  value: ${GATEWAY_STACK_NAMESPACE}
- op: add
  path: /metadata/labels
  value:
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /data/rules.yaml
  value: |-
    mode: allowlist
    rules:
      - name: client-server
        left_cidrs:
          - ${GATEWAY_STACK_SERVICE_CIDR}
        right_cidrs:
          - ${GATEWAY_STACK_SERVICE_CIDR}
EOF
}

gateway_stack_write_gateway_patch() {
    cat > "${GATEWAY_STACK_PATCH_DIR}/20-nse-ovs-gateway.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${GATEWAY_STACK_MIDDLE_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${GATEWAY_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${GATEWAY_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_MIDDLE}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${GATEWAY_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_MIDDLE}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${GATEWAY_STACK_MIDDLE_DEPLOYMENT_NAME}
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_MIDDLE}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${GATEWAY_STACK_VNF_NODE}
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
      value: ${GATEWAY_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_LABELS
      value: ${GATEWAY_STACK_MIDDLE_NSM_LABELS}
    - name: NSM_GATEWAY_RULES_PATH
      value: /etc/nse-gateway/rules.yaml
    - name: NSM_LOG_LEVEL
      value: TRACE
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
EOF
}

gateway_stack_write_server_patch() {
    cat > "${GATEWAY_STACK_PATCH_DIR}/30-nse-ovs-server.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${GATEWAY_STACK_SERVER_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${GATEWAY_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${GATEWAY_STACK_SERVER_DEPLOYMENT_NAME}
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_SERVER}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${GATEWAY_STACK_SERVER_DEPLOYMENT_NAME}
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_SERVER}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${GATEWAY_STACK_SERVER_DEPLOYMENT_NAME}
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_SERVER}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${GATEWAY_STACK_SERVER_NODE}
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
      value: ${GATEWAY_STACK_SERVICE_CIDR}
    - name: NSM_SERVICE_NAMES
      value: ${GATEWAY_STACK_NETWORK_SERVICE_NAME}
    - name: NSM_REGISTER_SERVICE
      value: "false"
    - name: NSM_LABELS
      value: ${GATEWAY_STACK_SERVER_NSM_LABELS}
    - name: NSM_LOG_LEVEL
      value: INFO
    - name: NSM_CONNECT_TO
      value: unix:///var/lib/networkservicemesh/nsm.io.sock
    - name: IPERF3_PORT
      value: "5201"
EOF
}

gateway_stack_write_client_patch() {
    cat > "${GATEWAY_STACK_PATCH_DIR}/40-nsc-ovs-client.yaml" <<EOF
- op: replace
  path: /metadata/name
  value: ${GATEWAY_STACK_CLIENT_DEPLOYMENT_NAME}
- op: replace
  path: /metadata/namespace
  value: ${GATEWAY_STACK_NAMESPACE}
- op: replace
  path: /metadata/labels
  value:
    app: ${GATEWAY_STACK_CLIENT_DEPLOYMENT_NAME}
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_CLIENT}
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/selector/matchLabels
  value:
    app: ${GATEWAY_STACK_CLIENT_DEPLOYMENT_NAME}
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_CLIENT}
- op: replace
  path: /spec/template/metadata/labels
  value:
    app: ${GATEWAY_STACK_CLIENT_DEPLOYMENT_NAME}
    ${GATEWAY_STACK_LABEL_KEY}: ${GATEWAY_STACK_ID}
    ${GATEWAY_ROLE_LABEL_KEY}: ${GATEWAY_ROLE_CLIENT}
    spiffe.io/spiffe-id: "true"
    app.kubernetes.io/managed-by: nsm-ovs-test-platform
- op: replace
  path: /spec/template/spec/nodeSelector
  value:
    kubernetes.io/hostname: ${GATEWAY_STACK_CLIENT_NODE}
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
      value: ${GATEWAY_STACK_CLIENT_NETWORK_SERVICES}
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
      value: ${GATEWAY_STACK_CLIENT_NETWORK_SERVICES}
    - name: NSM_NAME
      value: "\$(POD_NAME)-\$(POD_UID)"
EOF
}

gateway_stack_render() {
    rm -rf "${GATEWAY_STACK_GENERATED_DIR}"
    mkdir -p "${GATEWAY_STACK_PATCH_DIR}"

    gateway_stack_write_kustomization
    gateway_stack_write_namespace_patch
    gateway_stack_write_networkservice_patch
    gateway_stack_write_rules_patch
    gateway_stack_write_gateway_patch
    gateway_stack_write_server_patch
    gateway_stack_write_client_patch
    gateway_stack_write_resolved_values
}

gateway_stack_apply_runtime_context() {
    GATEWAY_RUNTIME_ROOT="${GATEWAY_STACK_GENERATED_DIR}"
    GATEWAY_K8S_DIR="${GATEWAY_STACK_GENERATED_DIR}"
    GATEWAY_VERIFY_SCRIPT="${GATEWAY_VERIFY_ASSET_SCRIPT}"
    GATEWAY_NAMESPACE="${GATEWAY_STACK_NAMESPACE}"
    GATEWAY_NETWORK_SERVICE_NAME="${GATEWAY_STACK_NETWORK_SERVICE_NAME}"
    GATEWAY_DEPLOYMENT_NAME="${GATEWAY_STACK_MIDDLE_DEPLOYMENT_NAME}"
    GATEWAY_SERVER_DEPLOYMENT_NAME="${GATEWAY_STACK_SERVER_DEPLOYMENT_NAME}"
    GATEWAY_CLIENT_DEPLOYMENT_NAME="${GATEWAY_STACK_CLIENT_DEPLOYMENT_NAME}"
    GATEWAY_SERVICE_NAME="${GATEWAY_STACK_NETWORK_SERVICE_NAME}"
    GATEWAY_SERVER_CIDR_PREFIX="${GATEWAY_STACK_SERVICE_CIDR}"
    GATEWAY_SERVER_IPV4="${GATEWAY_STACK_SERVER_IPV4}"
    GATEWAY_MIDDLE_POD_SELECTOR="${GATEWAY_STACK_MIDDLE_POD_SELECTOR}"
    GATEWAY_SERVER_POD_SELECTOR="${GATEWAY_STACK_SERVER_POD_SELECTOR}"
    GATEWAY_CLIENT_POD_SELECTOR="${GATEWAY_STACK_CLIENT_POD_SELECTOR}"
}

gateway_stack_prepare_rendered_runtime() {
    gateway_init_runtime_context
    gateway_require_runtime_assets
    gateway_stack_prepare_plan
    gateway_stack_render
    gateway_stack_apply_runtime_context
}

gateway_stack_prepare_existing_rendered_runtime() {
    gateway_init_runtime_context
    gateway_require_runtime_assets
    gateway_stack_require_existing_state
    gateway_stack_prepare_plan
    gateway_stack_render
    gateway_stack_apply_runtime_context
}

gateway_stack_print_plan() {
    printf 'stack_id: %s [source=cli]\n' "${GATEWAY_STACK_ID}"
    printf 'state file: %s\n' "${GATEWAY_STACK_STATE_FILE}"
    printf 'generated dir: %s\n' "${GATEWAY_STACK_GENERATED_DIR}"
    printf 'namespace: %s [source=%s origin=%s]\n' "${GATEWAY_STACK_NAMESPACE}" "${GATEWAY_STACK_NAMESPACE_SOURCE}" "${GATEWAY_STACK_NAMESPACE_ORIGIN_SOURCE}"
    printf 'network_service_name: %s [source=%s origin=%s]\n' "${GATEWAY_STACK_NETWORK_SERVICE_NAME}" "${GATEWAY_STACK_NETWORK_SERVICE_NAME_SOURCE}" "${GATEWAY_STACK_NETWORK_SERVICE_NAME_ORIGIN_SOURCE}"
    printf 'service_cidr: %s [source=%s origin=%s]\n' "${GATEWAY_STACK_SERVICE_CIDR}" "${GATEWAY_STACK_SERVICE_CIDR_SOURCE}" "${GATEWAY_STACK_SERVICE_CIDR_ORIGIN_SOURCE}"
    printf 'stack_label: %s [source=derived]\n' "${GATEWAY_STACK_LABEL}"
    printf 'role_label.client: %s=%s [source=derived]\n' "${GATEWAY_ROLE_LABEL_KEY}" "${GATEWAY_ROLE_CLIENT}"
    printf 'role_label.middle: %s=%s [source=derived]\n' "${GATEWAY_ROLE_LABEL_KEY}" "${GATEWAY_ROLE_MIDDLE}"
    printf 'role_label.server: %s=%s [source=derived]\n' "${GATEWAY_ROLE_LABEL_KEY}" "${GATEWAY_ROLE_SERVER}"
    printf 'gateway deployment: %s [source=derived]\n' "${GATEWAY_STACK_MIDDLE_DEPLOYMENT_NAME}"
    printf 'server deployment: %s [source=derived]\n' "${GATEWAY_STACK_SERVER_DEPLOYMENT_NAME}"
    printf 'client deployment: %s [source=derived]\n' "${GATEWAY_STACK_CLIENT_DEPLOYMENT_NAME}"
    printf 'rules configmap: %s [source=derived]\n' "${GATEWAY_STACK_RULES_CONFIGMAP_NAME}"
    printf 'vnf_node: %s [source=%s origin=%s]\n' "${GATEWAY_STACK_VNF_NODE}" "${GATEWAY_STACK_VNF_NODE_SOURCE}" "${GATEWAY_STACK_VNF_NODE_ORIGIN_SOURCE}"
    printf 'client_node: %s [source=%s origin=%s]\n' "${GATEWAY_STACK_CLIENT_NODE}" "${GATEWAY_STACK_CLIENT_NODE_SOURCE}" "${GATEWAY_STACK_CLIENT_NODE_ORIGIN_SOURCE}"
    printf 'server_node: %s [source=%s origin=%s]\n' "${GATEWAY_STACK_SERVER_NODE}" "${GATEWAY_STACK_SERVER_NODE_SOURCE}" "${GATEWAY_STACK_SERVER_NODE_ORIGIN_SOURCE}"
    printf 'gateway env.NSM_SERVICE_NAME: %s [source=derived]\n' "${GATEWAY_STACK_NETWORK_SERVICE_NAME}"
    printf 'gateway env.NSM_LABELS: %s [source=derived]\n' "${GATEWAY_STACK_MIDDLE_NSM_LABELS}"
    printf 'server env.NSM_SERVICE_NAMES: %s [source=derived]\n' "${GATEWAY_STACK_NETWORK_SERVICE_NAME}"
    printf 'server env.NSM_CIDR_PREFIX: %s [source=derived]\n' "${GATEWAY_STACK_SERVICE_CIDR}"
    printf 'rules.yaml cidr: %s [source=derived]\n' "${GATEWAY_STACK_SERVICE_CIDR}"
    printf 'client env.NSM_NETWORK_SERVICES: %s [source=derived]\n' "${GATEWAY_STACK_CLIENT_NETWORK_SERVICES}"
    printf 'cidr pool: %s [source=%s]\n' "${GATEWAY_STACK_CIDR_POOL}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_POOL]}"
    printf 'cidr prefix len: %s [source=%s]\n' "${GATEWAY_STACK_CIDR_PREFIX_LEN}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_PREFIX_LEN]}"
}
