#!/usr/bin/env bash

set -euo pipefail

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_LIB_DIR}/../.." && pwd)"

TZ="${TZ:-Asia/Shanghai}"
export TZ

KUBECTL="${KUBECTL:-kubectl}"
KUSTOMIZE_DIR="${REPO_ROOT}/manifests/base"

NAMESPACE="${VM_NAMESPACE:-victoriametrics-system}"
STATEFULSET_NAME="${VM_STATEFULSET_NAME:-victoria-metrics}"
SERVICE_NAME="${VM_SERVICE_NAME:-victoria-metrics}"
HEADLESS_SERVICE_NAME="${VM_HEADLESS_SERVICE_NAME:-victoria-metrics-internal}"
APP_SELECTOR='app.kubernetes.io/name=victoria-metrics,app.kubernetes.io/component=single-node'
PVC_NAME="${VM_PVC_NAME:-data-victoria-metrics-0}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"
PORT_FORWARD_LOCAL_PORT="${VM_LOCAL_PORT:-18428}"
HTTP_PORT="${VM_HTTP_PORT:-8428}"

SOURCE_IMAGE_REF="${SOURCE_IMAGE_REF:-victoriametrics/victoria-metrics:v1.133.0}"
TARGET_IMAGE_REF="${TARGET_IMAGE_REF:-zihaocnic/victoriametrics-k8s:v1.133.0}"

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

statefulset_exists() {
    "${KUBECTL}" get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

service_exists() {
    "${KUBECTL}" get service "${SERVICE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

headless_service_exists() {
    "${KUBECTL}" get service "${HEADLESS_SERVICE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

pvc_exists() {
    "${KUBECTL}" get pvc "${PVC_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
}

render_manifests() {
    "${KUBECTL}" kustomize --load-restrictor LoadRestrictionsNone "${KUSTOMIZE_DIR}"
}

print_statefulset_summary() {
    "${KUBECTL}" get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o wide
}

print_service_summary() {
    "${KUBECTL}" get service "${SERVICE_NAME}" "${HEADLESS_SERVICE_NAME}" -n "${NAMESPACE}" -o wide
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

wait_for_statefulset_deletion() {
    local timeout_seconds=${1:-180}
    local deadline=$((SECONDS + timeout_seconds))

    while statefulset_exists; do
        if (( SECONDS >= deadline )); then
            die "timed out waiting for statefulset deletion: ${STATEFULSET_NAME}"
        fi
        sleep 2
    done
}

dump_component_state() {
    if ! namespace_exists; then
        log_warn "namespace not found: ${NAMESPACE}"
        return 0
    fi

    log_info "statefulset summary"
    "${KUBECTL}" get statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" -o wide || true

    log_info "service summary"
    "${KUBECTL}" get service -n "${NAMESPACE}" "${SERVICE_NAME}" "${HEADLESS_SERVICE_NAME}" -o wide || true

    log_info "pvc summary"
    "${KUBECTL}" get pvc -n "${NAMESPACE}" -o wide || true

    log_info "pod summary"
    "${KUBECTL}" get pods -n "${NAMESPACE}" -l "${APP_SELECTOR}" -o wide || true

    log_info "namespace events"
    "${KUBECTL}" get events -n "${NAMESPACE}" --sort-by=.metadata.creationTimestamp || true

    if statefulset_exists; then
        log_info "describe statefulset/${STATEFULSET_NAME}"
        "${KUBECTL}" describe statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" || true
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

