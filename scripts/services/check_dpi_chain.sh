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
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/dpi.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/dpi_stack.sh"

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    dpi_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    dpi_require_basic_ready

    k8s_namespace_exists "${DPI_NAMESPACE}" || die "dpi namespace not found: ${DPI_NAMESPACE}"

    log_info "checking dpi stack ${DPI_STACK_ID} in namespace ${DPI_NAMESPACE}"
    dpi_wait_ready "${CHECK_TIMEOUT:-60s}"
    dpi_check_client_interface

    log_info "current dpi deployments"
    "${KUBECTL:-kubectl}" get deploy -n "${DPI_NAMESPACE}" -o wide
    log_info "current dpi pods"
    "${KUBECTL:-kubectl}" get pods -n "${DPI_NAMESPACE}" -o wide

    if dpi_try_ping_server; then
        log_success "dpi client ping to ${DPI_SERVER_IPV4} succeeded"
    else
        die "dpi client ping to ${DPI_SERVER_IPV4} failed"
    fi

    if dpi_try_iperf_server; then
        log_success "dpi explicit iperf smoke passed"
    else
        die "dpi explicit iperf smoke failed"
    fi

    log_success "dpi stack ${DPI_STACK_ID} is ready for non-formal smoke validation"
}

main "$@"
