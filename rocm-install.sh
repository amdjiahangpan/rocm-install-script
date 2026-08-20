#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2120,SC2119

if [[ "${ROCM_INSTALL_LIBRARY_MODE:-}" != 1 ]]; then
    set -euo pipefail
fi

SCRIPT_VERSION=3.0.0
ROCM_VERSION=7.14.0
ROCM_SERIES=7.14
AMDGPU_RELEASE=31.40
AMDGPU_BUILD_ID=31400000
ROCM_PACKAGES_ROOT=https://repo.amd.com/rocm/packages-multi-arch
ROCM_GPG_KEY_URL=${ROCM_PACKAGES_ROOT}/gpg/rocm.gpg
ROCM_WHL_INDEX=https://repo.amd.com/rocm/whl-multi-arch/
ROCM_TARBALL_ROOT=https://repo.amd.com/rocm/tarball-multi-arch/
ROCM_MULTIARCH_TARBALL_ARTIFACT=therock-dist-linux-multiarch-7.14.0.tar.gz
ROCM_GPU_LOOKUP_URL='https://rocm.docs.amd.com/en/latest/install/rocm.html?fam=all&w=compute&os=ubuntu&ubuntu-ver=24.04&i=runfile'
ROCM_GPU_LOOKUP_ZH_URL='https://github.com/amdjiahangpan/hello-rocm/blob/master/docs/zh/00-environment/rocm-gpu-architecture-table.md'
ROCM_RUNFILE_NAME=rocm-installer-7.14.0-7.run
ROCM_RUNFILE_URL="https://repo.radeon.com/rocm/installer/rocm-runfile-installer/rocm-rel-7.14/${ROCM_RUNFILE_NAME}"
AMDGPU_REPOSITORY=https://repo.radeon.com/amdgpu/${AMDGPU_RELEASE}/ubuntu
AMDGPU_GPG_KEY_URL=https://repo.radeon.com/rocm/rocm.gpg.key
SUPPORTED_OS_KEYS=ubuntu-24.04.4,ubuntu-26.04
KERNEL_MIN_FREE_KIB=524288
EXIT_KERNEL_ACTION_REQUIRED=20
EXIT_KERNEL_REBOOT_REQUIRED=21
EXIT_KERNEL_REBOOT_FAILED=22
EXIT_DRIVER_RUNTIME_FAILED=23
EXIT_DRIVER_REBOOT_REQUIRED=24

ARTIFACT_DATA='gfx950|gfx950|device-gfx950|therock-dist-linux-gfx950-dcgpu-7.14.0.tar.gz
gfx942|gfx942|device-gfx942|therock-dist-linux-gfx94X-dcgpu-7.14.0.tar.gz
gfx90a|gfx90a|device-gfx90a|therock-dist-linux-gfx90a-7.14.0.tar.gz
gfx908|gfx908|device-gfx908|therock-dist-linux-gfx908-7.14.0.tar.gz
gfx1201|gfx1201|device-gfx1201|therock-dist-linux-gfx120X-all-7.14.0.tar.gz
gfx1200|gfx1200|device-gfx1200|therock-dist-linux-gfx120X-all-7.14.0.tar.gz
gfx1100|gfx1100|device-gfx1100|therock-dist-linux-gfx110X-all-7.14.0.tar.gz
gfx1101|gfx1101|device-gfx1101|therock-dist-linux-gfx110X-all-7.14.0.tar.gz
gfx1102|gfx1102|device-gfx1102|therock-dist-linux-gfx110X-all-7.14.0.tar.gz
gfx1030|gfx1030|device-gfx1030|therock-dist-linux-gfx103X-all-7.14.0.tar.gz
gfx1151|gfx1151|device-gfx1151|therock-dist-linux-gfx1151-7.14.0.tar.gz
gfx1150|gfx1150|device-gfx1150|therock-dist-linux-gfx1150-7.14.0.tar.gz
gfx1152|gfx1152|device-gfx1152|therock-dist-linux-gfx1152-7.14.0.tar.gz
gfx1153|gfx1153|device-gfx1153|therock-dist-linux-gfx1153-7.14.0.tar.gz
gfx1103|gfx1103|device-gfx1103|therock-dist-linux-gfx110X-all-7.14.0.tar.gz'

PCI_GPU_DATA='7590|*|gfx1200|radeon'

GPU_CLASS_DATA='gfx950|instinct
gfx942|instinct
gfx90a|instinct
gfx908|instinct
gfx1201|radeon
gfx1200|radeon
gfx1100|radeon
gfx1101|radeon
gfx1102|radeon
gfx1030|radeon
gfx1151|ryzen
gfx1150|ryzen
gfx1152|ryzen
gfx1153|ryzen
gfx1103|ryzen'

declare -A ROCM_714_ARTIFACT_RECORDS=()
declare -A ROCM_714_OS_RECORDS=(
    [ubuntu-24.04.4]='apt|ubuntu2404'
    [ubuntu-26.04]='apt|ubuntu2604'
)
declare -A INSTALL_PLAN=()

initialize_tables() {
    local gfx package_suffix pip_extra tarball_artifact

    ROCM_714_ARTIFACT_RECORDS=()
    while IFS='|' read -r gfx package_suffix pip_extra tarball_artifact; do
        [[ -n "$gfx" ]] || continue
        ROCM_714_ARTIFACT_RECORDS["$gfx"]="${package_suffix}|${pip_extra}|${tarball_artifact}"
    done <<< "$ARTIFACT_DATA"
}

initialize_tables

reset_defaults() {
    SKIP_SSH=false
    ROOT_PASSWORD=''
    REBOOT_DELAY=0
    PREPARE_KERNEL=false
    REBOOT_AFTER_KERNEL=false
    VERIFY_ONLY=false
    UNINSTALL=false
    NON_INTERACTIVE=false
    DKMS_CLEANUP_POLICY=auto
    WORKLOAD=compute
    INSTALL_METHOD=apt
    PACKAGE_PROFILE=full
    GPU_ARCHES=''
    GPU_PRODUCT_NAMES=''
    GPU_CLASSES=''
    GPU_DETECTION_SOURCE=''
    GPU_DEVICE_COUNT=0
    GPU_UNMAPPED_PCI=''
    OS_DESCRIPTION=''
    unset GPU_ARCH GPU_PRODUCT_NAME
    INSTALL_PLAN=()
    DRIVER_MODE=auto
    SHOW_HELP=false
    REBOOT_REQUIRED=false
    DRIVER_ACTIVATION_REQUIRED=false
}

reset_defaults

normalize_os_key() {
    [[ $# -eq 2 ]] || return 1
    case "$1|$2" in
        ubuntu\|24.04|ubuntu\|24.04.4) printf '%s\n' ubuntu-24.04.4 ;;
        ubuntu\|26.04) printf '%s\n' ubuntu-26.04 ;;
        *) return 1 ;;
    esac
}

