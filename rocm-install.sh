#!/usr/bin/env bash
# shellcheck disable=SC2034

if [[ "${ROCM_INSTALL_LIBRARY_MODE:-}" != 1 ]]; then
    set -euo pipefail
fi

SCRIPT_VERSION=3.0.0
ROCM_VERSION=7.14.0
ROCM_SERIES=7.14
AMDGPU_RELEASE=31.40
ROCM_PACKAGES_ROOT=https://repo.amd.com/rocm/packages-multi-arch
ROCM_GPG_KEY_URL=${ROCM_PACKAGES_ROOT}/gpg/rocm.gpg
ROCM_WHL_INDEX=https://repo.amd.com/rocm/whl-multi-arch/
ROCM_TARBALL_ROOT=https://repo.amd.com/rocm/tarball-multi-arch/
AMDGPU_REPOSITORY=https://repo.radeon.com/amdgpu/${AMDGPU_RELEASE}/ubuntu
AMDGPU_GPG_KEY_URL=https://repo.radeon.com/rocm/rocm.gpg.key
SUPPORTED_OS_KEYS=ubuntu-24.04.4,ubuntu-26.04

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
    VERIFY_ONLY=false
    UNINSTALL=false
    NON_INTERACTIVE=false
    DKMS_CLEANUP_POLICY=auto
    WORKLOAD=compute
    INSTALL_METHOD=apt
    PACKAGE_PROFILE=full
    GPU_ARCH=''
    GPU_PRODUCT_NAME=''
    DRIVER_MODE=auto
    SHOW_HELP=false
    REBOOT_REQUIRED=false
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

resolve_package_name() {
    local profile=${1:-} gfx=${2:-} record package_suffix

    [[ $# -eq 2 && "$profile" == full ]] || return 1
    validate_artifact_gfx "$gfx" || return 1
    record=${ROCM_714_ARTIFACT_RECORDS[$gfx]}
    IFS='|' read -r package_suffix _ _ <<< "$record"
    printf 'amdrocm-core-sdk%s-%s\n' "$ROCM_SERIES" "$package_suffix"
}

resolve_pip_requirement() {
    local gfx=${1:-} record pip_extra

    [[ $# -eq 1 ]] || return 1
    validate_artifact_gfx "$gfx" || return 1
    record=${ROCM_714_ARTIFACT_RECORDS[$gfx]}
    IFS='|' read -r _ pip_extra _ <<< "$record"
    printf 'rocm[libraries,%s]==%s\n' "$pip_extra" "$ROCM_VERSION"
}

resolve_tarball_artifact() {
    local gfx=${1:-} record tarball_artifact

    [[ $# -eq 1 ]] || return 1
    validate_artifact_gfx "$gfx" || return 1
    record=${ROCM_714_ARTIFACT_RECORDS[$gfx]}
    IFS='|' read -r _ _ tarball_artifact <<< "$record"
    printf '%s\n' "$tarball_artifact"
}

is_supported_gpu_arch() {
    validate_artifact_gfx "${1:-}"
}

kernel_policy_for() {
    local driver_mode=${1:-} os_key=${2:-}

    [[ $# -eq 2 ]] || return 1
    case "$driver_mode|$os_key" in
        inbox\|ubuntu-24.04.4) printf '%s\n' ubuntu-hwe-6.17 ;;
        dkms\|ubuntu-24.04.4) printf '%s\n' ubuntu-ga-6.8 ;;
        inbox\|ubuntu-26.04|dkms\|ubuntu-26.04) printf '%s\n' ubuntu-ga-7.0 ;;
        *) return 1 ;;
    esac
}

validate_ubuntu_kernel() {
    local driver_mode=${1:-} os_key=${2:-} kernel_release=${3:-} policy expected actual

    [[ $# -eq 3 ]] || return 1
    policy=$(kernel_policy_for "$driver_mode" "$os_key") || return 1
    [[ "$kernel_release" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+([[:alnum:].+_-]*)$ ]] || return 1
    actual="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    case "$policy" in
        ubuntu-hwe-6.17) expected=6.17 ;;
        ubuntu-ga-6.8) expected=6.8 ;;
        ubuntu-ga-7.0) expected=7.0 ;;
        *) return 1 ;;
    esac
    [[ "$actual" == "$expected" ]]
}

resolve_driver_mode() {
    case "${1:-}" in
        auto|inbox) printf '%s\n' inbox ;;
        dkms) printf '%s\n' dkms ;;
        *) return 1 ;;
    esac
}

