#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/template.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/template_stack.sh"

usage() {
    cat <<'EOF'
Usage: ./bin/nsm-ovs-lab render-template-stack --stack-id <id> [platform-options]
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
                die "unknown render-template-stack argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_log_resolved_config
    template_stack_prepare_rendered_runtime
    template_render_dir "${TEMPLATE_STACK_GENERATED_DIR}"

    log_info "rendered template stack ${TEMPLATE_STACK_ID} into ${TEMPLATE_STACK_GENERATED_DIR}"
    log_info "resolved values file: ${TEMPLATE_STACK_RESOLVED_VALUES_FILE}"
    template_stack_print_plan
}

main "$@"
