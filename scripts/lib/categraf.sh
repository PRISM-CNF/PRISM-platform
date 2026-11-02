#!/usr/bin/env bash

if [[ -n "${NSM_OVS_CATEGRAF_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_CATEGRAF_SH_LOADED=1

categraf_assets_require_synced() {
    [[ -d "${CATEGRAF_ASSETS_ROOT}" ]] || die "categraf assets root not found: ${CATEGRAF_ASSETS_ROOT}; verify the bundled assets"
    [[ -d "${CATEGRAF_CONFIGS_BASE_DIR}" ]] || die "categraf config assets not found: ${CATEGRAF_CONFIGS_BASE_DIR}; verify the bundled assets"
    [[ -d "${CATEGRAF_MANIFESTS_BASE_DIR}" ]] || die "categraf manifest assets not found: ${CATEGRAF_MANIFESTS_BASE_DIR}; verify the bundled assets"
    [[ -x "${CATEGRAF_DEPLOY_SCRIPT}" ]] || die "categraf deploy asset script not found or not executable: ${CATEGRAF_DEPLOY_SCRIPT}; verify the bundled assets"
    [[ -x "${CATEGRAF_CHECK_SCRIPT}" ]] || die "categraf check asset script not found or not executable: ${CATEGRAF_CHECK_SCRIPT}; verify the bundled assets"
    [[ -x "${CATEGRAF_CLEANUP_SCRIPT}" ]] || die "categraf cleanup asset script not found or not executable: ${CATEGRAF_CLEANUP_SCRIPT}; verify the bundled assets"
    [[ -f "${CATEGRAF_COMMON_LIB_SCRIPT}" ]] || die "categraf common asset library not found: ${CATEGRAF_COMMON_LIB_SCRIPT}; verify the bundled assets"
}

categraf_run_asset_script() {
    local script_path=$1
    local action_label=$2

    categraf_assets_require_synced
    log_info "running categraf ${action_label} asset script: ${script_path}"
    "${script_path}"
}
