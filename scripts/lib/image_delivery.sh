#!/usr/bin/env bash

if [[ -n "${NSM_OVS_IMAGE_DELIVERY_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_IMAGE_DELIVERY_SH_LOADED=1

image_delivery_current_mode() {
    printf '%s\n' "${IMAGE_DELIVERY_MODE:-registry-pull}"
}

image_delivery_is_registry_pull() {
    [[ "$(image_delivery_current_mode)" == "registry-pull" ]]
}

image_delivery_is_preload_import() {
    [[ "$(image_delivery_current_mode)" == "preload-import" ]]
}

image_delivery_default_import_enabled() {
    if image_delivery_is_preload_import; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

image_delivery_log_mode() {
    local operation=${1:-platform operation}

    log_info "image delivery mode: $(image_delivery_current_mode)"
    if image_delivery_is_registry_pull; then
        log_info "${operation} expects cluster nodes to pull pinned public image refs directly"
    else
        log_info "${operation} allows explicit local preload/import compatibility flow"
    fi
}

image_delivery_log_template_override_expectation() {
    local image_ref=$1

    if image_delivery_is_registry_pull; then
        log_warn "template image override ${image_ref} must be reachable by target cluster nodes; registry-pull mode does not imply local image import"
    else
        log_info "template image override ${image_ref} can rely on a prior local preload/import step in compatibility mode"
    fi
}
