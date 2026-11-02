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
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/image_delivery.sh"

usage() {
    cat <<'EOF'
Usage: ./bin/nsm-ovs-lab deploy-template --stack-id <id> [platform-options] [--template-image-ref <image>]
EOF
}

cleanup_overlay_dir() {
    if [[ -n "${TEMPLATE_OVERLAY_DIR:-}" ]]; then
        rm -rf "${TEMPLATE_OVERLAY_DIR}"
    fi
}

main() {
    local template_image_ref=""
    local apply_dir

    TEMPLATE_OVERLAY_DIR=""

    platform_init "$@"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            --template-image-ref)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --template-image-ref"
                template_image_ref="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown deploy-template argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_log_resolved_config
    image_delivery_log_mode "deploy-template"
    template_stack_prepare_rendered_runtime
    k8s_require_cluster
    k8s_log_context
    template_warn_if_gateway_present
    template_require_basic_ready

    trap cleanup_overlay_dir EXIT

    if [[ -n "${template_image_ref}" ]]; then
        TEMPLATE_OVERLAY_DIR="$(mktemp -d /tmp/nsm-ovs-template-overlay.XXXXXX)"
        template_write_image_override_overlay "${TEMPLATE_OVERLAY_DIR}" "${template_image_ref}" "${TEMPLATE_STACK_GENERATED_DIR}"
        apply_dir="${TEMPLATE_OVERLAY_DIR}"
        image_delivery_log_template_override_expectation "${template_image_ref}"
        log_info "deploying template stack ${TEMPLATE_STACK_ID} with template image override: ${template_image_ref}"
    else
        apply_dir="${TEMPLATE_STACK_GENERATED_DIR}"
        log_info "deploying template stack ${TEMPLATE_STACK_ID} with rendered assets from ${TEMPLATE_STACK_GENERATED_DIR}"
    fi

    template_apply_dir "${apply_dir}"
    template_wait_ready "${WAIT_TIMEOUT:-180s}"

    log_success "template stack deploy completed: ${TEMPLATE_STACK_ID}"
}

main "$@"
