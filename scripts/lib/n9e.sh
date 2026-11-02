#!/usr/bin/env bash

if [[ -n "${NSM_OVS_N9E_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_N9E_SH_LOADED=1

n9e_assets_require_synced() {
    [[ -d "${N9E_ASSETS_ROOT}" ]] || die "n9e assets root not found: ${N9E_ASSETS_ROOT}; verify the bundled assets"
    [[ -d "${N9E_CONFIGS_BASE_DIR}" ]] || die "n9e config assets not found: ${N9E_CONFIGS_BASE_DIR}; verify the bundled assets"
    [[ -d "${N9E_MANIFESTS_BASE_DIR}" ]] || die "n9e manifest assets not found: ${N9E_MANIFESTS_BASE_DIR}; verify the bundled assets"
    [[ -x "${N9E_DEPLOY_SCRIPT}" ]] || die "n9e deploy asset script not found or not executable: ${N9E_DEPLOY_SCRIPT}; verify the bundled assets"
    [[ -x "${N9E_CHECK_SCRIPT}" ]] || die "n9e check asset script not found or not executable: ${N9E_CHECK_SCRIPT}; verify the bundled assets"
    [[ -x "${N9E_CLEANUP_SCRIPT}" ]] || die "n9e cleanup asset script not found or not executable: ${N9E_CLEANUP_SCRIPT}; verify the bundled assets"
    [[ -f "${N9E_COMMON_LIB_SCRIPT}" ]] || die "n9e common asset library not found: ${N9E_COMMON_LIB_SCRIPT}; verify the bundled assets"
}

n9e_run_asset_script() {
    local script_path=$1
    local action_label=$2

    n9e_assets_require_synced
    log_info "running n9e ${action_label} asset script: ${script_path}"
    "${script_path}"
}
