#!/usr/bin/env bash

if [[ -n "${NSM_OVS_HOST_MEASUREMENT_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_HOST_MEASUREMENT_COMMON_SH_LOADED=1

HOST_MEASUREMENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_MEASUREMENT_SCRIPT_ROOT="$(cd "${HOST_MEASUREMENT_LIB_DIR}/.." && pwd)"
HOST_MEASUREMENT_REPO_ROOT="$(cd "${HOST_MEASUREMENT_SCRIPT_ROOT}/../.." && pwd)"

# shellcheck source=/dev/null
source "${HOST_MEASUREMENT_REPO_ROOT}/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "${HOST_MEASUREMENT_REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "${HOST_MEASUREMENT_REPO_ROOT}/scripts/host-measurement/lib/contract.sh"

declare -gA HOST_MEASUREMENT_CONFIG_MAP=()

hm_default_env_file() {
    local explicit="${HOST_MEASUREMENT_REPO_ROOT}/config/host-measurement/node01-stack.env"
    local example="${HOST_MEASUREMENT_REPO_ROOT}/config/host-measurement/node01-stack.env.example"

    if [[ -f "${explicit}" ]]; then
        printf '%s\n' "${explicit}"
    else
        printf '%s\n' "${example}"
    fi
}

hm_resolve_setting() {
    local output_name=$1
    local config_key=$2
    local default_value=$3
    local value="${!config_key:-${HOST_MEASUREMENT_CONFIG_MAP[${config_key}]:-${default_value}}}"

    printf -v "${output_name}" '%s' "${value}"
    export "${output_name}"
}

hm_join_csv() {
    local joined="" item

    for item in "$@"; do
        [[ -n "${item}" ]] || continue
        joined+="${joined:+,}${item}"
    done

    printf '%s\n' "${joined}"
}

hm_toml_string_array_from_lines() {
    local first=true item escaped

    printf '['
    while IFS= read -r item; do
        [[ -n "${item}" ]] || continue
        escaped="${item//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        if [[ "${first}" == "true" ]]; then
            first=false
        else
            printf ', '
        fi
        printf '"%s"' "${escaped}"
    done
    printf ']'
}

hm_k8s_endpoint_urls_from_json() {
    local endpoints_json=$1
    local port_name=$2

    jq -r --arg port_name "${port_name}" '
        [
            .subsets[]? as $subset
            | ($subset.ports[]? | select(.name == $port_name) | .port) as $port
            | $subset.addresses[]?.ip
            | "http://\(.)" + ":" + ($port | tostring) + "/metrics"
        ]
        | unique[]
    ' <<<"${endpoints_json}"
}

hm_discover_cluster_targets() {
    local remote_node_name="" apiserver_url="" token_b64="" endpoints_json=""
    local kubelet_blocker="" cadvisor_blocker="" ksm_blocker="" ksm_self_blocker=""
    local ksm_urls="" ksm_self_urls=""

    if [[ "${HM_CLUSTER_TARGETS_DISCOVERED:-0}" == "1" ]]; then
        return 0
    fi
    HM_CLUSTER_TARGETS_DISCOVERED=1

    HM_REMOTE_NODE_NAME="${HM_SSH_TARGET}"
    HM_REMOTE_NODE_NAME_SOURCE="config"
    HM_APISERVER_URL=""
    HM_APISERVER_SOURCE="missing"

    HM_CATEGRAF_CLUSTER_TOKEN_AVAILABLE="0"
    HM_CATEGRAF_CLUSTER_TOKEN_BLOCKER="cluster-auth-token-unavailable"
    HM_CATEGRAF_CLUSTER_TOKEN_SECRET_USED="${HM_CLUSTER_AUTH_TOKEN_SECRET}"
    HM_CATEGRAF_CLUSTER_TOKEN_VALUE=""

    HM_KUBELET_PROXY_METRICS_URL=""
    HM_CADVISOR_PROXY_METRICS_URL=""
    HM_KUBELET_DISCOVERY_BLOCKER=""
    HM_CADVISOR_DISCOVERY_BLOCKER=""

    HM_KSM_METRICS_URLS_CSV=""
    HM_KSM_METRICS_URLS_TOML="[]"
    HM_KSM_SELF_METRICS_URLS_CSV=""
    HM_KSM_SELF_METRICS_URLS_TOML="[]"
    HM_KSM_DISCOVERY_BLOCKER=""
    HM_KSM_SELF_DISCOVERY_BLOCKER=""

    remote_node_name="$(ssh "${HM_SSH_TARGET_REF}" "hostname -s" 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
    if [[ -n "${remote_node_name}" ]]; then
        HM_REMOTE_NODE_NAME="${remote_node_name}"
        HM_REMOTE_NODE_NAME_SOURCE="ssh"
    fi

    apiserver_url="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
    if [[ -n "${apiserver_url}" ]]; then
        HM_APISERVER_URL="${apiserver_url}"
        HM_APISERVER_SOURCE="kubeconfig"
    fi

    token_b64="$(kubectl -n "${HM_CLUSTER_AUTH_NAMESPACE}" get secret "${HM_CLUSTER_AUTH_TOKEN_SECRET}" -o jsonpath='{.data.token}' 2>/dev/null || true)"
    if [[ -n "${token_b64}" ]]; then
        HM_CATEGRAF_CLUSTER_TOKEN_AVAILABLE="1"
        HM_CATEGRAF_CLUSTER_TOKEN_BLOCKER=""
        HM_CATEGRAF_CLUSTER_TOKEN_VALUE="$(printf '%s' "${token_b64}" | base64 -d)"
    fi

    kubelet_blocker="$(hm_join_csv \
        "${HM_CATEGRAF_CLUSTER_TOKEN_BLOCKER}" \
        "$( [[ -n "${HM_APISERVER_URL}" ]] || printf 'apiserver-url-unavailable' )" \
        "$( [[ -n "${HM_REMOTE_NODE_NAME}" ]] || printf 'remote-node-name-unavailable' )")"
    if [[ -n "${HM_APISERVER_URL}" && -n "${HM_REMOTE_NODE_NAME}" && "${HM_CATEGRAF_CLUSTER_TOKEN_AVAILABLE}" == "1" ]]; then
        HM_KUBELET_PROXY_METRICS_URL="${HM_APISERVER_URL}/api/v1/nodes/${HM_REMOTE_NODE_NAME}/proxy/metrics"
        HM_CADVISOR_PROXY_METRICS_URL="${HM_APISERVER_URL}/api/v1/nodes/${HM_REMOTE_NODE_NAME}/proxy/metrics/cadvisor"
    else
        HM_KUBELET_DISCOVERY_BLOCKER="${kubelet_blocker:-kubelet-proxy-unavailable}"
        HM_CADVISOR_DISCOVERY_BLOCKER="${HM_KUBELET_DISCOVERY_BLOCKER}"
    fi

    endpoints_json="$(kubectl -n "${HM_KUBE_STATE_METRICS_NAMESPACE}" get endpoints "${HM_KUBE_STATE_METRICS_SERVICE}" -o json 2>/dev/null || true)"
    if [[ -n "${endpoints_json}" ]]; then
        ksm_urls="$(hm_k8s_endpoint_urls_from_json "${endpoints_json}" "http-metrics")"
        ksm_self_urls="$(hm_k8s_endpoint_urls_from_json "${endpoints_json}" "telemetry")"
    fi

    if [[ -n "${ksm_urls}" ]]; then
        HM_KSM_METRICS_URLS_CSV="$(paste -sd, <<<"${ksm_urls}")"
        HM_KSM_METRICS_URLS_TOML="$(hm_toml_string_array_from_lines <<<"${ksm_urls}")"
    else
        ksm_blocker="$(hm_join_csv \
            "$( [[ -n "${endpoints_json}" ]] || printf 'kube-state-metrics-endpoints-unavailable' )" \
            "$( [[ -n "${ksm_urls}" ]] || printf 'kube-state-metrics-http-metrics-port-unavailable' )")"
        HM_KSM_DISCOVERY_BLOCKER="${ksm_blocker:-kube-state-metrics-unavailable}"
    fi

    if [[ -n "${ksm_self_urls}" ]]; then
        HM_KSM_SELF_METRICS_URLS_CSV="$(paste -sd, <<<"${ksm_self_urls}")"
        HM_KSM_SELF_METRICS_URLS_TOML="$(hm_toml_string_array_from_lines <<<"${ksm_self_urls}")"
    else
        ksm_self_blocker="$(hm_join_csv \
            "$( [[ -n "${endpoints_json}" ]] || printf 'kube-state-metrics-endpoints-unavailable' )" \
            "$( [[ -n "${ksm_self_urls}" ]] || printf 'kube-state-metrics-telemetry-port-unavailable' )")"
        HM_KSM_SELF_DISCOVERY_BLOCKER="${ksm_self_blocker:-kube-state-metrics-self-unavailable}"
    fi
}

hm_load_config() {
    local env_file=${1:-}

    if [[ -z "${env_file}" ]]; then
        env_file="$(hm_default_env_file)"
    fi

    [[ -f "${env_file}" ]] || die "host measurement env file not found: ${env_file}"
    platform_load_env_file "${env_file}" HOST_MEASUREMENT_CONFIG_MAP

    HM_ENV_FILE="${env_file}"
    export HM_ENV_FILE

    hm_resolve_setting HM_SSH_TARGET NSM_OVS_HOST_MEASUREMENT_SSH_TARGET "node01"
    hm_resolve_setting HM_SSH_USER NSM_OVS_HOST_MEASUREMENT_SSH_USER "root"
    hm_resolve_setting HM_HOST_USER NSM_OVS_HOST_MEASUREMENT_HOST_USER "nsmovs-measure"
    hm_resolve_setting HM_STAGE_DIR NSM_OVS_HOST_MEASUREMENT_STAGE_DIR "/var/tmp/nsm-ovs-host-measurement"
    hm_resolve_setting HM_INSTALL_PREFIX NSM_OVS_HOST_MEASUREMENT_INSTALL_PREFIX "/opt/nsm-ovs/measurement"
    hm_resolve_setting HM_CONFIG_ROOT NSM_OVS_HOST_MEASUREMENT_CONFIG_ROOT "/etc/nsm-ovs/measurement"
    hm_resolve_setting HM_DATA_ROOT NSM_OVS_HOST_MEASUREMENT_DATA_ROOT "/var/lib/nsm-ovs/measurement"
    hm_resolve_setting HM_SERVICE_PREFIX NSM_OVS_HOST_MEASUREMENT_SERVICE_PREFIX "nsm-ovs-measure"
    hm_resolve_setting HM_GHPROXY_PREFIX NSM_OVS_HOST_MEASUREMENT_GHPROXY_PREFIX "https://gh-proxy.com/"
    hm_resolve_setting HM_CATEGRAF_VERSION NSM_OVS_HOST_MEASUREMENT_CATEGRAF_VERSION "v0.4.36"
    hm_resolve_setting HM_CATEGRAF_RELEASE_URL NSM_OVS_HOST_MEASUREMENT_CATEGRAF_RELEASE_URL "https://github.com/flashcatcloud/categraf/releases/download/v0.4.36/categraf-v0.4.36-linux-amd64.tar.gz"
    hm_resolve_setting HM_N9E_VERSION NSM_OVS_HOST_MEASUREMENT_N9E_VERSION "v8.4.1"
    hm_resolve_setting HM_N9E_RELEASE_URL NSM_OVS_HOST_MEASUREMENT_N9E_RELEASE_URL "https://github.com/ccfos/nightingale/releases/download/v8.4.1/n9e-v8.4.1-linux-amd64.tar.gz"
    hm_resolve_setting HM_VM_VERSION NSM_OVS_HOST_MEASUREMENT_VM_VERSION "v1.133.0"
    hm_resolve_setting HM_VM_RELEASE_URL NSM_OVS_HOST_MEASUREMENT_VM_RELEASE_URL "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v1.133.0/victoria-metrics-linux-amd64-v1.133.0.tar.gz"
    hm_resolve_setting HM_VM_RETENTION NSM_OVS_HOST_MEASUREMENT_VM_RETENTION "30d"
    hm_resolve_setting HM_VM_LISTEN_HOST NSM_OVS_HOST_MEASUREMENT_VM_LISTEN_HOST "127.0.0.1"
    hm_resolve_setting HM_VM_LISTEN_PORT NSM_OVS_HOST_MEASUREMENT_VM_LISTEN_PORT "18428"
    hm_resolve_setting HM_VM_TUNNEL_LOCAL_PORT NSM_OVS_HOST_MEASUREMENT_VM_TUNNEL_LOCAL_PORT "18430"
    hm_resolve_setting HM_N9E_LISTEN_HOST NSM_OVS_HOST_MEASUREMENT_N9E_LISTEN_HOST "0.0.0.0"
    hm_resolve_setting HM_N9E_LISTEN_PORT NSM_OVS_HOST_MEASUREMENT_N9E_LISTEN_PORT "17000"
    hm_resolve_setting HM_CATEGRAF_LISTEN_HOST NSM_OVS_HOST_MEASUREMENT_CATEGRAF_LISTEN_HOST "127.0.0.1"
    hm_resolve_setting HM_CATEGRAF_LISTEN_PORT NSM_OVS_HOST_MEASUREMENT_CATEGRAF_LISTEN_PORT "19100"
    hm_resolve_setting HM_PCM_METRICS_URL NSM_OVS_HOST_MEASUREMENT_PCM_METRICS_URL "http://127.0.0.1:9738/metrics"
    hm_resolve_setting HM_KUBE_PROXY_METRICS_URL NSM_OVS_HOST_MEASUREMENT_KUBE_PROXY_METRICS_URL "http://127.0.0.1:10249/metrics"
    hm_resolve_setting HM_ENABLE_PCM NSM_OVS_HOST_MEASUREMENT_ENABLE_PCM "1"
    hm_resolve_setting HM_ENABLE_PCM_WATCHDOG NSM_OVS_HOST_MEASUREMENT_ENABLE_PCM_WATCHDOG "1"
    hm_resolve_setting HM_PCM_SENSOR_SERVICE_NAME NSM_OVS_HOST_MEASUREMENT_PCM_SENSOR_SERVICE_NAME "pcm-sensor-server.service"
    hm_resolve_setting HM_PCM_WATCHDOG_INTERVAL_SEC NSM_OVS_HOST_MEASUREMENT_PCM_WATCHDOG_INTERVAL_SEC "5"
    hm_resolve_setting HM_PCM_WATCHDOG_CURL_TIMEOUT_SEC NSM_OVS_HOST_MEASUREMENT_PCM_WATCHDOG_CURL_TIMEOUT_SEC "3"
    hm_resolve_setting HM_PCM_WATCHDOG_FAILURE_THRESHOLD NSM_OVS_HOST_MEASUREMENT_PCM_WATCHDOG_FAILURE_THRESHOLD "1"
    hm_resolve_setting HM_PCM_WATCHDOG_RECOVERY_TIMEOUT_SEC NSM_OVS_HOST_MEASUREMENT_PCM_WATCHDOG_RECOVERY_TIMEOUT_SEC "20"
    hm_resolve_setting HM_PCM_WATCHDOG_GRACE_SEC NSM_OVS_HOST_MEASUREMENT_PCM_WATCHDOG_GRACE_SEC "15"
    hm_resolve_setting HM_ENABLE_PCM_L1 NSM_OVS_HOST_MEASUREMENT_ENABLE_PCM_L1 "1"
    hm_resolve_setting HM_PCM_L1_LISTEN_HOST NSM_OVS_HOST_MEASUREMENT_PCM_L1_LISTEN_HOST "127.0.0.1"
    hm_resolve_setting HM_PCM_L1_LISTEN_PORT NSM_OVS_HOST_MEASUREMENT_PCM_L1_LISTEN_PORT "9748"
    hm_resolve_setting HM_PCM_L1_SAMPLE_INTERVAL_SEC NSM_OVS_HOST_MEASUREMENT_PCM_L1_SAMPLE_INTERVAL_SEC "5"
    hm_resolve_setting HM_PCM_L1_TIMEOUT_SEC NSM_OVS_HOST_MEASUREMENT_PCM_L1_TIMEOUT_SEC "15"
    hm_resolve_setting HM_PCM_CORE_BIN NSM_OVS_HOST_MEASUREMENT_PCM_CORE_BIN "/opt/intel-pcm/bin/pcm-core"
    hm_resolve_setting HM_PCM_L1_EVENT_SPEC NSM_OVS_HOST_MEASUREMENT_PCM_L1_EVENT_SPEC "cpu/umask=0x08,event=0xd1,name=MEM_LOAD_RETIRED.L1_MISS/"
    hm_resolve_setting HM_PCM_L1_METRIC_NAME NSM_OVS_HOST_MEASUREMENT_PCM_L1_METRIC_NAME "pcm_mem_load_retired_l1_miss_interval_count"
    hm_resolve_setting HM_PCM_L1_HIT_EVENT_SPEC NSM_OVS_HOST_MEASUREMENT_PCM_L1_HIT_EVENT_SPEC "cpu/umask=0x01,event=0xd1,name=MEM_LOAD_RETIRED.L1_HIT/"
    hm_resolve_setting HM_PCM_L1_HIT_METRIC_NAME NSM_OVS_HOST_MEASUREMENT_PCM_L1_HIT_METRIC_NAME "pcm_mem_load_retired_l1_hit_interval_count"
    hm_resolve_setting HM_PCM_L1_JOB_NAME NSM_OVS_HOST_MEASUREMENT_PCM_L1_JOB_NAME "pcm-core-l1"
    hm_resolve_setting HM_ENABLE_KUBE_PROXY NSM_OVS_HOST_MEASUREMENT_ENABLE_KUBE_PROXY "1"
    hm_resolve_setting HM_TZ NSM_OVS_HOST_MEASUREMENT_TZ "Asia/Shanghai"
    hm_resolve_setting HM_CLUSTER_AUTH_NAMESPACE NSM_OVS_HOST_MEASUREMENT_CLUSTER_AUTH_NAMESPACE "flashcat"
    hm_resolve_setting HM_CLUSTER_AUTH_SERVICE_ACCOUNT NSM_OVS_HOST_MEASUREMENT_CLUSTER_AUTH_SERVICE_ACCOUNT "categraf-daemonset"
    hm_resolve_setting HM_CLUSTER_AUTH_TOKEN_SECRET NSM_OVS_HOST_MEASUREMENT_CLUSTER_AUTH_TOKEN_SECRET "categraf-daemonset-secret"
    hm_resolve_setting HM_KUBE_STATE_METRICS_NAMESPACE NSM_OVS_HOST_MEASUREMENT_KUBE_STATE_METRICS_NAMESPACE "kube-system"
    hm_resolve_setting HM_KUBE_STATE_METRICS_SERVICE NSM_OVS_HOST_MEASUREMENT_KUBE_STATE_METRICS_SERVICE "kube-state-metrics"

    HM_SSH_TARGET_REF="${HM_SSH_TARGET}"
    if [[ "${HM_SSH_TARGET_REF}" != *@* && -n "${HM_SSH_USER}" ]]; then
        HM_SSH_TARGET_REF="${HM_SSH_USER}@${HM_SSH_TARGET}"
    fi
    export HM_SSH_TARGET_REF

    HM_VMSINGLE_SERVICE_NAME="${HM_SERVICE_PREFIX}-vmsingle"
    HM_N9E_SERVICE_NAME="${HM_SERVICE_PREFIX}-n9e"
    HM_CATEGRAF_SERVICE_NAME="${HM_SERVICE_PREFIX}-categraf"
    HM_PCM_WATCHDOG_SERVICE_NAME="${HM_SERVICE_PREFIX}-pcm-sensor-watchdog"
    HM_PCM_L1_SERVICE_NAME="${HM_SERVICE_PREFIX}-pcm-core-l1"
    export HM_VMSINGLE_SERVICE_NAME HM_N9E_SERVICE_NAME HM_CATEGRAF_SERVICE_NAME HM_PCM_WATCHDOG_SERVICE_NAME HM_PCM_L1_SERVICE_NAME

    HM_VMSINGLE_LISTEN_ADDR="${HM_VM_LISTEN_HOST}:${HM_VM_LISTEN_PORT}"
    HM_N9E_LISTEN_ADDR="${HM_N9E_LISTEN_HOST}:${HM_N9E_LISTEN_PORT}"
    HM_N9E_LOCAL_ADDR="127.0.0.1:${HM_N9E_LISTEN_PORT}"
    HM_CATEGRAF_HTTP_ADDR="${HM_CATEGRAF_LISTEN_HOST}:${HM_CATEGRAF_LISTEN_PORT}"
    HM_PCM_L1_LISTEN_ADDR="${HM_PCM_L1_LISTEN_HOST}:${HM_PCM_L1_LISTEN_PORT}"
    HM_N9E_REMOTE_WRITE_URL="http://${HM_N9E_LOCAL_ADDR}/prometheus/v1/write"
    HM_VM_REMOTE_WRITE_URL="http://${HM_VMSINGLE_LISTEN_ADDR}/api/v1/write"
    HM_PCM_L1_METRICS_URL="http://${HM_PCM_L1_LISTEN_ADDR}/metrics"
    HM_PCM_L1_HEALTH_URL="http://${HM_PCM_L1_LISTEN_ADDR}/healthz"
    HM_PCM_L1_INSTALL_DIR="${HM_INSTALL_PREFIX}/pcm-core-l1"
    HM_PCM_L1_SCRIPT_PATH="${HM_PCM_L1_INSTALL_DIR}/pcm_core_l1_exporter.py"
    HM_PCM_L1_CONFIG_DIR="${HM_CONFIG_ROOT}/pcm-core-l1"
    HM_PCM_L1_ENV_FILE="${HM_PCM_L1_CONFIG_DIR}/exporter.env"
    HM_PCM_L1_DATA_DIR="${HM_DATA_ROOT}/pcm-core-l1"
    HM_PCM_WATCHDOG_INSTALL_DIR="${HM_INSTALL_PREFIX}/pcm-sensor-watchdog"
    HM_PCM_WATCHDOG_SCRIPT_PATH="${HM_PCM_WATCHDOG_INSTALL_DIR}/pcm_sensor_watchdog.sh"
    HM_PCM_WATCHDOG_CONFIG_DIR="${HM_CONFIG_ROOT}/pcm-sensor-watchdog"
    HM_PCM_WATCHDOG_ENV_FILE="${HM_PCM_WATCHDOG_CONFIG_DIR}/watchdog.env"
    HM_PCM_WATCHDOG_DATA_DIR="${HM_DATA_ROOT}/pcm-sensor-watchdog"
    HM_CATEGRAF_CREDENTIALS_DIR="${HM_CONFIG_ROOT}/categraf/credentials"
    HM_CATEGRAF_BEARER_TOKEN_FILE="${HM_CATEGRAF_CREDENTIALS_DIR}/flashcat-categraf-daemonset.token"
    HM_KUBELET_JOB_NAME="kubelet"
    HM_CADVISOR_JOB_NAME="cadvisor"
    HM_KUBE_STATE_METRICS_JOB_NAME="kube-state-metrics"
    HM_KUBE_STATE_METRICS_SELF_JOB_NAME="kube-state-metrics-self"
    export HM_VMSINGLE_LISTEN_ADDR HM_N9E_LISTEN_ADDR HM_N9E_LOCAL_ADDR HM_CATEGRAF_HTTP_ADDR HM_PCM_L1_LISTEN_ADDR HM_N9E_REMOTE_WRITE_URL HM_VM_REMOTE_WRITE_URL
    export HM_PCM_L1_METRICS_URL HM_PCM_L1_HEALTH_URL HM_PCM_L1_INSTALL_DIR HM_PCM_L1_SCRIPT_PATH HM_PCM_L1_CONFIG_DIR HM_PCM_L1_ENV_FILE HM_PCM_L1_DATA_DIR
    export HM_PCM_WATCHDOG_INSTALL_DIR HM_PCM_WATCHDOG_SCRIPT_PATH HM_PCM_WATCHDOG_CONFIG_DIR HM_PCM_WATCHDOG_ENV_FILE HM_PCM_WATCHDOG_DATA_DIR
    export HM_CATEGRAF_CREDENTIALS_DIR HM_CATEGRAF_BEARER_TOKEN_FILE HM_KUBELET_JOB_NAME HM_CADVISOR_JOB_NAME HM_KUBE_STATE_METRICS_JOB_NAME HM_KUBE_STATE_METRICS_SELF_JOB_NAME

    HM_CLUSTER_TARGETS_DISCOVERED=0
}

hm_require_local_commands() {
    local cmd
    for cmd in ssh scp mktemp jq curl sha256sum kubectl base64; do
        require_command "${cmd}"
    done
}

hm_write_command_file() {
    local output_file=$1
    shift

    {
        printf 'cwd=%s\n' "$(pwd)"
        printf 'command='
        printf '%q ' "$@"
        printf '\n'
    } > "${output_file}"
}

hm_now_stamp() {
    date '+%Y%m%d-%H%M%S'
}

hm_make_state_dir() {
    local label=$1
    local dir="${HOST_MEASUREMENT_REPO_ROOT}/state/host-measurement/${HM_SSH_TARGET}/${label}-$(hm_now_stamp)"
    mkdir -p "${dir}"
    printf '%s\n' "${dir}"
}

hm_make_artifact_dir() {
    local label=$1
    local dir="${HOST_MEASUREMENT_REPO_ROOT}/artifacts/validation/${label}-$(hm_now_stamp)"
    mkdir -p "${dir}"
    printf '%s\n' "${dir}"
}

hm_render_template_file() {
    local src=$1
    local dst=$2
    shift 2
    local key value escaped

    cp "${src}" "${dst}"
    while [[ $# -gt 0 ]]; do
        key=$1
        value=$2
        shift 2
        escaped="${value//\\/\\\\}"
        escaped="${escaped//&/\\&}"
        escaped="${escaped//|/\\|}"
        sed -i "s|@${key}@|${escaped}|g" "${dst}"
    done
}

hm_append_categraf_prometheus_comment() {
    local output_file=$1
    local comment=$2

    printf '# %s\n\n' "${comment}" >> "${output_file}"
}

hm_append_categraf_prometheus_instance() {
    local output_file=$1
    local urls_toml=$2
    local job_name=$3
    local url_label_value=$4
    local bearer_token_file=${5:-}
    local use_tls=${6:-false}
    local insecure_skip_verify=${7:-false}

    cat >> "${output_file}" <<EOF
[[instances]]
urls = ${urls_toml}
EOF
    if [[ -n "${bearer_token_file}" ]]; then
        printf 'bearer_token_file = "%s"\n' "${bearer_token_file}" >> "${output_file}"
    fi
    if [[ "${use_tls}" == "true" ]]; then
        printf 'use_tls = true\n' >> "${output_file}"
    fi
    if [[ "${insecure_skip_verify}" == "true" ]]; then
        printf 'insecure_skip_verify = true\n' >> "${output_file}"
    fi
    cat >> "${output_file}" <<EOF
url_label_key = "instance"
url_label_value = "${url_label_value}"
labels = { job = "${job_name}" }

EOF
}

hm_stage_categraf_credentials() {
    local target_root=$1
    local token_file="${target_root}/$(basename "${HM_CATEGRAF_BEARER_TOKEN_FILE}")"

    hm_discover_cluster_targets
    install -d "${target_root}"
    if [[ "${HM_CATEGRAF_CLUSTER_TOKEN_AVAILABLE}" == "1" && -n "${HM_CATEGRAF_CLUSTER_TOKEN_VALUE}" ]]; then
        printf '%s\n' "${HM_CATEGRAF_CLUSTER_TOKEN_VALUE}" > "${token_file}"
        chmod 0600 "${token_file}"
    fi
}

hm_write_categraf_prometheus_config() {
    local output_file=$1

    hm_discover_cluster_targets

    : > "${output_file}"
    if [[ "${HM_ENABLE_PCM}" == "1" ]]; then
        hm_append_categraf_prometheus_instance \
            "${output_file}" \
            "[\"${HM_PCM_METRICS_URL}\"]" \
            "pcm-sensor-server" \
            "{{.Host}}"
    fi

    if [[ "${HM_ENABLE_PCM_L1}" == "1" ]]; then
        hm_append_categraf_prometheus_instance \
            "${output_file}" \
            "[\"${HM_PCM_L1_METRICS_URL}\"]" \
            "${HM_PCM_L1_JOB_NAME}" \
            "{{.Host}}"
    fi

    if [[ "${HM_ENABLE_KUBE_PROXY}" == "1" ]]; then
        hm_append_categraf_prometheus_instance \
            "${output_file}" \
            "[\"${HM_KUBE_PROXY_METRICS_URL}\"]" \
            "kube-proxy" \
            "{{.Host}}"
    fi

    if [[ -n "${HM_KUBELET_PROXY_METRICS_URL}" ]]; then
        hm_append_categraf_prometheus_instance \
            "${output_file}" \
            "[\"${HM_KUBELET_PROXY_METRICS_URL}\"]" \
            "${HM_KUBELET_JOB_NAME}" \
            "${HM_REMOTE_NODE_NAME}" \
            "${HM_CATEGRAF_BEARER_TOKEN_FILE}" \
            true \
            true
    else
        hm_append_categraf_prometheus_comment "${output_file}" "${HM_KUBELET_JOB_NAME} omitted: ${HM_KUBELET_DISCOVERY_BLOCKER}"
    fi

    if [[ -n "${HM_CADVISOR_PROXY_METRICS_URL}" ]]; then
        hm_append_categraf_prometheus_instance \
            "${output_file}" \
            "[\"${HM_CADVISOR_PROXY_METRICS_URL}\"]" \
            "${HM_CADVISOR_JOB_NAME}" \
            "${HM_REMOTE_NODE_NAME}" \
            "${HM_CATEGRAF_BEARER_TOKEN_FILE}" \
            true \
            true
    else
        hm_append_categraf_prometheus_comment "${output_file}" "${HM_CADVISOR_JOB_NAME} omitted: ${HM_CADVISOR_DISCOVERY_BLOCKER}"
    fi

    if [[ "${HM_KSM_METRICS_URLS_TOML}" != "[]" ]]; then
        hm_append_categraf_prometheus_instance \
            "${output_file}" \
            "${HM_KSM_METRICS_URLS_TOML}" \
            "${HM_KUBE_STATE_METRICS_JOB_NAME}" \
            "{{.Host}}"
    else
        hm_append_categraf_prometheus_comment "${output_file}" "${HM_KUBE_STATE_METRICS_JOB_NAME} omitted: ${HM_KSM_DISCOVERY_BLOCKER}"
    fi

    if [[ "${HM_KSM_SELF_METRICS_URLS_TOML}" != "[]" ]]; then
        hm_append_categraf_prometheus_instance \
            "${output_file}" \
            "${HM_KSM_SELF_METRICS_URLS_TOML}" \
            "${HM_KUBE_STATE_METRICS_SELF_JOB_NAME}" \
            "{{.Host}}"
    else
        hm_append_categraf_prometheus_comment "${output_file}" "${HM_KUBE_STATE_METRICS_SELF_JOB_NAME} omitted: ${HM_KSM_SELF_DISCOVERY_BLOCKER}"
    fi
}

hm_copy_input_templates() {
    local target_root=$1

    install -d "${target_root}/input.cpu" \
        "${target_root}/input.disk" \
        "${target_root}/input.diskio" \
        "${target_root}/input.kernel" \
        "${target_root}/input.kernel_vmstat" \
        "${target_root}/input.linux_sysctl_fs" \
        "${target_root}/input.mem" \
        "${target_root}/input.net" \
        "${target_root}/input.netstat" \
        "${target_root}/input.processes" \
        "${target_root}/input.prometheus" \
        "${target_root}/input.system"

    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/cpu.toml" "${target_root}/input.cpu/cpu.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/disk.toml" "${target_root}/input.disk/disk.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/diskio.toml" "${target_root}/input.diskio/diskio.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/kernel.toml" "${target_root}/input.kernel/kernel.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/kernel_vmstat.toml" "${target_root}/input.kernel_vmstat/kernel_vmstat.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/linux_sysctl_fs.toml" "${target_root}/input.linux_sysctl_fs/linux_sysctl_fs.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/mem.toml" "${target_root}/input.mem/mem.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/net.toml" "${target_root}/input.net/net.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/netstat.toml" "${target_root}/input.netstat/netstat.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/processes.toml" "${target_root}/input.processes/processes.toml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/inputs/system.toml" "${target_root}/input.system/system.toml"
    hm_write_categraf_prometheus_config "${target_root}/input.prometheus/prometheus.toml"
}

hm_remote_url_candidates() {
    local url=$1

    printf '%s\n' "${url}"
    if [[ "${url}" == https://github.com/* && -n "${HM_GHPROXY_PREFIX}" ]]; then
        printf '%s%s\n' "${HM_GHPROXY_PREFIX%/}/" "${url}"
    fi
}

hm_render_payload() {
    local payload_root=$1
    local categraf_root="${payload_root}/categraf/conf"
    local categraf_credentials_root="${payload_root}/categraf/credentials"
    local n9e_root="${payload_root}/n9e"
    local pcm_watchdog_root="${payload_root}/pcm-sensor-watchdog"
    local pcm_l1_root="${payload_root}/pcm-core-l1"
    local systemd_root="${payload_root}/systemd"
    local categraf_exec_start="${HM_INSTALL_PREFIX}/categraf/current/categraf --configs ${HM_CONFIG_ROOT}/categraf/conf"

    hm_discover_cluster_targets
    install -d "${categraf_root}" "${categraf_credentials_root}" "${n9e_root}" "${pcm_watchdog_root}" "${pcm_l1_root}" "${systemd_root}"

    hm_render_template_file \
        "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/config.toml.tpl" \
        "${categraf_root}/config.toml" \
        HOSTNAME "${HM_SSH_TARGET}" \
        CATEGRAF_HTTP_ADDRESS "${HM_CATEGRAF_HTTP_ADDR}" \
        N9E_REMOTE_WRITE_URL "${HM_N9E_REMOTE_WRITE_URL}"
    hm_copy_input_templates "${categraf_root}"
    hm_stage_categraf_credentials "${categraf_credentials_root}"

    hm_render_template_file \
        "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/categraf/systemd/nsm-ovs-measure-categraf.service.tpl" \
        "${systemd_root}/${HM_CATEGRAF_SERVICE_NAME}.service" \
        N9E_SERVICE_NAME "${HM_N9E_SERVICE_NAME}" \
        HOST_USER "${HM_HOST_USER}" \
        CATEGRAF_WORKDIR "${HM_CONFIG_ROOT}/categraf" \
        TZ "${HM_TZ}" \
        CATEGRAF_EXEC_START "${categraf_exec_start}"

    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/pcm-sensor-watchdog/pcm_sensor_watchdog.sh" "${pcm_watchdog_root}/pcm_sensor_watchdog.sh"
    chmod 0755 "${pcm_watchdog_root}/pcm_sensor_watchdog.sh"

    hm_render_template_file \
        "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/pcm-sensor-watchdog/watchdog.env.tpl" \
        "${pcm_watchdog_root}/watchdog.env" \
        PCM_SENSOR_SERVICE_NAME "${HM_PCM_SENSOR_SERVICE_NAME}" \
        PCM_METRICS_URL "${HM_PCM_METRICS_URL}" \
        PCM_WATCHDOG_INTERVAL_SEC "${HM_PCM_WATCHDOG_INTERVAL_SEC}" \
        PCM_WATCHDOG_CURL_TIMEOUT_SEC "${HM_PCM_WATCHDOG_CURL_TIMEOUT_SEC}" \
        PCM_WATCHDOG_FAILURE_THRESHOLD "${HM_PCM_WATCHDOG_FAILURE_THRESHOLD}" \
        PCM_WATCHDOG_RECOVERY_TIMEOUT_SEC "${HM_PCM_WATCHDOG_RECOVERY_TIMEOUT_SEC}" \
        PCM_WATCHDOG_GRACE_SEC "${HM_PCM_WATCHDOG_GRACE_SEC}"

    hm_render_template_file \
        "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/pcm-sensor-watchdog/systemd/nsm-ovs-measure-pcm-sensor-watchdog.service.tpl" \
        "${systemd_root}/${HM_PCM_WATCHDOG_SERVICE_NAME}.service" \
        TZ "${HM_TZ}" \
        PCM_WATCHDOG_SCRIPT_PATH "${HM_PCM_WATCHDOG_SCRIPT_PATH}" \
        PCM_WATCHDOG_ENV_FILE "${HM_PCM_WATCHDOG_ENV_FILE}" \
        PCM_WATCHDOG_WORKDIR "${HM_PCM_WATCHDOG_DATA_DIR}"

    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/pcm-core-l1/pcm_core_l1_exporter.py" "${pcm_l1_root}/pcm_core_l1_exporter.py"
    chmod 0755 "${pcm_l1_root}/pcm_core_l1_exporter.py"

    hm_render_template_file \
        "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/pcm-core-l1/exporter.env.tpl" \
        "${pcm_l1_root}/exporter.env" \
        PCM_CORE_BIN "${HM_PCM_CORE_BIN}" \
        PCM_L1_MISS_EVENT_SPEC "${HM_PCM_L1_EVENT_SPEC}" \
        PCM_L1_MISS_METRIC_NAME "${HM_PCM_L1_METRIC_NAME}" \
        PCM_L1_HIT_EVENT_SPEC "${HM_PCM_L1_HIT_EVENT_SPEC}" \
        PCM_L1_HIT_METRIC_NAME "${HM_PCM_L1_HIT_METRIC_NAME}" \
        PCM_LISTEN_HOST "${HM_PCM_L1_LISTEN_HOST}" \
        PCM_LISTEN_PORT "${HM_PCM_L1_LISTEN_PORT}" \
        PCM_SAMPLE_INTERVAL_SEC "${HM_PCM_L1_SAMPLE_INTERVAL_SEC}" \
        PCM_TIMEOUT_SEC "${HM_PCM_L1_TIMEOUT_SEC}"

    hm_render_template_file \
        "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/pcm-core-l1/systemd/nsm-ovs-measure-pcm-core-l1.service.tpl" \
        "${systemd_root}/${HM_PCM_L1_SERVICE_NAME}.service" \
        PCM_L1_SCRIPT_PATH "${HM_PCM_L1_SCRIPT_PATH}" \
        PCM_L1_ENV_FILE "${HM_PCM_L1_ENV_FILE}" \
        PCM_L1_WORKDIR "${HM_PCM_L1_DATA_DIR}" \
        TZ "${HM_TZ}"

    hm_render_template_file \
        "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/n9e/config.toml.tpl" \
        "${n9e_root}/config.toml" \
        N9E_HTTP_HOST "${HM_N9E_LISTEN_HOST}" \
        N9E_HTTP_PORT "${HM_N9E_LISTEN_PORT}" \
        N9E_DB_DSN "${HM_DATA_ROOT}/n9e/n9e.db" \
        N9E_METRICS_YAML "${HM_CONFIG_ROOT}/n9e/metrics.yaml" \
        VM_REMOTE_WRITE_URL "${HM_VM_REMOTE_WRITE_URL}"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/n9e/metrics.yaml" "${n9e_root}/metrics.yaml"
    cp "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/n9e/ops.yaml" "${n9e_root}/ops.yaml"

    hm_render_template_file \
        "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/n9e/systemd/nsm-ovs-measure-n9e.service.tpl" \
        "${systemd_root}/${HM_N9E_SERVICE_NAME}.service" \
        VM_SERVICE_NAME "${HM_VMSINGLE_SERVICE_NAME}" \
        HOST_USER "${HM_HOST_USER}" \
        N9E_WORKDIR "${HM_DATA_ROOT}/n9e" \
        TZ "${HM_TZ}" \
        N9E_BIN "${HM_INSTALL_PREFIX}/n9e/current/n9e" \
        N9E_CONFIG_DIR "${HM_CONFIG_ROOT}/n9e"

    hm_render_template_file \
        "${HOST_MEASUREMENT_REPO_ROOT}/assets/measurement/host/victoriametrics/systemd/nsm-ovs-measure-vmsingle.service.tpl" \
        "${systemd_root}/${HM_VMSINGLE_SERVICE_NAME}.service" \
        HOST_USER "${HM_HOST_USER}" \
        VM_WORKDIR "${HM_DATA_ROOT}/victoriametrics" \
        TZ "${HM_TZ}" \
        VM_BIN "${HM_INSTALL_PREFIX}/victoriametrics/current/victoria-metrics-prod" \
        VM_DATA_DIR "${HM_DATA_ROOT}/victoriametrics" \
        VM_LISTEN_ADDR "${HM_VMSINGLE_LISTEN_ADDR}" \
        VM_RETENTION "${HM_VM_RETENTION}"
}

hm_write_resolved_env() {
    local output_file=$1

    hm_discover_cluster_targets

    cat > "${output_file}" <<EOF
env_file=${HM_ENV_FILE}
ssh_target=${HM_SSH_TARGET}
ssh_user=${HM_SSH_USER}
ssh_target_ref=${HM_SSH_TARGET_REF}
host_user=${HM_HOST_USER}
stage_dir=${HM_STAGE_DIR}
install_prefix=${HM_INSTALL_PREFIX}
config_root=${HM_CONFIG_ROOT}
data_root=${HM_DATA_ROOT}
service_prefix=${HM_SERVICE_PREFIX}
ghproxy_prefix=${HM_GHPROXY_PREFIX}
categraf_version=${HM_CATEGRAF_VERSION}
categraf_release_url=${HM_CATEGRAF_RELEASE_URL}
n9e_version=${HM_N9E_VERSION}
n9e_release_url=${HM_N9E_RELEASE_URL}
vm_version=${HM_VM_VERSION}
vm_release_url=${HM_VM_RELEASE_URL}
vm_retention=${HM_VM_RETENTION}
vm_listen_addr=${HM_VMSINGLE_LISTEN_ADDR}
n9e_listen_addr=${HM_N9E_LISTEN_ADDR}
n9e_local_addr=${HM_N9E_LOCAL_ADDR}
categraf_http_addr=${HM_CATEGRAF_HTTP_ADDR}
pcm_metrics_url=${HM_PCM_METRICS_URL}
kube_proxy_metrics_url=${HM_KUBE_PROXY_METRICS_URL}
enable_pcm=${HM_ENABLE_PCM}
enable_pcm_watchdog=${HM_ENABLE_PCM_WATCHDOG}
pcm_sensor_service_name=${HM_PCM_SENSOR_SERVICE_NAME}
pcm_watchdog_service_name=${HM_PCM_WATCHDOG_SERVICE_NAME}
pcm_watchdog_interval_sec=${HM_PCM_WATCHDOG_INTERVAL_SEC}
pcm_watchdog_curl_timeout_sec=${HM_PCM_WATCHDOG_CURL_TIMEOUT_SEC}
pcm_watchdog_failure_threshold=${HM_PCM_WATCHDOG_FAILURE_THRESHOLD}
pcm_watchdog_recovery_timeout_sec=${HM_PCM_WATCHDOG_RECOVERY_TIMEOUT_SEC}
pcm_watchdog_grace_sec=${HM_PCM_WATCHDOG_GRACE_SEC}
pcm_watchdog_script_path=${HM_PCM_WATCHDOG_SCRIPT_PATH}
pcm_watchdog_env_file=${HM_PCM_WATCHDOG_ENV_FILE}
pcm_watchdog_data_dir=${HM_PCM_WATCHDOG_DATA_DIR}
enable_pcm_l1=${HM_ENABLE_PCM_L1}
pcm_l1_service_name=${HM_PCM_L1_SERVICE_NAME}
pcm_l1_listen_addr=${HM_PCM_L1_LISTEN_ADDR}
pcm_l1_metrics_url=${HM_PCM_L1_METRICS_URL}
pcm_l1_health_url=${HM_PCM_L1_HEALTH_URL}
pcm_l1_sample_interval_sec=${HM_PCM_L1_SAMPLE_INTERVAL_SEC}
pcm_l1_timeout_sec=${HM_PCM_L1_TIMEOUT_SEC}
pcm_l1_miss_metric_name=${HM_PCM_L1_METRIC_NAME}
pcm_l1_hit_metric_name=${HM_PCM_L1_HIT_METRIC_NAME}
pcm_l1_job_name=${HM_PCM_L1_JOB_NAME}
pcm_core_bin=${HM_PCM_CORE_BIN}
pcm_l1_miss_event_spec=${HM_PCM_L1_EVENT_SPEC}
pcm_l1_hit_event_spec=${HM_PCM_L1_HIT_EVENT_SPEC}
pcm_l1_script_path=${HM_PCM_L1_SCRIPT_PATH}
pcm_l1_env_file=${HM_PCM_L1_ENV_FILE}
pcm_l1_data_dir=${HM_PCM_L1_DATA_DIR}
enable_kube_proxy=${HM_ENABLE_KUBE_PROXY}
tz=${HM_TZ}
vm_service_name=${HM_VMSINGLE_SERVICE_NAME}
n9e_service_name=${HM_N9E_SERVICE_NAME}
categraf_service_name=${HM_CATEGRAF_SERVICE_NAME}
n9e_remote_write_url=${HM_N9E_REMOTE_WRITE_URL}
vm_remote_write_url=${HM_VM_REMOTE_WRITE_URL}
remote_node_name=${HM_REMOTE_NODE_NAME}
remote_node_name_source=${HM_REMOTE_NODE_NAME_SOURCE}
apiserver_url=${HM_APISERVER_URL}
apiserver_source=${HM_APISERVER_SOURCE}
cluster_auth_namespace=${HM_CLUSTER_AUTH_NAMESPACE}
cluster_auth_service_account=${HM_CLUSTER_AUTH_SERVICE_ACCOUNT}
cluster_auth_token_secret=${HM_CLUSTER_AUTH_TOKEN_SECRET}
categraf_bearer_token_file=${HM_CATEGRAF_BEARER_TOKEN_FILE}
cluster_auth_token_available=${HM_CATEGRAF_CLUSTER_TOKEN_AVAILABLE}
cluster_auth_token_blocker=${HM_CATEGRAF_CLUSTER_TOKEN_BLOCKER}
kubelet_proxy_metrics_url=${HM_KUBELET_PROXY_METRICS_URL}
kubelet_discovery_blocker=${HM_KUBELET_DISCOVERY_BLOCKER}
cadvisor_proxy_metrics_url=${HM_CADVISOR_PROXY_METRICS_URL}
cadvisor_discovery_blocker=${HM_CADVISOR_DISCOVERY_BLOCKER}
kube_state_metrics_namespace=${HM_KUBE_STATE_METRICS_NAMESPACE}
kube_state_metrics_service=${HM_KUBE_STATE_METRICS_SERVICE}
kube_state_metrics_urls=${HM_KSM_METRICS_URLS_CSV}
kube_state_metrics_discovery_blocker=${HM_KSM_DISCOVERY_BLOCKER}
kube_state_metrics_self_urls=${HM_KSM_SELF_METRICS_URLS_CSV}
kube_state_metrics_self_discovery_blocker=${HM_KSM_SELF_DISCOVERY_BLOCKER}
EOF
}
