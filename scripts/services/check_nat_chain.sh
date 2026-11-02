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
source "${PLATFORM_REPO_ROOT}/scripts/lib/nat.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/nat_stack.sh"

main() {
    local nat_cross_node=false
    local backend_record_timeout='20s'
    local backend_record_client_pod=''

    platform_init "$@"
    platform_require_no_extra_args
    platform_log_resolved_config

    nat_stack_prepare_existing_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    nat_require_basic_ready

    k8s_namespace_exists "${NAT_NAMESPACE}" || die "nat namespace not found: ${NAT_NAMESPACE}"

    log_info "checking nat stack ${NAT_STACK_ID} in namespace ${NAT_NAMESPACE}"
    nat_wait_ready "${CHECK_TIMEOUT:-60s}"

    if nat_steering_mode_is_legacy; then
        log_info "nat steering mode: legacy-inject"
        nat_refresh_server_then_client "${LEGACY_REFRESH_TIMEOUT:-180s}"
        nat_wait_ready "${CHECK_TIMEOUT:-60s}"
    else
        log_info "nat steering mode: auto"
        log_info "auto mode keeps current backend-oriented readiness checks; virtual tuple steering remains untouched"
    fi

    nat_check_client_interface

    log_info "current nat deployments"
    "${KUBECTL:-kubectl}" get deploy -n "${NAT_NAMESPACE}" -o wide
    log_info "current nat pods"
    "${KUBECTL:-kubectl}" get pods -n "${NAT_NAMESPACE}" -o wide

    if [[ "${NAT_STACK_CLIENT_NODE}" != "${NAT_STACK_VNF_NODE}" ]]; then
        nat_cross_node=true
    fi

    if nat_steering_mode_is_legacy; then
        nat_apply_legacy_steering

        if nat_virtual_route_via_nsm; then
            log_success "nat virtual route ${NAT_VIRTUAL_IPV4} resolves via nsm-1"
        else
            die "nat virtual route ${NAT_VIRTUAL_IPV4} is not using nsm-1"
        fi

        if nat_virtual_neigh_present; then
            log_success "nat virtual neighbor ${NAT_VIRTUAL_IPV4} is present on nsm-1"
        else
            die "nat virtual neighbor ${NAT_VIRTUAL_IPV4} is missing on nsm-1"
        fi

        if [[ "${nat_cross_node}" == "true" ]]; then
            log_info "nat legacy-inject mode: cross-node relax backend direct check"
            log_info "nat legacy-inject mode: virtual tuple is the primary gate"
            log_info "nat legacy-inject mode: backend direct iperf is time-boxed to ${backend_record_timeout} and record-only"

            backend_record_client_pod="$(nat_client_pod_name)"
            if [[ -n "${backend_record_client_pod}" ]] \
                && nat_start_server_iperf_once \
                && timeout "${backend_record_timeout}" \
                    "${KUBECTL:-kubectl}" exec -n "${NAT_NAMESPACE}" "${backend_record_client_pod}" -c client -- \
                    sh -eu -c "command -v iperf3 >/dev/null 2>&1 && iperf3 -c '${NAT_BACKEND_IPV4}' -p '${NAT_BACKEND_PORT}' -t 10"; then
                log_success "nat backend direct iperf smoke passed (cross-node record only)"
            else
                log_warn "nat backend direct iperf smoke failed (cross-node record only)"
            fi
        else
            log_info "nat legacy-inject mode: same-node keeps backend direct + virtual tuple as hard gates"

            if nat_try_iperf_server; then
                log_success "nat explicit backend iperf smoke passed"
            else
                die "nat explicit backend iperf smoke failed"
            fi
        fi

        if nat_try_iperf_virtual_tuple; then
            log_success "nat explicit virtual tuple iperf smoke passed"
        else
            die "nat explicit virtual tuple iperf smoke failed"
        fi
    else
        if nat_try_ping_server; then
            log_success "nat client ping to backend ${NAT_SERVER_IPV4} succeeded"
        else
            die "nat client ping to backend ${NAT_SERVER_IPV4} failed"
        fi

        if nat_try_iperf_server; then
            log_success "nat explicit backend iperf smoke passed"
        else
            die "nat explicit backend iperf smoke failed"
        fi
    fi

    log_success "nat stack ${NAT_STACK_ID} is ready for non-formal smoke validation (steering_mode=${NAT_STEERING_MODE})"
}

main "$@"
