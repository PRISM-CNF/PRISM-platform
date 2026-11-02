#!/usr/bin/env bash

if [[ -n "${NSM_OVS_REPO_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_REPO_SH_LOADED=1

declare -ga REPO_TEMP_CLONE_DIRS=()

repo_is_git_worktree() {
    local repo_path=$1
    git -C "${repo_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

repo_origin_url() {
    local repo_path=$1
    git -C "${repo_path}" remote get-url origin 2>/dev/null || true
}

repo_branch() {
    local repo_path=$1
    git -C "${repo_path}" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

repo_commit() {
    local repo_path=$1
    git -C "${repo_path}" rev-parse HEAD 2>/dev/null || true
}

repo_print_metadata() {
    local repo_label=$1
    local repo_url=$2
    local repo_path=$3
    local origin_url branch_name commit_sha

    origin_url="$(repo_origin_url "${repo_path}")"
    branch_name="$(repo_branch "${repo_path}")"
    commit_sha="$(repo_commit "${repo_path}")"

    log_info "${repo_label} repo path: ${repo_path}"
    log_info "${repo_label} configured url: ${repo_url}"
    if [[ -n "${origin_url}" ]]; then
        log_info "${repo_label} origin remote: ${origin_url}"
    else
        log_warn "${repo_label} origin remote is not configured"
    fi
    if [[ -n "${branch_name}" ]]; then
        log_info "${repo_label} branch: ${branch_name}"
    else
        log_warn "${repo_label} branch could not be resolved"
    fi
    if [[ -n "${commit_sha}" ]]; then
        log_info "${repo_label} commit: ${commit_sha}"
    else
        log_warn "${repo_label} commit could not be resolved"
    fi

    if [[ -n "${origin_url}" && "${origin_url}" != "${repo_url}" ]]; then
        log_warn "${repo_label} origin remote differs from configured url"
    fi
}

ensure_repo_present() {
    local repo_label=$1
    local repo_url=$2
    local repo_path=$3

    require_command git

    if [[ -e "${repo_path}" && ! -d "${repo_path}" ]]; then
        die "${repo_label} path exists but is not a directory: ${repo_path}"
    fi

    if [[ -d "${repo_path}" ]]; then
        repo_is_git_worktree "${repo_path}" || die "${repo_label} path exists but is not a git worktree: ${repo_path}"
        log_info "${repo_label} repo already present"
    else
        mkdir -p "$(dirname "${repo_path}")"
        log_info "cloning ${repo_label} repo from ${repo_url} to ${repo_path}"
        git clone "${repo_url}" "${repo_path}"
        log_success "${repo_label} repo cloned"
    fi

    repo_print_metadata "${repo_label}" "${repo_url}" "${repo_path}"
}

repo_acquire_source_tree() {
    local repo_label=$1
    local repo_url=$2
    local repo_path=$3
    local out_path_var=$4
    local out_mode_var=$5
    local source_path source_mode temp_clone_dir

    require_command git

    if [[ -d "${repo_path}" ]]; then
        repo_is_git_worktree "${repo_path}" || die "${repo_label} path exists but is not a git worktree: ${repo_path}"
        source_path="${repo_path}"
        source_mode="local-worktree"
        log_info "using local ${repo_label} source repo: ${source_path}"
    else
        temp_clone_dir="$(mktemp -d "/tmp/nsm-ovs-${repo_label}.XXXXXX")"
        log_info "local ${repo_label} repo missing; cloning ${repo_url} into temporary source dir ${temp_clone_dir}"
        git clone --depth 1 "${repo_url}" "${temp_clone_dir}"
        REPO_TEMP_CLONE_DIRS+=("${temp_clone_dir}")
        source_path="${temp_clone_dir}"
        source_mode="temp-clone"
    fi

    printf -v "${out_path_var}" '%s' "${source_path}"
    printf -v "${out_mode_var}" '%s' "${source_mode}"
}

repo_cleanup_temporary_sources() {
    local temp_dir

    for temp_dir in "${REPO_TEMP_CLONE_DIRS[@]:-}"; do
        [[ -n "${temp_dir}" ]] || continue
        [[ -d "${temp_dir}" ]] || continue
        rm -rf "${temp_dir}"
    done

    REPO_TEMP_CLONE_DIRS=()
}

ensure_platform_repos() {
    ensure_repo_present "deployment-k8s" "${DEPLOYMENT_K8S_REPO_URL}" "${DEPLOYMENT_K8S_REPO_PATH}"
    ensure_repo_present "basic" "${BASIC_REPO_URL}" "${BASIC_REPO_PATH}"
}

ensure_template_repo() {
    ensure_repo_present "template" "${TEMPLATE_REPO_URL}" "${TEMPLATE_REPO_PATH}"
}

ensure_template_stack_repos() {
    ensure_template_repo
    ensure_repo_present "client" "${CLIENT_REPO_URL}" "${CLIENT_REPO_PATH}"
    ensure_repo_present "server" "${SERVER_REPO_URL}" "${SERVER_REPO_PATH}"
}
