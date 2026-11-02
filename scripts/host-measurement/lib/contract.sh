#!/usr/bin/env bash

if [[ -n "${NSM_OVS_HOST_MEASUREMENT_CONTRACT_SH_LOADED:-}" ]]; then
    return 0
fi
NSM_OVS_HOST_MEASUREMENT_CONTRACT_SH_LOADED=1

hm_measurement_backend() {
    printf 'node01-host-managed\n'
}

hm_measurement_contract_name() {
    printf 'node01-host-managed-v2\n'
}

hm_measurement_required_metric_groups() {
    printf 'pcm,cpu,disk,diskio,kube-proxy,kubelet,cadvisor,kube-state-metrics,kube-state-metrics-self,system,mem,net,netstat,processes,kernel,kernel-vmstat,linux-sysctl-fs\n'
}

hm_measurement_partial_metric_groups() {
    printf 'kubelet,cadvisor,kube-state-metrics,kube-state-metrics-self\n'
}

hm_measurement_excluded_metric_groups() {
    printf '\n'
}

hm_measurement_query_expression() {
    cat <<'EOF'
({job=~"pcm-sensor-server|kube-proxy|kubelet|cadvisor|kube-state-metrics|kube-state-metrics-self"} or {__name__=~"cpu_.*|disk_.*|diskio_.*|system_.*|mem_.*|net_.*|netstat_.*|processes_.*|kernel_.*|linux_sysctl_fs_.*"})
EOF
}

hm_metric_groups_list() {
    hm_measurement_required_metric_groups | tr ',' '\n'
}

hm_metric_group_is_partial_allowed() {
    local group=$1

    case "${group}" in
        kubelet|cadvisor|kube-state-metrics|kube-state-metrics-self)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

hm_metric_group_query_predicate() {
    local group=$1

    case "${group}" in
        pcm)
            printf '((.metric.job // "") == "pcm-sensor-server") or ((.metric.__name__ // "") == "Measurement_Interval_in_us")\n'
            ;;
        cpu)
            printf '((.metric.__name__ // "") | startswith("cpu_"))\n'
            ;;
        disk)
            printf '((.metric.__name__ // "") | startswith("disk_"))\n'
            ;;
        diskio)
            printf '((.metric.__name__ // "") | startswith("diskio_"))\n'
            ;;
        kube-proxy)
            printf '((.metric.job // "") == "kube-proxy")\n'
            ;;
        kubelet)
            printf '((.metric.job // "") == "kubelet")\n'
            ;;
        cadvisor)
            printf '((.metric.job // "") == "cadvisor")\n'
            ;;
        kube-state-metrics)
            printf '((.metric.job // "") == "kube-state-metrics")\n'
            ;;
        kube-state-metrics-self)
            printf '((.metric.job // "") == "kube-state-metrics-self")\n'
            ;;
        system)
            printf '((.metric.__name__ // "") | startswith("system_"))\n'
            ;;
        mem)
            printf '((.metric.__name__ // "") | startswith("mem_"))\n'
            ;;
        net)
            printf '((.metric.__name__ // "") | startswith("net_"))\n'
            ;;
        netstat)
            printf '((.metric.__name__ // "") | startswith("netstat_"))\n'
            ;;
        processes)
            printf '((.metric.__name__ // "") | startswith("processes_"))\n'
            ;;
        kernel)
            printf '(.metric.__name__ // "") as $name | ($name | startswith("kernel_")) and (($name | startswith("kernel_vmstat_")) | not)\n'
            ;;
        kernel-vmstat)
            printf '((.metric.__name__ // "") | startswith("kernel_vmstat_"))\n'
            ;;
        linux-sysctl-fs)
            printf '((.metric.__name__ // "") | startswith("linux_sysctl_fs_"))\n'
            ;;
        *)
            return 1
            ;;
    esac
}

hm_metric_group_name_predicate() {
    local group=$1

    case "${group}" in
        pcm)
            printf '. == "Measurement_Interval_in_us"\n'
            ;;
        cpu)
            printf 'startswith("cpu_")\n'
            ;;
        disk)
            printf 'startswith("disk_")\n'
            ;;
        diskio)
            printf 'startswith("diskio_")\n'
            ;;
        system)
            printf 'startswith("system_")\n'
            ;;
        mem)
            printf 'startswith("mem_")\n'
            ;;
        net)
            printf 'startswith("net_")\n'
            ;;
        netstat)
            printf 'startswith("netstat_")\n'
            ;;
        processes)
            printf 'startswith("processes_")\n'
            ;;
        kernel)
            printf 'startswith("kernel_") and (startswith("kernel_vmstat_") | not)\n'
            ;;
        kernel-vmstat)
            printf 'startswith("kernel_vmstat_")\n'
            ;;
        linux-sysctl-fs)
            printf 'startswith("linux_sysctl_fs_")\n'
            ;;
        *)
            return 1
            ;;
    esac
}

hm_metric_group_present_from_query_file() {
    local group=$1
    local query_file=$2
    local predicate

    predicate="$(hm_metric_group_query_predicate "${group}")" || return 1
    jq -e "any(.data.result[]?; ${predicate})" "${query_file}" >/dev/null
}

hm_metric_group_present_from_names_file() {
    local group=$1
    local names_file=$2
    local predicate

    predicate="$(hm_metric_group_name_predicate "${group}")" || return 1
    jq -e "any(.data[]?; ${predicate})" "${names_file}" >/dev/null
}

hm_metric_groups_present_from_query_file() {
    local query_file=$1
    local group present=""

    while IFS= read -r group; do
        [[ -n "${group}" ]] || continue
        if hm_metric_group_present_from_query_file "${group}" "${query_file}"; then
            present+="${present:+,}${group}"
        fi
    done < <(hm_metric_groups_list)

    printf '%s\n' "${present}"
}

hm_metric_groups_missing_from_query_file() {
    local query_file=$1
    local group missing=""

    while IFS= read -r group; do
        [[ -n "${group}" ]] || continue
        if ! hm_metric_group_present_from_query_file "${group}" "${query_file}"; then
            missing+="${missing:+,}${group}"
        fi
    done < <(hm_metric_groups_list)

    printf '%s\n' "${missing}"
}

hm_metric_groups_hard_missing_from_query_file() {
    local query_file=$1
    local group missing=""

    while IFS= read -r group; do
        [[ -n "${group}" ]] || continue
        if hm_metric_group_present_from_query_file "${group}" "${query_file}"; then
            continue
        fi
        if hm_metric_group_is_partial_allowed "${group}"; then
            continue
        fi
        missing+="${missing:+,}${group}"
    done < <(hm_metric_groups_list)

    printf '%s\n' "${missing}"
}

hm_metric_groups_partial_missing_from_query_file() {
    local query_file=$1
    local group missing=""

    while IFS= read -r group; do
        [[ -n "${group}" ]] || continue
        if hm_metric_group_present_from_query_file "${group}" "${query_file}"; then
            continue
        fi
        if ! hm_metric_group_is_partial_allowed "${group}"; then
            continue
        fi
        missing+="${missing:+,}${group}"
    done < <(hm_metric_groups_list)

    printf '%s\n' "${missing}"
}
