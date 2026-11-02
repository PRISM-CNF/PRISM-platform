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
source "${PLATFORM_REPO_ROOT}/scripts/lib/firewall.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/firewall_stack.sh"

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    firewall_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    firewall_require_basic_ready

    k8s_namespace_exists "${FIREWALL_NAMESPACE}" || die "firewall namespace not found: ${FIREWALL_NAMESPACE}"

    log_info "checking firewall stack ${FIREWALL_STACK_ID} in namespace ${FIREWALL_NAMESPACE}"
    firewall_wait_ready "${CHECK_TIMEOUT:-60s}"
    firewall_check_client_interface

    log_info "current firewall deployments"
    "${KUBECTL:-kubectl}" get deploy -n "${FIREWALL_NAMESPACE}" -o wide
    log_info "current firewall pods"
    "${KUBECTL:-kubectl}" get pods -n "${FIREWALL_NAMESPACE}" -o wide

    if firewall_try_ping_server; then
        log_success "firewall client ping to ${FIREWALL_SERVER_IPV4} succeeded"
    else
        die "firewall client ping to ${FIREWALL_SERVER_IPV4} failed"
    fi

    if firewall_try_iperf_server; then
        log_success "firewall explicit iperf smoke passed"
    else
        die "firewall explicit iperf smoke failed"
    fi

    log_success "firewall stack ${FIREWALL_STACK_ID} is ready for non-formal smoke validation"
}

main "$@"
