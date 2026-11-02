#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

KEEP_PVC=0

usage() {
    cat <<'EOF'
Usage:
  ./scripts/cleanup.sh [--keep-pvc]

Options:
  --keep-pvc   Delete StatefulSet and services but retain namespace and PVC.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-pvc)
                KEEP_PVC=1
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
}

main() {
    parse_args "$@"

    require_command "${KUBECTL}"
    require_cluster
    ensure_repo_layout

    if (( KEEP_PVC == 1 )); then
        if ! namespace_exists; then
            log_info "namespace already absent: ${NAMESPACE}"
            exit 0
        fi

        log_info "cleaning victoria metrics workload while keeping pvc ${PVC_NAME}"
        "${KUBECTL}" delete statefulset "${STATEFULSET_NAME}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null || true
        "${KUBECTL}" delete service "${SERVICE_NAME}" "${HEADLESS_SERVICE_NAME}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null || true

        if statefulset_exists; then
            log_info "waiting for statefulset deletion: ${STATEFULSET_NAME}"
            wait_for_statefulset_deletion 180
        fi

        if pvc_exists; then
            log_success "victoria metrics workload removed and pvc retained: ${PVC_NAME}"
            print_pvc_summary
        else
            log_warn "expected retained pvc not found: ${PVC_NAME}"
        fi
        exit 0
    fi

    log_info "cleaning victoria metrics resources from ${KUSTOMIZE_DIR}"
    render_manifests | "${KUBECTL}" delete -f - --ignore-not-found=true >/dev/null || true
    "${KUBECTL}" delete namespace "${NAMESPACE}" --ignore-not-found=true >/dev/null || true

    if namespace_exists; then
        log_info "waiting for namespace deletion: ${NAMESPACE}"
        wait_for_namespace_deletion 180
    fi

    log_success "victoria metrics cleanup completed"
}

main "$@"