trim_field() {
    local value=${1:-}

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
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

detect_gpu_architecture() {
    local root=${1:-}
    local properties_file line cpu_cores='' gfx_target_version='' gfx
    local -A seen=()

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
        seen["$gfx"]=1
    done
    [[ ${#seen[@]} -eq 1 ]] || return 1
    printf '%s\n' "${!seen[@]}"
}

normalize_pci_id() {
    local value=${1:-}

    value=$(trim_field "$value")
    value=${value#0x}
    value=${value#0X}
    [[ "$value" =~ ^[[:xdigit:]]{1,4}$ ]] || return 1
    printf '%04X\n' "$((16#$value))"
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

detect_gpu_product_name() {
    local drm_root=${1:-} ids_path=${2:-}
    local device_path product_name device revision

    [[ -d "$drm_root" ]] || return 1
    for device_path in "$drm_root"/card[0-9]*/device; do
        [[ -d "$device_path" ]] || continue
        product_name=''
        [[ -r "$device_path/product_name" ]] && IFS= read -r product_name < "$device_path/product_name"
        product_name=$(trim_field "$product_name")
        if [[ -n "$product_name" ]]; then
            printf '%s\n' "$product_name"
            return 0
        fi
        [[ -r "$device_path/device" && -r "$device_path/revision" ]] || continue
        IFS= read -r device < "$device_path/device"
        IFS= read -r revision < "$device_path/revision"
        device=$(normalize_pci_id "$device") || continue
        revision=$(normalize_pci_id "$revision") || continue
        lookup_amdgpu_product_name "$ids_path" "$device" "$revision" && return 0
    done
    return 1
}

resolve_gpu_identity() {
    local requested_arch=${1:-} detected_arch

    GPU_ARCH=''
    GPU_PRODUCT_NAME=''
    [[ $# -eq 1 ]] || return 64
    [[ -z "$requested_arch" ]] || is_supported_gpu_arch "$requested_arch" || return 64
    if [[ -n "$requested_arch" ]]; then
        GPU_ARCH=$requested_arch
    else
        detected_arch=$(detect_gpu_architecture "${GPU_DETECTION_KFD_ROOT:-/sys/class/kfd/kfd/topology/nodes}") || return 1
        is_supported_gpu_arch "$detected_arch" || return 1
        GPU_ARCH=$detected_arch
    fi
    GPU_PRODUCT_NAME=$(detect_gpu_product_name "${GPU_DETECTION_DRM_ROOT:-/sys/class/drm}" "${AMDGPU_IDS_PATH:-/usr/share/libdrm/amdgpu.ids}" 2>/dev/null || true)
}

install_plan_keys() {
    printf '%s\n' gfx os_key repo_slug method artifact driver_mode
}

reset_install_plan() {
    INSTALL_PLAN=()
}

resolve_plan_artifact() {
    local method=${1:-} gfx=${2:-}

    case "$method" in
        apt) resolve_package_name full "$gfx" ;;
        pip) resolve_pip_requirement "$gfx" ;;
        tarball) resolve_tarball_artifact "$gfx" ;;
        *) return 1 ;;
    esac
}

validate_install_plan() {
    local key gfx os_key repo_slug expected_artifact expected_driver

    [[ ${#INSTALL_PLAN[@]} -eq 6 || ${#INSTALL_PLAN[@]} -eq 7 ]] || return 1
    while IFS= read -r key; do
        [[ -v "INSTALL_PLAN[$key]" ]] || return 1
    done < <(install_plan_keys)
    gfx=${INSTALL_PLAN[gfx]}
    validate_artifact_gfx "$gfx" || return 1
    os_key=${INSTALL_PLAN[os_key]}
    repo_slug=$(resolve_os_record "$os_key") || return 1
    repo_slug=${repo_slug#*|}
    [[ "${INSTALL_PLAN[repo_slug]}" == "$repo_slug" ]] || return 1
    expected_artifact=$(resolve_plan_artifact "${INSTALL_PLAN[method]}" "$gfx") || return 1
    [[ "${INSTALL_PLAN[artifact]}" == "$expected_artifact" ]] || return 1
    expected_driver=$(resolve_driver_mode "$DRIVER_MODE") || return 1
    [[ "${INSTALL_PLAN[driver_mode]}" == "$expected_driver" ]]
}

resolve_install_plan() {
    local os_key os_record repo_slug artifact driver_mode

    [[ "${OS_ID:-}" == ubuntu && "${ARCH:-}" == x86_64 ]] || return 1
    [[ "${WORKLOAD:-}" == compute && "${PACKAGE_PROFILE:-}" == full ]] || return 1
    [[ "${SKIP_SSH:-}" == true || "${SKIP_SSH:-}" == false ]] || return 1
    [[ "${DKMS_CLEANUP_POLICY:-}" == auto || "${DKMS_CLEANUP_POLICY:-}" == ask || "${DKMS_CLEANUP_POLICY:-}" == always || "${DKMS_CLEANUP_POLICY:-}" == never ]] || return 1
    [[ "${ROOT_PASSWORD:-}" != *$'\n'* && "${ROOT_PASSWORD:-}" != *$'\r'* ]] || return 1
    case "${INSTALL_METHOD:-}" in apt|pip|tarball) ;; *) return 1 ;; esac
    os_key=$(normalize_os_key "$OS_ID" "${OS_VERSION:-}") || return 1
    validate_artifact_gfx "${GPU_ARCH:-}" || return 1
    driver_mode=$(resolve_driver_mode "$DRIVER_MODE") || return 1
    if [[ -n ${KERNEL_VERSION:-} ]]; then
        validate_ubuntu_kernel "$driver_mode" "$os_key" "$KERNEL_VERSION" || return 1
    fi
    os_record=$(resolve_os_record "$os_key") || return 1
    repo_slug=${os_record#*|}
    artifact=$(resolve_plan_artifact "$INSTALL_METHOD" "$GPU_ARCH") || return 1
    INSTALL_PLAN=(
        [gfx]="$GPU_ARCH"
        [os_key]="$os_key"
        [repo_slug]="$repo_slug"
        [method]="$INSTALL_METHOD"
        [artifact]="$artifact"
        [driver_mode]="$driver_mode"
    )
    [[ -z "$GPU_PRODUCT_NAME" ]] || INSTALL_PLAN[product_name]=$GPU_PRODUCT_NAME
    validate_install_plan
}

print_install_plan() {
    local key

    validate_install_plan || return 1
    printf '%s\n' 'INSTALL PLAN'
    while IFS= read -r key; do
        printf '%s=%s\n' "$key" "${INSTALL_PLAN[$key]}"
    done < <(install_plan_keys)
    [[ -z "${INSTALL_PLAN[product_name]:-}" ]] || printf 'product_name=%s\n' "${INSTALL_PLAN[product_name]}"
}

detect_system() {
    local os_release_file=${OS_RELEASE_FILE:-/etc/os-release}

    [[ -r "$os_release_file" ]] || return 1
    # shellcheck disable=SC1090
    . "$os_release_file"
    OS_ID=${ID:-}
    OS_VERSION=${VERSION_ID:-}
    ARCH=${SYSTEM_ARCH_OVERRIDE:-$(uname -m)}
    KERNEL_VERSION=${SYSTEM_KERNEL_OVERRIDE:-$(uname -r)}
    [[ "$OS_ID" == ubuntu && "$ARCH" == x86_64 ]] || return 1
    normalize_os_key "$OS_ID" "$OS_VERSION" >/dev/null || return 1
}

require_root() {
    [[ ${EUID:-1} -eq 0 ]]
}

verify_installation() {
    local install_root rocminfo_output amd_smi_output

    if [[ "${REBOOT_REQUIRED:-false}" == true ]]; then
        printf '%s\n' 'ROCm installation is pending reboot; verification has not been run.'
        return 0
    fi
    install_root=$(rocm_install_root) || return $?
    rocminfo_output=$(capture_cmd "${install_root}/bin/rocminfo") || return $?
    amd_smi_output=$(capture_cmd "${install_root}/bin/amd-smi" version) || return $?
    [[ -n "$rocminfo_output" ]] || return 1
    [[ "$amd_smi_output" =~ (^|[^0-9.])7\.14\.0([^0-9.]|$) ]] || {
        printf '%s\n' 'ROCm verification failed: expected version 7.14.0.' >&2
        return 1
    }
    printf '%s\n' 'ROCm 7.14.0 verified with rocminfo and amd-smi.'
}

run_cmd() {
    "$@"
}

capture_cmd() {
    "$@"
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
    local package_name=${INSTALL_PLAN[artifact]:-} legacy_layout_target

    [[ -n "$package_name" ]] || return 1
    configure_rocm_apt_repository || return $?
    run_cmd apt-get update || return $?
    legacy_layout_target=$(capture_legacy_rocm_layout_target /opt/rocm) || return $?
    purge_legacy_rocm_packages || return $?
    repair_legacy_rocm_layout /opt/rocm "$legacy_layout_target" || return $?
    run_cmd apt-get install --yes "$package_name" || return $?
    rocm_apt_verification_root_exists /opt/rocm
}

install_rocm_pip() {
    local requirement=${INSTALL_PLAN[artifact]:-}
    local venv_path="/opt/rocm-${ROCM_VERSION}-venv"

    [[ -n "$requirement" ]] || return 1
    run_cmd python3 -m venv "$venv_path" || return $?
    run_cmd "${venv_path}/bin/pip" install --index-url "$ROCM_WHL_INDEX" "$requirement"
}

install_rocm_tarball() {
    local artifact=${INSTALL_PLAN[artifact]:-}
    local install_root="/opt/rocm-${ROCM_VERSION}"
    local temp_dir stage_root backup_root archive_url archive_path status
    local had_existing_root=false

    [[ -n "$artifact" ]] || return 1
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
    local line

    [[ -z "$AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION" && "$AMDGPU_DKMS_PACKAGE_VERSION" == *"${AMDGPU_RELEASE}"* && -n "$AMDGPU_DKMS_STATUS" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "${line,,}" =~ ^amdgpu/31\.40([.,[:space:]]|$) ]] || return 1
    done <<< "$AMDGPU_DKMS_STATUS"
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
            fi
            ;;
        dkms)
            if [[ $detection_status -eq 0 ]] && amdgpu_dkms_is_clean_3140; then
                return 0
            fi
            [[ $detection_status -eq 1 ]] || remove_existing_amdgpu_dkms || return $?
            configure_amdgpu_3140_repository || return $?
            install_amdgpu_3140 || return $?
            REBOOT_REQUIRED=true
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
  --method METHOD          Installation method: apt, pip, or tarball
  --gpu-arch ARCH          Override automatic KFD gfx detection
  --driver-mode MODE       Driver mode: auto, inbox, or dkms
  --skip-ssh               Skip SSH setup
  --root-password PASS     Set the root password during installation
  --skip-reboot            Skip reboot after installation
  --reboot-delay MIN       Delay reboot for 0 to 120 minutes
  --verify-only            Verify an existing installation
  --uninstall              Remove an existing installation
  --non-interactive        Run without prompts
  --dkms-cleanup POLICY    DKMS cleanup: auto, ask, always, or never
  --help, -h               Show this help
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
                case "$2" in apt|pip|tarball) INSTALL_METHOD=$2 ;; *) return 1 ;; esac
                shift 2
                ;;
            --gpu-arch)
                require_option_value "$1" "${2:-}" || return 1
                GPU_ARCH=$2
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
    [[ "$VERIFY_ONLY" != true || "$UNINSTALL" != true ]]
}

main() {
    reset_defaults
    parse_args "$@" || return $?
    if [[ "$SHOW_HELP" == true ]]; then
        show_help
        return 0
    fi
    require_root || return $?
    detect_system || return $?
    if [[ "$VERIFY_ONLY" == true ]]; then
        verify_installation
        return $?
    fi
    if [[ "$UNINSTALL" == true ]]; then
        do_uninstall
        return $?
    fi
    resolve_gpu_identity "$GPU_ARCH" || return $?
    resolve_install_plan || return $?
    print_install_plan || return $?
    confirm_install_plan || return $?
    step_install_driver || return $?
    step_prerequisites || return $?
    step_install_rocm || return $?
    step_ssh_config || return $?
    step_configure_env || return $?
    verify_installation || return $?
    if [[ "$REBOOT_REQUIRED" == true ]]; then
        handle_reboot
    fi
}

if [[ "${ROCM_INSTALL_LIBRARY_MODE:-}" != 1 ]]; then
    main "$@"
fi
