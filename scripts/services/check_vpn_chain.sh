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
source "${PLATFORM_REPO_ROOT}/scripts/lib/vpn.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/vpn_stack.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/cpuset.sh"

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    vpn_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    vpn_require_basic_ready

    k8s_namespace_exists "${VPN_NAMESPACE}" || die "vpn namespace not found: ${VPN_NAMESPACE}"

    log_info "checking vpn stack ${VPN_STACK_ID} in namespace ${VPN_NAMESPACE}"
    vpn_wait_ready "${CHECK_TIMEOUT:-180s}"
    vpn_wait_client_target_route_ready "${VPN_CLIENT_ROUTE_TIMEOUT_SECONDS}"
    log_success "vpn ready gating passed for encrypt/decrypt deployments"
    vpn_log_client_network_state "pre-smoke"

    log_info "current vpn deployments"
    "${KUBECTL:-kubectl}" get deploy -n "${VPN_NAMESPACE}" -o wide
    log_info "current vpn pods"
    "${KUBECTL:-kubectl}" get pods -n "${VPN_NAMESPACE}" -o wide

    if vpn_run_verify_smoke; then
        log_success "vpn TCP/UDP over VPN smoke passed"
    else
        die "vpn TCP/UDP over VPN smoke failed"
    fi

    log_info "vpn cleanup semantics: scaling client/server down, redeploying middle, and checking cleanup state"
    vpn_scale_client_down "${WAIT_TIMEOUT:-120s}"
    vpn_scale_server_down "${WAIT_TIMEOUT:-120s}"
    vpn_scale_middle_down "${WAIT_TIMEOUT:-120s}"
    vpn_scale_middle_up "${CHECK_TIMEOUT:-180s}"
    if vpn_run_cleanup_check; then
        log_success "vpn cleanup semantics passed"
    else
        die "vpn cleanup semantics failed"
    fi

    log_info "vpn recovery semantics: scaling server then client back up before rerunning TCP/UDP smoke"
    vpn_scale_server_up "${CHECK_TIMEOUT:-180s}"
    vpn_scale_client_up "${CHECK_TIMEOUT:-180s}"
    vpn_wait_recovery_ready "${CHECK_TIMEOUT:-180s}"
    log_success "vpn recovery ready gating passed"
    vpn_log_client_network_state "post-recovery"

    if vpn_run_verify_smoke; then
        log_success "vpn cleanup -> redeploy -> client init -> TCP/UDP smoke passed"
    else
        die "vpn post-cleanup TCP/UDP smoke failed"
    fi

    log_info "vpn ping remains observation-only and is not a hard gate"
    log_success "vpn stack ${VPN_STACK_ID} is ready for non-formal smoke validation"
}

main "$@"
