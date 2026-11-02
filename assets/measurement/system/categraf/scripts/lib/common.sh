#!/usr/bin/env bash

set -euo pipefail

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_LIB_DIR}/../.." && pwd)"

TZ="${TZ:-Asia/Shanghai}"
export TZ

KUBECTL="${KUBECTL:-kubectl}"
KUSTOMIZE_DIR="${REPO_ROOT}/manifests/base"
NAMESPACE="${CATEGRAF_NAMESPACE:-categraf-system}"
DAEMONSET_NAME="${CATEGRAF_DAEMONSET_NAME:-categraf-agent}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"
POD_SELECTOR='app.kubernetes.io/name=categraf-agent'

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

namespace_exists() {
    "${KUBECTL}" get namespace "${NAMESPACE}" >/dev/null 2>&1
}

daemonset_exists() {
    "${KUBECTL}" get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1
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

render_manifests() {
    "${KUBECTL}" kustomize --load-restrictor LoadRestrictionsNone "${KUSTOMIZE_DIR}"
}

print_daemonset_summary() {
    "${KUBECTL}" get daemonset "${DAEMONSET_NAME}" -n "${NAMESPACE}" -o wide
}

print_pod_summary() {
    "${KUBECTL}" get pods -n "${NAMESPACE}" -l "${POD_SELECTOR}" -o wide
}
