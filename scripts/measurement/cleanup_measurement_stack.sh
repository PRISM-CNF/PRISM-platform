#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/k8s.sh"

MEASUREMENT_STACK_FAILED=0

run_cleanup_step() {
    local label=$1
    local script_path=$2

    if ! "${script_path}"; then
        log_error "${label} cleanup failed"
        MEASUREMENT_STACK_FAILED=1
    fi
}

verify_namespace_absent() {
    local namespace=$1

    if k8s_namespace_exists "${namespace}"; then
        log_error "measurement namespace still present after cleanup: ${namespace}"
        MEASUREMENT_STACK_FAILED=1
    else
        log_info "measurement namespace absent: ${namespace}"
    fi
}

main() {
    local categraf_namespace n9e_namespace vm_namespace

    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    k8s_require_cluster
    k8s_log_context

    categraf_namespace="${CATEGRAF_NAMESPACE}"
    n9e_namespace="${N9E_NAMESPACE}"
    vm_namespace="${VM_NAMESPACE}"

    log_info "cleaning measurement stack in reverse order: categraf -> n9e -> victoriametrics"
    run_cleanup_step "categraf" "${PLATFORM_REPO_ROOT}/scripts/measurement/cleanup_categraf.sh"
    run_cleanup_step "n9e" "${PLATFORM_REPO_ROOT}/scripts/measurement/cleanup_n9e.sh"
    run_cleanup_step "victoriametrics" "${PLATFORM_REPO_ROOT}/scripts/measurement/cleanup_vm.sh"

    verify_namespace_absent "${categraf_namespace}"
    verify_namespace_absent "${n9e_namespace}"
    verify_namespace_absent "${vm_namespace}"

    if (( MEASUREMENT_STACK_FAILED != 0 )); then
        die "measurement stack cleanup completed with failures"
    fi

    log_success "measurement stack cleanup completed"
}

main "$@"
