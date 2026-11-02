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
source "${PLATFORM_REPO_ROOT}/scripts/lib/lb.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/lb_stack.sh"

main() {
    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    lb_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    lb_require_basic_ready

    k8s_namespace_exists "${LB_NAMESPACE}" || die "lb namespace not found: ${LB_NAMESPACE}"

    log_info "checking lb stack ${LB_STACK_ID} in namespace ${LB_NAMESPACE}"
    lb_wait_ready "${CHECK_TIMEOUT:-60s}"

    if lb_steering_mode_is_legacy; then
        log_info "lb steering mode: legacy-inject"
        lb_refresh_server_then_client "${LEGACY_REFRESH_TIMEOUT:-180s}"
        lb_wait_ready "${CHECK_TIMEOUT:-60s}"
    else
        log_info "lb steering mode: auto"
        log_info "auto mode keeps current backend-oriented readiness checks; VIP steering remains untouched"
    fi

    lb_check_client_interface

    log_info "current lb deployments"
    "${KUBECTL:-kubectl}" get deploy -n "${LB_NAMESPACE}" -o wide
    log_info "current lb pods"
    "${KUBECTL:-kubectl}" get pods -n "${LB_NAMESPACE}" -o wide

    if lb_try_verify_script; then
        log_success "lb verify script passed"
    else
        log_warn "lb verify script failed; falling back to explicit backend connectivity checks"
    fi

    if lb_steering_mode_is_legacy; then
        lb_apply_legacy_steering
        if lb_try_ping_vip; then
            log_success "lb client ping to VIP ${LB_VIP_IPV4} succeeded under legacy-inject steering"
        else
            die "lb client ping to VIP ${LB_VIP_IPV4} failed under legacy-inject steering"
        fi

        if lb_try_iperf_vip; then
            log_success "lb explicit VIP iperf smoke passed under legacy-inject steering"
        else
            die "lb explicit VIP iperf smoke failed under legacy-inject steering"
        fi
    else
        if lb_try_ping_server; then
            log_success "lb client ping to backend ${LB_SERVER_IPV4} succeeded"
        else
            die "lb client ping to backend ${LB_SERVER_IPV4} failed"
        fi

        if lb_try_iperf_server; then
            log_success "lb explicit backend iperf smoke passed"
        else
            die "lb explicit backend iperf smoke failed"
        fi
    fi

    log_success "lb stack ${LB_STACK_ID} is ready for non-formal smoke validation (steering_mode=${LB_STEERING_MODE})"
}

main "$@"
