#!/usr/bin/env bash

set -euo pipefail

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_LIB_DIR}/../.." && pwd)"

TZ="${TZ:-Asia/Shanghai}"
export TZ

KUBECTL="${KUBECTL:-kubectl}"
KUSTOMIZE_DIR="${REPO_ROOT}/manifests/base"

NAMESPACE="${N9E_NAMESPACE:-n9e-system}"
DEPLOYMENT_NAME="${N9E_DEPLOYMENT_NAME:-n9e}"
SERVICE_NAME="${N9E_SERVICE_NAME:-n9e}"
CONFIGMAP_NAME="${N9E_CONFIGMAP_NAME:-n9e-config}"
PVC_NAME="${N9E_PVC_NAME:-n9e-data}"
APP_SELECTOR='app.kubernetes.io/name=n9e,app.kubernetes.io/component=center'
WAIT_TIMEOUT="${WAIT_TIMEOUT:-240s}"
HTTP_PORT="${N9E_HTTP_PORT:-17000}"
PORT_FORWARD_LOCAL_PORT="${N9E_LOCAL_PORT:-17000}"

VM_NAMESPACE="${VM_NAMESPACE:-victoriametrics-system}"
VM_SERVICE_NAME="${VM_SERVICE_NAME:-victoria-metrics}"
VM_HTTP_PORT="${VM_HTTP_PORT:-8428}"
VM_LOCAL_PORT="${VM_LOCAL_PORT:-18428}"
VM_REMOTE_WRITE_URL="${VM_REMOTE_WRITE_URL:-http://victoria-metrics.victoriametrics-system.svc.cluster.local:8428/api/v1/write}"

SOURCE_IMAGE_REF="${SOURCE_IMAGE_REF:-}"
TARGET_IMAGE_REF="${TARGET_IMAGE_REF:-zihaocnic/n9e-k8s:v8.4.1}"
N9E_RELEASE_URL="${N9E_RELEASE_URL:-https://github.com/ccfos/nightingale/releases/download/v8.4.1/n9e-v8.4.1-linux-amd64.tar.gz}"
CATEGRAF_HELPER_IMAGE="${CATEGRAF_HELPER_IMAGE:-zihaocnic/categraf-k8s:v0.4.36}"

log_info() {
    printf '%s [INFO] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%:z')" "$*"
}

log_success() {
    printf '%s [OK] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%:z')" "$*"
}

log_warn() {
    printf '%s [WARN] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%:z')" "$*" >&2
}

log_error() {
    printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%:z')" "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_cluster() {
    "${KUBECTL}" version --client >/dev/null 2>&1 || die "kubectl is not available"
    "${KUBECTL}" cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster"
}

ensure_repo_layout() {
    [[ -d "${KUSTOMIZE_DIR}" ]] || die "kustomize directory not found: ${KUSTOMIZE_DIR}"
}

namespace_exists() {
    "${KUBECTL}" get namespace "${NAMESPACE}" >/dev/null 2>&1
}

deployment_exists() {
    "${KUBECTL}" get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

service_exists() {
    "${KUBECTL}" get service "${SERVICE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

configmap_exists() {
    "${KUBECTL}" get configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

pvc_exists() {
    "${KUBECTL}" get pvc "${PVC_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

vm_service_exists() {
    "${KUBECTL}" get service "${VM_SERVICE_NAME}" -n "${VM_NAMESPACE}" >/dev/null 2>&1
}

render_manifests() {
    "${KUBECTL}" kustomize --load-restrictor LoadRestrictionsNone "${KUSTOMIZE_DIR}"
}

print_deployment_summary() {
    "${KUBECTL}" get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o wide
}

print_service_summary() {
    "${KUBECTL}" get service "${SERVICE_NAME}" -n "${NAMESPACE}" -o wide
}

print_pvc_summary() {
    "${KUBECTL}" get pvc "${PVC_NAME}" -n "${NAMESPACE}" -o wide
}

print_pod_summary() {
    "${KUBECTL}" get pods -n "${NAMESPACE}" -l "${APP_SELECTOR}" -o wide
}

get_first_pod_name() {
    "${KUBECTL}" get pods -n "${NAMESPACE}" -l "${APP_SELECTOR}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -n 1
}

wait_for_namespace_deletion() {
    local timeout_seconds=${1:-180}
    local deadline=$((SECONDS + timeout_seconds))

    while namespace_exists; do
        if (( SECONDS >= deadline )); then
            die "timed out waiting for namespace deletion: ${NAMESPACE}"
        fi
        sleep 2
    done
}

dump_component_state() {
    if ! namespace_exists; then
        log_warn "namespace not found: ${NAMESPACE}"
        return 0
    fi

    log_info "deployment summary"
    "${KUBECTL}" get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o wide || true

    log_info "service summary"
    "${KUBECTL}" get service "${SERVICE_NAME}" -n "${NAMESPACE}" -o wide || true

    log_info "configmap summary"
    "${KUBECTL}" get configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" -o yaml || true

    log_info "pvc summary"
    "${KUBECTL}" get pvc -n "${NAMESPACE}" -o wide || true

    log_info "pod summary"
    "${KUBECTL}" get pods -n "${NAMESPACE}" -l "${APP_SELECTOR}" -o wide || true

    log_info "namespace events"
    "${KUBECTL}" get events -n "${NAMESPACE}" --sort-by=.metadata.creationTimestamp || true

    if deployment_exists; then
        log_info "describe deployment/${DEPLOYMENT_NAME}"
        "${KUBECTL}" describe deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" || true
    fi

    local pod_name
    pod_name="$(get_first_pod_name || true)"
    if [[ -n "${pod_name}" ]]; then
        log_info "describe pod/${pod_name}"
        "${KUBECTL}" describe pod "${pod_name}" -n "${NAMESPACE}" || true

        log_info "logs pod/${pod_name}"
        "${KUBECTL}" logs "${pod_name}" -n "${NAMESPACE}" --tail=200 || true
    fi
}
