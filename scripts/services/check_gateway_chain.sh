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
source "${PLATFORM_REPO_ROOT}/scripts/lib/gateway.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/gateway_stack.sh"

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    gateway_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    gateway_require_basic_ready

    k8s_namespace_exists "${GATEWAY_NAMESPACE}" || die "gateway namespace not found: ${GATEWAY_NAMESPACE}"

    log_info "checking gateway stack ${GATEWAY_STACK_ID} in namespace ${GATEWAY_NAMESPACE}"
    gateway_wait_ready "${CHECK_TIMEOUT:-60s}"
    gateway_check_client_interface

    log_info "current gateway deployments"
    "${KUBECTL:-kubectl}" get deploy -n "${GATEWAY_NAMESPACE}" -o wide
    log_info "current gateway pods"
    "${KUBECTL:-kubectl}" get pods -n "${GATEWAY_NAMESPACE}" -o wide

    if gateway_try_ping_server; then
        log_success "gateway client ping to ${GATEWAY_SERVER_IPV4} succeeded"
    else
        die "gateway client ping to ${GATEWAY_SERVER_IPV4} failed"
    fi

    if gateway_try_iperf_server; then
        log_success "gateway explicit iperf smoke passed"
    else
        die "gateway explicit iperf smoke failed"
    fi

    log_success "gateway stack ${GATEWAY_STACK_ID} is ready for non-formal smoke validation"
}

main "$@"