resolve_os_record() {
    local os_key=${1:-}

    [[ $# -eq 1 && -n ${ROCM_714_OS_RECORDS[$os_key]+x} ]] || return 1
    printf '%s\n' "${ROCM_714_OS_RECORDS[$os_key]}"
}

validate_artifact_gfx() {
    local gfx=${1:-}

    [[ $# -eq 1 && -n ${ROCM_714_ARTIFACT_RECORDS[$gfx]+x} ]] || return 1
}

normalize_records() {
    local records=${1:-} record
    local -a normalized_records=()

    [[ $# -eq 1 && -n "$records" ]] || return 1
    while IFS= read -r record || [[ -n "$record" ]]; do
        [[ "$record" != *$'\r'* && "$record" =~ [^[:space:]] ]] || return 1
        normalized_records+=("$record")
    done < <(printf '%s' "$records")
    ((${#normalized_records[@]})) || return 1
    printf '%s\n' "${normalized_records[@]}" | LC_ALL=C sort -u
}

normalize_gfxes() {
    local gfxes=${1:-} normalized_gfxes gfx

    [[ $# -eq 1 ]] || return 1
    normalized_gfxes=$(normalize_records "$gfxes") || return 1
    while IFS= read -r gfx || [[ -n "$gfx" ]]; do
        validate_artifact_gfx "$gfx" || return 1
    done <<< "$normalized_gfxes"
    printf '%s\n' "$normalized_gfxes"
}

records_to_csv() {
    local records=${1:-} normalized_records record escaped_record csv=''

    [[ $# -eq 1 ]] || return 1
    normalized_records=$(normalize_records "$records") || return 1
    while IFS= read -r record || [[ -n "$record" ]]; do
        escaped_record=$record
        if [[ "$record" == *,* || "$record" == *\"* ]]; then
            escaped_record=${record//\"/\"\"}
            escaped_record="\"${escaped_record}\""
        fi
        csv+="${csv:+,}${escaped_record}"
    done <<< "$normalized_records"
    printf '%s\n' "$csv"
}

resolve_package_name() {
    local profile=${1:-} gfx=${2:-} record package_suffix

    [[ $# -eq 2 && "$profile" == full ]] || return 1
    validate_artifact_gfx "$gfx" || return 1
    record=${ROCM_714_ARTIFACT_RECORDS[$gfx]}
    IFS='|' read -r package_suffix _ _ <<< "$record"
    printf 'amdrocm-core-sdk%s-%s\n' "$ROCM_SERIES" "$package_suffix"
}

resolve_pip_requirement() {
    local gfxes=${1:-} normalized_gfxes gfx record pip_extra
    local requirement='rocm[libraries'

    [[ $# -eq 1 ]] || return 1
    normalized_gfxes=$(normalize_gfxes "$gfxes") || return 1
    [[ "$gfxes" == "$normalized_gfxes" ]] || return 1
    while IFS= read -r gfx || [[ -n "$gfx" ]]; do
        record=${ROCM_714_ARTIFACT_RECORDS[$gfx]}
        IFS='|' read -r _ pip_extra _ <<< "$record"
        requirement+=",${pip_extra}"
    done <<< "$normalized_gfxes"
    printf '%s]==%s\n' "$requirement" "$ROCM_VERSION"
}

resolve_tarball_artifact() {
    local gfxes=${1:-} normalized_gfxes gfx record tarball_artifact
    local -a gfx_records=()

    [[ $# -eq 1 ]] || return 1
    normalized_gfxes=$(normalize_gfxes "$gfxes") || return 1
    [[ "$gfxes" == "$normalized_gfxes" ]] || return 1
    while IFS= read -r gfx || [[ -n "$gfx" ]]; do
        gfx_records+=("$gfx")
    done <<< "$normalized_gfxes"
    if ((${#gfx_records[@]} > 1)); then
        printf '%s\n' "$ROCM_MULTIARCH_TARBALL_ARTIFACT"
        return 0
    fi
    record=${ROCM_714_ARTIFACT_RECORDS[${gfx_records[0]}]}
    IFS='|' read -r _ _ tarball_artifact <<< "$record"
    printf '%s\n' "$tarball_artifact"
}

is_supported_gpu_arch() {
    validate_artifact_gfx "${1:-}"
}

gpu_class_for_gfx() {
    local requested_gfx=${1:-} gfx gpu_class

    [[ $# -eq 1 ]] || return 1
    validate_artifact_gfx "$requested_gfx" || return 1
    while IFS='|' read -r gfx gpu_class; do
        [[ "$gfx" == "$requested_gfx" ]] || continue
        case "$gpu_class" in ryzen|radeon|instinct) ;; *) return 1 ;; esac
        printf '%s\n' "$gpu_class"
        return 0
    done <<< "$GPU_CLASS_DATA"
    return 1
}

resolve_gpu_classes() {
    local gfxes=${1:-} normalized_gfxes gfx gpu_class
    local -a gpu_classes=()

    [[ $# -eq 1 ]] || return 1
    normalized_gfxes=$(normalize_gfxes "$gfxes") || return 1
    [[ "$gfxes" == "$normalized_gfxes" ]] || return 1
    while IFS= read -r gfx || [[ -n "$gfx" ]]; do
        gpu_class=$(gpu_class_for_gfx "$gfx") || return 1
        gpu_classes+=("$gpu_class")
    done <<< "$normalized_gfxes"
    normalize_records "$(printf '%s\n' "${gpu_classes[@]}")"
}

is_ryzen_scoped_gfx() {
    case "${1:-}" in
        gfx1103|gfx1150|gfx1151|gfx1152|gfx1153) return 0 ;;
        *) return 1 ;;
    esac
}

kernel_policy_for() {
    local driver_mode=${1:-} os_key=${2:-} gfxes=${3:-} normalized_gfxes gfx
    local has_ryzen_gfx=false has_non_ryzen_gfx=false

    [[ $# -eq 3 ]] || return 1
    normalized_gfxes=$(normalize_gfxes "$gfxes") || return 1
    [[ "$gfxes" == "$normalized_gfxes" ]] || return 1
    while IFS= read -r gfx || [[ -n "$gfx" ]]; do
        if is_ryzen_scoped_gfx "$gfx"; then
            has_ryzen_gfx=true
        else
            has_non_ryzen_gfx=true
        fi
    done <<< "$normalized_gfxes"

    case "$os_key" in
        ubuntu-24.04.4)
            if [[ "$has_ryzen_gfx" == true ]]; then
                [[ "$has_non_ryzen_gfx" == false && "$driver_mode" == inbox ]] || return 1
                printf '%s\n' '6.14.*-oem|linux-oem-6.14'
            else
                case "$driver_mode" in
                    inbox|dkms) printf '%s\n' '6.8.*-generic|linux-generic' ;;
                    *) return 1 ;;
                esac
            fi
            ;;
        ubuntu-26.04)
            case "$driver_mode" in
                inbox|dkms) printf '%s\n' '7.0.*-generic|linux-generic-7.0' ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

kernel_release_matches_target() {
    local kernel_target=${1:-} kernel_release=${2:-}

    [[ $# -eq 2 ]] || return 1
    case "$kernel_target" in
        '6.14.*-oem') [[ "$kernel_release" =~ ^6\.14\.[0-9]+(-[[:alnum:].+_]+)*-oem$ ]] ;;
        '6.8.*-generic') [[ "$kernel_release" =~ ^6\.8\.[0-9]+(-[[:alnum:].+_]+)*-generic$ ]] ;;
        '7.0.*-generic') [[ "$kernel_release" =~ ^7\.0\.[0-9]+(-[[:alnum:].+_]+)*-generic$ ]] ;;
        *) return 1 ;;
    esac
}

validate_ubuntu_kernel() {
    local driver_mode=${1:-} os_key=${2:-} kernel_release=${3:-} gfxes=${4:-}
    local kernel_policy kernel_target kernel_package

    [[ $# -eq 4 ]] || return 1
    kernel_policy=$(kernel_policy_for "$driver_mode" "$os_key" "$gfxes") || return 1
    IFS='|' read -r kernel_target kernel_package <<< "$kernel_policy"
    [[ -n "$kernel_package" ]] || return 1
    kernel_release_matches_target "$kernel_target" "$kernel_release"
}

resolve_driver_mode() {
    local requested_mode=${1:-} os_key=${2:-} gpu_classes=${3:-} gfxes=${4:-}
    local normalized_classes expected_classes

    [[ $# -eq 4 ]] || return 1
    normalized_classes=$(normalize_records "$gpu_classes") || return 1
    [[ "$gpu_classes" == "$normalized_classes" ]] || return 1
    expected_classes=$(resolve_gpu_classes "$gfxes") || return 1
    [[ "$normalized_classes" == "$expected_classes" ]] || return 1
    [[ "$normalized_classes" != *$'\n'* ]] || return 1
    case "$os_key|$normalized_classes" in
        ubuntu-24.04.4\|ryzen|ubuntu-26.04\|ryzen)
            case "$requested_mode" in auto|inbox) printf '%s\n' inbox ;; *) return 1 ;; esac
            ;;
        ubuntu-24.04.4\|radeon|ubuntu-24.04.4\|instinct|ubuntu-26.04\|radeon|ubuntu-26.04\|instinct)
            case "$requested_mode" in auto|dkms) printf '%s\n' dkms ;; *) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
}

trim_field() {
    local value=${1:-}

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

extract_rocminfo_gfxes() {
    local rocminfo_output=${1:-} line name
    local -a gfxes=()

    [[ $# -eq 1 ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*Name:[[:space:]]*(.*)$ ]] || continue
        name=$(trim_field "${BASH_REMATCH[1]}")
        name=${name,,}
        [[ "$name" =~ ^gfx[[:xdigit:]]+$ ]] || continue
        gfxes+=("$name")
    done < <(printf '%s' "$rocminfo_output")
    ((${#gfxes[@]})) || return 1
    normalize_records "$(printf '%s\n' "${gfxes[@]}")"
}

kfd_gfx_target() {
    local value=${1:-} parsed major minor stepping

    [[ $# -eq 1 ]] || return 1
    value=${value,,}
    value=${value#0x}
    if [[ "$value" =~ [a-f] ]]; then
        [[ "$value" =~ ^[0-9a-f]+$ ]] || return 1
        parsed=$((16#$value))
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        parsed=$((10#$value))
    else
        return 1
    fi
    major=$(((parsed / 10000) % 100))
    minor=$(((parsed / 100) % 100))
    stepping=$((parsed % 100))
    [[ $major -gt 0 ]] || return 1
    if ((minor < 16 && stepping < 16)); then
        printf 'gfx%d%x%x\n' "$major" "$minor" "$stepping"
    else
        printf 'gfx%d%d%d\n' "$major" "$minor" "$stepping"
    fi
}

detect_gpu_architectures() {
    local root=${1:-}
    local properties_file line cpu_cores='' gfx_target_version='' gfx
    local -a gfxes=()

    [[ $# -eq 1 && -d "$root" ]] || return 1
    for properties_file in "$root"/*/properties; do
        [[ -r "$properties_file" ]] || continue
        cpu_cores=''
        gfx_target_version=''
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                cpu_cores_count\ *) cpu_cores=${line#cpu_cores_count } ;;
                gfx_target_version\ *)
                    gfx_target_version=${line#gfx_target_version }
                    ;;
            esac
        done < "$properties_file"
        [[ "$cpu_cores" == 0 && "$gfx_target_version" != 0 && -n "$gfx_target_version" ]] || continue
        gfx=$(kfd_gfx_target "$gfx_target_version") || return 1
        gfxes+=("$gfx")
    done
    ((${#gfxes[@]})) || return 1
    normalize_gfxes "$(printf '%s\n' "${gfxes[@]}")"
}

count_kfd_gpu_devices() {
    local root=${1:-} properties_file line cpu_cores='' gfx_target_version='' gfx count=0

    [[ $# -eq 1 && -d "$root" ]] || return 1
    for properties_file in "$root"/*/properties; do
        [[ -r "$properties_file" ]] || continue
        cpu_cores=''
        gfx_target_version=''
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                cpu_cores_count\ *) cpu_cores=${line#cpu_cores_count } ;;
                gfx_target_version\ *) gfx_target_version=${line#gfx_target_version } ;;
            esac
        done < "$properties_file"
        [[ "$cpu_cores" == 0 && -n "$gfx_target_version" && "$gfx_target_version" != 0 ]] || continue
        gfx=$(kfd_gfx_target "$gfx_target_version") || return 1
        validate_artifact_gfx "$gfx" || return 1
        count=$((count + 1))
    done
    ((count > 0)) || return 1
    printf '%s\n' "$count"
}

kfd_gpu_nodes_present() {
    local root=${1:-} properties_file line cpu_cores='' gfx_target_version=''

    [[ $# -eq 1 && -d "$root" ]] || return 1
    for properties_file in "$root"/*/properties; do
        [[ -r "$properties_file" ]] || continue
        cpu_cores=''
        gfx_target_version=''
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                cpu_cores_count\ *) cpu_cores=${line#cpu_cores_count } ;;
                gfx_target_version\ *) gfx_target_version=${line#gfx_target_version } ;;
            esac
        done < "$properties_file"
        [[ "$cpu_cores" == 0 && -n "$gfx_target_version" && "$gfx_target_version" != 0 ]] && return 0
    done
    return 1
}

normalize_pci_id() {
    local value=${1:-}

    value=$(trim_field "$value")
    value=${value#0x}
    value=${value#0X}
    [[ "$value" =~ ^[[:xdigit:]]{1,4}$ ]] || return 1
    printf '%04X\n' "$((16#$value))"
}

lookup_pci_gpu_record() {
    local device=${1:-} revision=${2:-}
    local row_device row_revision gfx gpu_class normalized_device normalized_revision fallback=''

    [[ $# -eq 2 ]] || return 1
    normalized_device=$(normalize_pci_id "$device") || return 1
    normalized_revision=$(normalize_pci_id "$revision") || return 1
    while IFS='|' read -r row_device row_revision gfx gpu_class; do
        [[ -n "$row_device" ]] || continue
        row_device=$(normalize_pci_id "$row_device") || return 1
        [[ "$row_device" == "$normalized_device" ]] || continue
        validate_artifact_gfx "$gfx" || return 1
        case "$gpu_class" in ryzen|radeon|instinct) ;; *) return 1 ;; esac
        if [[ "$row_revision" == '*' ]]; then
            fallback="${gfx}|${gpu_class}"
            continue
        fi
        row_revision=$(normalize_pci_id "$row_revision") || return 1
        if [[ "$row_revision" == "$normalized_revision" ]]; then
            printf '%s|%s\n' "$gfx" "$gpu_class"
            return 0
        fi
    done <<< "$PCI_GPU_DATA"
    [[ -n "$fallback" ]] || return 1
    printf '%s\n' "$fallback"
}

detect_gpu_architectures_from_pci() {
    local root=${1:-} device_path vendor device revision pci_class record normalized_device normalized_revision
    local -a records=()

    [[ $# -eq 1 && -d "$root" ]] || return 1
    for device_path in "$root"/*; do
        [[ -d "$device_path" && -r "$device_path/vendor" && -r "$device_path/device" && -r "$device_path/revision" && -r "$device_path/class" ]] || continue
        IFS= read -r vendor < "$device_path/vendor" || continue
        IFS= read -r device < "$device_path/device" || continue
        IFS= read -r revision < "$device_path/revision" || continue
        IFS= read -r pci_class < "$device_path/class" || continue
        vendor=$(normalize_pci_id "$vendor") || continue
        [[ "$vendor" == 1002 ]] || continue
        pci_class=$(trim_field "$pci_class")
        pci_class=${pci_class#0x}
        pci_class=${pci_class#0X}
        [[ "$pci_class" =~ ^[[:xdigit:]]{6}$ && "${pci_class:0:2}" == 03 ]] || continue
        if ! record=$(lookup_pci_gpu_record "$device" "$revision"); then
            normalized_device=$(normalize_pci_id "$device" 2>/dev/null || printf '%s' "$device")
            normalized_revision=$(normalize_pci_id "$revision" 2>/dev/null || printf '%s' "$revision")
            if [[ "${PCI_ALLOW_UNMAPPED:-false}" != true ]]; then
                printf 'Unsupported AMD display PCI device 1002:%s revision %s; provide the complete reviewed --gpu-arch set.\n' \
                    "$normalized_device" "$normalized_revision" >&2
            fi
            return 2
        fi
        records+=("$record")
    done
    ((${#records[@]})) || return 1
    normalize_records "$(printf '%s\n' "${records[@]}")"
}

count_amd_display_pci_devices() {
    local root=${1:-} device_path vendor pci_class count=0

    [[ $# -eq 1 && -d "$root" ]] || return 1
    for device_path in "$root"/*; do
        [[ -d "$device_path" && -r "$device_path/vendor" && -r "$device_path/class" ]] || continue
        IFS= read -r vendor < "$device_path/vendor" || continue
        IFS= read -r pci_class < "$device_path/class" || continue
        vendor=$(normalize_pci_id "$vendor") || continue
        [[ "$vendor" == 1002 ]] || continue
        pci_class=$(trim_field "$pci_class")
        pci_class=${pci_class#0x}
        pci_class=${pci_class#0X}
        [[ "$pci_class" =~ ^[[:xdigit:]]{6}$ && "${pci_class:0:2}" == 03 ]] || continue
        count=$((count + 1))
    done
    ((count > 0)) || return 1
    printf '%s\n' "$count"
}

detect_unmapped_bound_pci_devices() {
    local root=${1:-} device_path bdf vendor device revision pci_class driver_path normalized_device normalized_revision
    local unmapped_count=0

    [[ $# -eq 1 && -d "$root" ]] || return 1
    for device_path in "$root"/*; do
        [[ -d "$device_path" && -r "$device_path/vendor" && -r "$device_path/device" && -r "$device_path/revision" && -r "$device_path/class" ]] || continue
        IFS= read -r vendor < "$device_path/vendor" || continue
        IFS= read -r device < "$device_path/device" || continue
        IFS= read -r revision < "$device_path/revision" || continue
        IFS= read -r pci_class < "$device_path/class" || continue
        vendor=$(normalize_pci_id "$vendor") || continue
        [[ "$vendor" == 1002 ]] || continue
        pci_class=$(trim_field "$pci_class")
        pci_class=${pci_class#0x}
        pci_class=${pci_class#0X}
        [[ "$pci_class" =~ ^[[:xdigit:]]{6}$ && "${pci_class:0:2}" == 03 ]] || continue
        if lookup_pci_gpu_record "$device" "$revision" >/dev/null 2>&1; then
            continue
        fi
        normalized_device=$(normalize_pci_id "$device") || return 1
        normalized_revision=$(normalize_pci_id "$revision") || return 1
        if [[ ! -L "$device_path/driver" ]]; then
            printf 'Unmapped AMD display PCI device 1002:%s revision %s is not bound to amdgpu.\n' "$normalized_device" "$normalized_revision" >&2
            return 1
        fi
        driver_path=$(readlink -f "$device_path/driver") || return 1
        if [[ "${driver_path##*/}" != amdgpu ]]; then
            printf 'Unmapped AMD display PCI device 1002:%s revision %s is bound to %s, not amdgpu.\n' "$normalized_device" "$normalized_revision" "${driver_path##*/}" >&2
            return 1
        fi
        bdf=${device_path##*/}
        printf '%s|1002:%s|%s\n' "$bdf" "$normalized_device" "$normalized_revision"
        unmapped_count=$((unmapped_count + 1))
    done
    ((unmapped_count > 0))
}

lookup_amdgpu_product_name() {
    local ids_path=${1:-} device=${2:-} revision=${3:-}
    local row_device row_revision product

    [[ $# -eq 3 && -r "$ids_path" ]] || return 1
    while IFS=, read -r row_device row_revision product; do
        row_device=$(normalize_pci_id "$row_device") || continue
        row_revision=$(normalize_pci_id "$row_revision") || continue
        [[ "$row_device" == "$device" && "$row_revision" == "$revision" ]] || continue
        product=$(trim_field "$product")
        [[ -n "$product" ]] || continue
        printf 'AMD %s\n' "$product"
        return 0
    done < "$ids_path"
    return 1
}

detect_gpu_product_names() {
    local drm_root=${1:-} ids_path=${2:-}
    local device_path product_name device revision
    local -a product_names=()

    [[ -d "$drm_root" ]] || return 1
    for device_path in "$drm_root"/card[0-9]*/device; do
        [[ -d "$device_path" ]] || continue
        product_name=''
        if [[ -r "$device_path/product_name" ]]; then
            if IFS= read -r product_name < "$device_path/product_name"; then
                :
            elif [[ -n "$product_name" ]]; then
                :
            else
                product_name=''
            fi
        fi
        product_name=$(trim_field "$product_name")
        if [[ -n "$product_name" ]]; then
            product_names+=("$product_name")
            continue
        fi
        [[ -r "$device_path/device" && -r "$device_path/revision" ]] || continue
        device=''
        revision=''
        if IFS= read -r device < "$device_path/device"; then
            :
        elif [[ -z "$device" ]]; then
            continue
        fi
        if IFS= read -r revision < "$device_path/revision"; then
            :
        elif [[ -z "$revision" ]]; then
            continue
        fi
        device=$(normalize_pci_id "$device") || continue
        revision=$(normalize_pci_id "$revision") || continue
        if product_name=$(lookup_amdgpu_product_name "$ids_path" "$device" "$revision"); then
            product_names+=("$product_name")
        fi
    done
    ((${#product_names[@]})) || return 1
    normalize_records "$(printf '%s\n' "${product_names[@]}")"
}

resolve_gpu_identity() {
    local requested_arches=${GPU_ARCHES:-}
    local kfd_root=${GPU_DETECTION_KFD_ROOT:-/sys/class/kfd/kfd/topology/nodes}
    local pci_root=${GPU_DETECTION_PCI_ROOT:-/sys/bus/pci/devices}
    local kfd_gfxes='' pci_records='' pci_gfxes='' pci_classes='' unmapped_pci='' record gfx gpu_class
    local kfd_count=0 pci_count=0 kfd_status=1 pci_status=1

    GPU_ARCHES=''
    GPU_CLASSES=''
    GPU_PRODUCT_NAMES=''
    GPU_DETECTION_SOURCE=''
    GPU_DEVICE_COUNT=0
    GPU_UNMAPPED_PCI=''
    [[ $# -eq 0 ]] || return 64
    if [[ -n "$requested_arches" ]]; then
        GPU_ARCHES=$(normalize_gfxes "$requested_arches") || return 64
        GPU_DETECTION_SOURCE=explicit
    else
        if kfd_gfxes=$(detect_gpu_architectures "$kfd_root"); then
            kfd_status=0
            kfd_count=$(count_kfd_gpu_devices "$kfd_root") || return 1
        elif kfd_gpu_nodes_present "$kfd_root"; then
            return 1
        fi
        if pci_records=$(PCI_ALLOW_UNMAPPED=$([[ $kfd_status -eq 0 ]] && printf true || printf false) detect_gpu_architectures_from_pci "$pci_root"); then
            pci_status=0
            pci_count=$(count_amd_display_pci_devices "$pci_root") || return 1
            while IFS='|' read -r gfx gpu_class; do
                pci_gfxes+="${pci_gfxes:+$'\n'}${gfx}"
                pci_classes+="${pci_classes:+$'\n'}${gpu_class}"
            done <<< "$pci_records"
            pci_gfxes=$(normalize_gfxes "$pci_gfxes") || return 1
            pci_classes=$(normalize_records "$pci_classes") || return 1
        else
            pci_status=$?
            if [[ $pci_status -eq 2 && $kfd_status -eq 0 ]]; then
                pci_count=$(count_amd_display_pci_devices "$pci_root") || return 1
                unmapped_pci=$(detect_unmapped_bound_pci_devices "$pci_root") || return 1
                [[ $pci_count -eq $kfd_count ]] || return 1
            elif [[ $pci_status -ne 1 ]]; then
                return "$pci_status"
            fi
        fi
        if [[ $kfd_status -eq 0 && $pci_status -eq 0 ]]; then
            [[ "$kfd_gfxes" == "$pci_gfxes" && $kfd_count -eq $pci_count ]] || return 1
            GPU_ARCHES=$kfd_gfxes
            GPU_CLASSES=$pci_classes
            GPU_DEVICE_COUNT=$kfd_count
            GPU_DETECTION_SOURCE=kfd+pci
        elif [[ $kfd_status -eq 0 && $pci_status -eq 2 ]]; then
            GPU_ARCHES=$kfd_gfxes
            GPU_DEVICE_COUNT=$kfd_count
            GPU_UNMAPPED_PCI=$unmapped_pci
            GPU_DETECTION_SOURCE=kfd+unmapped-pci
        elif [[ $kfd_status -eq 0 ]]; then
            GPU_ARCHES=$kfd_gfxes
            GPU_DEVICE_COUNT=$kfd_count
            GPU_DETECTION_SOURCE=kfd
        elif [[ $pci_status -eq 0 ]]; then
            GPU_ARCHES=$pci_gfxes
            GPU_CLASSES=$pci_classes
            GPU_DEVICE_COUNT=$pci_count
            GPU_DETECTION_SOURCE=pci
        else
            return 1
        fi
    fi
    local expected_classes
    expected_classes=$(resolve_gpu_classes "$GPU_ARCHES") || return 1
    if [[ -n "$GPU_CLASSES" ]]; then
        [[ "$GPU_CLASSES" == "$expected_classes" ]] || return 1
    else
        GPU_CLASSES=$expected_classes
    fi
    GPU_PRODUCT_NAMES=$(detect_gpu_product_names "${GPU_DETECTION_DRM_ROOT:-/sys/class/drm}" "${AMDGPU_IDS_PATH:-/usr/share/libdrm/amdgpu.ids}" 2>/dev/null || true)
}

install_plan_keys() {
    printf '%s\n' gfxes gpu_classes gpu_source os_key os_description repo_slug method artifacts driver_mode driver_status actions kernel_status kernel_target kernel_package
}

reset_install_plan() {
    INSTALL_PLAN=()
}

resolve_plan_artifacts() {
    local method=${1:-} gfx_collection=${2:-} normalized_gfxes gfx

    [[ $# -eq 2 ]] || return 1
    normalized_gfxes=$(normalize_gfxes "$gfx_collection") || return 1
    [[ "$gfx_collection" == "$normalized_gfxes" ]] || return 1
    case "$method" in
        apt)
            while IFS= read -r gfx || [[ -n "$gfx" ]]; do
                resolve_package_name full "$gfx" || return $?
            done <<< "$normalized_gfxes"
            ;;
        pip) resolve_pip_requirement "$normalized_gfxes" ;;
        tarball) resolve_tarball_artifact "$normalized_gfxes" ;;
        *) return 1 ;;
    esac
}

validate_install_plan() {
    local key gfxes normalized_gfxes gpu_classes expected_classes os_key os_description expected_os_description os_record repo_slug
    local expected_artifacts expected_driver expected_driver_status expected_actions normalized_product_names kernel_policy kernel_target kernel_package kernel_status

    [[ ${#INSTALL_PLAN[@]} -eq 14 || ${#INSTALL_PLAN[@]} -eq 15 ]] || return 1
    for key in "${!INSTALL_PLAN[@]}"; do
        case "$key" in
            gfxes|gpu_classes|gpu_source|os_key|os_description|repo_slug|method|artifacts|driver_mode|driver_status|actions|kernel_status|kernel_target|kernel_package|product_names) ;;
            *) return 1 ;;
        esac
    done
    while IFS= read -r key; do
        [[ -v "INSTALL_PLAN[$key]" ]] || return 1
    done < <(install_plan_keys)
    gfxes=${INSTALL_PLAN[gfxes]}
    normalized_gfxes=$(normalize_gfxes "$gfxes") || return 1
    [[ "$gfxes" == "$normalized_gfxes" ]] || return 1
    gpu_classes=${INSTALL_PLAN[gpu_classes]}
    expected_classes=$(resolve_gpu_classes "$gfxes") || return 1
    [[ "$gpu_classes" == "$expected_classes" ]] || return 1
    case "${INSTALL_PLAN[gpu_source]}" in explicit|kfd|pci|kfd+pci) ;; *) return 1 ;; esac
    os_key=${INSTALL_PLAN[os_key]}
    os_description=${INSTALL_PLAN[os_description]}
    expected_os_description=${OS_DESCRIPTION:-"${OS_ID:-unknown} ${OS_VERSION:-unknown}"}
    [[ -n "$os_description" && "$os_description" != *$'\n'* && "$os_description" != *$'\r'* && "$os_description" == "$expected_os_description" ]] || return 1
    os_record=$(resolve_os_record "$os_key") || return 1
    repo_slug=${os_record#*|}
    [[ "${INSTALL_PLAN[repo_slug]}" == "$repo_slug" ]] || return 1
    expected_artifacts=$(resolve_plan_artifacts "${INSTALL_PLAN[method]}" "$gfxes") || return 1
    [[ "${INSTALL_PLAN[artifacts]}" == "$expected_artifacts" ]] || return 1
    expected_driver=$(resolve_driver_mode "${DRIVER_MODE:-}" "$os_key" "$gpu_classes" "$gfxes") || return 1
    [[ "${INSTALL_PLAN[driver_mode]}" == "$expected_driver" ]] || return 1
    kernel_policy=$(kernel_policy_for "${INSTALL_PLAN[driver_mode]}" "$os_key" "$gfxes") || return 1
    IFS='|' read -r kernel_target kernel_package <<< "$kernel_policy"
    [[ "${INSTALL_PLAN[kernel_target]}" == "$kernel_target" ]] || return 1
    [[ "${INSTALL_PLAN[kernel_package]}" == "$kernel_package" ]] || return 1
    kernel_status=$(resolve_kernel_status "$kernel_target" "$kernel_package" "${KERNEL_VERSION:-}") || return $?
    [[ "${INSTALL_PLAN[kernel_status]}" == "$kernel_status" ]] || return 1
    expected_driver_status=$(resolve_driver_status "${INSTALL_PLAN[driver_mode]}" "$gfxes") || return 1
    [[ "${INSTALL_PLAN[driver_status]}" == "$expected_driver_status" ]] || return 1
    expected_actions=$(resolve_install_actions "$kernel_status" "$expected_driver_status" "${INSTALL_PLAN[method]}") || return 1
    [[ "${INSTALL_PLAN[actions]}" == "$expected_actions" ]] || return 1
    if [[ -v 'INSTALL_PLAN[product_names]' ]]; then
        normalized_product_names=$(normalize_records "${INSTALL_PLAN[product_names]}") || return 1
        [[ "${INSTALL_PLAN[product_names]}" == "$normalized_product_names" ]] || return 1
    fi
}

resolve_install_plan() {
    local os_key os_description os_record repo_slug artifacts driver_mode driver_status actions normalized_gfxes normalized_gpu_classes gpu_source
    local kernel_policy kernel_target kernel_package kernel_status
    local normalized_product_names=''

    reset_install_plan
    [[ "${OS_ID:-}" == ubuntu && "${ARCH:-}" == x86_64 ]] || return 1
    [[ "${WORKLOAD:-}" == compute && "${PACKAGE_PROFILE:-}" == full ]] || return 1
    [[ "${SKIP_SSH:-}" == true || "${SKIP_SSH:-}" == false ]] || return 1
    [[ "${DKMS_CLEANUP_POLICY:-}" == auto || "${DKMS_CLEANUP_POLICY:-}" == ask || "${DKMS_CLEANUP_POLICY:-}" == always || "${DKMS_CLEANUP_POLICY:-}" == never ]] || return 1
    [[ "${ROOT_PASSWORD:-}" != *$'\n'* && "${ROOT_PASSWORD:-}" != *$'\r'* ]] || return 1
    case "${INSTALL_METHOD:-}" in apt|pip|tarball) ;; *) return 1 ;; esac
    os_key=$(normalize_os_key "$OS_ID" "${OS_VERSION:-}") || return 1
    os_description=${OS_DESCRIPTION:-"${OS_ID} ${OS_VERSION:-unknown}"}
    [[ -n "$os_description" && "$os_description" != *$'\n'* && "$os_description" != *$'\r'* ]] || return 1
    normalized_gfxes=$(normalize_gfxes "${GPU_ARCHES:-}") || return 1
    [[ "${GPU_ARCHES:-}" == "$normalized_gfxes" ]] || return 1
    normalized_gpu_classes=$(resolve_gpu_classes "$normalized_gfxes") || return 1
    if [[ -n ${GPU_CLASSES:-} ]]; then
        [[ "$GPU_CLASSES" == "$normalized_gpu_classes" ]] || return 1
    fi
    gpu_source=${GPU_DETECTION_SOURCE:-explicit}
    case "$gpu_source" in explicit|kfd|pci|kfd+pci) ;; *) return 1 ;; esac
    if [[ -n ${GPU_PRODUCT_NAMES:-} ]]; then
        normalized_product_names=$(normalize_records "$GPU_PRODUCT_NAMES") || return 1
        [[ "$GPU_PRODUCT_NAMES" == "$normalized_product_names" ]] || return 1
    fi
    driver_mode=$(resolve_driver_mode "$DRIVER_MODE" "$os_key" "$normalized_gpu_classes" "$normalized_gfxes") || return 1
    kernel_policy=$(kernel_policy_for "$driver_mode" "$os_key" "$normalized_gfxes") || return 1
    IFS='|' read -r kernel_target kernel_package <<< "$kernel_policy"
    kernel_status=$(resolve_kernel_status "$kernel_target" "$kernel_package" "${KERNEL_VERSION:-}") || return $?
    driver_status=$(resolve_driver_status "$driver_mode" "$normalized_gfxes") || return 1
    actions=$(resolve_install_actions "$kernel_status" "$driver_status" "$INSTALL_METHOD") || return 1
    os_record=$(resolve_os_record "$os_key") || return 1
    repo_slug=${os_record#*|}
    artifacts=$(resolve_plan_artifacts "$INSTALL_METHOD" "$normalized_gfxes") || return 1
    INSTALL_PLAN=(
        [gfxes]="$normalized_gfxes"
        [gpu_classes]="$normalized_gpu_classes"
        [gpu_source]="$gpu_source"
        [os_key]="$os_key"
        [os_description]="$os_description"
        [repo_slug]="$repo_slug"
        [method]="$INSTALL_METHOD"
        [artifacts]="$artifacts"
        [driver_mode]="$driver_mode"
        [driver_status]="$driver_status"
        [actions]="$actions"
        [kernel_status]="$kernel_status"
        [kernel_target]="$kernel_target"
        [kernel_package]="$kernel_package"
    )
    [[ -z "$normalized_product_names" ]] || INSTALL_PLAN[product_names]=$normalized_product_names
    if validate_install_plan; then
        return 0
    fi
    reset_install_plan
    return 1
}

print_install_plan() {
    local gfx_csv gpu_class_csv artifact_csv action_csv product_name_csv output

    validate_install_plan || return 1
    gfx_csv=$(records_to_csv "${INSTALL_PLAN[gfxes]}") || return 1
    gpu_class_csv=$(records_to_csv "${INSTALL_PLAN[gpu_classes]}") || return 1
    artifact_csv=$(records_to_csv "${INSTALL_PLAN[artifacts]}") || return 1
    action_csv=$(records_to_csv "${INSTALL_PLAN[actions]}") || return 1
    output=$'INSTALL PLAN\n'
    output+="gfx=${gfx_csv}"$'\n'
    output+="gpu_class=${gpu_class_csv}"$'\n'
    output+="gpu_source=${INSTALL_PLAN[gpu_source]}"$'\n'
    output+="os=${INSTALL_PLAN[os_description]}"$'\n'
    output+="os_policy=${INSTALL_PLAN[os_key]}"$'\n'
    output+="method=${INSTALL_PLAN[method]}"$'\n'
    output+="artifact=${artifact_csv}"$'\n'
    output+="driver_mode=${INSTALL_PLAN[driver_mode]}"$'\n'
    output+="driver_status=${INSTALL_PLAN[driver_status]}"$'\n'
    output+="action=${action_csv}"$'\n'
    output+="kernel_status=${INSTALL_PLAN[kernel_status]}"$'\n'
    output+="kernel_target=${INSTALL_PLAN[kernel_target]}"$'\n'
    output+="kernel_package=${INSTALL_PLAN[kernel_package]}"$'\n'
    if [[ -v 'INSTALL_PLAN[product_names]' ]]; then
        product_name_csv=$(records_to_csv "${INSTALL_PLAN[product_names]}") || return 1
        output+="product_name=${product_name_csv}"$'\n'
    fi
    printf '%s' "$output"
}

detect_system() {
    local os_release_file=${OS_RELEASE_FILE:-/etc/os-release}

    [[ -r "$os_release_file" ]] || return 1
    unset ID VERSION_ID PRETTY_NAME
    # shellcheck disable=SC1090
    . "$os_release_file"
    OS_ID=${ID:-}
    OS_VERSION=${VERSION_ID:-}
    OS_DESCRIPTION=${PRETTY_NAME:-"${OS_ID} ${OS_VERSION:-unknown}"}
    ARCH=${SYSTEM_ARCH_OVERRIDE:-$(uname -m)}
    KERNEL_VERSION=${SYSTEM_KERNEL_OVERRIDE:-$(uname -r)}
    [[ "$OS_ID" == ubuntu && "$ARCH" == x86_64 ]] || return 1
    normalize_os_key "$OS_ID" "$OS_VERSION" >/dev/null || return 1
}

require_root() {
    [[ ${EUID:-1} -eq 0 ]]
}

verify_installation() {
    local install_root rocminfo_output amd_smi_output requested_records requested_gfxes visible_gfxes requested_gfx visible_gfx found

    if [[ "${REBOOT_REQUIRED:-false}" == true ]]; then
        printf '%s\n' 'ROCm installation is pending reboot; verification has not been run.'
        return 0
    fi
    if [[ -v 'INSTALL_PLAN[gfxes]' ]]; then
        requested_records=${INSTALL_PLAN[gfxes]}
        requested_gfxes=$(normalize_gfxes "$requested_records") || return 1
        [[ "$requested_records" == "$requested_gfxes" ]] || return 1
    else
        requested_records=${GPU_ARCHES:-}
        requested_gfxes=$(normalize_gfxes "$requested_records") || return 1
    fi
    install_root=$(rocm_install_root) || return $?
    rocminfo_output=$(capture_cmd "${install_root}/bin/rocminfo") || return $?
    amd_smi_output=$(capture_cmd "${install_root}/bin/amd-smi" version) || return $?
    visible_gfxes=$(extract_rocminfo_gfxes "$rocminfo_output") || {
        printf '%s\n' 'ROCm verification failed: rocminfo did not report a concrete gfx agent.' >&2
        return 1
    }
    while IFS= read -r requested_gfx || [[ -n "$requested_gfx" ]]; do
        found=false
        while IFS= read -r visible_gfx || [[ -n "$visible_gfx" ]]; do
            if [[ "$visible_gfx" == "$requested_gfx" ]]; then
                found=true
                break
            fi
        done <<< "$visible_gfxes"
        if [[ "$found" != true ]]; then
            printf 'ROCm verification failed: requested gfx target %s was not reported by rocminfo.\n' "$requested_gfx" >&2
            return 1
        fi
    done <<< "$requested_gfxes"
    [[ "$amd_smi_output" =~ (^|[^0-9.])7\.14\.0([^0-9.]|$) ]] || {
        printf '%s\n' 'ROCm verification failed: expected version 7.14.0.' >&2
        return 1
    }
    printf '%s\n' 'ROCm 7.14.0 verified for requested gfx agents with rocminfo and amd-smi.'
}

run_cmd() {
    "$@"
}

capture_cmd() {
    "$@"
}

kernel_package_is_installed() {
    local package=${1:-} package_status

    [[ $# -eq 1 && -n "$package" ]] || return 1
    package_status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) || return 1
    [[ "$package_status" == installed ]]
}

approved_kernel_spec_is_valid() {
    local kernel_target=${1:-} kernel_package=${2:-}

    [[ $# -eq 2 ]] || return 1
    case "$kernel_target|$kernel_package" in
        '6.14.*-oem|linux-oem-6.14'|'6.8.*-generic|linux-generic'|'7.0.*-generic|linux-generic-7.0') ;;
        *) return 1 ;;
    esac
}

kernel_package_has_candidate() {
    local package=${1:-} policy_output line candidate='' candidate_count=0

    [[ $# -eq 1 && -n "$package" ]] || return 1
    policy_output=$(capture_cmd env LC_ALL=C apt-cache policy "$package") || return $?
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*Candidate: ]] || continue
        candidate_count=$((candidate_count + 1))
        [[ "$line" =~ ^[[:space:]]*Candidate:[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]] || return 1
        candidate=${BASH_REMATCH[1]}
    done <<< "$policy_output"
    [[ $candidate_count -eq 1 && "$candidate" != '(none)' ]]
}

kernel_install_simulation_is_safe() {
    local package=${1:-} simulation_output line

    [[ $# -eq 1 && -n "$package" ]] || return 1
    simulation_output=$(capture_cmd env LC_ALL=C apt-get --simulate --no-remove --install-recommends install "$package") || return $?
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ ! "$line" =~ ^[[:space:]]*Remv[[:space:]] ]] || return 1
    done <<< "$simulation_output"
}

kernel_boot_image_exists() {
    local kernel_target=${1:-} boot_dir=${KERNEL_BOOT_DIR:-/boot} image pattern

    [[ $# -eq 1 && -d "$boot_dir" ]] || return 1
    case "$kernel_target" in
        '6.14.*-oem') pattern='vmlinuz-6.14.*-oem' ;;
        '6.8.*-generic') pattern='vmlinuz-6.8.*-generic' ;;
        '7.0.*-generic') pattern='vmlinuz-7.0.*-generic' ;;
        *) return 1 ;;
    esac
    for image in "$boot_dir"/$pattern; do
        [[ -f "$image" && -r "$image" && -s "$image" ]] && return 0
    done
    return 1
}

resolve_kernel_status() {
    local kernel_target=${1:-} kernel_package=${2:-} kernel_release=${3:-}

    [[ $# -eq 3 ]] || return 1
    approved_kernel_spec_is_valid "$kernel_target" "$kernel_package" || return 1
    if kernel_release_matches_target "$kernel_target" "$kernel_release"; then
        printf '%s\n' ready
    elif kernel_package_is_installed "$kernel_package" && kernel_boot_image_exists "$kernel_target"; then
        printf '%s\n' reboot-required
    else
        printf '%s\n' install-required
    fi
}

kernel_boot_has_minimum_free_space() {
    local boot_dir=${KERNEL_BOOT_DIR:-/boot} df_output header data_line
    local filesystem blocks used available capacity mount_point extra
    local header_filesystem header_blocks header_used header_available header_capacity header_mounted header_on header_extra
    local -a df_lines=()

    [[ -d "$boot_dir" ]] || return 1
    df_output=$(capture_cmd env LC_ALL=C df -Pk "$boot_dir") || return $?
    while IFS= read -r data_line || [[ -n "$data_line" ]]; do
        df_lines+=("$data_line")
    done <<< "$df_output"
    [[ ${#df_lines[@]} -eq 2 ]] || return 1
    header=${df_lines[0]}
    data_line=${df_lines[1]}
    read -r header_filesystem header_blocks header_used header_available header_capacity header_mounted header_on header_extra <<< "$header"
    [[ "$header_filesystem" == Filesystem && "$header_blocks" == 1024-blocks && "$header_used" == Used && "$header_available" == Available && "$header_capacity" == Capacity && "$header_mounted" == Mounted && "$header_on" == on && -z "$header_extra" ]] || return 1
    read -r filesystem blocks used available capacity mount_point extra <<< "$data_line"
    [[ -n "$filesystem" && "$blocks" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ && "$capacity" =~ ^[0-9]+%$ && -n "$mount_point" && -z "$extra" ]] || return 1
    ((10#$available >= KERNEL_MIN_FREE_KIB))
}

install_approved_kernel() {
    local kernel_target=${INSTALL_PLAN[kernel_target]:-} kernel_package=${INSTALL_PLAN[kernel_package]:-}

    approved_kernel_spec_is_valid "$kernel_target" "$kernel_package" || return 1
    kernel_boot_has_minimum_free_space || return $?
    run_cmd apt-get update || return $?
    kernel_package_has_candidate "$kernel_package" || return $?
    kernel_install_simulation_is_safe "$kernel_package" || return $?
    run_cmd apt-get --yes --no-remove --install-recommends install "$kernel_package" || return $?
    kernel_package_is_installed "$kernel_package" || return 1
    kernel_boot_image_exists "$kernel_target"
}

prepare_approved_kernel() {
    local kernel_status=${INSTALL_PLAN[kernel_status]:-}

    case "$kernel_status" in
        ready) return 0 ;;
        install-required)
            install_approved_kernel || return $?
            REBOOT_REQUIRED=true
            ;;
        reboot-required) REBOOT_REQUIRED=true ;;
        *) return 1 ;;
    esac
}

kernel_pattern_for_target() {
    case "${1:-}" in
        '6.14.*-oem') printf '%s\n' 'vmlinuz-6.14.*-oem' ;;
        '6.8.*-generic') printf '%s\n' 'vmlinuz-6.8.*-generic' ;;
        '7.0.*-generic') printf '%s\n' 'vmlinuz-7.0.*-generic' ;;
        *) return 1 ;;
    esac
}

latest_kernel_release_for_target() {
    local kernel_target=${1:-} boot_dir=${KERNEL_BOOT_DIR:-/boot} pattern image release latest=''
    local -a releases=()

    [[ $# -eq 1 && -d "$boot_dir" ]] || return 1
    pattern=$(kernel_pattern_for_target "$kernel_target") || return 1
    for image in "$boot_dir"/$pattern; do
        [[ -f "$image" && -r "$image" && -s "$image" ]] || continue
        release=${image##*/vmlinuz-}
        kernel_release_matches_target "$kernel_target" "$release" || continue
        releases+=("$release")
    done
    ((${#releases[@]})) || return 1
    while IFS= read -r release || [[ -n "$release" ]]; do
        latest=$release
    done < <(printf '%s\n' "${releases[@]}" | LC_ALL=C sort -V)
    [[ -n "$latest" ]] || return 1
    printf '%s\n' "$latest"
}

resolve_grub_kernel_entry() {
    local kernel_target=${1:-} grub_config=${GRUB_CONFIG_FILE:-/boot/grub/grub.cfg}
    local release line submenu_found=false entry_found=false

    [[ $# -eq 1 && -r "$grub_config" ]] || return 1
    release=$(latest_kernel_release_for_target "$kernel_target") || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" != *"submenu 'Advanced options for Ubuntu'"* ]] || submenu_found=true
        [[ "$line" != *"menuentry 'Ubuntu, with Linux ${release}'"* ]] || entry_found=true
    done < "$grub_config"
    [[ "$submenu_found" == true && "$entry_found" == true ]] || return 1
    printf 'Advanced options for Ubuntu>Ubuntu, with Linux %s\n' "$release"
}

pending_kernel_state_path() {
    local state_root=${INSTALLER_STATE_ROOT:-/var/lib/rocm-installer}

    [[ "$state_root" == /* ]] || return 1
    printf '%s/pending-kernel\n' "${state_root%/}"
}

read_boot_id() {
    local boot_id_file=${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id} boot_id

    [[ -r "$boot_id_file" ]] || return 1
    IFS= read -r boot_id < "$boot_id_file" || return 1
    boot_id=$(trim_field "$boot_id")
    [[ -n "$boot_id" && "$boot_id" != *'|'* ]] || return 1
    printf '%s\n' "$boot_id"
}

write_pending_kernel_state() {
    local target=${1:-} entry=${2:-} boot_id=${3:-} attempts=${4:-}
    local state_root=${INSTALLER_STATE_ROOT:-/var/lib/rocm-installer} state_path temporary

    [[ $# -eq 4 && "$state_root" == /* && -n "$entry" && "$entry" != *$'\n'* && "$entry" != *$'\r'* && -n "$boot_id" && "$boot_id" != *$'\n'* && "$attempts" =~ ^[0-9]+$ ]] || return 1
    kernel_pattern_for_target "$target" >/dev/null || return 1
    state_path=$(pending_kernel_state_path) || return 1
    install -d -m 0700 "$state_root" || return $?
    temporary=$(mktemp "${state_root%/}/.pending-kernel.XXXXXX") || return $?
    if printf 'target=%s\nentry=%s\nboot_id=%s\nattempts=%s\n' "$target" "$entry" "$boot_id" "$attempts" > "$temporary" \
        && chmod 0600 "$temporary" \
        && mv -f "$temporary" "$state_path"; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}

read_pending_kernel_state() {
    local state_path key value seen_target=false seen_entry=false seen_boot_id=false seen_attempts=false

    PENDING_KERNEL_TARGET=''
    PENDING_KERNEL_ENTRY=''
    PENDING_KERNEL_BOOT_ID=''
    PENDING_KERNEL_ATTEMPTS=''
    state_path=$(pending_kernel_state_path) || return 1
    [[ -r "$state_path" ]] || return 1
    while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
        case "$key" in
            target) [[ "$seen_target" == false ]] || return 1; PENDING_KERNEL_TARGET=$value; seen_target=true ;;
            entry) [[ "$seen_entry" == false ]] || return 1; PENDING_KERNEL_ENTRY=$value; seen_entry=true ;;
            boot_id) [[ "$seen_boot_id" == false ]] || return 1; PENDING_KERNEL_BOOT_ID=$value; seen_boot_id=true ;;
            attempts) [[ "$seen_attempts" == false ]] || return 1; PENDING_KERNEL_ATTEMPTS=$value; seen_attempts=true ;;
            *) return 1 ;;
        esac
    done < "$state_path"
    [[ "$seen_target" == true && "$seen_entry" == true && "$seen_boot_id" == true && "$seen_attempts" == true ]] || return 1
    kernel_pattern_for_target "$PENDING_KERNEL_TARGET" >/dev/null || return 1
    [[ -n "$PENDING_KERNEL_ENTRY" && -n "$PENDING_KERNEL_BOOT_ID" && "$PENDING_KERNEL_ATTEMPTS" =~ ^[0-9]+$ ]] || return 1
}

clear_pending_kernel_state() {
    local state_path

    state_path=$(pending_kernel_state_path) || return 1
    rm -f "$state_path"
}

reconcile_pending_kernel_state() {
    local state_path current_boot_id

    state_path=$(pending_kernel_state_path) || return 1
    [[ -e "$state_path" ]] || return 0
    read_pending_kernel_state || return 1
    if kernel_release_matches_target "$PENDING_KERNEL_TARGET" "${KERNEL_VERSION:-}"; then
        clear_pending_kernel_state
        return $?
    fi
    current_boot_id=$(read_boot_id) || return 1
    if [[ "$current_boot_id" == "$PENDING_KERNEL_BOOT_ID" ]]; then
        printf 'ROCm kernel reboot is pending: current kernel=%s, target kernel=%s, boot entry=%s.\n' \
            "${KERNEL_VERSION:-unknown}" "$PENDING_KERNEL_TARGET" "$PENDING_KERNEL_ENTRY" >&2
        return "$EXIT_KERNEL_REBOOT_REQUIRED"
    fi
    printf 'ROCm kernel boot failed: system rebooted but current kernel=%s does not match target kernel=%s. Automatic reboot will not be attempted again; select boot entry %s manually.\n' \
        "${KERNEL_VERSION:-unknown}" "$PENDING_KERNEL_TARGET" "$PENDING_KERNEL_ENTRY" >&2
    return "$EXIT_KERNEL_REBOOT_FAILED"
}

configure_grub_next_entry() {
    local entry=${1:-} grub_env=${GRUB_ENV_FILE:-/boot/grub/grubenv} grub_output line next_entry='' next_entry_count=0

    [[ $# -eq 1 && -n "$entry" ]] || return 1
    run_cmd grub-reboot "$entry" || return $?
    grub_output=$(capture_cmd grub-editenv "$grub_env" list) || return $?
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == next_entry=* ]] || continue
        next_entry_count=$((next_entry_count + 1))
        next_entry=${line#next_entry=}
    done <<< "$grub_output"
    [[ $next_entry_count -eq 1 && "$next_entry" == "$entry" ]]
}

snapshot_grub_one_shot_state() {
    local grub_env=${GRUB_ENV_FILE:-/boot/grub/grubenv} grub_output line

    GRUB_PREVIOUS_NEXT_ENTRY_PRESENT=false
    GRUB_PREVIOUS_NEXT_ENTRY=''
    GRUB_PREVIOUS_SAVED_ENTRY_PRESENT=false
    GRUB_PREVIOUS_SAVED_ENTRY=''
    grub_output=$(capture_cmd grub-editenv "$grub_env" list) || return $?
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            next_entry=*)
                [[ "$GRUB_PREVIOUS_NEXT_ENTRY_PRESENT" == false ]] || return 1
                GRUB_PREVIOUS_NEXT_ENTRY_PRESENT=true
                GRUB_PREVIOUS_NEXT_ENTRY=${line#next_entry=}
                ;;
            prev_saved_entry=*)
                [[ "$GRUB_PREVIOUS_SAVED_ENTRY_PRESENT" == false ]] || return 1
                GRUB_PREVIOUS_SAVED_ENTRY_PRESENT=true
                GRUB_PREVIOUS_SAVED_ENTRY=${line#prev_saved_entry=}
                ;;
        esac
    done <<< "$grub_output"
}

restore_grub_one_shot_state() {
    local grub_env=${GRUB_ENV_FILE:-/boot/grub/grubenv} grub_output line
    local current_next_present=false current_next='' current_saved_present=false current_saved=''

    run_cmd grub-editenv "$grub_env" unset next_entry || return $?
    run_cmd grub-editenv "$grub_env" unset prev_saved_entry || return $?
    if [[ "$GRUB_PREVIOUS_NEXT_ENTRY_PRESENT" == true ]]; then
        run_cmd grub-editenv "$grub_env" set "next_entry=${GRUB_PREVIOUS_NEXT_ENTRY}" || return $?
    fi
    if [[ "$GRUB_PREVIOUS_SAVED_ENTRY_PRESENT" == true ]]; then
        run_cmd grub-editenv "$grub_env" set "prev_saved_entry=${GRUB_PREVIOUS_SAVED_ENTRY}" || return $?
    fi
    grub_output=$(capture_cmd grub-editenv "$grub_env" list) || return $?
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            next_entry=*)
                [[ "$current_next_present" == false ]] || return 1
                current_next_present=true
                current_next=${line#next_entry=}
                ;;
            prev_saved_entry=*)
                [[ "$current_saved_present" == false ]] || return 1
                current_saved_present=true
                current_saved=${line#prev_saved_entry=}
                ;;
        esac
    done <<< "$grub_output"
    [[ "$current_next_present" == "$GRUB_PREVIOUS_NEXT_ENTRY_PRESENT" && "$current_next" == "$GRUB_PREVIOUS_NEXT_ENTRY" ]] || return 1
    [[ "$current_saved_present" == "$GRUB_PREVIOUS_SAVED_ENTRY_PRESENT" && "$current_saved" == "$GRUB_PREVIOUS_SAVED_ENTRY" ]]
}

confirm_kernel_reboot() {
    local answer

    [[ "${NON_INTERACTIVE:-false}" != true ]] || return 0
    read -r -p 'Reboot once into the reviewed kernel entry? [y/N] ' answer || return 1
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}

prepare_kernel_reboot() {
    local entry boot_id

    [[ "${PREPARE_KERNEL:-false}" == true && "${REBOOT_AFTER_KERNEL:-false}" == true ]] || return 1
    entry=$(resolve_grub_kernel_entry "${INSTALL_PLAN[kernel_target]:-}") || return 1
    printf 'ROCm will select one boot attempt: current kernel=%s, target kernel=%s, boot entry=%s.\n' \
        "${KERNEL_VERSION:-unknown}" "${INSTALL_PLAN[kernel_target]:-unknown}" "$entry" >&2
    confirm_kernel_reboot || return 1
    snapshot_grub_one_shot_state || return 1
    boot_id=$(read_boot_id) || return 1
    write_pending_kernel_state "${INSTALL_PLAN[kernel_target]}" "$entry" "$boot_id" 1 || return 1
    if ! configure_grub_next_entry "$entry"; then
        if restore_grub_one_shot_state; then
            clear_pending_kernel_state || return 1
        fi
        return 1
    fi
    handle_reboot || return $?
    return "$EXIT_KERNEL_REBOOT_REQUIRED"
}

write_managed_file() {
    local path=$1 mode=$2 content=$3

    # shellcheck disable=SC2016
    run_cmd bash -c 'install -d -m 0755 "$(dirname "$2")" && printf "%s" "$1" > "$2" && chmod "$3" "$2"' \
        bash "$content" "$path" "$mode"
}

managed_file_has_content() {
    local path=$1 expected=$2 actual

    [[ -r "$path" ]] || return 1
    actual=$(<"$path")
    [[ "$actual" == "${expected%$'\n'}" ]]
}

set_root_password() {
    [[ "${ROOT_PASSWORD:-}" != *$'\n'* && "${ROOT_PASSWORD:-}" != *$'\r'* ]] || return 1
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
}

run_optional_cmd() {
    if ! run_cmd "$@"; then
        printf 'Optional tools could not be installed: %s\n' "$*" >&2
    fi
}

write_apt_source() {
    local source_line=$1 source_path=$2

    # shellcheck disable=SC2016
    run_cmd bash -c 'printf "%s\n" "$1" > "$2"' bash "$source_line" "$source_path"
}

install_apt_key() {
    local key_url=$1 keyring_path=$2

    # shellcheck disable=SC2016
    run_cmd bash -o pipefail -c 'curl -fsSL "$1" | gpg --dearmor --yes --output "$2"' \
        bash "$key_url" "$keyring_path"
}

configure_rocm_apt_repository() {
    local repo_slug=${INSTALL_PLAN[repo_slug]:-} source_line

    case "$repo_slug" in
        ubuntu2404|ubuntu2604) ;;
        *) return 1 ;;
    esac
    source_line="deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] ${ROCM_PACKAGES_ROOT}/${repo_slug} stable main"
    run_cmd install -d -m 0755 /etc/apt/keyrings || return $?
    install_apt_key "$ROCM_GPG_KEY_URL" /etc/apt/keyrings/amdrocm.gpg || return $?
    write_apt_source "$source_line" /etc/apt/sources.list.d/rocm.list
}

install_rocm_apt() {
    local artifacts=${INSTALL_PLAN[artifacts]:-} package_name legacy_layout_target
    local -a package_names=()

    [[ -n "$artifacts" ]] || return 1
    while IFS= read -r package_name || [[ -n "$package_name" ]]; do
        [[ "$package_name" != *$'\r'* && "$package_name" =~ [^[:space:]] ]] || return 1
        package_names+=("$package_name")
    done < <(printf '%s' "$artifacts")
    ((${#package_names[@]})) || return 1
    configure_rocm_apt_repository || return $?
    run_cmd apt-get update || return $?
    legacy_layout_target=$(capture_legacy_rocm_layout_target /opt/rocm) || return $?
    purge_legacy_rocm_packages || return $?
    repair_legacy_rocm_layout /opt/rocm "$legacy_layout_target" || return $?
    run_cmd apt-get install --yes "${package_names[@]}" || return $?
    rocm_apt_verification_root_exists /opt/rocm
}

install_rocm_pip() {
    local artifacts=${INSTALL_PLAN[artifacts]:-} requirement
    local venv_path="/opt/rocm-${ROCM_VERSION}-venv"
    local -a requirements=()

    [[ -n "$artifacts" ]] || return 1
    while IFS= read -r requirement || [[ -n "$requirement" ]]; do
        [[ "$requirement" != *$'\r'* && "$requirement" =~ [^[:space:]] ]] || return 1
        requirements+=("$requirement")
    done < <(printf '%s' "$artifacts")
    [[ ${#requirements[@]} -eq 1 ]] || return 1
    requirement=${requirements[0]}
    run_cmd python3 -m venv "$venv_path" || return $?
    run_cmd "${venv_path}/bin/pip" install --index-url "$ROCM_WHL_INDEX" "$requirement"
}

install_rocm_tarball() {
    local artifacts=${INSTALL_PLAN[artifacts]:-} artifact
    local install_root="/opt/rocm-${ROCM_VERSION}"
    local temp_dir stage_root backup_root archive_url archive_path status
    local had_existing_root=false
    local -a artifacts_to_install=()

    [[ -n "$artifacts" ]] || return 1
    while IFS= read -r artifact || [[ -n "$artifact" ]]; do
        [[ "$artifact" != *$'\r'* && "$artifact" =~ [^[:space:]] ]] || return 1
        artifacts_to_install+=("$artifact")
    done < <(printf '%s' "$artifacts")
    [[ ${#artifacts_to_install[@]} -eq 1 ]] || return 1
    artifact=${artifacts_to_install[0]}
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/rocm-tarball.XXXXXX") || return $?
    stage_root="${temp_dir}/staging"
    backup_root="${temp_dir}/previous-rocm-${ROCM_VERSION}"
    archive_url="${ROCM_TARBALL_ROOT}${artifact}"
    archive_path="${temp_dir}/${artifact}"

    run_cmd curl -fL --retry 0 --output "$archive_path" "$archive_url" || {
        status=$?
        run_cmd rm -rf "$temp_dir" || return $?
        return "$status"
    }
    run_cmd install -d -m 0755 "$stage_root" || {
        status=$?
        run_cmd rm -rf "$temp_dir" || return $?
        return "$status"
    }
    run_cmd tar -xzf "$archive_path" --strip-components=1 -C "$stage_root" || {
        status=$?
        run_cmd rm -rf "$temp_dir" || return $?
        return "$status"
    }
    if run_cmd test -e "$install_root"; then
        had_existing_root=true
        run_cmd mv "$install_root" "$backup_root" || {
            status=$?
            run_cmd rm -rf "$temp_dir" || return $?
            return "$status"
        }
    else
        status=$?
        if [[ $status -ne 1 ]]; then
            run_cmd rm -rf "$temp_dir" || return $?
            return "$status"
        fi
    fi
    run_cmd mv "$stage_root" "$install_root" || {
        status=$?
        if [[ "$had_existing_root" == true ]]; then
            run_cmd mv "$backup_root" "$install_root" || return $?
        fi
        run_cmd rm -rf "$temp_dir" || return $?
        return "$status"
    }
    run_cmd ln -sfn "$install_root" /opt/rocm || {
        status=$?
        run_cmd rm -rf "$install_root" || return $?
        if [[ "$had_existing_root" == true ]]; then
            run_cmd mv "$backup_root" "$install_root" || return $?
        fi
        run_cmd rm -rf "$temp_dir" || return $?
        return "$status"
    }
    if [[ "$had_existing_root" == true ]]; then
        run_cmd rm -rf "$backup_root" || return $?
    fi
    run_cmd rm -rf "$temp_dir"
}

install_rocm() {
    case "${INSTALL_PLAN[method]:-${INSTALL_METHOD:-}}" in
        apt) install_rocm_apt ;;
        pip) install_rocm_pip ;;
        tarball) install_rocm_tarball ;;
        *) return 1 ;;
    esac
}

AMDGPU_DKMS_PACKAGE_VERSION=''
AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION=''
AMDGPU_DKMS_STATUS=''

detect_existing_amdgpu_dkms() {
    local package package_status dkms_status line

    AMDGPU_DKMS_PACKAGE_VERSION=''
    AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION=''
    AMDGPU_DKMS_STATUS=''
    for package in amdgpu-dkms amdgpu-dkms-firmware; do
        if package_status=$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$package" 2>/dev/null); then
            [[ "$package_status" == installed\ * ]] || continue
            case "$package" in
                amdgpu-dkms) AMDGPU_DKMS_PACKAGE_VERSION=${package_status#installed } ;;
                amdgpu-dkms-firmware) AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION=${package_status#installed } ;;
            esac
        fi
    done
    if dkms_status=$(dkms status 2>/dev/null); then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "${line,,}" == amdgpu/* ]] || continue
            AMDGPU_DKMS_STATUS+="${AMDGPU_DKMS_STATUS:+$'\n'}${line}"
        done <<< "$dkms_status"
    fi
    [[ -n "$AMDGPU_DKMS_PACKAGE_VERSION" || -n "$AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION" || -n "$AMDGPU_DKMS_STATUS" ]]
}

amdgpu_dkms_is_clean_3140() {
    local package_version firmware_version package_pattern firmware_pattern
    local driver_base build_suffix expected_module_version line module_field kernel_field status_field
    local status_count=0 running_kernel_found=false

    [[ -n "$AMDGPU_DKMS_PACKAGE_VERSION" && -n "$AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION" && -n "$AMDGPU_DKMS_STATUS" && -n "${KERNEL_VERSION:-}" ]] || return 1
    package_version=${AMDGPU_DKMS_PACKAGE_VERSION#*:}
    firmware_version=${AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION#*:}
    package_pattern="^([0-9]+\\.[0-9]+\\.[0-9]+)\\.${AMDGPU_BUILD_ID}-(.+)$"
    firmware_pattern="^31\\.40\\.0\\.0\\.${AMDGPU_BUILD_ID}-(.+)$"
    [[ "$package_version" =~ $package_pattern ]] || return 1
    driver_base=${BASH_REMATCH[1]}
    build_suffix=${BASH_REMATCH[2]}
    [[ "$firmware_version" =~ $firmware_pattern ]] || return 1
    [[ "${BASH_REMATCH[1]}" == "$build_suffix" ]] || return 1
    expected_module_version="${driver_base}-${build_suffix}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || return 1
        module_field=${line%%,*}
        [[ "$module_field" == "amdgpu/${expected_module_version}" ]] || return 1
        kernel_field=${line#*,}
        kernel_field=${kernel_field%%,*}
        kernel_field=$(trim_field "$kernel_field")
        status_field=${line##*:}
        status_field=$(trim_field "$status_field")
        [[ "$status_field" == installed* ]] || return 1
        status_count=$((status_count + 1))
        [[ "$kernel_field" != "$KERNEL_VERSION" ]] || running_kernel_found=true
    done <<< "$AMDGPU_DKMS_STATUS"
    ((status_count > 0)) && [[ "$running_kernel_found" == true ]]
}

amdgpu_dkms_runtime_is_active() {
    local expected_gfxes=${1:-${INSTALL_PLAN[gfxes]:-}} module_path
    local pci_root=${AMDGPU_RUNTIME_PCI_ROOT:-${GPU_DETECTION_PCI_ROOT:-/sys/bus/pci/devices}}
    local kfd_root=${AMDGPU_RUNTIME_KFD_ROOT:-${GPU_DETECTION_KFD_ROOT:-/sys/class/kfd/kfd/topology/nodes}}
    local kfd_gfxes pci_records pci_gfxes='' record gfx gpu_class
    local device_path vendor device revision pci_class driver_path matched_devices=0
    [[ $# -le 1 ]] || return 1

    expected_gfxes=$(normalize_gfxes "$expected_gfxes") || return 1
    if [[ -n ${AMDGPU_RUNTIME_MODULE_PATH_OVERRIDE:-} ]]; then
        module_path=$AMDGPU_RUNTIME_MODULE_PATH_OVERRIDE
    else
        module_path=$(capture_cmd modinfo -F filename amdgpu) || return 1
    fi
    [[ "$module_path" == */updates/dkms/amdgpu.ko* ]] || return 1

    kfd_gfxes=$(detect_gpu_architectures "$kfd_root") || return 1
    [[ "$kfd_gfxes" == "$expected_gfxes" ]] || return 1
    pci_records=$(detect_gpu_architectures_from_pci "$pci_root") || return 1
    while IFS='|' read -r gfx gpu_class; do
        pci_gfxes+="${pci_gfxes:+$'\n'}${gfx}"
    done <<< "$pci_records"
    pci_gfxes=$(normalize_gfxes "$pci_gfxes") || return 1
    [[ "$pci_gfxes" == "$expected_gfxes" ]] || return 1

    for device_path in "$pci_root"/*; do
        [[ -d "$device_path" && -r "$device_path/vendor" && -r "$device_path/device" && -r "$device_path/revision" && -r "$device_path/class" ]] || continue
        IFS= read -r vendor < "$device_path/vendor" || continue
        IFS= read -r device < "$device_path/device" || continue
        IFS= read -r revision < "$device_path/revision" || continue
        IFS= read -r pci_class < "$device_path/class" || continue
        vendor=$(normalize_pci_id "$vendor") || continue
        [[ "$vendor" == 1002 ]] || continue
        pci_class=$(trim_field "$pci_class")
        pci_class=${pci_class#0x}
        pci_class=${pci_class#0X}
        [[ "$pci_class" =~ ^[[:xdigit:]]{6}$ && "${pci_class:0:2}" == 03 ]] || continue
        record=$(lookup_pci_gpu_record "$device" "$revision") || return 1
        gfx=${record%%|*}
        [[ "$expected_gfxes" == "$gfx" || "$expected_gfxes" == "$gfx"$'\n'* || "$expected_gfxes" == *$'\n'"$gfx" || "$expected_gfxes" == *$'\n'"$gfx"$'\n'* ]] || return 1
        [[ -L "$device_path/driver" ]] || return 1
        driver_path=$(readlink -f "$device_path/driver") || return 1
        [[ "${driver_path##*/}" == amdgpu ]] || return 1
        matched_devices=$((matched_devices + 1))
    done
    ((matched_devices > 0))
}

amdgpu_inbox_runtime_is_active() {
    local expected_gfxes=${1:-} module_path
    local kfd_root=${AMDGPU_RUNTIME_KFD_ROOT:-${GPU_DETECTION_KFD_ROOT:-/sys/class/kfd/kfd/topology/nodes}} kfd_gfxes
    local pci_root=${AMDGPU_RUNTIME_PCI_ROOT:-${GPU_DETECTION_PCI_ROOT:-/sys/bus/pci/devices}}
    local device_path vendor pci_class driver_path matched_devices=0

    [[ $# -eq 1 && -d "$pci_root" ]] || return 1
    expected_gfxes=$(normalize_gfxes "$expected_gfxes") || return 1
    if [[ -n ${AMDGPU_RUNTIME_MODULE_PATH_OVERRIDE:-} ]]; then
        module_path=$AMDGPU_RUNTIME_MODULE_PATH_OVERRIDE
    else
        module_path=$(capture_cmd modinfo -F filename amdgpu) || return 1
    fi
    [[ "$module_path" == */kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko* && "$module_path" != */updates/dkms/* ]] || return 1
    kfd_gfxes=$(detect_gpu_architectures "$kfd_root") || return 1
    [[ "$kfd_gfxes" == "$expected_gfxes" ]] || return 1
    for device_path in "$pci_root"/*; do
        [[ -d "$device_path" && -r "$device_path/vendor" && -r "$device_path/class" ]] || continue
        IFS= read -r vendor < "$device_path/vendor" || continue
        IFS= read -r pci_class < "$device_path/class" || continue
        vendor=$(normalize_pci_id "$vendor") || continue
        [[ "$vendor" == 1002 ]] || continue
        pci_class=$(trim_field "$pci_class")
        pci_class=${pci_class#0x}
        pci_class=${pci_class#0X}
        [[ "$pci_class" =~ ^[[:xdigit:]]{6}$ && "${pci_class:0:2}" == 03 ]] || continue
        [[ -L "$device_path/driver" ]] || return 1
        driver_path=$(readlink -f "$device_path/driver") || return 1
        [[ "${driver_path##*/}" == amdgpu ]] || return 1
        matched_devices=$((matched_devices + 1))
    done
    ((matched_devices > 0))
}

resolve_driver_status() {
    local driver_mode=${1:-} gfxes=${2:-${INSTALL_PLAN[gfxes]:-}} detection_status

    [[ $# -ge 1 && $# -le 2 ]] || return 1
    case "$driver_mode" in inbox|dkms) ;; *) return 1 ;; esac
    if detect_existing_amdgpu_dkms; then
        detection_status=0
    else
        detection_status=$?
    fi
    [[ $detection_status -eq 0 || $detection_status -eq 1 ]] || return "$detection_status"
    case "$driver_mode" in
        inbox)
            if [[ $detection_status -eq 0 ]]; then
                printf '%s\n' migration-required
            elif amdgpu_inbox_runtime_is_active "$gfxes"; then
                printf '%s\n' ready
            else
                printf '%s\n' runtime-failed
            fi
            ;;
        dkms)
            if [[ $detection_status -eq 1 ]]; then
                printf '%s\n' install-required
            elif ! amdgpu_dkms_is_clean_3140; then
                printf '%s\n' migration-required
            elif amdgpu_dkms_runtime_is_active "$gfxes"; then
                printf '%s\n' ready
            else
                printf '%s\n' reboot-required
            fi
            ;;
    esac
}

resolve_install_actions() {
    local kernel_status=${1:-} driver_status=${2:-} method=${3:-}

    [[ $# -eq 3 ]] || return 1
    case "$kernel_status" in ready|install-required|reboot-required) ;; *) return 1 ;; esac
    case "$driver_status" in ready|install-required|migration-required|reboot-required|runtime-failed) ;; *) return 1 ;; esac
    case "$method" in apt|pip|tarball) ;; *) return 1 ;; esac
    if [[ "$kernel_status" != ready ]]; then
        printf 'kernel:%s\n' "$kernel_status"
        return 0
    fi
    if [[ "$driver_status" != ready ]]; then
        printf 'driver:%s\n' "$driver_status"
        return 0
    fi
    printf 'rocm:%s\n' "$method"
}

confirm_dkms_cleanup() {
    local answer

    case "${DKMS_CLEANUP_POLICY:-auto}" in
        always) return 0 ;;
        never) return 1 ;;
        auto|ask)
            [[ "${NON_INTERACTIVE:-false}" != true ]] || return 1
            read -r -p 'Remove the existing AMDGPU DKMS installation? [y/N] ' answer || return 1
            [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
            ;;
        *) return 1 ;;
    esac
}

remove_existing_amdgpu_dkms() {
    local detection_status
    local -a packages=()

    if detect_existing_amdgpu_dkms; then
        detection_status=0
    else
        detection_status=$?
    fi
    [[ $detection_status -eq 0 ]] || return "$detection_status"
    confirm_dkms_cleanup || return 1
    if [[ -n "$AMDGPU_DKMS_PACKAGE_VERSION" ]]; then
        packages+=(amdgpu-dkms)
    fi
    if [[ -n "$AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION" ]]; then
        packages+=(amdgpu-dkms-firmware)
    fi
    if ((${#packages[@]})); then
        run_cmd dpkg --purge "${packages[@]}" || return $?
    fi
    if detect_existing_amdgpu_dkms; then
        return 1
    fi
    detection_status=$?
    [[ $detection_status -eq 1 ]] || return "$detection_status"
}

configure_amdgpu_3140_repository() {
    local os_key=${INSTALL_PLAN[os_key]:-} codename source_line

    case "$os_key" in
        ubuntu-24.04.4) codename=noble ;;
        ubuntu-26.04) codename=resolute ;;
        *) return 1 ;;
    esac
    source_line="deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] ${AMDGPU_REPOSITORY} ${codename} main"
    run_cmd install -d -m 0755 /etc/apt/keyrings || return $?
    install_apt_key "$AMDGPU_GPG_KEY_URL" /etc/apt/keyrings/rocm.gpg || return $?
    write_apt_source "$source_line" /etc/apt/sources.list.d/amdgpu.list || return $?
    run_cmd apt-get update
}

install_amdgpu_3140() {
    run_cmd apt-get install --yes amdgpu-dkms
}

migrate_driver() {
    local driver_mode=${INSTALL_PLAN[driver_mode]:-}
    local detection_status

    case "$driver_mode" in
        inbox|dkms) ;;
        *) return 1 ;;
    esac
    if detect_existing_amdgpu_dkms; then
        detection_status=0
    else
        detection_status=$?
    fi
    [[ $detection_status -eq 0 || $detection_status -eq 1 ]] || return "$detection_status"

    case "$driver_mode" in
        inbox)
            if [[ $detection_status -eq 0 ]]; then
                remove_existing_amdgpu_dkms || return $?
                REBOOT_REQUIRED=true
                DRIVER_ACTIVATION_REQUIRED=true
            fi
            ;;
        dkms)
            if [[ $detection_status -eq 0 ]] && amdgpu_dkms_is_clean_3140; then
                if amdgpu_dkms_runtime_is_active; then
                    return 0
                fi
                REBOOT_REQUIRED=true
                DRIVER_ACTIVATION_REQUIRED=true
                return 0
            fi
            [[ $detection_status -eq 1 ]] || remove_existing_amdgpu_dkms || return $?
            configure_amdgpu_3140_repository || return $?
            install_amdgpu_3140 || return $?
            detect_existing_amdgpu_dkms || return $?
            amdgpu_dkms_is_clean_3140 || return 1
            REBOOT_REQUIRED=true
            DRIVER_ACTIVATION_REQUIRED=true
            ;;
    esac
}

step_prerequisites() {
    local -a required_packages=(curl ca-certificates gnupg pciutils systemd-timesyncd)
    local -a optional_packages=(
        build-essential cmake git python3 python3-pip python3-setuptools python3-wheel
        vim htop tmux screen net-tools nfs-common rsync usbutils lshw dmidecode
        sysstat iotop unzip zip p7zip-full jq libnuma-dev
    )

    case "${INSTALL_PLAN[method]:-${INSTALL_METHOD:-}}" in
        pip) required_packages+=(python3 python3-venv python3-pip) ;;
        tarball) required_packages+=(tar gzip) ;;
        apt) ;;
        *) return 1 ;;
    esac
    run_cmd apt-get update || return $?
    run_cmd apt-get install --yes "${required_packages[@]}" || return $?
    run_optional_cmd apt-get install --yes "${optional_packages[@]}"
    run_cmd systemctl enable --now systemd-timesyncd || return $?
    run_cmd timedatectl set-ntp true
}

step_install_driver() {
    migrate_driver
}

step_install_rocm() {
    install_rocm
}

step_ssh_config() {
    local ssh_config

    [[ "${SKIP_SSH:-false}" != true ]] || return 0
    ssh_config=$'PermitRootLogin yes\nPasswordAuthentication yes\n'
    run_cmd apt-get install --yes openssh-server || return $?
    write_managed_file /etc/ssh/sshd_config.d/99-rocm-installer.conf 0644 "$ssh_config" || return $?
    run_cmd systemctl enable --now ssh || return $?
    run_cmd systemctl restart ssh || return $?
    if [[ -n "${ROOT_PASSWORD:-}" ]]; then
        set_root_password || return $?
        printf '%s\n' 'Root password updated.'
    fi
}

user_has_required_groups() {
    local user=$1 groups

    groups=$(id -nG "$user") || return $?
    [[ " $groups " == *' video '* && " $groups " == *' render '* ]]
}

rocm_install_root() {
    case "${INSTALL_PLAN[method]:-${INSTALL_METHOD:-}}" in
        apt) printf '%s\n' /opt/rocm/core-7.14 ;;
        pip) printf '/opt/rocm-%s-venv\n' "$ROCM_VERSION" ;;
        tarball) printf '%s\n' /opt/rocm ;;
        *) return 1 ;;
    esac
}

step_configure_env() {
    local actual_user install_root udev_rules linker_config profile_config

    actual_user=${SUDO_USER:-${USER:-root}}
    install_root=$(rocm_install_root) || return $?
    if ! user_has_required_groups "$actual_user"; then
        run_cmd usermod -aG video,render "$actual_user" || return $?
        REBOOT_REQUIRED=true
    fi

    udev_rules=$'KERNEL=="kfd", GROUP="render", MODE="0660"\nSUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660"\n'
    if ! managed_file_has_content /etc/udev/rules.d/70-amdgpu.rules "$udev_rules"; then
        write_managed_file /etc/udev/rules.d/70-amdgpu.rules 0644 "$udev_rules" || return $?
        run_cmd udevadm control --reload-rules || return $?
        run_cmd udevadm trigger || return $?
        REBOOT_REQUIRED=true
    fi

    linker_config="${install_root}/lib"$'\n'"${install_root}/lib64"$'\n'
    if [[ "${INSTALL_PLAN[method]:-${INSTALL_METHOD:-}}" == pip ]]; then
        profile_config="export ROCM_VENV=${install_root}"$'\n'"export ROCM_PATH=${install_root}"$'\n'"export PATH=${install_root}/bin:\$PATH"$'\n'
    else
        profile_config="export ROCM_PATH=${install_root}"$'\n'"export HIP_PATH=${install_root}"$'\n'"export PATH=${install_root}/bin:\$PATH"$'\n'"export LD_LIBRARY_PATH=${install_root}/lib:${install_root}/lib64:\${LD_LIBRARY_PATH:-}"$'\n'
    fi
    write_managed_file /etc/ld.so.conf.d/rocm.conf 0644 "$linker_config" || return $?
    write_managed_file /etc/profile.d/rocm.sh 0644 "$profile_config" || return $?
    run_cmd ldconfig
}

is_expected_rocm_link() {
    local target

    [[ -L /opt/rocm ]] || return 1
    target=$(readlink /opt/rocm) || return $?
    [[ "$target" == "/opt/rocm-${ROCM_VERSION}" ]]
}

rocm_apt_package_candidates() {
    local gfx package

    for gfx in "${!ROCM_714_ARTIFACT_RECORDS[@]}"; do
        package=$(resolve_package_name full "$gfx") || return $?
        printf '%s\n' "$package"
    done | LC_ALL=C sort -u
}

rocm_apt_installed_package_candidates() {
    local package package_status

    while IFS= read -r package; do
        if package_status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) && [[ "$package_status" == installed ]]; then
            printf '%s\n' "$package"
        fi
    done < <(rocm_apt_package_candidates)
}

detect_legacy_rocm_packages() {
    local package package_status query_output

    query_output=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null) || return $?
    while IFS=$'\t' read -r package package_status; do
        [[ "$package_status" == installed && "$package" =~ ^rocm($|-) ]] || continue
        printf '%s\n' "$package"
    done <<< "$query_output" | LC_ALL=C sort -u
}

purge_legacy_rocm_packages() {
    local output package
    local -a packages=()

    output=$(detect_legacy_rocm_packages) || return $?
    while IFS= read -r package; do
        [[ -n "$package" ]] && packages+=("$package")
    done <<< "$output"
    ((${#packages[@]})) || return 0
    run_cmd apt-get purge --yes "${packages[@]}"
}

capture_legacy_rocm_layout_target() {
    local active_root=${1:-/opt/rocm} target suffix

    [[ -L "$active_root" ]] || return 0
    target=$(readlink "$active_root") || return $?
    suffix=${target#"${active_root}-"}
    [[ "$target" == /* && "$suffix" != "$target" && -n "$suffix" && "$suffix" != */ && -d "$target" ]] || return 0
    printf '%s\n' "$target"
}

find_interrupted_rocm_layout_candidate() {
    local active_root=${1:-/opt/rocm} candidate found=""

    for candidate in "${active_root}-"*; do
        [[ -d "$candidate" && ! -L "$candidate" && -d "$candidate/core-7.14" ]] || continue
        [[ -z "$found" ]] || return 2
        found=$candidate
    done
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

repair_legacy_rocm_layout() {
    local active_root=${1:-/opt/rocm} captured_target=${2:-} candidate status

    [[ ! -e "$active_root" && ! -L "$active_root" ]] || return 0
    if [[ -n "$captured_target" && -d "$captured_target" ]]; then
        run_cmd mv "$captured_target" "$active_root"
        return $?
    fi
    candidate=$(find_interrupted_rocm_layout_candidate "$active_root")
    status=$?
    case "$status" in
        0) run_cmd mv "$candidate" "$active_root" ;;
        1) run_cmd install -d -m 0755 "$active_root" ;;
        *) return "$status" ;;
    esac
}

rocm_apt_verification_root_exists() {
    local active_root=${1:-/opt/rocm}

    [[ -d "$active_root/core-7.14" ]]
}

do_uninstall() {
    local output package failure_status=0 command_status
    local -a packages=()

    if [[ "${NON_INTERACTIVE:-false}" != true ]]; then
        read -r -p 'Remove ROCm 7.14.0? [y/N] ' output || return 1
        [[ "$output" == y || "$output" == Y || "$output" == yes || "$output" == YES ]] || return 1
    fi
    output=$(rocm_apt_installed_package_candidates) || return $?
    while IFS= read -r package; do
        [[ -n "$package" ]] && packages+=("$package")
    done <<< "$output"
    if ((${#packages[@]})); then
        if run_cmd apt-get purge --yes "${packages[@]}"; then
            :
        else
            failure_status=$?
        fi
    fi
    if run_cmd rm -rf /opt/rocm/core-7.14 "/opt/rocm-${ROCM_VERSION}" "/opt/rocm-${ROCM_VERSION}-venv"; then
        :
    else
        command_status=$?
        if ((failure_status == 0)); then
            failure_status=$command_status
        fi
    fi
    if is_expected_rocm_link; then
        if run_cmd rm -f /opt/rocm; then
            :
        else
            command_status=$?
            if ((failure_status == 0)); then
                failure_status=$command_status
            fi
        fi
    fi
    if run_cmd rm -f \
        /etc/apt/sources.list.d/rocm.list \
        /etc/apt/keyrings/amdrocm.gpg \
        /etc/profile.d/rocm.sh \
        /etc/ld.so.conf.d/rocm.conf \
        /etc/udev/rules.d/70-amdgpu.rules; then
        :
    else
        command_status=$?
        if ((failure_status == 0)); then
            failure_status=$command_status
        fi
    fi
    if run_cmd ldconfig; then
        :
    else
        command_status=$?
        if ((failure_status == 0)); then
            failure_status=$command_status
        fi
    fi
    if run_cmd udevadm control --reload-rules; then
        :
    else
        command_status=$?
        if ((failure_status == 0)); then
            failure_status=$command_status
        fi
    fi
    if ((failure_status == 0)); then
        printf '%s\n' 'ROCm 7.14.0 removed; amdgpu-dkms was left installed.'
    else
        printf '%s\n' 'ROCm cleanup completed with errors; amdgpu-dkms was left installed.' >&2
    fi
    return "$failure_status"
}

handle_reboot() {
    [[ "${REBOOT_DELAY:-0}" -eq -1 ]] && return 0
    if [[ "$REBOOT_DELAY" -eq 0 ]]; then
        run_cmd reboot
    else
        run_cmd shutdown -r "+${REBOOT_DELAY}" 'ROCm installation complete. System rebooting for driver activation.'
    fi
}

confirm_install_plan() {
    local answer

    [[ "${NON_INTERACTIVE:-false}" != true ]] || return 0
    read -r -p 'Proceed with this installation plan? [y/N] ' answer || return 1
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}

show_help() {
    cat <<EOF
ROCm 7.14.0 Installer v${SCRIPT_VERSION}

Usage: sudo $0 [options]

Options:
  --method METHOD          Installation method: apt, pip, tarball, or runfile
  --gpu-arch ARCH          Override automatic GFX detection; may be repeated
  --driver-mode MODE       Driver mode: auto, inbox, or dkms
  --skip-ssh               Skip SSH setup
  --root-password PASS     Set the root password during installation
  --skip-reboot            Skip reboot after installation
  --reboot-delay MIN       Delay reboot for 0 to 120 minutes
  --prepare-kernel         Install the reviewed kernel when it is not running
  --reboot-after-kernel    Select the reviewed kernel for one reboot attempt
  --verify-only            Verify an existing installation
  --uninstall              Remove an existing installation
  --non-interactive        Run without prompts
  --dkms-cleanup POLICY    DKMS cleanup: auto, ask, always, or never
  --help, -h               Show this help

GPU architecture lookup:
  ${ROCM_GPU_LOOKUP_URL}
  ${ROCM_GPU_LOOKUP_ZH_URL}

Explicit all-architecture fallback:
  --method runfile --gpu-arch all  (official Runfile gfx=all)
EOF
}

require_option_value() {
    [[ $# -ge 2 && -n "${2:-}" && "$2" != --* ]]
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --method)
                require_option_value "$1" "${2:-}" || return 1
                case "$2" in apt|pip|tarball|runfile) INSTALL_METHOD=$2 ;; *) return 1 ;; esac
                shift 2
                ;;
            --gpu-arch)
                require_option_value "$1" "${2:-}" || return 1
                [[ -z "$GPU_ARCHES" ]] || GPU_ARCHES+=$'\n'
                GPU_ARCHES+=$2
                shift 2
                ;;
            --driver-mode)
                require_option_value "$1" "${2:-}" || return 1
                case "$2" in auto|inbox|dkms) DRIVER_MODE=$2 ;; *) return 1 ;; esac
                shift 2
                ;;
            --skip-ssh)
                SKIP_SSH=true
                shift
                ;;
            --root-password)
                require_option_value "$1" "${2:-}" || return 1
                [[ "$2" != *$'\n'* && "$2" != *$'\r'* ]] || return 1
                ROOT_PASSWORD=$2
                shift 2
                ;;
            --skip-reboot)
                REBOOT_DELAY=-1
                shift
                ;;
            --reboot-delay)
                require_option_value "$1" "${2:-}" || return 1
                [[ "$2" =~ ^(0|[1-9][0-9]?)$|^1[01][0-9]$|^120$ ]] || return 1
                REBOOT_DELAY=$2
                shift 2
                ;;
            --prepare-kernel)
                PREPARE_KERNEL=true
                shift
                ;;
            --reboot-after-kernel)
                REBOOT_AFTER_KERNEL=true
                shift
                ;;
            --verify-only)
                VERIFY_ONLY=true
                shift
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --dkms-cleanup)
                require_option_value "$1" "${2:-}" || return 1
                case "$2" in auto|ask|always|never) DKMS_CLEANUP_POLICY=$2 ;; *) return 1 ;; esac
                shift 2
                ;;
            --help|-h)
                SHOW_HELP=true
                shift
                ;;
            *) return 1 ;;
        esac
    done
    [[ "$VERIFY_ONLY" != true || "$UNINSTALL" != true ]] || return 1
    [[ "$REBOOT_AFTER_KERNEL" != true || "$PREPARE_KERNEL" == true ]] || return 1
    [[ "$PREPARE_KERNEL" != true || ( "$VERIFY_ONLY" != true && "$UNINSTALL" != true ) ]] || return 1
    if [[ "$GPU_ARCHES" == all || "$GPU_ARCHES" == *$'\n'all || "$GPU_ARCHES" == all$'\n'* || "$GPU_ARCHES" == *$'\n'all$'\n'* ]]; then
        [[ "$GPU_ARCHES" == all && "$INSTALL_METHOD" == runfile ]] || return 1
    fi
}

preflight_error() {
    printf 'ROCm preflight failed during %s: %s\n' "$1" "$2" >&2
}

run_stage() {
    local stage=${1:-} status

    [[ $# -ge 2 && -n "$stage" ]] || return 1
    shift
    if "$@"; then
        return 0
    else
        status=$?
    fi
    printf 'ROCm installer failed during %s: status=%s os=%s kernel=%s driver=%s gfx=%s.\n' \
        "$stage" "$status" "${OS_DESCRIPTION:-${OS_ID:-unknown}-${OS_VERSION:-unknown}}" \
        "${KERNEL_VERSION:-unknown}" "${INSTALL_PLAN[driver_mode]:-${DRIVER_MODE:-unknown}}" \
        "${GPU_ARCHES//$'\n'/,}" >&2
    return "$status"
}

report_kernel_action_required() {
    printf 'ROCm kernel action required: current kernel=%s, target kernel=%s, package=%s. Re-run with --prepare-kernel to install the reviewed kernel.\n' \
        "${KERNEL_VERSION:-unknown}" "${INSTALL_PLAN[kernel_target]:-unknown}" "${INSTALL_PLAN[kernel_package]:-unknown}" >&2
}

report_kernel_reboot_required() {
    printf 'ROCm kernel reboot required: current kernel=%s, target kernel=%s, package=%s. Select the target kernel, reboot, verify uname -r, and run the installer again.\n' \
        "${KERNEL_VERSION:-unknown}" "${INSTALL_PLAN[kernel_target]:-unknown}" "${INSTALL_PLAN[kernel_package]:-unknown}" >&2
}


report_driver_runtime_failed() {
    printf 'ROCm driver runtime failed: mode=%s kernel=%s gfx=%s. The selected driver is not active; no ROCm packages were changed.\n' \
        "${INSTALL_PLAN[driver_mode]:-unknown}" "${KERNEL_VERSION:-unknown}" "${GPU_ARCHES//$'\n'/,}" >&2
}

report_driver_activation_required() {
    printf 'ROCm driver activation required: mode=%s kernel=%s gfx=%s. Reboot once, verify KFD and the active module, then run the installer again.\n' \
        "${INSTALL_PLAN[driver_mode]:-unknown}" "${KERNEL_VERSION:-unknown}" "${GPU_ARCHES//$'\n'/,}" >&2
}

stop_for_driver_activation() {
    report_driver_activation_required
    run_stage 'driver activation reboot' handle_reboot || return $?
    return "$EXIT_DRIVER_REBOOT_REQUIRED"
}
main() {
    local status

    reset_defaults
    parse_args "$@" || {
        status=$?
        preflight_error 'argument parsing' "check the options and run '$0 --help'."
        return "$status"
    }
    if [[ "$SHOW_HELP" == true ]]; then
        show_help
        return 0
    fi
    require_root || {
        status=$?
        preflight_error 'root privilege check' 're-run with sudo or as root.'
        return "$status"
    }
    detect_system || {
        status=$?
        preflight_error 'system detection' "supported Ubuntu/x86_64 is required; detected os=${OS_ID:-unknown}-${OS_VERSION:-unknown} arch=${ARCH:-unknown} kernel=${KERNEL_VERSION:-unknown}."
        return "$status"
    }
    if [[ "$UNINSTALL" == true ]]; then
        do_uninstall
        return $?
    fi
    reconcile_pending_kernel_state || return $?
    resolve_gpu_identity || {
        status=$?
        preflight_error 'GPU/KFD discovery' 'check the KFD topology or provide a supported --gpu-arch value.'
        return "$status"
    }
    if [[ "$VERIFY_ONLY" == true ]]; then
        verify_installation
        return $?
    fi
    resolve_install_plan || {
        status=$?
        preflight_error 'installation plan validation' "check supported OS/kernel/driver/gfx values: os=${OS_ID:-unknown}-${OS_VERSION:-unknown} kernel=${KERNEL_VERSION:-unknown} driver=${DRIVER_MODE:-unknown} gfx=${GPU_ARCHES//$'\n'/,}."
        return "$status"
    }
    print_install_plan || {
        status=$?
        preflight_error 'installation plan rendering' 'the validated plan could not be written or rendered; check stdout and the output destination.'
        return "$status"
    }
    confirm_install_plan || {
        status=$?
        preflight_error 'installation confirmation' 'installation was cancelled; re-run with --non-interactive if appropriate.'
        return "$status"
    }
    run_stage 'installation plan revalidation' validate_install_plan || return $?
    if [[ "${INSTALL_PLAN[kernel_status]}" != ready ]]; then
        if [[ "$PREPARE_KERNEL" != true ]]; then
            report_kernel_action_required
            return "$EXIT_KERNEL_ACTION_REQUIRED"
        fi
        run_stage 'kernel preparation' prepare_approved_kernel || return $?
        if [[ "$REBOOT_AFTER_KERNEL" == true ]]; then
            prepare_kernel_reboot || return $?
        fi
        report_kernel_reboot_required
        return "$EXIT_KERNEL_REBOOT_REQUIRED"
    fi
    case "${INSTALL_PLAN[driver_status]}" in
        runtime-failed)
            report_driver_runtime_failed
            return "$EXIT_DRIVER_RUNTIME_FAILED"
            ;;
        reboot-required)
            stop_for_driver_activation
            return $?
            ;;
    esac
    run_stage 'driver migration' step_install_driver || return $?
    if [[ "$DRIVER_ACTIVATION_REQUIRED" == true ]]; then
        stop_for_driver_activation
        return $?
    fi
    run_stage 'prerequisite installation' step_prerequisites || return $?
    run_stage 'ROCm installation' step_install_rocm || return $?
    run_stage 'SSH configuration' step_ssh_config || return $?
    run_stage 'environment configuration' step_configure_env || return $?
    run_stage 'ROCm verification' verify_installation || return $?
    if [[ "$REBOOT_REQUIRED" == true ]]; then
        run_stage 'post-install reboot' handle_reboot || return $?
    fi
}

is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}

show_startup_menu() {
    local choice

    printf '%s\n' \
        '1. Install or repair ROCm' \
        '2. Verify ROCm installation' \
        '3. Uninstall ROCm' \
        '4. Exit'
    while true; do
        printf '%s' 'Select an action [1-4]: '
        if ! IFS= read -r choice; then
            return 0
        fi
        case "$choice" in
            1)
                main
                return $?
                ;;
            2)
                main --verify-only
                return $?
                ;;
            3)
                main --uninstall
                return $?
                ;;
            4) return 0 ;;
            *) printf '%s\n' 'Invalid selection. Enter 1, 2, 3, or 4.' >&2 ;;
        esac
    done
}

run_entrypoint() {
    if (($#)); then
        main "$@"
    elif is_interactive_terminal; then
        show_startup_menu
    else
        main
    fi
}

if [[ "${ROCM_INSTALL_LIBRARY_MODE:-}" != 1 ]]; then
    run_entrypoint "$@"
fi
