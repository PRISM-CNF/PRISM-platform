#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/repo.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/template.sh"
# shellcheck source=/dev/null
source "${PLATFORM_REPO_ROOT}/scripts/lib/image_delivery.sh"

usage() {
    cat <<'EOF'
Usage: ./bin/nsm-ovs-lab build-template [platform-options] [--tag <tag>] [--import|--no-import] [--output-tar <path>]

This is a source-mode command. It requires the template source repository and is not part of the default runtime asset dependency chain.
The default local import behavior follows IMAGE_DELIVERY_MODE: registry-pull disables implicit ctr import, preload-import enables it.
EOF
}

main() {
    local image_tag=dev
    local import_image=""
    local import_image_source="image-delivery-mode"
    local output_tar=""
    local image_ref tar_path

    platform_init "$@"

    while [[ ${#PLATFORM_EXTRA_ARGS[@]} -gt 0 ]]; do
        case "${PLATFORM_EXTRA_ARGS[0]}" in
            --tag)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --tag"
                image_tag="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            --import)
                import_image=true
                import_image_source='cli:--import'
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:1}")
                ;;
            --no-import)
                import_image=false
                import_image_source='cli:--no-import'
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:1}")
                ;;
            --output-tar)
                [[ ${#PLATFORM_EXTRA_ARGS[@]} -ge 2 ]] || die "missing value for --output-tar"
                output_tar="${PLATFORM_EXTRA_ARGS[1]}"
                PLATFORM_EXTRA_ARGS=("${PLATFORM_EXTRA_ARGS[@]:2}")
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown build-template argument: ${PLATFORM_EXTRA_ARGS[0]}"
                ;;
        esac
    done

    platform_log_resolved_config
    image_delivery_log_mode "build-template"
    if [[ -z "${import_image}" ]]; then
        import_image="$(image_delivery_default_import_enabled)"
    fi
    log_info "template build local import enabled: ${import_image} [source=${import_image_source}]"
    if [[ "${import_image}" == "true" && "$(image_delivery_default_import_enabled)" != "true" ]]; then
        log_warn "local ctr import is explicitly enabled even though registry-pull is the active platform mode"
    elif [[ "${import_image}" == "false" && "$(image_delivery_default_import_enabled)" == "true" ]]; then
        log_warn "local ctr import is explicitly disabled even though preload-import is the active compatibility mode"
    fi

    ensure_template_repo
    template_init_source_context
    template_require_source_tree
    require_command docker
    if [[ "${import_image}" == "true" ]]; then
        require_command ctr
    fi

    image_ref="${TEMPLATE_REPO_NAME}:${image_tag}"
    tar_path="${output_tar}"

    log_info "build-template is running in source mode from ${TEMPLATE_SOURCE_ROOT}"
    log_info "image ref: ${image_ref}"
    docker build -t "${image_ref}" "${TEMPLATE_SOURCE_ROOT}"

    if [[ -z "${tar_path}" && "${import_image}" == "true" ]]; then
        tar_path="$(mktemp "/tmp/${TEMPLATE_REPO_NAME}-${image_tag}.XXXXXX.tar")"
    fi

    if [[ -n "${tar_path}" ]]; then
        log_info "saving image tar: ${tar_path}"
        docker save "${image_ref}" -o "${tar_path}"
    fi

    if [[ "${import_image}" == "true" ]]; then
        log_info "importing image into ctr -n k8s.io"
        ctr -n k8s.io images import "${tar_path}"
    fi

    if [[ -z "${output_tar}" && -n "${tar_path}" ]]; then
        rm -f "${tar_path}"
    fi

    log_success "template image build completed: ${image_ref}"
    log_info "deploy-template still defaults to the pinned images in ${TEMPLATE_K8S_ASSETS_DIR}"
    if [[ "${import_image}" == "true" ]]; then
        log_info "local ctr import completed for compatibility mode consumers"
    else
        log_warn "no local ctr import was performed; a deploy-template image override must use an image ref reachable by target cluster nodes"
    fi
    log_info "to deploy this image explicitly, run: ./bin/nsm-ovs-lab deploy-template --stack-id <id> --template-image-ref ${image_ref}"
}

main "$@"
