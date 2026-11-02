#!/usr/bin/env bash

if [[ -n "${NSM_OVS_PATHS_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_PATHS_SH_LOADED=1

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT_FROM_LIB="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"

declare -gA PLATFORM_DEFAULTS_CONFIG=()
declare -gA PLATFORM_PATHS_CONFIG=()
declare -gA PLATFORM_CLUSTER_PROFILE_CONFIG=()
declare -gA PLATFORM_CLUSTER_LOCAL_CONFIG=()
declare -gA PLATFORM_CLI_OVERRIDES=()
declare -gA PLATFORM_VALUE_SOURCE=()
declare -ga PLATFORM_EXTRA_ARGS=()

platform_trim() {
    local value=${1-}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

platform_unquote() {
    local value=${1-}
    if [[ ${#value} -ge 2 ]]; then
        if [[ ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
            value=${value:1:${#value}-2}
        elif [[ ${value:0:1} == "'" && ${value: -1} == "'" ]]; then
            value=${value:1:${#value}-2}
        fi
    fi
    printf '%s' "${value}"
}

platform_load_env_file() {
    local file_path=$1
    local map_name=$2
    local -n map_ref="${map_name}"
    local raw_line line key value

    map_ref=()

    [[ -f "${file_path}" ]] || return 0

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        line="$(platform_trim "${raw_line}")"
        [[ -z "${line}" ]] && continue
        [[ ${line:0:1} == "#" ]] && continue

        if [[ "${line}" != *=* ]]; then
            log_warn "skipping invalid config line in ${file_path}: ${raw_line}"
            continue
        fi

        key="$(platform_trim "${line%%=*}")"
        value="$(platform_trim "${line#*=}")"
        value="$(platform_unquote "${value}")"

        [[ -n "${key}" ]] || continue
        [[ -n "${value}" ]] || continue

        map_ref["${key}"]="${value}"
    done < "${file_path}"
}

platform_cli_value() {
    local key=$1
    if [[ -n "${PLATFORM_CLI_OVERRIDES[${key}]:-}" ]]; then
        printf '%s' "${PLATFORM_CLI_OVERRIDES[${key}]}"
    fi
}

platform_cluster_profile_path() {
    local profile=$1

    [[ -n "${profile}" ]] || return 1

    if [[ "${profile}" == */* ]]; then
        printf '%s\n' "${profile}"
    elif [[ "${profile}" == *.env ]]; then
        printf '%s/%s\n' "${CLUSTER_CONFIG_ROOT}" "${profile}"
    else
        printf '%s/%s.env\n' "${CLUSTER_CONFIG_ROOT}" "${profile}"
    fi
}

platform_parse_cli_args() {
    PLATFORM_CLI_OVERRIDES=()
    PLATFORM_EXTRA_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nsm-root)
                [[ $# -ge 2 ]] || die "missing value for --nsm-root"
                [[ -n "${2}" ]] || die "empty value is not allowed for --nsm-root"
                PLATFORM_CLI_OVERRIDES[NSM_ROOT]="${2}"
                shift 2
                ;;
            --nsm-root=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --nsm-root"
                PLATFORM_CLI_OVERRIDES[NSM_ROOT]="${1#*=}"
                shift
                ;;
            --cluster-profile)
                [[ $# -ge 2 ]] || die "missing value for --cluster-profile"
                [[ -n "${2}" ]] || die "empty value is not allowed for --cluster-profile"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CLUSTER_PROFILE]="${2}"
                shift 2
                ;;
            --cluster-profile=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --cluster-profile"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CLUSTER_PROFILE]="${1#*=}"
                shift
                ;;
            --kubeconfig)
                [[ $# -ge 2 ]] || die "missing value for --kubeconfig"
                [[ -n "${2}" ]] || die "empty value is not allowed for --kubeconfig"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_KUBECONFIG]="${2}"
                shift 2
                ;;
            --kubeconfig=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --kubeconfig"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_KUBECONFIG]="${1#*=}"
                shift
                ;;
            --context)
                [[ $# -ge 2 ]] || die "missing value for --context"
                [[ -n "${2}" ]] || die "empty value is not allowed for --context"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CONTEXT]="${2}"
                shift 2
                ;;
            --context=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --context"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CONTEXT]="${1#*=}"
                shift
                ;;
            --image-delivery-mode)
                [[ $# -ge 2 ]] || die "missing value for --image-delivery-mode"
                [[ -n "${2}" ]] || die "empty value is not allowed for --image-delivery-mode"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_IMAGE_DELIVERY_MODE]="${2}"
                shift 2
                ;;
            --image-delivery-mode=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --image-delivery-mode"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_IMAGE_DELIVERY_MODE]="${1#*=}"
                shift
                ;;
            --basic-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --basic-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --basic-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_BASIC_REPO_NAME]="${2}"
                shift 2
                ;;
            --basic-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --basic-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_BASIC_REPO_NAME]="${1#*=}"
                shift
                ;;
            --basic-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --basic-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --basic-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_BASIC_REPO_URL]="${2}"
                shift 2
                ;;
            --basic-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --basic-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_BASIC_REPO_URL]="${1#*=}"
                shift
                ;;
            --deployment-k8s-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --deployment-k8s-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --deployment-k8s-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_DEPLOYMENT_K8S_REPO_NAME]="${2}"
                shift 2
                ;;
            --deployment-k8s-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --deployment-k8s-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_DEPLOYMENT_K8S_REPO_NAME]="${1#*=}"
                shift
                ;;
            --deployment-k8s-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --deployment-k8s-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --deployment-k8s-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_DEPLOYMENT_K8S_REPO_URL]="${2}"
                shift 2
                ;;
            --deployment-k8s-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --deployment-k8s-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_DEPLOYMENT_K8S_REPO_URL]="${1#*=}"
                shift
                ;;
            --template-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --template-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --template-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_REPO_NAME]="${2}"
                shift 2
                ;;
            --template-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --template-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_REPO_NAME]="${1#*=}"
                shift
                ;;
            --template-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --template-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --template-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_REPO_URL]="${2}"
                shift 2
                ;;
            --template-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --template-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_REPO_URL]="${1#*=}"
                shift
                ;;
            --firewall-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --firewall-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --firewall-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_FIREWALL_REPO_NAME]="${2}"
                shift 2
                ;;
            --firewall-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --firewall-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_FIREWALL_REPO_NAME]="${1#*=}"
                shift
                ;;
            --firewall-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --firewall-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --firewall-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_FIREWALL_REPO_URL]="${2}"
                shift 2
                ;;
            --firewall-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --firewall-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_FIREWALL_REPO_URL]="${1#*=}"
                shift
                ;;
            --nat-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --nat-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --nat-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_NAT_REPO_NAME]="${2}"
                shift 2
                ;;
            --nat-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --nat-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_NAT_REPO_NAME]="${1#*=}"
                shift
                ;;
            --nat-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --nat-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --nat-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_NAT_REPO_URL]="${2}"
                shift 2
                ;;
            --nat-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --nat-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_NAT_REPO_URL]="${1#*=}"
                shift
                ;;
            --gateway-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --gateway-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --gateway-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_GATEWAY_REPO_NAME]="${2}"
                shift 2
                ;;
            --gateway-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --gateway-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_GATEWAY_REPO_NAME]="${1#*=}"
                shift
                ;;
            --gateway-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --gateway-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --gateway-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_GATEWAY_REPO_URL]="${2}"
                shift 2
                ;;
            --gateway-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --gateway-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_GATEWAY_REPO_URL]="${1#*=}"
                shift
                ;;
            --dpi-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --dpi-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --dpi-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_DPI_REPO_NAME]="${2}"
                shift 2
                ;;
            --dpi-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --dpi-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_DPI_REPO_NAME]="${1#*=}"
                shift
                ;;
            --dpi-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --dpi-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --dpi-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_DPI_REPO_URL]="${2}"
                shift 2
                ;;
            --dpi-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --dpi-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_DPI_REPO_URL]="${1#*=}"
                shift
                ;;
            --lb-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --lb-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --lb-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_LB_REPO_NAME]="${2}"
                shift 2
                ;;
            --lb-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --lb-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_LB_REPO_NAME]="${1#*=}"
                shift
                ;;
            --lb-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --lb-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --lb-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_LB_REPO_URL]="${2}"
                shift 2
                ;;
            --lb-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --lb-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_LB_REPO_URL]="${1#*=}"
                shift
                ;;
            --vpn-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --vpn-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --vpn-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VPN_REPO_NAME]="${2}"
                shift 2
                ;;
            --vpn-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --vpn-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VPN_REPO_NAME]="${1#*=}"
                shift
                ;;
            --vpn-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --vpn-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --vpn-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VPN_REPO_URL]="${2}"
                shift 2
                ;;
            --vpn-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --vpn-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VPN_REPO_URL]="${1#*=}"
                shift
                ;;
            --lb-steering-mode)
                [[ $# -ge 2 ]] || die "missing value for --lb-steering-mode"
                [[ -n "${2}" ]] || die "empty value is not allowed for --lb-steering-mode"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_LB_STEERING_MODE]="${2}"
                shift 2
                ;;
            --lb-steering-mode=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --lb-steering-mode"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_LB_STEERING_MODE]="${1#*=}"
                shift
                ;;
            --nat-steering-mode)
                [[ $# -ge 2 ]] || die "missing value for --nat-steering-mode"
                [[ -n "${2}" ]] || die "empty value is not allowed for --nat-steering-mode"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_NAT_STEERING_MODE]="${2}"
                shift 2
                ;;
            --nat-steering-mode=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --nat-steering-mode"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_NAT_STEERING_MODE]="${1#*=}"
                shift
                ;;
            --vpn-xnode-mode)
                [[ $# -ge 2 ]] || die "missing value for --vpn-xnode-mode"
                [[ -n "${2}" ]] || die "empty value is not allowed for --vpn-xnode-mode"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VPN_XNODE_MODE]="${2}"
                shift 2
                ;;
            --vpn-xnode-mode=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --vpn-xnode-mode"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VPN_XNODE_MODE]="${1#*=}"
                shift
                ;;
            --pcm-deployment-mode)
                [[ $# -ge 2 ]] || die "missing value for --pcm-deployment-mode"
                [[ -n "${2}" ]] || die "empty value is not allowed for --pcm-deployment-mode"
                PLATFORM_CLI_OVERRIDES[PCM_DEPLOYMENT_MODE]="${2}"
                shift 2
                ;;
            --pcm-deployment-mode=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --pcm-deployment-mode"
                PLATFORM_CLI_OVERRIDES[PCM_DEPLOYMENT_MODE]="${1#*=}"
                shift
                ;;
            --client-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --client-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --client-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CLIENT_REPO_NAME]="${2}"
                shift 2
                ;;
            --client-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --client-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CLIENT_REPO_NAME]="${1#*=}"
                shift
                ;;
            --client-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --client-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --client-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CLIENT_REPO_URL]="${2}"
                shift 2
                ;;
            --client-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --client-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CLIENT_REPO_URL]="${1#*=}"
                shift
                ;;
            --server-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --server-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --server-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_SERVER_REPO_NAME]="${2}"
                shift 2
                ;;
            --server-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --server-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_SERVER_REPO_NAME]="${1#*=}"
                shift
                ;;
            --server-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --server-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --server-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_SERVER_REPO_URL]="${2}"
                shift 2
                ;;
            --server-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --server-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_SERVER_REPO_URL]="${1#*=}"
                shift
                ;;
            --categraf-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --categraf-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --categraf-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CATEGRAF_REPO_NAME]="${2}"
                shift 2
                ;;
            --categraf-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --categraf-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CATEGRAF_REPO_NAME]="${1#*=}"
                shift
                ;;
            --categraf-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --categraf-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --categraf-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CATEGRAF_REPO_URL]="${2}"
                shift 2
                ;;
            --categraf-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --categraf-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_CATEGRAF_REPO_URL]="${1#*=}"
                shift
                ;;
            --vm-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --vm-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --vm-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VICTORIAMETRICS_REPO_NAME]="${2}"
                shift 2
                ;;
            --vm-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --vm-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VICTORIAMETRICS_REPO_NAME]="${1#*=}"
                shift
                ;;
            --vm-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --vm-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --vm-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VICTORIAMETRICS_REPO_URL]="${2}"
                shift 2
                ;;
            --vm-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --vm-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_VICTORIAMETRICS_REPO_URL]="${1#*=}"
                shift
                ;;
            --n9e-repo-name)
                [[ $# -ge 2 ]] || die "missing value for --n9e-repo-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --n9e-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_N9E_REPO_NAME]="${2}"
                shift 2
                ;;
            --n9e-repo-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --n9e-repo-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_N9E_REPO_NAME]="${1#*=}"
                shift
                ;;
            --n9e-repo-url)
                [[ $# -ge 2 ]] || die "missing value for --n9e-repo-url"
                [[ -n "${2}" ]] || die "empty value is not allowed for --n9e-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_N9E_REPO_URL]="${2}"
                shift 2
                ;;
            --n9e-repo-url=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --n9e-repo-url"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_N9E_REPO_URL]="${1#*=}"
                shift
                ;;
            --stack-id)
                [[ $# -ge 2 ]] || die "missing value for --stack-id"
                [[ -n "${2}" ]] || die "empty value is not allowed for --stack-id"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_STACK_ID]="${2}"
                shift 2
                ;;
            --stack-id=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --stack-id"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_STACK_ID]="${1#*=}"
                shift
                ;;
            --namespace)
                [[ $# -ge 2 ]] || die "missing value for --namespace"
                [[ -n "${2}" ]] || die "empty value is not allowed for --namespace"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_NAMESPACE_OVERRIDE]="${2}"
                shift 2
                ;;
            --namespace=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --namespace"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_NAMESPACE_OVERRIDE]="${1#*=}"
                shift
                ;;
            --network-service-name)
                [[ $# -ge 2 ]] || die "missing value for --network-service-name"
                [[ -n "${2}" ]] || die "empty value is not allowed for --network-service-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE]="${2}"
                shift 2
                ;;
            --network-service-name=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --network-service-name"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE]="${1#*=}"
                shift
                ;;
            --cidr-prefix)
                [[ $# -ge 2 ]] || die "missing value for --cidr-prefix"
                [[ -n "${2}" ]] || die "empty value is not allowed for --cidr-prefix"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_CIDR_PREFIX_OVERRIDE]="${2}"
                shift 2
                ;;
            --cidr-prefix=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --cidr-prefix"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_CIDR_PREFIX_OVERRIDE]="${1#*=}"
                shift
                ;;
            --vnf-node)
                [[ $# -ge 2 ]] || die "missing value for --vnf-node"
                [[ -n "${2}" ]] || die "empty value is not allowed for --vnf-node"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_VNF_NODE]="${2}"
                shift 2
                ;;
            --vnf-node=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --vnf-node"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_VNF_NODE]="${1#*=}"
                shift
                ;;
            --client-node)
                [[ $# -ge 2 ]] || die "missing value for --client-node"
                [[ -n "${2}" ]] || die "empty value is not allowed for --client-node"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_CLIENT_NODE]="${2}"
                shift 2
                ;;
            --client-node=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --client-node"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_CLIENT_NODE]="${1#*=}"
                shift
                ;;
            --server-node)
                [[ $# -ge 2 ]] || die "missing value for --server-node"
                [[ -n "${2}" ]] || die "empty value is not allowed for --server-node"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_SERVER_NODE]="${2}"
                shift 2
                ;;
            --server-node=*)
                [[ -n "${1#*=}" ]] || die "empty value is not allowed for --server-node"
                PLATFORM_CLI_OVERRIDES[NSM_OVS_TEMPLATE_SERVER_NODE]="${1#*=}"
                shift
                ;;
            *)
                PLATFORM_EXTRA_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

platform_set_value() {
    local name=$1
    local value=$2
    local source=$3

    printf -v "${name}" '%s' "${value}"
    export "${name}"
    PLATFORM_VALUE_SOURCE["${name}"]="${source}"
}

platform_resolve_value() {
    local target_name=$1
    local config_key=$2
    local default_value=$3
    local default_source=$4
    local resolved_value resolved_source

    if [[ -n "$(platform_cli_value "${config_key}")" ]]; then
        resolved_value="$(platform_cli_value "${config_key}")"
        resolved_source='cli'
    elif [[ -n "${!config_key:-}" ]]; then
        resolved_value="${!config_key}"
        resolved_source="env:${config_key}"
    elif [[ -n "${PLATFORM_PATHS_CONFIG[${config_key}]:-}" ]]; then
        resolved_value="${PLATFORM_PATHS_CONFIG[${config_key}]}"
        resolved_source='config:paths.env'
    elif [[ -n "${PLATFORM_CLUSTER_LOCAL_CONFIG[${config_key}]:-}" ]]; then
        resolved_value="${PLATFORM_CLUSTER_LOCAL_CONFIG[${config_key}]}"
        resolved_source='config:cluster.env'
    elif [[ -n "${PLATFORM_CLUSTER_PROFILE_CONFIG[${config_key}]:-}" ]]; then
        resolved_value="${PLATFORM_CLUSTER_PROFILE_CONFIG[${config_key}]}"
        resolved_source="config:cluster-profile:${CLUSTER_PROFILE}"
    elif [[ -n "${PLATFORM_DEFAULTS_CONFIG[${config_key}]:-}" ]]; then
        resolved_value="${PLATFORM_DEFAULTS_CONFIG[${config_key}]}"
        resolved_source='config:defaults.env'
    else
        resolved_value="${default_value}"
        resolved_source="${default_source}"
    fi

    [[ -n "${resolved_value}" ]] || die "resolved value is empty for ${target_name}"
    platform_set_value "${target_name}" "${resolved_value}" "${resolved_source}"
}

platform_require_no_extra_args() {
    if [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; then
        die "unknown arguments: ${PLATFORM_EXTRA_ARGS[*]}"
    fi
}

platform_resolve_optional_input() {
    local target_name=$1
    local config_key=$2
    local resolved_value=""
    local resolved_source="unset"

    if [[ -n "$(platform_cli_value "${config_key}")" ]]; then
        resolved_value="$(platform_cli_value "${config_key}")"
        resolved_source='cli'
    elif [[ -n "${!config_key:-}" ]]; then
        resolved_value="${!config_key}"
        resolved_source="env:${config_key}"
    fi

    platform_set_value "${target_name}" "${resolved_value}" "${resolved_source}"
}

platform_resolve_optional_value() {
    local target_name=$1
    local config_key=$2
    local resolved_value=""
    local resolved_source="unset"

    if [[ -n "$(platform_cli_value "${config_key}")" ]]; then
        resolved_value="$(platform_cli_value "${config_key}")"
        resolved_source='cli'
    elif [[ -n "${!config_key:-}" ]]; then
        resolved_value="${!config_key}"
        resolved_source="env:${config_key}"
    elif [[ -n "${PLATFORM_PATHS_CONFIG[${config_key}]:-}" ]]; then
        resolved_value="${PLATFORM_PATHS_CONFIG[${config_key}]}"
        resolved_source='config:paths.env'
    elif [[ -n "${PLATFORM_CLUSTER_LOCAL_CONFIG[${config_key}]:-}" ]]; then
        resolved_value="${PLATFORM_CLUSTER_LOCAL_CONFIG[${config_key}]}"
        resolved_source='config:cluster.env'
    elif [[ -n "${PLATFORM_CLUSTER_PROFILE_CONFIG[${config_key}]:-}" ]]; then
        resolved_value="${PLATFORM_CLUSTER_PROFILE_CONFIG[${config_key}]}"
        resolved_source="config:cluster-profile:${CLUSTER_PROFILE}"
    elif [[ -n "${PLATFORM_DEFAULTS_CONFIG[${config_key}]:-}" ]]; then
        resolved_value="${PLATFORM_DEFAULTS_CONFIG[${config_key}]}"
        resolved_source='config:defaults.env'
    fi

    platform_set_value "${target_name}" "${resolved_value}" "${resolved_source}"
}

platform_validate_image_delivery_mode() {
    local mode=$1

    case "${mode}" in
        registry-pull|preload-import)
            ;;
        *)
            die "unsupported image delivery mode: ${mode} (expected registry-pull or preload-import)"
            ;;
    esac
}

platform_validate_lb_steering_mode() {
    local mode=$1

    case "${mode}" in
        auto|legacy-inject)
            ;;
        *)
            die "unsupported lb steering mode: ${mode} (expected auto or legacy-inject)"
            ;;
    esac
}

platform_validate_nat_steering_mode() {
    local mode=$1

    case "${mode}" in
        auto|legacy-inject)
            ;;
        *)
            die "unsupported nat steering mode: ${mode} (expected auto or legacy-inject)"
            ;;
    esac
}

platform_validate_vpn_xnode_mode() {
    local mode=$1

    case "${mode}" in
        disabled|exploratory)
            ;;
        *)
            die "unsupported vpn xnode mode: ${mode} (expected disabled or exploratory)"
            ;;
    esac
}

platform_validate_pcm_deployment_mode() {
    local mode=$1

    case "${mode}" in
        in-cluster|host-transition)
            ;;
        *)
            die "unsupported PCM deployment mode: ${mode} (expected in-cluster or host-transition)"
            ;;
    esac
}

platform_init() {
    local defaults_file paths_file cluster_local_file default_nsm_root cluster_profile_file
    local registry_pull_enabled=false
    local preload_import_enabled=false

    platform_parse_cli_args "$@"

    platform_set_value "PLATFORM_REPO_ROOT" "${PLATFORM_ROOT_FROM_LIB}" "derived:script-location"
    platform_set_value "CLUSTER_CONFIG_ROOT" "${PLATFORM_REPO_ROOT}/config/clusters" "derived:platform-root/config/clusters"
    platform_set_value "CLUSTER_LOCAL_CONFIG_FILE" "${PLATFORM_REPO_ROOT}/config/cluster.env" "derived:platform-root/config/cluster.env"
    platform_set_value "PLATFORM_KUBECTL_WRAPPER" "${PLATFORM_REPO_ROOT}/scripts/bin/platform-kubectl" "derived:platform-root/scripts/bin/platform-kubectl"
    platform_set_value "ASSETS_ROOT" "${PLATFORM_REPO_ROOT}/assets" "derived:platform-root/assets"
    platform_set_value "ARTIFACTS_ROOT" "${PLATFORM_REPO_ROOT}/artifacts" "derived:platform-root/artifacts"
    platform_set_value "BASELINE_ARTIFACTS_ROOT" "${ARTIFACTS_ROOT}/baseline" "derived:ARTIFACTS_ROOT/baseline"
    platform_set_value "PAIRWISE_ARTIFACTS_ROOT" "${ARTIFACTS_ROOT}/pairwise" "derived:ARTIFACTS_ROOT/pairwise"
    platform_set_value "BASELINE_COMPARE_ARTIFACTS_ROOT" "${BASELINE_ARTIFACTS_ROOT}/compare" "derived:BASELINE_ARTIFACTS_ROOT/compare"
    platform_set_value "VALIDATION_ARTIFACTS_ROOT" "${ARTIFACTS_ROOT}/validation" "derived:ARTIFACTS_ROOT/validation"
    platform_set_value "MULTI_STACK_VALIDATION_ROOT" "${VALIDATION_ARTIFACTS_ROOT}/multi-stack" "derived:VALIDATION_ARTIFACTS_ROOT/multi-stack"
    platform_set_value "CONCURRENT_BASELINE_VALIDATION_ROOT" "${VALIDATION_ARTIFACTS_ROOT}/concurrent-baseline" "derived:VALIDATION_ARTIFACTS_ROOT/concurrent-baseline"
    platform_set_value "FIXED_LOAD_COMPARE_VALIDATION_ROOT" "${VALIDATION_ARTIFACTS_ROOT}/fixed-load-compare" "derived:VALIDATION_ARTIFACTS_ROOT/fixed-load-compare"
    platform_set_value "STATE_ROOT" "${PLATFORM_REPO_ROOT}/state" "derived:platform-root/state"
    platform_set_value "STACK_STATE_ROOT" "${STATE_ROOT}/stacks" "derived:STATE_ROOT/stacks"
    platform_set_value "TEMPLATE_STACK_STATE_ROOT" "${STACK_STATE_ROOT}" "derived:STACK_STATE_ROOT"
    platform_set_value "GENERATED_ROOT" "${PLATFORM_REPO_ROOT}/generated" "derived:platform-root/generated"
    platform_set_value "TEMPLATE_GENERATED_ROOT" "${GENERATED_ROOT}/template" "derived:GENERATED_ROOT/template"
    platform_set_value "FIREWALL_STACK_STATE_ROOT" "${STACK_STATE_ROOT}" "derived:STACK_STATE_ROOT"
    platform_set_value "FIREWALL_GENERATED_ROOT" "${GENERATED_ROOT}/firewall" "derived:GENERATED_ROOT/firewall"
    platform_set_value "NAT_STACK_STATE_ROOT" "${STACK_STATE_ROOT}" "derived:STACK_STATE_ROOT"
    platform_set_value "NAT_GENERATED_ROOT" "${GENERATED_ROOT}/nat" "derived:GENERATED_ROOT/nat"
    platform_set_value "GATEWAY_STACK_STATE_ROOT" "${STACK_STATE_ROOT}" "derived:STACK_STATE_ROOT"
    platform_set_value "GATEWAY_GENERATED_ROOT" "${GENERATED_ROOT}/gateway" "derived:GENERATED_ROOT/gateway"
    platform_set_value "DPI_STACK_STATE_ROOT" "${STACK_STATE_ROOT}" "derived:STACK_STATE_ROOT"
    platform_set_value "DPI_GENERATED_ROOT" "${GENERATED_ROOT}/dpi" "derived:GENERATED_ROOT/dpi"
    platform_set_value "LB_STACK_STATE_ROOT" "${STACK_STATE_ROOT}" "derived:STACK_STATE_ROOT"
    platform_set_value "LB_GENERATED_ROOT" "${GENERATED_ROOT}/lb" "derived:GENERATED_ROOT/lb"
    platform_set_value "VPN_STACK_STATE_ROOT" "${STACK_STATE_ROOT}" "derived:STACK_STATE_ROOT"
    platform_set_value "VPN_GENERATED_ROOT" "${GENERATED_ROOT}/vpn" "derived:GENERATED_ROOT/vpn"
    platform_set_value "ARTIFACTS_ROOT" "${PLATFORM_REPO_ROOT}/artifacts" "derived:platform-root/artifacts"
    platform_set_value "BASELINE_ARTIFACTS_ROOT" "${ARTIFACTS_ROOT}/baseline" "derived:ARTIFACTS_ROOT/baseline"
    platform_set_value "PAIRWISE_ARTIFACTS_ROOT" "${ARTIFACTS_ROOT}/pairwise" "derived:ARTIFACTS_ROOT/pairwise"
    platform_set_value "BASIC_ASSETS_ROOT" "${ASSETS_ROOT}/basic" "derived:ASSETS_ROOT/basic"
    platform_set_value "BASIC_ASSETS_MANIFESTS_DIR" "${BASIC_ASSETS_ROOT}/manifests" "derived:BASIC_ASSETS_ROOT/manifests"
    platform_set_value "BASIC_ASSETS_WRAPPERS_DIR" "${BASIC_ASSETS_ROOT}/wrappers" "derived:BASIC_ASSETS_ROOT/wrappers"
    platform_set_value "BASIC_DEPLOY_WRAPPER" "${BASIC_ASSETS_WRAPPERS_DIR}/deploy.sh" "derived:BASIC_ASSETS_WRAPPERS_DIR/deploy.sh"
    platform_set_value "BASIC_STATUS_WRAPPER" "${BASIC_ASSETS_WRAPPERS_DIR}/status.sh" "derived:BASIC_ASSETS_WRAPPERS_DIR/status.sh"
    platform_set_value "BASIC_CLEANUP_WRAPPER" "${BASIC_ASSETS_WRAPPERS_DIR}/cleanup.sh" "derived:BASIC_ASSETS_WRAPPERS_DIR/cleanup.sh"
    platform_set_value "TEMPLATE_ASSETS_ROOT" "${ASSETS_ROOT}/template" "derived:ASSETS_ROOT/template"
    platform_set_value "TEMPLATE_K8S_ASSETS_DIR" "${TEMPLATE_ASSETS_ROOT}/k8s" "derived:TEMPLATE_ASSETS_ROOT/k8s"
    platform_set_value "TEMPLATE_VERIFY_ASSETS_DIR" "${TEMPLATE_ASSETS_ROOT}/verify" "derived:TEMPLATE_ASSETS_ROOT/verify"
    platform_set_value "TEMPLATE_VERIFY_ASSET_SCRIPT" "${TEMPLATE_VERIFY_ASSETS_DIR}/verify_same_node_chain.sh" "derived:TEMPLATE_VERIFY_ASSETS_DIR/verify_same_node_chain.sh"
    platform_set_value "FIREWALL_ASSETS_ROOT" "${ASSETS_ROOT}/firewall" "derived:ASSETS_ROOT/firewall"
    platform_set_value "FIREWALL_K8S_ASSETS_DIR" "${FIREWALL_ASSETS_ROOT}/k8s" "derived:FIREWALL_ASSETS_ROOT/k8s"
    platform_set_value "FIREWALL_VERIFY_ASSETS_DIR" "${FIREWALL_ASSETS_ROOT}/verify" "derived:FIREWALL_ASSETS_ROOT/verify"
    platform_set_value "FIREWALL_VERIFY_ASSET_SCRIPT" "${FIREWALL_VERIFY_ASSETS_DIR}/verify_same_node_chain.sh" "derived:FIREWALL_VERIFY_ASSETS_DIR/verify_same_node_chain.sh"
    platform_set_value "NAT_ASSETS_ROOT" "${ASSETS_ROOT}/nat" "derived:ASSETS_ROOT/nat"
    platform_set_value "NAT_K8S_ASSETS_DIR" "${NAT_ASSETS_ROOT}/k8s" "derived:NAT_ASSETS_ROOT/k8s"
    platform_set_value "NAT_VERIFY_ASSETS_DIR" "${NAT_ASSETS_ROOT}/verify" "derived:NAT_ASSETS_ROOT/verify"
    platform_set_value "NAT_VERIFY_ASSET_SCRIPT" "${NAT_VERIFY_ASSETS_DIR}/verify_same_node_chain.sh" "derived:NAT_VERIFY_ASSETS_DIR/verify_same_node_chain.sh"
    platform_set_value "GATEWAY_ASSETS_ROOT" "${ASSETS_ROOT}/gateway" "derived:ASSETS_ROOT/gateway"
    platform_set_value "GATEWAY_K8S_ASSETS_DIR" "${GATEWAY_ASSETS_ROOT}/k8s" "derived:GATEWAY_ASSETS_ROOT/k8s"
    platform_set_value "GATEWAY_VERIFY_ASSETS_DIR" "${GATEWAY_ASSETS_ROOT}/verify" "derived:GATEWAY_ASSETS_ROOT/verify"
    platform_set_value "GATEWAY_VERIFY_ASSET_SCRIPT" "${GATEWAY_VERIFY_ASSETS_DIR}/verify_same_node_chain.sh" "derived:GATEWAY_VERIFY_ASSETS_DIR/verify_same_node_chain.sh"
    platform_set_value "DPI_ASSETS_ROOT" "${ASSETS_ROOT}/dpi" "derived:ASSETS_ROOT/dpi"
    platform_set_value "DPI_K8S_ASSETS_DIR" "${DPI_ASSETS_ROOT}/k8s" "derived:DPI_ASSETS_ROOT/k8s"
    platform_set_value "DPI_VERIFY_ASSETS_DIR" "${DPI_ASSETS_ROOT}/verify" "derived:DPI_ASSETS_ROOT/verify"
    platform_set_value "DPI_VERIFY_ASSET_SCRIPT" "${DPI_VERIFY_ASSETS_DIR}/verify_same_node_chain.sh" "derived:DPI_VERIFY_ASSETS_DIR/verify_same_node_chain.sh"
    platform_set_value "LB_ASSETS_ROOT" "${ASSETS_ROOT}/lb" "derived:ASSETS_ROOT/lb"
    platform_set_value "LB_K8S_ASSETS_DIR" "${LB_ASSETS_ROOT}/k8s" "derived:LB_ASSETS_ROOT/k8s"
    platform_set_value "LB_VERIFY_ASSETS_DIR" "${LB_ASSETS_ROOT}/verify" "derived:LB_ASSETS_ROOT/verify"
    platform_set_value "LB_VERIFY_ASSET_SCRIPT" "${LB_VERIFY_ASSETS_DIR}/verify_same_node_chain.sh" "derived:LB_VERIFY_ASSETS_DIR/verify_same_node_chain.sh"
    platform_set_value "VPN_ASSETS_ROOT" "${ASSETS_ROOT}/vpn" "derived:ASSETS_ROOT/vpn"
    platform_set_value "VPN_K8S_ASSETS_DIR" "${VPN_ASSETS_ROOT}/k8s" "derived:VPN_ASSETS_ROOT/k8s"
    platform_set_value "VPN_VERIFY_ASSETS_DIR" "${VPN_ASSETS_ROOT}/verify" "derived:VPN_ASSETS_ROOT/verify"
    platform_set_value "VPN_VERIFY_ASSET_SCRIPT" "${VPN_VERIFY_ASSETS_DIR}/verify_same_node_chain.sh" "derived:VPN_VERIFY_ASSETS_DIR/verify_same_node_chain.sh"
    platform_set_value "VPN_CLEANUP_ASSET_SCRIPT" "${VPN_VERIFY_ASSETS_DIR}/check_vpn_cleanup.sh" "derived:VPN_VERIFY_ASSETS_DIR/check_vpn_cleanup.sh"
    platform_set_value "MEASUREMENT_ASSETS_ROOT" "${ASSETS_ROOT}/measurement" "derived:ASSETS_ROOT/measurement"
    platform_set_value "SYSTEM_MEASUREMENT_ASSETS_ROOT" "${MEASUREMENT_ASSETS_ROOT}/system" "derived:MEASUREMENT_ASSETS_ROOT/system"
    platform_set_value "STORAGE_MEASUREMENT_ASSETS_ROOT" "${MEASUREMENT_ASSETS_ROOT}/storage" "derived:MEASUREMENT_ASSETS_ROOT/storage"
    platform_set_value "CONTROL_MEASUREMENT_ASSETS_ROOT" "${MEASUREMENT_ASSETS_ROOT}/control" "derived:MEASUREMENT_ASSETS_ROOT/control"
    platform_set_value "CATEGRAF_ASSETS_ROOT" "${SYSTEM_MEASUREMENT_ASSETS_ROOT}/categraf" "derived:SYSTEM_MEASUREMENT_ASSETS_ROOT/categraf"
    platform_set_value "CATEGRAF_CONFIGS_ROOT" "${CATEGRAF_ASSETS_ROOT}/configs" "derived:CATEGRAF_ASSETS_ROOT/configs"
    platform_set_value "CATEGRAF_CONFIGS_BASE_DIR" "${CATEGRAF_CONFIGS_ROOT}/base" "derived:CATEGRAF_CONFIGS_ROOT/base"
    platform_set_value "CATEGRAF_MANIFESTS_ROOT" "${CATEGRAF_ASSETS_ROOT}/manifests" "derived:CATEGRAF_ASSETS_ROOT/manifests"
    platform_set_value "CATEGRAF_MANIFESTS_BASE_DIR" "${CATEGRAF_MANIFESTS_ROOT}/base" "derived:CATEGRAF_MANIFESTS_ROOT/base"
    platform_set_value "CATEGRAF_SCRIPTS_DIR" "${CATEGRAF_ASSETS_ROOT}/scripts" "derived:CATEGRAF_ASSETS_ROOT/scripts"
    platform_set_value "CATEGRAF_SCRIPTS_LIB_DIR" "${CATEGRAF_SCRIPTS_DIR}/lib" "derived:CATEGRAF_SCRIPTS_DIR/lib"
    platform_set_value "CATEGRAF_DEPLOY_SCRIPT" "${CATEGRAF_SCRIPTS_DIR}/deploy.sh" "derived:CATEGRAF_SCRIPTS_DIR/deploy.sh"
    platform_set_value "CATEGRAF_CHECK_SCRIPT" "${CATEGRAF_SCRIPTS_DIR}/check.sh" "derived:CATEGRAF_SCRIPTS_DIR/check.sh"
    platform_set_value "CATEGRAF_CLEANUP_SCRIPT" "${CATEGRAF_SCRIPTS_DIR}/cleanup.sh" "derived:CATEGRAF_SCRIPTS_DIR/cleanup.sh"
    platform_set_value "CATEGRAF_COMMON_LIB_SCRIPT" "${CATEGRAF_SCRIPTS_LIB_DIR}/common.sh" "derived:CATEGRAF_SCRIPTS_LIB_DIR/common.sh"
    platform_set_value "VICTORIAMETRICS_ASSETS_ROOT" "${STORAGE_MEASUREMENT_ASSETS_ROOT}/victoriametrics" "derived:STORAGE_MEASUREMENT_ASSETS_ROOT/victoriametrics"
    platform_set_value "VICTORIAMETRICS_MANIFESTS_ROOT" "${VICTORIAMETRICS_ASSETS_ROOT}/manifests" "derived:VICTORIAMETRICS_ASSETS_ROOT/manifests"
    platform_set_value "VICTORIAMETRICS_MANIFESTS_BASE_DIR" "${VICTORIAMETRICS_MANIFESTS_ROOT}/base" "derived:VICTORIAMETRICS_MANIFESTS_ROOT/base"
    platform_set_value "VICTORIAMETRICS_SCRIPTS_DIR" "${VICTORIAMETRICS_ASSETS_ROOT}/scripts" "derived:VICTORIAMETRICS_ASSETS_ROOT/scripts"
    platform_set_value "VICTORIAMETRICS_SCRIPTS_LIB_DIR" "${VICTORIAMETRICS_SCRIPTS_DIR}/lib" "derived:VICTORIAMETRICS_SCRIPTS_DIR/lib"
    platform_set_value "VICTORIAMETRICS_DEPLOY_SCRIPT" "${VICTORIAMETRICS_SCRIPTS_DIR}/deploy.sh" "derived:VICTORIAMETRICS_SCRIPTS_DIR/deploy.sh"
    platform_set_value "VICTORIAMETRICS_CHECK_SCRIPT" "${VICTORIAMETRICS_SCRIPTS_DIR}/check.sh" "derived:VICTORIAMETRICS_SCRIPTS_DIR/check.sh"
    platform_set_value "VICTORIAMETRICS_CLEANUP_SCRIPT" "${VICTORIAMETRICS_SCRIPTS_DIR}/cleanup.sh" "derived:VICTORIAMETRICS_SCRIPTS_DIR/cleanup.sh"
    platform_set_value "VICTORIAMETRICS_COMMON_LIB_SCRIPT" "${VICTORIAMETRICS_SCRIPTS_LIB_DIR}/common.sh" "derived:VICTORIAMETRICS_SCRIPTS_LIB_DIR/common.sh"
    platform_set_value "N9E_ASSETS_ROOT" "${CONTROL_MEASUREMENT_ASSETS_ROOT}/n9e" "derived:CONTROL_MEASUREMENT_ASSETS_ROOT/n9e"
    platform_set_value "N9E_CONFIGS_ROOT" "${N9E_ASSETS_ROOT}/configs" "derived:N9E_ASSETS_ROOT/configs"
    platform_set_value "N9E_CONFIGS_BASE_DIR" "${N9E_CONFIGS_ROOT}/base" "derived:N9E_CONFIGS_ROOT/base"
    platform_set_value "N9E_MANIFESTS_ROOT" "${N9E_ASSETS_ROOT}/manifests" "derived:N9E_ASSETS_ROOT/manifests"
    platform_set_value "N9E_MANIFESTS_BASE_DIR" "${N9E_MANIFESTS_ROOT}/base" "derived:N9E_MANIFESTS_ROOT/base"
    platform_set_value "N9E_SCRIPTS_DIR" "${N9E_ASSETS_ROOT}/scripts" "derived:N9E_ASSETS_ROOT/scripts"
    platform_set_value "N9E_SCRIPTS_LIB_DIR" "${N9E_SCRIPTS_DIR}/lib" "derived:N9E_SCRIPTS_DIR/lib"
    platform_set_value "N9E_DEPLOY_SCRIPT" "${N9E_SCRIPTS_DIR}/deploy.sh" "derived:N9E_SCRIPTS_DIR/deploy.sh"
    platform_set_value "N9E_CHECK_SCRIPT" "${N9E_SCRIPTS_DIR}/check.sh" "derived:N9E_SCRIPTS_DIR/check.sh"
    platform_set_value "N9E_CLEANUP_SCRIPT" "${N9E_SCRIPTS_DIR}/cleanup.sh" "derived:N9E_SCRIPTS_DIR/cleanup.sh"
    platform_set_value "N9E_COMMON_LIB_SCRIPT" "${N9E_SCRIPTS_LIB_DIR}/common.sh" "derived:N9E_SCRIPTS_LIB_DIR/common.sh"

    defaults_file="${PLATFORM_REPO_ROOT}/config/defaults.env"
    paths_file="${PLATFORM_REPO_ROOT}/config/paths.env"
    cluster_local_file="${CLUSTER_LOCAL_CONFIG_FILE}"

    platform_load_env_file "${defaults_file}" PLATFORM_DEFAULTS_CONFIG
    platform_load_env_file "${paths_file}" PLATFORM_PATHS_CONFIG
    platform_resolve_value "ARTIFACTS_ROOT" "NSM_OVS_ARTIFACTS_ROOT" "${PLATFORM_REPO_ROOT}/artifacts" "default:platform-root/artifacts"
    platform_resolve_value "BASELINE_ARTIFACTS_ROOT" "NSM_OVS_BASELINE_ARTIFACTS_ROOT" "${ARTIFACTS_ROOT}/baseline" "default:ARTIFACTS_ROOT/baseline"
    platform_resolve_value "PAIRWISE_ARTIFACTS_ROOT" "NSM_OVS_PAIRWISE_ARTIFACTS_ROOT" "${ARTIFACTS_ROOT}/pairwise" "default:ARTIFACTS_ROOT/pairwise"
    platform_resolve_value "BASELINE_COMPARE_ARTIFACTS_ROOT" "NSM_OVS_BASELINE_COMPARE_ARTIFACTS_ROOT" "${BASELINE_ARTIFACTS_ROOT}/compare" "default:BASELINE_ARTIFACTS_ROOT/compare"
    platform_resolve_value "VALIDATION_ARTIFACTS_ROOT" "NSM_OVS_VALIDATION_ARTIFACTS_ROOT" "${ARTIFACTS_ROOT}/validation" "default:ARTIFACTS_ROOT/validation"
    platform_resolve_value "MULTI_STACK_VALIDATION_ROOT" "NSM_OVS_MULTI_STACK_VALIDATION_ROOT" "${VALIDATION_ARTIFACTS_ROOT}/multi-stack" "default:VALIDATION_ARTIFACTS_ROOT/multi-stack"
    platform_resolve_value "CONCURRENT_BASELINE_VALIDATION_ROOT" "NSM_OVS_CONCURRENT_BASELINE_VALIDATION_ROOT" "${VALIDATION_ARTIFACTS_ROOT}/concurrent-baseline" "default:VALIDATION_ARTIFACTS_ROOT/concurrent-baseline"
    platform_resolve_value "FIXED_LOAD_COMPARE_VALIDATION_ROOT" "NSM_OVS_FIXED_LOAD_COMPARE_VALIDATION_ROOT" "${VALIDATION_ARTIFACTS_ROOT}/fixed-load-compare" "default:VALIDATION_ARTIFACTS_ROOT/fixed-load-compare"
    platform_resolve_value "CLUSTER_PROFILE" "NSM_OVS_CLUSTER_PROFILE" "vm-lab" "default:vm-lab"

    cluster_profile_file="$(platform_cluster_profile_path "${CLUSTER_PROFILE}")"
    [[ -f "${cluster_profile_file}" ]] || die "cluster profile file not found: ${cluster_profile_file}"
    platform_set_value "CLUSTER_PROFILE_FILE" "${cluster_profile_file}" "derived:cluster-profile:${CLUSTER_PROFILE}"
    platform_load_env_file "${cluster_profile_file}" PLATFORM_CLUSTER_PROFILE_CONFIG
    platform_load_env_file "${cluster_local_file}" PLATFORM_CLUSTER_LOCAL_CONFIG

    default_nsm_root="$(cd "${PLATFORM_REPO_ROOT}/.." && pwd)"

    platform_resolve_value "KUBECTL_BIN_REAL" "NSM_OVS_KUBECTL_BIN" "kubectl" "default:kubectl"
    platform_resolve_optional_value "KUBECONFIG_PATH" "NSM_OVS_KUBECONFIG"
    platform_resolve_optional_value "KUBECTL_CONTEXT" "NSM_OVS_CONTEXT"
    platform_resolve_value "IMAGE_DELIVERY_MODE" "NSM_OVS_IMAGE_DELIVERY_MODE" "registry-pull" "default:registry-pull"
    platform_validate_image_delivery_mode "${IMAGE_DELIVERY_MODE}"
    platform_resolve_value "NSM_ROOT" "NSM_ROOT" "${default_nsm_root}" "default:parent-dir"
    platform_resolve_value "BASIC_REPO_NAME" "NSM_OVS_BASIC_REPO_NAME" "nsm-ovs-basic" "default:nsm-ovs-basic"
    platform_resolve_value "BASIC_REPO_URL" "NSM_OVS_BASIC_REPO_URL" "git@github.com:NSM-OVS/nsm-ovs-basic.git" "default:git@github.com:NSM-OVS/nsm-ovs-basic.git"
    platform_resolve_value "DEPLOYMENT_K8S_REPO_NAME" "NSM_OVS_DEPLOYMENT_K8S_REPO_NAME" "deployment-k8s" "default:deployment-k8s"
    platform_resolve_value "DEPLOYMENT_K8S_REPO_URL" "NSM_OVS_DEPLOYMENT_K8S_REPO_URL" "git@github.com:NSM-CNF/deployment-k8s.git" "default:git@github.com:NSM-CNF/deployment-k8s.git"
    platform_resolve_value "TEMPLATE_REPO_NAME" "NSM_OVS_TEMPLATE_REPO_NAME" "nse-ovs-template" "default:nse-ovs-template"
    platform_resolve_value "TEMPLATE_REPO_URL" "NSM_OVS_TEMPLATE_REPO_URL" "git@github.com:NSM-OVS/nse-ovs-template.git" "default:git@github.com:NSM-OVS/nse-ovs-template.git"
    platform_resolve_value "FIREWALL_REPO_NAME" "NSM_OVS_FIREWALL_REPO_NAME" "nse-ovs-firewall" "default:nse-ovs-firewall"
    platform_resolve_value "FIREWALL_REPO_URL" "NSM_OVS_FIREWALL_REPO_URL" "git@github.com:NSM-OVS/nse-ovs-firewall.git" "default:git@github.com:NSM-OVS/nse-ovs-firewall.git"
    platform_resolve_value "NAT_REPO_NAME" "NSM_OVS_NAT_REPO_NAME" "nse-ovs-nat" "default:nse-ovs-nat"
    platform_resolve_value "NAT_REPO_URL" "NSM_OVS_NAT_REPO_URL" "git@github.com:NSM-OVS/nse-ovs-nat.git" "default:git@github.com:NSM-OVS/nse-ovs-nat.git"
    platform_resolve_value "GATEWAY_REPO_NAME" "NSM_OVS_GATEWAY_REPO_NAME" "nse-ovs-gateway" "default:nse-ovs-gateway"
    platform_resolve_value "GATEWAY_REPO_URL" "NSM_OVS_GATEWAY_REPO_URL" "git@github.com:NSM-OVS/nse-ovs-gateway.git" "default:git@github.com:NSM-OVS/nse-ovs-gateway.git"
    platform_resolve_value "DPI_REPO_NAME" "NSM_OVS_DPI_REPO_NAME" "nse-ovs-dpi" "default:nse-ovs-dpi"
    platform_resolve_value "DPI_REPO_URL" "NSM_OVS_DPI_REPO_URL" "git@github.com:NSM-OVS/nse-ovs-dpi.git" "default:git@github.com:NSM-OVS/nse-ovs-dpi.git"
    platform_resolve_value "LB_REPO_NAME" "NSM_OVS_LB_REPO_NAME" "nse-ovs-lb" "default:nse-ovs-lb"
    platform_resolve_value "LB_REPO_URL" "NSM_OVS_LB_REPO_URL" "git@github.com:NSM-OVS/nse-ovs-lb.git" "default:git@github.com:NSM-OVS/nse-ovs-lb.git"
    platform_resolve_value "VPN_REPO_NAME" "NSM_OVS_VPN_REPO_NAME" "nse-ovs-vpn" "default:nse-ovs-vpn"
    platform_resolve_value "VPN_REPO_URL" "NSM_OVS_VPN_REPO_URL" "git@github.com:NSM-OVS/nse-ovs-vpn.git" "default:git@github.com:NSM-OVS/nse-ovs-vpn.git"
    platform_resolve_value "LB_STEERING_MODE" "NSM_OVS_LB_STEERING_MODE" "auto" "default:auto"
    platform_validate_lb_steering_mode "${LB_STEERING_MODE}"
    platform_resolve_value "NAT_STEERING_MODE" "NSM_OVS_NAT_STEERING_MODE" "auto" "default:auto"
    platform_validate_nat_steering_mode "${NAT_STEERING_MODE}"
    if [[ -n "$(platform_cli_value "NSM_OVS_VPN_XNODE_MODE")" ]]; then
        platform_set_value "VPN_XNODE_MODE" "$(platform_cli_value "NSM_OVS_VPN_XNODE_MODE")" "cli"
    else
        platform_set_value "VPN_XNODE_MODE" "disabled" "default:disabled"
    fi
    platform_validate_vpn_xnode_mode "${VPN_XNODE_MODE}"
    platform_resolve_value "PCM_DEPLOYMENT_MODE" "PCM_DEPLOYMENT_MODE" "in-cluster" "default:in-cluster"
    platform_validate_pcm_deployment_mode "${PCM_DEPLOYMENT_MODE}"
    platform_set_value "CPU_PIN_MODE" "off" "source-snapshot:affinity-workflow-excluded"
    platform_resolve_value "CLIENT_REPO_NAME" "NSM_OVS_CLIENT_REPO_NAME" "nsc-ovs-client" "default:nsc-ovs-client"
    platform_resolve_value "CLIENT_REPO_URL" "NSM_OVS_CLIENT_REPO_URL" "git@github.com:NSM-OVS/nsc-ovs-client.git" "default:git@github.com:NSM-OVS/nsc-ovs-client.git"
    platform_resolve_value "SERVER_REPO_NAME" "NSM_OVS_SERVER_REPO_NAME" "nse-ovs-server" "default:nse-ovs-server"
    platform_resolve_value "SERVER_REPO_URL" "NSM_OVS_SERVER_REPO_URL" "git@github.com:NSM-OVS/nse-ovs-server.git" "default:git@github.com:NSM-OVS/nse-ovs-server.git"
    platform_resolve_value "CATEGRAF_REPO_NAME" "NSM_OVS_CATEGRAF_REPO_NAME" "categraf-k8s" "default:categraf-k8s"
    platform_resolve_value "CATEGRAF_REPO_URL" "NSM_OVS_CATEGRAF_REPO_URL" "git@github.com:NSM-OVS/categraf-k8s.git" "default:git@github.com:NSM-OVS/categraf-k8s.git"
    platform_resolve_value "VICTORIAMETRICS_REPO_NAME" "NSM_OVS_VICTORIAMETRICS_REPO_NAME" "victoriametrics-k8s" "default:victoriametrics-k8s"
    platform_resolve_value "VICTORIAMETRICS_REPO_URL" "NSM_OVS_VICTORIAMETRICS_REPO_URL" "git@github.com:NSM-OVS/victoriametrics-k8s.git" "default:git@github.com:NSM-OVS/victoriametrics-k8s.git"
    platform_resolve_value "N9E_REPO_NAME" "NSM_OVS_N9E_REPO_NAME" "n9e-k8s" "default:n9e-k8s"
    platform_resolve_value "N9E_REPO_URL" "NSM_OVS_N9E_REPO_URL" "git@github.com:NSM-OVS/n9e-k8s.git" "default:git@github.com:NSM-OVS/n9e-k8s.git"
    platform_resolve_value "HUMAN_TIMEZONE" "NSM_OVS_HUMAN_TIMEZONE" "Asia/Shanghai" "default:Asia/Shanghai"
    platform_resolve_value "TEMPLATE_CIDR_POOL" "NSM_OVS_TEMPLATE_CIDR_POOL" "172.16.64.0/18" "default:172.16.64.0/18"
    platform_resolve_value "TEMPLATE_CIDR_PREFIX_LEN" "NSM_OVS_TEMPLATE_CIDR_PREFIX_LEN" "31" "default:31"
    platform_resolve_value "SPIRE_NAMESPACE" "NSM_OVS_BASIC_SPIRE_NAMESPACE" "spire" "default:spire"
    platform_resolve_value "NSM_SYSTEM_NAMESPACE" "NSM_OVS_BASIC_NSM_SYSTEM_NAMESPACE" "nsm-system" "default:nsm-system"
    platform_resolve_value "BASIC_FORWARDER_NAMESPACE" "NSM_OVS_BASIC_FORWARDER_NAMESPACE" "${NSM_SYSTEM_NAMESPACE}" "default:NSM_SYSTEM_NAMESPACE"
    platform_resolve_value "BASIC_FORWARDER_DAEMONSET_NAME" "NSM_OVS_BASIC_FORWARDER_DAEMONSET_NAME" "forwarder-ovs" "default:forwarder-ovs"
    platform_resolve_value "TEMPLATE_GATEWAY_NAMESPACE" "NSM_OVS_TEMPLATE_GATEWAY_NAMESPACE" "nse-ovs-gateway" "default:nse-ovs-gateway"
    platform_resolve_value "CATEGRAF_NAMESPACE" "NSM_OVS_MEASUREMENT_CATEGRAF_NAMESPACE" "categraf-system" "default:categraf-system"
    platform_resolve_value "CATEGRAF_CONFIGMAP_NAME" "NSM_OVS_MEASUREMENT_CATEGRAF_CONFIGMAP_NAME" "categraf-config" "default:categraf-config"
    platform_resolve_value "N9E_NAMESPACE" "NSM_OVS_MEASUREMENT_N9E_NAMESPACE" "n9e-system" "default:n9e-system"
    platform_resolve_value "N9E_SERVICE_NAME" "NSM_OVS_MEASUREMENT_N9E_SERVICE_NAME" "n9e" "default:n9e"
    platform_resolve_value "N9E_HTTP_PORT" "NSM_OVS_MEASUREMENT_N9E_HTTP_PORT" "17000" "default:17000"
    platform_resolve_value "VM_NAMESPACE" "NSM_OVS_MEASUREMENT_VM_NAMESPACE" "victoriametrics-system" "default:victoriametrics-system"
    platform_resolve_value "VM_SERVICE_NAME" "NSM_OVS_MEASUREMENT_VM_SERVICE_NAME" "victoria-metrics" "default:victoria-metrics"
    platform_resolve_value "VM_HTTP_PORT" "NSM_OVS_MEASUREMENT_VM_HTTP_PORT" "8428" "default:8428"
    platform_resolve_value "TEMPLATE_DEFAULT_VNF_NODE" "NSM_OVS_TEMPLATE_DEFAULT_VNF_NODE" "node01" "default:node01"
    platform_resolve_value "TEMPLATE_DEFAULT_CLIENT_NODE" "NSM_OVS_TEMPLATE_DEFAULT_CLIENT_NODE" "node01" "default:node01"
    platform_resolve_value "TEMPLATE_DEFAULT_SERVER_NODE" "NSM_OVS_TEMPLATE_DEFAULT_SERVER_NODE" "node01" "default:node01"
    platform_set_value "NSM_OVS_HUMAN_TIMEZONE" "${HUMAN_TIMEZONE}" "derived:HUMAN_TIMEZONE"
    platform_set_value "TZ" "${HUMAN_TIMEZONE}" "derived:HUMAN_TIMEZONE"
    platform_set_value "KUBECONFIG" "${KUBECONFIG_PATH}" "derived:KUBECONFIG_PATH"
    platform_set_value "KUBECTL" "${PLATFORM_KUBECTL_WRAPPER}" "derived:platform-kubectl-wrapper"
    platform_set_value "NSM_OVS_KUBECTL_BIN" "${KUBECTL_BIN_REAL}" "derived:KUBECTL_BIN_REAL"
    platform_set_value "NSM_OVS_CLUSTER_PROFILE" "${CLUSTER_PROFILE}" "derived:CLUSTER_PROFILE"
    platform_set_value "NSM_OVS_IMAGE_DELIVERY_MODE" "${IMAGE_DELIVERY_MODE}" "derived:IMAGE_DELIVERY_MODE"
    platform_set_value "NSM_OVS_LB_STEERING_MODE" "${LB_STEERING_MODE}" "derived:LB_STEERING_MODE"
    platform_set_value "NSM_OVS_NAT_STEERING_MODE" "${NAT_STEERING_MODE}" "derived:NAT_STEERING_MODE"
    platform_set_value "NSM_OVS_VPN_XNODE_MODE" "${VPN_XNODE_MODE}" "derived:VPN_XNODE_MODE"
    platform_set_value "NSM_OVS_PCM_DEPLOYMENT_MODE" "${PCM_DEPLOYMENT_MODE}" "derived:PCM_DEPLOYMENT_MODE"
    platform_set_value "NSM_OVS_CPU_PIN_MODE" "${CPU_PIN_MODE}" "derived:CPU_PIN_MODE"
    platform_set_value "NSM_OVS_MEASUREMENT_VM_NAMESPACE" "${VM_NAMESPACE}" "derived:VM_NAMESPACE"
    platform_set_value "NSM_OVS_MEASUREMENT_VM_SERVICE_NAME" "${VM_SERVICE_NAME}" "derived:VM_SERVICE_NAME"
    platform_set_value "NSM_OVS_MEASUREMENT_VM_HTTP_PORT" "${VM_HTTP_PORT}" "derived:VM_HTTP_PORT"
    platform_set_value "NSM_OVS_MEASUREMENT_N9E_NAMESPACE" "${N9E_NAMESPACE}" "derived:N9E_NAMESPACE"
    platform_set_value "NSM_OVS_MEASUREMENT_N9E_SERVICE_NAME" "${N9E_SERVICE_NAME}" "derived:N9E_SERVICE_NAME"
    platform_set_value "NSM_OVS_MEASUREMENT_N9E_HTTP_PORT" "${N9E_HTTP_PORT}" "derived:N9E_HTTP_PORT"
    platform_set_value "NSM_OVS_MEASUREMENT_CATEGRAF_NAMESPACE" "${CATEGRAF_NAMESPACE}" "derived:CATEGRAF_NAMESPACE"
    platform_set_value "NSM_OVS_MEASUREMENT_CATEGRAF_CONFIGMAP_NAME" "${CATEGRAF_CONFIGMAP_NAME}" "derived:CATEGRAF_CONFIGMAP_NAME"

    if [[ "${IMAGE_DELIVERY_MODE}" == "registry-pull" ]]; then
        registry_pull_enabled=true
    elif [[ "${IMAGE_DELIVERY_MODE}" == "preload-import" ]]; then
        preload_import_enabled=true
    fi
    platform_set_value "IMAGE_DELIVERY_REGISTRY_PULL_ENABLED" "${registry_pull_enabled}" "derived:IMAGE_DELIVERY_MODE"
    platform_set_value "IMAGE_DELIVERY_PRELOAD_IMPORT_ENABLED" "${preload_import_enabled}" "derived:IMAGE_DELIVERY_MODE"

    platform_set_value "BASIC_REPO_PATH" "${NSM_ROOT}/${BASIC_REPO_NAME}" "derived:NSM_ROOT+BASIC_REPO_NAME"
    platform_set_value "DEPLOYMENT_K8S_REPO_PATH" "${NSM_ROOT}/${DEPLOYMENT_K8S_REPO_NAME}" "derived:NSM_ROOT+DEPLOYMENT_K8S_REPO_NAME"
    platform_set_value "TEMPLATE_REPO_PATH" "${NSM_ROOT}/${TEMPLATE_REPO_NAME}" "derived:NSM_ROOT+TEMPLATE_REPO_NAME"
    platform_set_value "FIREWALL_REPO_PATH" "${NSM_ROOT}/${FIREWALL_REPO_NAME}" "derived:NSM_ROOT+FIREWALL_REPO_NAME"
    platform_set_value "NAT_REPO_PATH" "${NSM_ROOT}/${NAT_REPO_NAME}" "derived:NSM_ROOT+NAT_REPO_NAME"
    platform_set_value "GATEWAY_REPO_PATH" "${NSM_ROOT}/${GATEWAY_REPO_NAME}" "derived:NSM_ROOT+GATEWAY_REPO_NAME"
    platform_set_value "DPI_REPO_PATH" "${NSM_ROOT}/${DPI_REPO_NAME}" "derived:NSM_ROOT+DPI_REPO_NAME"
    platform_set_value "LB_REPO_PATH" "${NSM_ROOT}/${LB_REPO_NAME}" "derived:NSM_ROOT+LB_REPO_NAME"
    platform_set_value "VPN_REPO_PATH" "${NSM_ROOT}/${VPN_REPO_NAME}" "derived:NSM_ROOT+VPN_REPO_NAME"
    platform_set_value "CLIENT_REPO_PATH" "${NSM_ROOT}/${CLIENT_REPO_NAME}" "derived:NSM_ROOT+CLIENT_REPO_NAME"
    platform_set_value "SERVER_REPO_PATH" "${NSM_ROOT}/${SERVER_REPO_NAME}" "derived:NSM_ROOT+SERVER_REPO_NAME"
    platform_set_value "CATEGRAF_REPO_PATH" "${NSM_ROOT}/${CATEGRAF_REPO_NAME}" "derived:NSM_ROOT+CATEGRAF_REPO_NAME"
    platform_set_value "VICTORIAMETRICS_REPO_PATH" "${NSM_ROOT}/${VICTORIAMETRICS_REPO_NAME}" "derived:NSM_ROOT+VICTORIAMETRICS_REPO_NAME"
    platform_set_value "N9E_REPO_PATH" "${NSM_ROOT}/${N9E_REPO_NAME}" "derived:NSM_ROOT+N9E_REPO_NAME"
    platform_resolve_optional_input "TEMPLATE_STACK_ID_INPUT" "NSM_OVS_TEMPLATE_STACK_ID"
    platform_resolve_optional_input "TEMPLATE_NAMESPACE_OVERRIDE_INPUT" "NSM_OVS_TEMPLATE_NAMESPACE_OVERRIDE"
    platform_resolve_optional_input "TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT" "NSM_OVS_TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE"
    platform_resolve_optional_input "TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT" "NSM_OVS_TEMPLATE_CIDR_PREFIX_OVERRIDE"
    platform_resolve_optional_input "TEMPLATE_VNF_NODE_INPUT" "NSM_OVS_TEMPLATE_VNF_NODE"
    platform_resolve_optional_input "TEMPLATE_CLIENT_NODE_INPUT" "NSM_OVS_TEMPLATE_CLIENT_NODE"
    platform_resolve_optional_input "TEMPLATE_SERVER_NODE_INPUT" "NSM_OVS_TEMPLATE_SERVER_NODE"
}

platform_print_cluster_target() {
    printf 'cluster profile: %s [source=%s]\n' "${CLUSTER_PROFILE}" "${PLATFORM_VALUE_SOURCE[CLUSTER_PROFILE]}"
    printf 'cluster profile file: %s [source=%s]\n' "${CLUSTER_PROFILE_FILE}" "${PLATFORM_VALUE_SOURCE[CLUSTER_PROFILE_FILE]}"
    printf 'cluster local config file: %s [source=%s]\n' "${CLUSTER_LOCAL_CONFIG_FILE}" "${PLATFORM_VALUE_SOURCE[CLUSTER_LOCAL_CONFIG_FILE]}"
    printf 'kubectl wrapper: %s [source=%s]\n' "${KUBECTL}" "${PLATFORM_VALUE_SOURCE[KUBECTL]}"
    printf 'kubectl real bin: %s [source=%s]\n' "${KUBECTL_BIN_REAL}" "${PLATFORM_VALUE_SOURCE[KUBECTL_BIN_REAL]}"
    if [[ -n "${KUBECONFIG_PATH}" ]]; then
        printf 'kubeconfig: %s [source=%s]\n' "${KUBECONFIG_PATH}" "${PLATFORM_VALUE_SOURCE[KUBECONFIG_PATH]}"
    else
        printf 'kubeconfig: <ambient> [source=%s]\n' "${PLATFORM_VALUE_SOURCE[KUBECONFIG_PATH]}"
    fi
    if [[ -n "${KUBECTL_CONTEXT}" ]]; then
        printf 'kubectl context: %s [source=%s]\n' "${KUBECTL_CONTEXT}" "${PLATFORM_VALUE_SOURCE[KUBECTL_CONTEXT]}"
    else
        printf 'kubectl context: <ambient> [source=%s]\n' "${PLATFORM_VALUE_SOURCE[KUBECTL_CONTEXT]}"
    fi
    printf 'image delivery mode: %s [source=%s]\n' "${IMAGE_DELIVERY_MODE}" "${PLATFORM_VALUE_SOURCE[IMAGE_DELIVERY_MODE]}"
    printf 'registry-pull active: %s [source=%s]\n' "${IMAGE_DELIVERY_REGISTRY_PULL_ENABLED}" "${PLATFORM_VALUE_SOURCE[IMAGE_DELIVERY_REGISTRY_PULL_ENABLED]}"
    printf 'preload-import active: %s [source=%s]\n' "${IMAGE_DELIVERY_PRELOAD_IMPORT_ENABLED}" "${PLATFORM_VALUE_SOURCE[IMAGE_DELIVERY_PRELOAD_IMPORT_ENABLED]}"
    printf 'spire namespace: %s [source=%s]\n' "${SPIRE_NAMESPACE}" "${PLATFORM_VALUE_SOURCE[SPIRE_NAMESPACE]}"
    printf 'nsm-system namespace: %s [source=%s]\n' "${NSM_SYSTEM_NAMESPACE}" "${PLATFORM_VALUE_SOURCE[NSM_SYSTEM_NAMESPACE]}"
    printf 'forwarder namespace: %s [source=%s]\n' "${BASIC_FORWARDER_NAMESPACE}" "${PLATFORM_VALUE_SOURCE[BASIC_FORWARDER_NAMESPACE]}"
    printf 'forwarder daemonset: %s [source=%s]\n' "${BASIC_FORWARDER_DAEMONSET_NAME}" "${PLATFORM_VALUE_SOURCE[BASIC_FORWARDER_DAEMONSET_NAME]}"
    printf 'template gateway namespace: %s [source=%s]\n' "${TEMPLATE_GATEWAY_NAMESPACE}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_GATEWAY_NAMESPACE]}"
    printf 'categraf namespace: %s [source=%s]\n' "${CATEGRAF_NAMESPACE}" "${PLATFORM_VALUE_SOURCE[CATEGRAF_NAMESPACE]}"
    printf 'categraf configmap name: %s [source=%s]\n' "${CATEGRAF_CONFIGMAP_NAME}" "${PLATFORM_VALUE_SOURCE[CATEGRAF_CONFIGMAP_NAME]}"
    printf 'n9e namespace: %s [source=%s]\n' "${N9E_NAMESPACE}" "${PLATFORM_VALUE_SOURCE[N9E_NAMESPACE]}"
    printf 'n9e service name: %s [source=%s]\n' "${N9E_SERVICE_NAME}" "${PLATFORM_VALUE_SOURCE[N9E_SERVICE_NAME]}"
    printf 'n9e http port: %s [source=%s]\n' "${N9E_HTTP_PORT}" "${PLATFORM_VALUE_SOURCE[N9E_HTTP_PORT]}"
    printf 'victoriametrics namespace: %s [source=%s]\n' "${VM_NAMESPACE}" "${PLATFORM_VALUE_SOURCE[VM_NAMESPACE]}"
    printf 'victoriametrics service name: %s [source=%s]\n' "${VM_SERVICE_NAME}" "${PLATFORM_VALUE_SOURCE[VM_SERVICE_NAME]}"
    printf 'victoriametrics http port: %s [source=%s]\n' "${VM_HTTP_PORT}" "${PLATFORM_VALUE_SOURCE[VM_HTTP_PORT]}"
    printf 'default VNF node: %s [source=%s]\n' "${TEMPLATE_DEFAULT_VNF_NODE}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_DEFAULT_VNF_NODE]}"
    printf 'default client node: %s [source=%s]\n' "${TEMPLATE_DEFAULT_CLIENT_NODE}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_DEFAULT_CLIENT_NODE]}"
    printf 'default server node: %s [source=%s]\n' "${TEMPLATE_DEFAULT_SERVER_NODE}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_DEFAULT_SERVER_NODE]}"
}

platform_print_resolved_config() {
    printf 'platform repo root: %s [source=%s]\n' "${PLATFORM_REPO_ROOT}" "${PLATFORM_VALUE_SOURCE[PLATFORM_REPO_ROOT]}"
    platform_print_cluster_target
    printf 'NSM_ROOT: %s [source=%s]\n' "${NSM_ROOT}" "${PLATFORM_VALUE_SOURCE[NSM_ROOT]}"
    printf 'assets root: %s [source=%s]\n' "${ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[ASSETS_ROOT]}"
    printf 'artifacts root: %s [source=%s]\n' "${ARTIFACTS_ROOT}" "${PLATFORM_VALUE_SOURCE[ARTIFACTS_ROOT]}"
    printf 'baseline artifacts root: %s [source=%s]\n' "${BASELINE_ARTIFACTS_ROOT}" "${PLATFORM_VALUE_SOURCE[BASELINE_ARTIFACTS_ROOT]}"
    printf 'baseline compare artifacts root: %s [source=%s]\n' "${BASELINE_COMPARE_ARTIFACTS_ROOT}" "${PLATFORM_VALUE_SOURCE[BASELINE_COMPARE_ARTIFACTS_ROOT]}"
    printf 'validation artifacts root: %s [source=%s]\n' "${VALIDATION_ARTIFACTS_ROOT}" "${PLATFORM_VALUE_SOURCE[VALIDATION_ARTIFACTS_ROOT]}"
    printf 'multi-stack validation root: %s [source=%s]\n' "${MULTI_STACK_VALIDATION_ROOT}" "${PLATFORM_VALUE_SOURCE[MULTI_STACK_VALIDATION_ROOT]}"
    printf 'concurrent baseline validation root: %s [source=%s]\n' "${CONCURRENT_BASELINE_VALIDATION_ROOT}" "${PLATFORM_VALUE_SOURCE[CONCURRENT_BASELINE_VALIDATION_ROOT]}"
    printf 'fixed-load compare validation root: %s [source=%s]\n' "${FIXED_LOAD_COMPARE_VALIDATION_ROOT}" "${PLATFORM_VALUE_SOURCE[FIXED_LOAD_COMPARE_VALIDATION_ROOT]}"
    printf 'state root: %s [source=%s]\n' "${STATE_ROOT}" "${PLATFORM_VALUE_SOURCE[STATE_ROOT]}"
    printf 'template stack state root: %s [source=%s]\n' "${TEMPLATE_STACK_STATE_ROOT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_STACK_STATE_ROOT]}"
    printf 'generated root: %s [source=%s]\n' "${GENERATED_ROOT}" "${PLATFORM_VALUE_SOURCE[GENERATED_ROOT]}"
    printf 'template generated root: %s [source=%s]\n' "${TEMPLATE_GENERATED_ROOT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_GENERATED_ROOT]}"
    printf 'firewall stack state root: %s [source=%s]\n' "${FIREWALL_STACK_STATE_ROOT}" "${PLATFORM_VALUE_SOURCE[FIREWALL_STACK_STATE_ROOT]}"
    printf 'firewall generated root: %s [source=%s]\n' "${FIREWALL_GENERATED_ROOT}" "${PLATFORM_VALUE_SOURCE[FIREWALL_GENERATED_ROOT]}"
    printf 'nat stack state root: %s [source=%s]\n' "${NAT_STACK_STATE_ROOT}" "${PLATFORM_VALUE_SOURCE[NAT_STACK_STATE_ROOT]}"
    printf 'nat generated root: %s [source=%s]\n' "${NAT_GENERATED_ROOT}" "${PLATFORM_VALUE_SOURCE[NAT_GENERATED_ROOT]}"
    printf 'gateway stack state root: %s [source=%s]\n' "${GATEWAY_STACK_STATE_ROOT}" "${PLATFORM_VALUE_SOURCE[GATEWAY_STACK_STATE_ROOT]}"
    printf 'gateway generated root: %s [source=%s]\n' "${GATEWAY_GENERATED_ROOT}" "${PLATFORM_VALUE_SOURCE[GATEWAY_GENERATED_ROOT]}"
    printf 'dpi stack state root: %s [source=%s]\n' "${DPI_STACK_STATE_ROOT}" "${PLATFORM_VALUE_SOURCE[DPI_STACK_STATE_ROOT]}"
    printf 'dpi generated root: %s [source=%s]\n' "${DPI_GENERATED_ROOT}" "${PLATFORM_VALUE_SOURCE[DPI_GENERATED_ROOT]}"
    printf 'lb stack state root: %s [source=%s]\n' "${LB_STACK_STATE_ROOT}" "${PLATFORM_VALUE_SOURCE[LB_STACK_STATE_ROOT]}"
    printf 'lb generated root: %s [source=%s]\n' "${LB_GENERATED_ROOT}" "${PLATFORM_VALUE_SOURCE[LB_GENERATED_ROOT]}"
    printf 'vpn stack state root: %s [source=%s]\n' "${VPN_STACK_STATE_ROOT}" "${PLATFORM_VALUE_SOURCE[VPN_STACK_STATE_ROOT]}"
    printf 'vpn generated root: %s [source=%s]\n' "${VPN_GENERATED_ROOT}" "${PLATFORM_VALUE_SOURCE[VPN_GENERATED_ROOT]}"
    printf 'artifacts root: %s [source=%s]\n' "${ARTIFACTS_ROOT}" "${PLATFORM_VALUE_SOURCE[ARTIFACTS_ROOT]}"
    printf 'baseline artifacts root: %s [source=%s]\n' "${BASELINE_ARTIFACTS_ROOT}" "${PLATFORM_VALUE_SOURCE[BASELINE_ARTIFACTS_ROOT]}"
    printf 'basic assets root: %s [source=%s]\n' "${BASIC_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[BASIC_ASSETS_ROOT]}"
    printf 'basic manifests dir: %s [source=%s]\n' "${BASIC_ASSETS_MANIFESTS_DIR}" "${PLATFORM_VALUE_SOURCE[BASIC_ASSETS_MANIFESTS_DIR]}"
    printf 'basic wrappers dir: %s [source=%s]\n' "${BASIC_ASSETS_WRAPPERS_DIR}" "${PLATFORM_VALUE_SOURCE[BASIC_ASSETS_WRAPPERS_DIR]}"
    printf 'template assets root: %s [source=%s]\n' "${TEMPLATE_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_ASSETS_ROOT]}"
    printf 'template k8s dir: %s [source=%s]\n' "${TEMPLATE_K8S_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_K8S_ASSETS_DIR]}"
    printf 'template verify dir: %s [source=%s]\n' "${TEMPLATE_VERIFY_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_VERIFY_ASSETS_DIR]}"
    printf 'firewall assets root: %s [source=%s]\n' "${FIREWALL_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[FIREWALL_ASSETS_ROOT]}"
    printf 'firewall k8s dir: %s [source=%s]\n' "${FIREWALL_K8S_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[FIREWALL_K8S_ASSETS_DIR]}"
    printf 'firewall verify dir: %s [source=%s]\n' "${FIREWALL_VERIFY_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[FIREWALL_VERIFY_ASSETS_DIR]}"
    printf 'nat assets root: %s [source=%s]\n' "${NAT_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[NAT_ASSETS_ROOT]}"
    printf 'nat k8s dir: %s [source=%s]\n' "${NAT_K8S_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[NAT_K8S_ASSETS_DIR]}"
    printf 'nat verify dir: %s [source=%s]\n' "${NAT_VERIFY_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[NAT_VERIFY_ASSETS_DIR]}"
    printf 'gateway assets root: %s [source=%s]\n' "${GATEWAY_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[GATEWAY_ASSETS_ROOT]}"
    printf 'gateway k8s dir: %s [source=%s]\n' "${GATEWAY_K8S_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[GATEWAY_K8S_ASSETS_DIR]}"
    printf 'gateway verify dir: %s [source=%s]\n' "${GATEWAY_VERIFY_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[GATEWAY_VERIFY_ASSETS_DIR]}"
    printf 'dpi assets root: %s [source=%s]\n' "${DPI_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[DPI_ASSETS_ROOT]}"
    printf 'dpi k8s dir: %s [source=%s]\n' "${DPI_K8S_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[DPI_K8S_ASSETS_DIR]}"
    printf 'dpi verify dir: %s [source=%s]\n' "${DPI_VERIFY_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[DPI_VERIFY_ASSETS_DIR]}"
    printf 'lb assets root: %s [source=%s]\n' "${LB_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[LB_ASSETS_ROOT]}"
    printf 'lb k8s dir: %s [source=%s]\n' "${LB_K8S_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[LB_K8S_ASSETS_DIR]}"
    printf 'lb verify dir: %s [source=%s]\n' "${LB_VERIFY_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[LB_VERIFY_ASSETS_DIR]}"
    printf 'vpn assets root: %s [source=%s]\n' "${VPN_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[VPN_ASSETS_ROOT]}"
    printf 'vpn k8s dir: %s [source=%s]\n' "${VPN_K8S_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[VPN_K8S_ASSETS_DIR]}"
    printf 'vpn verify dir: %s [source=%s]\n' "${VPN_VERIFY_ASSETS_DIR}" "${PLATFORM_VALUE_SOURCE[VPN_VERIFY_ASSETS_DIR]}"
    printf 'measurement assets root: %s [source=%s]\n' "${MEASUREMENT_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[MEASUREMENT_ASSETS_ROOT]}"
    printf 'system measurement assets root: %s [source=%s]\n' "${SYSTEM_MEASUREMENT_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[SYSTEM_MEASUREMENT_ASSETS_ROOT]}"
    printf 'storage measurement assets root: %s [source=%s]\n' "${STORAGE_MEASUREMENT_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[STORAGE_MEASUREMENT_ASSETS_ROOT]}"
    printf 'control measurement assets root: %s [source=%s]\n' "${CONTROL_MEASUREMENT_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[CONTROL_MEASUREMENT_ASSETS_ROOT]}"
    printf 'categraf assets root: %s [source=%s]\n' "${CATEGRAF_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[CATEGRAF_ASSETS_ROOT]}"
    printf 'categraf configs base dir: %s [source=%s]\n' "${CATEGRAF_CONFIGS_BASE_DIR}" "${PLATFORM_VALUE_SOURCE[CATEGRAF_CONFIGS_BASE_DIR]}"
    printf 'categraf manifests base dir: %s [source=%s]\n' "${CATEGRAF_MANIFESTS_BASE_DIR}" "${PLATFORM_VALUE_SOURCE[CATEGRAF_MANIFESTS_BASE_DIR]}"
    printf 'categraf scripts dir: %s [source=%s]\n' "${CATEGRAF_SCRIPTS_DIR}" "${PLATFORM_VALUE_SOURCE[CATEGRAF_SCRIPTS_DIR]}"
    printf 'victoriametrics assets root: %s [source=%s]\n' "${VICTORIAMETRICS_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[VICTORIAMETRICS_ASSETS_ROOT]}"
    printf 'victoriametrics manifests base dir: %s [source=%s]\n' "${VICTORIAMETRICS_MANIFESTS_BASE_DIR}" "${PLATFORM_VALUE_SOURCE[VICTORIAMETRICS_MANIFESTS_BASE_DIR]}"
    printf 'victoriametrics scripts dir: %s [source=%s]\n' "${VICTORIAMETRICS_SCRIPTS_DIR}" "${PLATFORM_VALUE_SOURCE[VICTORIAMETRICS_SCRIPTS_DIR]}"
    printf 'n9e assets root: %s [source=%s]\n' "${N9E_ASSETS_ROOT}" "${PLATFORM_VALUE_SOURCE[N9E_ASSETS_ROOT]}"
    printf 'n9e configs base dir: %s [source=%s]\n' "${N9E_CONFIGS_BASE_DIR}" "${PLATFORM_VALUE_SOURCE[N9E_CONFIGS_BASE_DIR]}"
    printf 'n9e manifests base dir: %s [source=%s]\n' "${N9E_MANIFESTS_BASE_DIR}" "${PLATFORM_VALUE_SOURCE[N9E_MANIFESTS_BASE_DIR]}"
    printf 'n9e scripts dir: %s [source=%s]\n' "${N9E_SCRIPTS_DIR}" "${PLATFORM_VALUE_SOURCE[N9E_SCRIPTS_DIR]}"
    printf 'basic repo name: %s [source=%s]\n' "${BASIC_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[BASIC_REPO_NAME]}"
    printf 'basic repo url: %s [source=%s]\n' "${BASIC_REPO_URL}" "${PLATFORM_VALUE_SOURCE[BASIC_REPO_URL]}"
    printf 'basic repo path: %s [source=%s]\n' "${BASIC_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[BASIC_REPO_PATH]}"
    printf 'deployment-k8s repo name: %s [source=%s]\n' "${DEPLOYMENT_K8S_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[DEPLOYMENT_K8S_REPO_NAME]}"
    printf 'deployment-k8s repo url: %s [source=%s]\n' "${DEPLOYMENT_K8S_REPO_URL}" "${PLATFORM_VALUE_SOURCE[DEPLOYMENT_K8S_REPO_URL]}"
    printf 'deployment-k8s repo path: %s [source=%s]\n' "${DEPLOYMENT_K8S_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[DEPLOYMENT_K8S_REPO_PATH]}"
    printf 'template repo name: %s [source=%s]\n' "${TEMPLATE_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_REPO_NAME]}"
    printf 'template repo url: %s [source=%s]\n' "${TEMPLATE_REPO_URL}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_REPO_URL]}"
    printf 'template repo path: %s [source=%s]\n' "${TEMPLATE_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_REPO_PATH]}"
    printf 'firewall repo name: %s [source=%s]\n' "${FIREWALL_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[FIREWALL_REPO_NAME]}"
    printf 'firewall repo url: %s [source=%s]\n' "${FIREWALL_REPO_URL}" "${PLATFORM_VALUE_SOURCE[FIREWALL_REPO_URL]}"
    printf 'firewall repo path: %s [source=%s]\n' "${FIREWALL_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[FIREWALL_REPO_PATH]}"
    printf 'nat repo name: %s [source=%s]\n' "${NAT_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[NAT_REPO_NAME]}"
    printf 'nat repo url: %s [source=%s]\n' "${NAT_REPO_URL}" "${PLATFORM_VALUE_SOURCE[NAT_REPO_URL]}"
    printf 'nat repo path: %s [source=%s]\n' "${NAT_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[NAT_REPO_PATH]}"
    printf 'gateway repo name: %s [source=%s]\n' "${GATEWAY_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[GATEWAY_REPO_NAME]}"
    printf 'gateway repo url: %s [source=%s]\n' "${GATEWAY_REPO_URL}" "${PLATFORM_VALUE_SOURCE[GATEWAY_REPO_URL]}"
    printf 'gateway repo path: %s [source=%s]\n' "${GATEWAY_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[GATEWAY_REPO_PATH]}"
    printf 'dpi repo name: %s [source=%s]\n' "${DPI_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[DPI_REPO_NAME]}"
    printf 'dpi repo url: %s [source=%s]\n' "${DPI_REPO_URL}" "${PLATFORM_VALUE_SOURCE[DPI_REPO_URL]}"
    printf 'dpi repo path: %s [source=%s]\n' "${DPI_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[DPI_REPO_PATH]}"
    printf 'lb repo name: %s [source=%s]\n' "${LB_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[LB_REPO_NAME]}"
    printf 'lb repo url: %s [source=%s]\n' "${LB_REPO_URL}" "${PLATFORM_VALUE_SOURCE[LB_REPO_URL]}"
    printf 'lb repo path: %s [source=%s]\n' "${LB_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[LB_REPO_PATH]}"
    printf 'vpn repo name: %s [source=%s]\n' "${VPN_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[VPN_REPO_NAME]}"
    printf 'vpn repo url: %s [source=%s]\n' "${VPN_REPO_URL}" "${PLATFORM_VALUE_SOURCE[VPN_REPO_URL]}"
    printf 'vpn repo path: %s [source=%s]\n' "${VPN_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[VPN_REPO_PATH]}"
    printf 'lb steering mode: %s [source=%s]\n' "${LB_STEERING_MODE}" "${PLATFORM_VALUE_SOURCE[LB_STEERING_MODE]}"
    printf 'nat steering mode: %s [source=%s]\n' "${NAT_STEERING_MODE}" "${PLATFORM_VALUE_SOURCE[NAT_STEERING_MODE]}"
    printf 'vpn xnode mode: %s [source=%s]\n' "${VPN_XNODE_MODE}" "${PLATFORM_VALUE_SOURCE[VPN_XNODE_MODE]}"
    printf 'pcm deployment mode: %s [source=%s]\n' "${PCM_DEPLOYMENT_MODE}" "${PLATFORM_VALUE_SOURCE[PCM_DEPLOYMENT_MODE]}"
    printf 'cpu pin mode: %s [source=%s]\n' "${CPU_PIN_MODE}" "${PLATFORM_VALUE_SOURCE[CPU_PIN_MODE]}"
    printf 'client repo name: %s [source=%s]\n' "${CLIENT_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[CLIENT_REPO_NAME]}"
    printf 'client repo url: %s [source=%s]\n' "${CLIENT_REPO_URL}" "${PLATFORM_VALUE_SOURCE[CLIENT_REPO_URL]}"
    printf 'client repo path: %s [source=%s]\n' "${CLIENT_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[CLIENT_REPO_PATH]}"
    printf 'server repo name: %s [source=%s]\n' "${SERVER_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[SERVER_REPO_NAME]}"
    printf 'server repo url: %s [source=%s]\n' "${SERVER_REPO_URL}" "${PLATFORM_VALUE_SOURCE[SERVER_REPO_URL]}"
    printf 'server repo path: %s [source=%s]\n' "${SERVER_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[SERVER_REPO_PATH]}"
    printf 'categraf repo name: %s [source=%s]\n' "${CATEGRAF_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[CATEGRAF_REPO_NAME]}"
    printf 'categraf repo url: %s [source=%s]\n' "${CATEGRAF_REPO_URL}" "${PLATFORM_VALUE_SOURCE[CATEGRAF_REPO_URL]}"
    printf 'categraf repo path: %s [source=%s]\n' "${CATEGRAF_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[CATEGRAF_REPO_PATH]}"
    printf 'victoriametrics repo name: %s [source=%s]\n' "${VICTORIAMETRICS_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[VICTORIAMETRICS_REPO_NAME]}"
    printf 'victoriametrics repo url: %s [source=%s]\n' "${VICTORIAMETRICS_REPO_URL}" "${PLATFORM_VALUE_SOURCE[VICTORIAMETRICS_REPO_URL]}"
    printf 'victoriametrics repo path: %s [source=%s]\n' "${VICTORIAMETRICS_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[VICTORIAMETRICS_REPO_PATH]}"
    printf 'n9e repo name: %s [source=%s]\n' "${N9E_REPO_NAME}" "${PLATFORM_VALUE_SOURCE[N9E_REPO_NAME]}"
    printf 'n9e repo url: %s [source=%s]\n' "${N9E_REPO_URL}" "${PLATFORM_VALUE_SOURCE[N9E_REPO_URL]}"
    printf 'n9e repo path: %s [source=%s]\n' "${N9E_REPO_PATH}" "${PLATFORM_VALUE_SOURCE[N9E_REPO_PATH]}"
    printf 'human timezone: %s [source=%s]\n' "${HUMAN_TIMEZONE}" "${PLATFORM_VALUE_SOURCE[HUMAN_TIMEZONE]}"
    printf 'template CIDR pool: %s [source=%s]\n' "${TEMPLATE_CIDR_POOL}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_POOL]}"
    printf 'template CIDR prefix len: %s [source=%s]\n' "${TEMPLATE_CIDR_PREFIX_LEN}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_PREFIX_LEN]}"
    if [[ -n "${TEMPLATE_STACK_ID_INPUT}" ]]; then
        printf 'template stack id input: %s [source=%s]\n' "${TEMPLATE_STACK_ID_INPUT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_STACK_ID_INPUT]}"
    fi
    if [[ -n "${TEMPLATE_NAMESPACE_OVERRIDE_INPUT}" ]]; then
        printf 'template namespace override input: %s [source=%s]\n' "${TEMPLATE_NAMESPACE_OVERRIDE_INPUT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_NAMESPACE_OVERRIDE_INPUT]}"
    fi
    if [[ -n "${TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT}" ]]; then
        printf 'template network service override input: %s [source=%s]\n' "${TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_NETWORK_SERVICE_NAME_OVERRIDE_INPUT]}"
    fi
    if [[ -n "${TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT}" ]]; then
        printf 'template CIDR override input: %s [source=%s]\n' "${TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CIDR_PREFIX_OVERRIDE_INPUT]}"
    fi
    if [[ -n "${TEMPLATE_VNF_NODE_INPUT}" ]]; then
        printf 'template VNF node input: %s [source=%s]\n' "${TEMPLATE_VNF_NODE_INPUT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_VNF_NODE_INPUT]}"
    fi
    if [[ -n "${TEMPLATE_CLIENT_NODE_INPUT}" ]]; then
        printf 'template client node input: %s [source=%s]\n' "${TEMPLATE_CLIENT_NODE_INPUT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_CLIENT_NODE_INPUT]}"
    fi
    if [[ -n "${TEMPLATE_SERVER_NODE_INPUT}" ]]; then
        printf 'template server node input: %s [source=%s]\n' "${TEMPLATE_SERVER_NODE_INPUT}" "${PLATFORM_VALUE_SOURCE[TEMPLATE_SERVER_NODE_INPUT]}"
    fi
}

platform_log_resolved_config() {
    log_info "resolved platform configuration"
    platform_print_resolved_config
}
