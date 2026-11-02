#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: install_node01_measurement_stack.sh [--env-file <path>] [--ssh-target <host>] [--ssh-user <user>] [--state-dir <dir>] [--print-summary]

Deploy the node01 host-managed measurement stack:
pcm-sensor-server (pre-existing) + categraf + n9e + local VictoriaMetrics single-node.
EOF
}

main() {
    local env_file="" state_dir="" print_summary=false
    local remote_stage payload_dir remote_env_file command_file resolved_env_file preflight_file rendered_env_file
    local remote_install_log remote_summary_env remote_summary_txt
    local -a original_args=("$@")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env-file)
                [[ $# -ge 2 ]] || die "missing value for --env-file"
                env_file=$2
                shift 2
                ;;
            --ssh-target)
                [[ $# -ge 2 ]] || die "missing value for --ssh-target"
                export NSM_OVS_HOST_MEASUREMENT_SSH_TARGET=$2
                shift 2
                ;;
            --ssh-user)
                [[ $# -ge 2 ]] || die "missing value for --ssh-user"
                export NSM_OVS_HOST_MEASUREMENT_SSH_USER=$2
                shift 2
                ;;
            --state-dir)
                [[ $# -ge 2 ]] || die "missing value for --state-dir"
                state_dir=$2
                shift 2
                ;;
            --print-summary)
                print_summary=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    hm_load_config "${env_file}"
    hm_require_local_commands

    [[ -n "${state_dir}" ]] || state_dir="$(hm_make_state_dir install-stack)"
    mkdir -p "${state_dir}"
    payload_dir="${state_dir}/payload"
    command_file="${state_dir}/command.txt"
    resolved_env_file="${state_dir}/resolved.env"
    preflight_file="${state_dir}/preflight.txt"
    rendered_env_file="${state_dir}/remote.env"
    remote_install_log="${state_dir}/remote-install.log"
    hm_write_command_file "${command_file}" "$0" "${original_args[@]}"
    hm_write_resolved_env "${resolved_env_file}"
    hm_render_payload "${payload_dir}"

    remote_stage="${HM_STAGE_DIR%/}/install-$(hm_now_stamp)"
    remote_env_file="${remote_stage}/remote.env"
    remote_summary_env="${remote_stage}/install-summary.env"
    remote_summary_txt="${remote_stage}/install-summary.txt"

    cat > "${rendered_env_file}" <<EOF
$(cat "${resolved_env_file}")
remote_stage=${remote_stage}
remote_summary_env=${remote_summary_env}
remote_summary_txt=${remote_summary_txt}
categraf_archive_name=categraf-${HM_CATEGRAF_VERSION}.tar.gz
n9e_archive_name=n9e-${HM_N9E_VERSION}.tar.gz
vm_archive_name=victoria-metrics-${HM_VM_VERSION}.tar.gz
EOF

    {
        printf 'ssh_target_ref=%s\n' "${HM_SSH_TARGET_REF}"
        printf 'state_dir=%s\n' "${state_dir}"
        printf 'remote_stage=%s\n' "${remote_stage}"
        printf '\n[remote-preflight]\n'
    } > "${preflight_file}"

    ssh "${HM_SSH_TARGET_REF}" "hostname; whoami; sudo -n true && echo sudo-ok; uname -m; command -v systemctl; command -v curl; command -v tar; command -v sha256sum; command -v useradd; command -v python3 || true; test -x '${HM_PCM_CORE_BIN}' && echo pcm-core-ok || true; printf '\n[ports]\n'; ss -ltn | grep -E ':9738|:9748|:10249|:17000|:18428|:19100|:8428' || true; printf '\n[pcm]\n'; curl -fsS ${HM_PCM_METRICS_URL} | sed -n '1,5p'; printf '\n[kube-proxy]\n'; curl -fsS ${HM_KUBE_PROXY_METRICS_URL} | sed -n '1,5p'; printf '\n[kubelet-http-status]\n'; curl -ksS -o /dev/null -w '%{http_code}\n' https://127.0.0.1:10250/metrics || true; printf '\n[cadvisor-http-status]\n'; curl -ksS -o /dev/null -w '%{http_code}\n' https://127.0.0.1:10250/metrics/cadvisor || true" >> "${preflight_file}" 2>&1

    log_info "preparing remote stage ${remote_stage} on ${HM_SSH_TARGET_REF}"
    ssh "${HM_SSH_TARGET_REF}" "rm -rf '${remote_stage}' && mkdir -p '${remote_stage}'"
    scp -r "${payload_dir}" "${HM_SSH_TARGET_REF}:${remote_stage}/payload" >/dev/null
    scp "${rendered_env_file}" "${HM_SSH_TARGET_REF}:${remote_env_file}" >/dev/null
    find "${payload_dir}/categraf/credentials" -type f -name '*.token' -delete 2>/dev/null || true

    log_info "installing host-managed measurement stack on ${HM_SSH_TARGET_REF}"
    ssh "${HM_SSH_TARGET_REF}" "sudo -n bash -s -- '${remote_stage}'" > "${remote_install_log}" 2>&1 <<'EOF'
set -euo pipefail

remote_stage=$1
source "${remote_stage}/remote.env"

die() {
    printf '[remote-install][ERROR] %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[remote-install] %s\n' "$*"
}

port_busy() {
    local port=$1
    ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)$port$"
}

download_with_fallback() {
    local label=$1
    local source_url=$2
    local output_file=$3
    local actual_url=""
    local candidate

    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        if curl -fL --retry 3 --connect-timeout 20 --max-time 300 -o "${output_file}" "${candidate}" >/dev/null 2>&1; then
            actual_url="${candidate}"
            break
        fi
    done < <(
        printf '%s\n' "${source_url}"
        if [[ "${source_url}" == https://github.com/* && -n "${ghproxy_prefix}" ]]; then
            printf '%s%s\n' "${ghproxy_prefix%/}/" "${source_url}"
        fi
    )

    [[ -n "${actual_url}" ]] || die "failed to download ${label} from ${source_url}"
    printf '%s' "${actual_url}"
}

extract_component() {
    local component=$1
    local version=$2
    local archive_file=$3
    local binary_name=$4
    local component_root="${install_prefix}/${component}"
    local release_dir="${component_root}/releases/${version}"
    local current_dir="${component_root}/current"
    local current_release_link="${component_root}/current-release"
    local binary_path=""

    rm -rf "${release_dir}" "${current_dir}"
    mkdir -p "${release_dir}" "${current_dir}"
    tar -xzf "${archive_file}" -C "${release_dir}"
    binary_path="$(find "${release_dir}" -type f -name "${binary_name}" | head -n 1)"
    [[ -n "${binary_path}" ]] || die "failed to discover ${binary_name} in ${archive_file}"
    ln -sfn "${release_dir}" "${current_release_link}"
    ln -sfn "${binary_path}" "${current_dir}/${binary_name}"
    printf '%s\n' "${binary_path}"
}

reuse_component_binary() {
    local component=$1
    local version=$2
    local binary_name=$3
    local component_root="${install_prefix}/${component}"
    local release_dir="${component_root}/releases/${version}"
    local current_dir="${component_root}/current"
    local current_release_link="${component_root}/current-release"
    local binary_path=""

    [[ -d "${release_dir}" ]] || return 1
    binary_path="$(find "${release_dir}" -type f -name "${binary_name}" | head -n 1)"
    [[ -n "${binary_path}" ]] || return 1
    rm -rf "${current_dir}"
    mkdir -p "${current_dir}"
    ln -sfn "${release_dir}" "${current_release_link}"
    ln -sfn "${binary_path}" "${current_dir}/${binary_name}"
    printf '%s\n' "${binary_path}"
}

download_root="${remote_stage}/downloads"
mkdir -p "${download_root}"

for service in "${pcm_watchdog_service_name}" "${pcm_l1_service_name}" "${categraf_service_name}" "${n9e_service_name}" "${vm_service_name}"; do
    systemctl stop "${service}.service" >/dev/null 2>&1 || true
done
systemctl disable "${pcm_watchdog_service_name}.service" >/dev/null 2>&1 || true
systemctl disable "${pcm_l1_service_name}.service" >/dev/null 2>&1 || true

for port in "${n9e_listen_addr##*:}" "${vm_listen_addr##*:}" "${categraf_http_addr##*:}"; do
    if port_busy "${port}"; then
        die "port ${port} is already in use on node01"
    fi
done

if [[ "${enable_pcm_l1}" == "1" ]]; then
    if port_busy "${pcm_l1_listen_addr##*:}"; then
        die "port ${pcm_l1_listen_addr##*:} is already in use on node01"
    fi
    command -v python3 >/dev/null 2>&1 || die "python3 is required for the optional pcm-core L1 exporter"
    [[ -x "${pcm_core_bin}" ]] || die "pcm-core binary is missing or not executable: ${pcm_core_bin}"
fi

if ! id -u "${host_user}" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "${data_root}" --shell /usr/sbin/nologin "${host_user}"
fi

install -d -m 0755 -o "${host_user}" -g "${host_user}" \
    "${install_prefix}" \
    "${install_prefix}/categraf/releases" \
    "${install_prefix}/n9e/releases" \
    "${install_prefix}/victoriametrics/releases" \
    "${config_root}/categraf" \
    "${config_root}/n9e" \
    "${data_root}/categraf" \
    "${data_root}/n9e" \
    "${data_root}/victoriametrics"

categraf_archive="${download_root}/${categraf_archive_name}"
n9e_archive="${download_root}/${n9e_archive_name}"
vm_archive="${download_root}/${vm_archive_name}"

if categraf_binary_path="$(reuse_component_binary categraf "${categraf_version}" "categraf")"; then
    categraf_actual_url="reuse-local-release:${categraf_version}"
    categraf_sha256="reuse-local-release"
else
    categraf_actual_url="$(download_with_fallback categraf "${categraf_release_url}" "${categraf_archive}")"
    categraf_sha256="$(sha256sum "${categraf_archive}" | awk '{print $1}')"
    categraf_binary_path="$(extract_component categraf "${categraf_version}" "${categraf_archive}" "categraf")"
fi

if n9e_binary_path="$(reuse_component_binary n9e "${n9e_version}" "n9e")"; then
    n9e_actual_url="reuse-local-release:${n9e_version}"
    n9e_sha256="reuse-local-release"
else
    n9e_actual_url="$(download_with_fallback n9e "${n9e_release_url}" "${n9e_archive}")"
    n9e_sha256="$(sha256sum "${n9e_archive}" | awk '{print $1}')"
    n9e_binary_path="$(extract_component n9e "${n9e_version}" "${n9e_archive}" "n9e")"
fi

if vm_binary_path="$(reuse_component_binary victoriametrics "${vm_version}" "victoria-metrics-prod")"; then
    vm_actual_url="reuse-local-release:${vm_version}"
    vm_sha256="reuse-local-release"
else
    vm_actual_url="$(download_with_fallback victoriametrics "${vm_release_url}" "${vm_archive}")"
    vm_sha256="$(sha256sum "${vm_archive}" | awk '{print $1}')"
    vm_binary_path="$(extract_component victoriametrics "${vm_version}" "${vm_archive}" "victoria-metrics-prod")"
fi

rm -rf "${config_root}/categraf/conf" "${config_root}/categraf/credentials" "${config_root}/n9e"
rm -rf "${config_root}/pcm-sensor-watchdog"
rm -rf "${config_root}/pcm-core-l1"
rm -f "/etc/systemd/system/${pcm_watchdog_service_name}.service"
rm -f "/etc/systemd/system/${pcm_l1_service_name}.service"
mkdir -p "${config_root}/categraf/conf" "${config_root}/categraf/credentials" "${config_root}/n9e"
cp -r "${remote_stage}/payload/categraf/conf/." "${config_root}/categraf/conf/"
if compgen -G "${remote_stage}/payload/categraf/credentials/*" >/dev/null; then
    install -d -m 0750 -o "${host_user}" -g "${host_user}" "${config_root}/categraf/credentials"
    install -m 0640 -o "${host_user}" -g "${host_user}" "${remote_stage}/payload/categraf/credentials/"* "${config_root}/categraf/credentials/"
fi
cp -r "${remote_stage}/payload/n9e/." "${config_root}/n9e/"
cp "${remote_stage}/payload/systemd/${categraf_service_name}.service" "/etc/systemd/system/${categraf_service_name}.service"
cp "${remote_stage}/payload/systemd/${n9e_service_name}.service" "/etc/systemd/system/${n9e_service_name}.service"
cp "${remote_stage}/payload/systemd/${vm_service_name}.service" "/etc/systemd/system/${vm_service_name}.service"
chown -R "${host_user}:${host_user}" "${install_prefix}" "${config_root}" "${data_root}"

if [[ "${enable_pcm}" == "1" && "${enable_pcm_watchdog}" == "1" ]]; then
    install -d -m 0755 -o root -g root "${config_root}/pcm-sensor-watchdog" "${install_prefix}/pcm-sensor-watchdog" "${data_root}/pcm-sensor-watchdog"
    install -m 0755 "${remote_stage}/payload/pcm-sensor-watchdog/pcm_sensor_watchdog.sh" "${pcm_watchdog_script_path}"
    install -m 0644 "${remote_stage}/payload/pcm-sensor-watchdog/watchdog.env" "${pcm_watchdog_env_file}"
    cp "${remote_stage}/payload/systemd/${pcm_watchdog_service_name}.service" "/etc/systemd/system/${pcm_watchdog_service_name}.service"
fi

if [[ "${enable_pcm_l1}" == "1" ]]; then
    install -d -m 0755 -o root -g root "${config_root}/pcm-core-l1" "${install_prefix}/pcm-core-l1" "${data_root}/pcm-core-l1"
    install -m 0755 "${remote_stage}/payload/pcm-core-l1/pcm_core_l1_exporter.py" "${pcm_l1_script_path}"
    install -m 0644 "${remote_stage}/payload/pcm-core-l1/exporter.env" "${pcm_l1_env_file}"
    cp "${remote_stage}/payload/systemd/${pcm_l1_service_name}.service" "/etc/systemd/system/${pcm_l1_service_name}.service"
fi

systemctl daemon-reload
if [[ "${enable_pcm}" == "1" && "${enable_pcm_watchdog}" == "1" ]]; then
    systemctl enable --now "${pcm_watchdog_service_name}.service"
fi
if [[ "${enable_pcm_l1}" == "1" ]]; then
    systemctl enable --now "${pcm_l1_service_name}.service"
    for _ in $(seq 1 30); do
        if curl -fsS "${pcm_l1_health_url}" >/dev/null; then
            break
        fi
        sleep 1
    done
    curl -fsS "${pcm_l1_health_url}" >/dev/null || die "optional pcm-core L1 exporter did not become ready"
fi
systemctl enable --now "${vm_service_name}.service"
for _ in $(seq 1 30); do
    if curl -fsS "http://${vm_listen_addr}/health" >/dev/null; then
        break
    fi
    sleep 1
done
curl -fsS "http://${vm_listen_addr}/health" >/dev/null || die "local VictoriaMetrics health check failed"

systemctl enable --now "${n9e_service_name}.service"
for _ in $(seq 1 30); do
    if curl -fsS "http://${n9e_local_addr}/metrics" >/dev/null; then
        break
    fi
    sleep 1
done
curl -fsS "http://${n9e_local_addr}/metrics" >/dev/null || die "local n9e metrics endpoint did not become ready"

systemctl enable --now "${categraf_service_name}.service"
for _ in $(seq 1 30); do
    categraf_http_code="$(curl -sS -o /dev/null -w '%{http_code}' "http://${categraf_http_addr}/" || true)"
    if [[ -n "${categraf_http_code}" && "${categraf_http_code}" != "000" ]]; then
        break
    fi
    sleep 1
done
[[ -n "${categraf_http_code:-}" && "${categraf_http_code}" != "000" ]] || die "local categraf http endpoint did not become reachable"
rm -f "${remote_stage}/payload/categraf/credentials/"* >/dev/null 2>&1 || true

cat > "${remote_summary_env}" <<EOS
remote_stage=${remote_stage}
host_user=${host_user}
categraf_actual_url=${categraf_actual_url}
categraf_sha256=${categraf_sha256}
categraf_binary_path=${categraf_binary_path}
n9e_actual_url=${n9e_actual_url}
n9e_sha256=${n9e_sha256}
n9e_binary_path=${n9e_binary_path}
vm_actual_url=${vm_actual_url}
vm_sha256=${vm_sha256}
vm_binary_path=${vm_binary_path}
vm_service_name=${vm_service_name}
n9e_service_name=${n9e_service_name}
categraf_service_name=${categraf_service_name}
categraf_bearer_token_file=${categraf_bearer_token_file}
cluster_auth_token_available=${cluster_auth_token_available}
cluster_auth_token_blocker=${cluster_auth_token_blocker}
kubelet_proxy_metrics_url=${kubelet_proxy_metrics_url}
kubelet_discovery_blocker=${kubelet_discovery_blocker}
cadvisor_proxy_metrics_url=${cadvisor_proxy_metrics_url}
cadvisor_discovery_blocker=${cadvisor_discovery_blocker}
kube_state_metrics_urls=${kube_state_metrics_urls}
kube_state_metrics_discovery_blocker=${kube_state_metrics_discovery_blocker}
kube_state_metrics_self_urls=${kube_state_metrics_self_urls}
kube_state_metrics_self_discovery_blocker=${kube_state_metrics_self_discovery_blocker}
pcm_l1_enabled=${enable_pcm_l1}
pcm_l1_service_name=${pcm_l1_service_name}
pcm_l1_metrics_url=${pcm_l1_metrics_url}
pcm_l1_health_url=${pcm_l1_health_url}
pcm_l1_metric_name=${pcm_l1_miss_metric_name}
vm_health_url=http://${vm_listen_addr}/health
n9e_metrics_url=http://${n9e_local_addr}/metrics
categraf_http_url=http://${categraf_http_addr}/
EOS

cat > "${remote_summary_txt}" <<EOS
Remote stage        : ${remote_stage}
Host user           : ${host_user}
Categraf download   : ${categraf_actual_url}
Categraf sha256     : ${categraf_sha256}
Categraf binary     : ${categraf_binary_path}
N9E download        : ${n9e_actual_url}
N9E sha256          : ${n9e_sha256}
N9E binary          : ${n9e_binary_path}
VM download         : ${vm_actual_url}
VM sha256           : ${vm_sha256}
VM binary           : ${vm_binary_path}
Services            : ${vm_service_name}, ${n9e_service_name}, ${categraf_service_name}$(if [[ "${enable_pcm_l1}" == "1" ]]; then printf ', %s' "${pcm_l1_service_name}"; fi)
Categraf token file : ${categraf_bearer_token_file}
Token available     : ${cluster_auth_token_available}
Token blocker       : ${cluster_auth_token_blocker}
Kubelet proxy URL   : ${kubelet_proxy_metrics_url}
Kubelet blocker     : ${kubelet_discovery_blocker}
Cadvisor proxy URL  : ${cadvisor_proxy_metrics_url}
Cadvisor blocker    : ${cadvisor_discovery_blocker}
KSM metrics URLs    : ${kube_state_metrics_urls}
KSM blocker         : ${kube_state_metrics_discovery_blocker}
KSM self URLs       : ${kube_state_metrics_self_urls}
KSM self blocker    : ${kube_state_metrics_self_discovery_blocker}
PCM core L1 enabled : ${enable_pcm_l1}
PCM core L1 metrics : ${pcm_l1_metrics_url}
PCM core L1 metric  : ${pcm_l1_miss_metric_name}
VM health           : http://${vm_listen_addr}/health
N9E bind            : ${n9e_listen_addr}
N9E metrics         : http://${n9e_local_addr}/metrics
Categraf http       : http://${categraf_http_addr}/
EOS

log "installation completed successfully"
EOF

    scp "${HM_SSH_TARGET_REF}:${remote_summary_env}" "${state_dir}/install-summary.env" >/dev/null
    scp "${HM_SSH_TARGET_REF}:${remote_summary_txt}" "${state_dir}/install-summary.txt" >/dev/null

    log_success "host-managed measurement stack installed on ${HM_SSH_TARGET}"
    log_info "state captured in ${state_dir}"
    if [[ "${print_summary}" == "true" ]]; then
        cat "${state_dir}/install-summary.txt"
    fi
}

main "$@"
