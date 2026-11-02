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
source "${PLATFORM_REPO_ROOT}/scripts/lib/template.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/template_stack.sh"

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    template_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    template_warn_if_gateway_present
    template_require_basic_ready

    k8s_namespace_exists "${TEMPLATE_NAMESPACE}" || die "template namespace not found: ${TEMPLATE_NAMESPACE}"

    log_info "checking template stack ${TEMPLATE_STACK_ID} in namespace ${TEMPLATE_NAMESPACE}"
    template_wait_ready "${CHECK_TIMEOUT:-60s}"
    template_check_client_interface

    log_info "current template deployments"
    "${KUBECTL:-kubectl}" get deploy -n "${TEMPLATE_NAMESPACE}" -o wide
    log_info "current template pods"
    "${KUBECTL:-kubectl}" get pods -n "${TEMPLATE_NAMESPACE}" -o wide

    if template_try_ping_server; then
        log_success "template client ping to ${TEMPLATE_SERVER_IPV4} succeeded"
    else
        log_warn "template client ping to ${TEMPLATE_SERVER_IPV4} failed; workload readiness still passed"
    fi

    if template_try_verify_script; then
        log_success "template verify script passed"
    elif template_try_iperf_server; then
        log_success "template iperf smoke fallback passed"
    else
        log_warn "template verify script and iperf smoke fallback both failed; continuing because ready checks passed"
    fi

    log_success "template stack ${TEMPLATE_STACK_ID} is ready for the next stage baseline preconditions"
}

main "$@"
