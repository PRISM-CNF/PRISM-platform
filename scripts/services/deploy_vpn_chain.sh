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
source "${PLATFORM_REPO_ROOT}/scripts/lib/image_delivery.sh"

usage() {
    cat <<'EOF'
Usage: ./bin/nsm-ovs-lab deploy-vpn --stack-id <id> [platform-options]
EOF
}

main() {
    platform_init "$@"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown deploy-vpn argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_log_resolved_config
    image_delivery_log_mode "deploy-vpn"
    vpn_stack_prepare_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    vpn_require_basic_ready
    "${KUBECTL:-kubectl}" get secret vpn-encrypt-wg vpn-decrypt-wg -n "${VPN_NAMESPACE}" >/dev/null || die "create VPN key Secrets in ${VPN_NAMESPACE} before deployment; see README.md"

    log_info "deploying vpn stack ${VPN_STACK_ID} with rendered assets from ${VPN_STACK_GENERATED_DIR}"
    vpn_apply_dir "${VPN_STACK_GENERATED_DIR}"
    vpn_wait_ready "${WAIT_TIMEOUT:-180s}"

    log_success "vpn stack deploy completed: ${VPN_STACK_ID}"
}

main "$@"
