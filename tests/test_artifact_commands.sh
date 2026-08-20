#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

artifact_fixture="${ROOT_DIR}/tests/fixtures/rocm-7.14-artifacts.tsv"

assert_command_output_eq() {
    local expected=$1 message=$2 output status
    shift 2

    if output=$("$@"); then
        :
    else
        status=$?
        fail "${message} (command failed with status ${status})"
    fi
    assert_eq "$expected" "$output" "$message"
}

IFS= read -r fixture_header < "$artifact_fixture"
assert_eq $'gfx\tpackage_suffix\tpip_extra\ttarball_artifact' "$fixture_header" "artifact fixture contains apt, pip, and tarball data only"

assert_command_output_eq "apt|ubuntu2404" "Ubuntu 24.04 uses the ubuntu2404 APT repository" resolve_os_record ubuntu-24.04.4
assert_command_output_eq "apt|ubuntu2604" "Ubuntu 26.04 uses the ubuntu2604 APT repository" resolve_os_record ubuntu-26.04
assert_eq "https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404" "${ROCM_PACKAGES_ROOT}/ubuntu2404" "Ubuntu 24.04 APT repository URL is exact"
assert_eq "https://repo.amd.com/rocm/packages-multi-arch/ubuntu2604" "${ROCM_PACKAGES_ROOT}/ubuntu2604" "Ubuntu 26.04 APT repository URL is exact"
assert_eq "therock-dist-linux-multiarch-7.14.0.tar.gz" "$ROCM_MULTIARCH_TARBALL_ARTIFACT" "multi-GFX tarball artifact is fixed for ROCm 7.14.0"

row_count=0
while IFS=$'\t' read -r gfx package_suffix pip_extra tarball_artifact; do
    [[ "$gfx" == gfx ]] && continue
    row_count=$((row_count + 1))
    assert_command_output_eq "amdrocm-core-sdk7.14-${package_suffix}" "${gfx} selects the full SDK package" resolve_package_name full "$gfx"
    assert_command_output_eq "rocm[libraries,${pip_extra}]==7.14.0" "${gfx} selects the pinned wheel extra" resolve_pip_requirement "$gfx"
    assert_command_output_eq "$tarball_artifact" "${gfx} selects the reviewed tarball" resolve_tarball_artifact "$gfx"
done < "$artifact_fixture"
assert_eq "15" "$row_count" "all supported architectures have explicit artifacts"

assert_command_output_eq "amdrocm-core-sdk7.14-gfx1151" "Ryzen full SDK package is architecture-specific" resolve_package_name full gfx1151
assert_command_output_eq "rocm[libraries,device-gfx1201]==7.14.0" "RX 9070 wheel requirement is architecture-specific" resolve_pip_requirement gfx1201
assert_command_output_eq "therock-dist-linux-gfx94X-dcgpu-7.14.0.tar.gz" "MI300X tarball uses the reviewed gfx94X bundle" resolve_tarball_artifact gfx942

assert_fails "unknown package architecture has no fallback" resolve_package_name full gfx9999
assert_fails "unknown pip architecture has no fallback" resolve_pip_requirement gfx9999
assert_fails "unknown tarball architecture has no fallback" resolve_tarball_artifact gfx9999
assert_fails "generic package selection is unavailable" resolve_package_name full all
assert_fails "generic wheel selection is unavailable" resolve_pip_requirement all
assert_fails "generic tarball selection is unavailable" resolve_tarball_artifact all

multi_gfxes=$'gfx1151\ngfx1201'
multi_packages=$'amdrocm-core-sdk7.14-gfx1151\namdrocm-core-sdk7.14-gfx1201'
multi_requirement='rocm[libraries,device-gfx1151,device-gfx1201]==7.14.0'
assert_command_output_eq "$multi_requirement" "pip composes one pinned requirement from normalized GFX records" resolve_pip_requirement "$multi_gfxes"
assert_command_output_eq "$ROCM_MULTIARCH_TARBALL_ARTIFACT" "multiple GFX records select the full multiarch tarball" resolve_tarball_artifact "$multi_gfxes"
assert_fails "pip rejects an unsorted GFX collection" resolve_pip_requirement $'gfx1201\ngfx1151'
assert_fails "pip rejects duplicate GFX records" resolve_pip_requirement $'gfx1151\ngfx1151'
assert_fails "pip validates every GFX record" resolve_pip_requirement $'gfx1151\ngfx9999'
assert_fails "tarball rejects an unsorted GFX collection" resolve_tarball_artifact $'gfx1201\ngfx1151'
assert_fails "tarball rejects duplicate GFX records" resolve_tarball_artifact $'gfx1151\ngfx1151'
assert_fails "tarball validates every GFX record before selecting multiarch" resolve_tarball_artifact $'gfx1151\ngfx9999'

assert_command_output_eq "$multi_packages" "APT plans one package record per normalized GFX" resolve_plan_artifacts apt "$multi_gfxes"
assert_command_output_eq "$multi_requirement" "pip plans one composed requirement record" resolve_plan_artifacts pip "$multi_gfxes"
assert_command_output_eq "$ROCM_MULTIARCH_TARBALL_ARTIFACT" "tarball plans one full multiarch artifact record" resolve_plan_artifacts tarball "$multi_gfxes"
assert_command_output_eq "amdrocm-core-sdk7.14-gfx1151" "single-GFX APT composition stays exact" resolve_plan_artifacts apt gfx1151
assert_command_output_eq "rocm[libraries,device-gfx1151]==7.14.0" "single-GFX pip composition stays exact" resolve_plan_artifacts pip gfx1151
assert_command_output_eq "therock-dist-linux-gfx1151-7.14.0.tar.gz" "single-GFX tarball composition stays exact" resolve_plan_artifacts tarball gfx1151
assert_command_output_eq "$ROCM_RUNFILE_URL" "Runfile plans the pinned official installer" resolve_plan_artifacts runfile "$multi_gfxes"
assert_fails "APT plan composition rejects a nonnormalized GFX collection" resolve_plan_artifacts apt $'gfx1201\ngfx1151'

assert_eq $'gfxes\ngpu_count\ngpu_classes\ngpu_source\nlookup_url\nfallback_recommended\nos_key\nos_description\nrepo_slug\nmethod\nartifacts\ndriver_mode\ndriver_status\nactions\nkernel_status\nkernel_target\nkernel_package' "$(install_plan_keys)" "install plan includes GPU inventory, lookup guidance, driver state, actions, and kernel fields"
assert_command_output_eq 'AMD Radeon Graphics' "plain CSV records stay unquoted" records_to_csv 'AMD Radeon Graphics'
assert_command_output_eq '"AMD Radeon, Pro"' "CSV records containing commas are quoted" records_to_csv 'AMD Radeon, Pro'
assert_command_output_eq '"AMD ""Radeon"" Pro"' "CSV records containing quotes are quoted and escaped" records_to_csv 'AMD "Radeon" Pro'

OS_DESCRIPTION='Ubuntu 24.04.2 LTS'
MOCK_PLAN_DRIVER_STATUS=install-required
resolve_driver_status() { printf '%s\n' "$MOCK_PLAN_DRIVER_STATUS"; }
set_valid_install_plan() {
    local method=$1 gfxes=$2 product_names=${3:-} artifacts gpu_classes driver_mode fallback_recommended kernel_policy kernel_target kernel_package

    if artifacts=$(resolve_plan_artifacts "$method" "$gfxes"); then
        :
    else
        fail "valid install plan fixture could not resolve ${method} artifacts"
    fi
    gpu_classes=$(resolve_gpu_classes "$gfxes") || fail "valid install plan fixture could not resolve GPU classes"
    driver_mode=$(resolve_driver_mode "${DRIVER_MODE:-auto}" ubuntu-24.04.4 "$gpu_classes" "$gfxes") || fail "valid install plan fixture could not resolve driver policy"
    kernel_policy=$(kernel_policy_for "$driver_mode" ubuntu-24.04.4 "$gfxes") || fail "valid install plan fixture could not resolve kernel policy"
    IFS='|' read -r kernel_target kernel_package <<< "$kernel_policy"
    INSTALL_PLAN=(
        [gfxes]="$gfxes"
        [gpu_count]="${GPU_DEVICE_COUNT:-0}"
        [gpu_classes]="$gpu_classes"
        [gpu_source]=explicit
        [lookup_url]="$ROCM_GPU_LOOKUP_URL"
        [fallback_recommended]=$([[ "$gfxes" == *$'\n'* ]] && printf true || printf false)
        [os_key]=ubuntu-24.04.4
        [os_description]="$OS_DESCRIPTION"
        [repo_slug]=ubuntu2404
        [method]="$method"
        [artifacts]="$artifacts"
        [driver_mode]="$driver_mode"
        [driver_status]="$MOCK_PLAN_DRIVER_STATUS"
        [actions]="$(resolve_install_actions install-required "$MOCK_PLAN_DRIVER_STATUS" "$method")"
        [kernel_status]=install-required
        [kernel_target]="$kernel_target"
        [kernel_package]="$kernel_package"
    )
    [[ $# -eq 2 ]] || INSTALL_PLAN[product_names]=$product_names
}

valid_plan_gfxes=$'gfx1200\ngfx1201'
valid_plan_packages=$'amdrocm-core-sdk7.14-gfx1200\namdrocm-core-sdk7.14-gfx1201'

set_valid_install_plan apt "$valid_plan_gfxes" $'AMD Radeon 8060S Graphics\nAMD Radeon AI PRO R9700'
assert_success "normalized plural install plan validates" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
# shellcheck disable=SC2154
INSTALL_PLAN[unknown]=value
assert_fails "install plan rejects unknown keys" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
unset 'INSTALL_PLAN[artifacts]'
assert_fails "install plan rejects missing required keys" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
INSTALL_PLAN[gfx]=gfx1151
assert_fails "install plan rejects legacy scalar GFX keys" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
INSTALL_PLAN[gfxes]=$'gfx1201\ngfx1151'
assert_fails "install plan rejects unsorted GFX records" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
INSTALL_PLAN[gfxes]=$'gfx1151\ngfx1151'
assert_fails "install plan rejects duplicate GFX records" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
INSTALL_PLAN[gfxes]=$'gfx1151\ngfx9999'
assert_fails "install plan rejects unsupported GFX records" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
INSTALL_PLAN[artifacts]=amdrocm-core-sdk7.14-gfx1151
assert_fails "install plan rejects method-specific artifact mismatches" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
INSTALL_PLAN[artifacts]=$'amdrocm-core-sdk7.14-gfx1201\namdrocm-core-sdk7.14-gfx1151'
assert_fails "install plan rejects reversed valid APT artifact records byte-for-byte" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
INSTALL_PLAN[repo_slug]=ubuntu2604
assert_fails "install plan rejects a repository that mismatches the OS" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
INSTALL_PLAN[driver_mode]=auto
assert_fails "install plan rejects unresolved driver modes" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes"
DRIVER_MODE=auto
INSTALL_PLAN[driver_mode]=inbox
assert_fails "install plan rejects a driver mode that mismatches the requested contextual policy" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes" $'AMD Radeon AI PRO R9700\nAMD Radeon 8060S Graphics'
assert_fails "install plan rejects unsorted product-name records" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes" $'AMD Radeon 8060S Graphics\nAMD Radeon 8060S Graphics'
assert_fails "install plan rejects duplicate product-name records" validate_install_plan

set_valid_install_plan apt "$valid_plan_gfxes" ''
assert_fails "install plan rejects an empty optional product-name collection" validate_install_plan

MOCK_KERNEL_METAPACKAGE_INSTALLED=false
kernel_package_is_installed() { [[ "$MOCK_KERNEL_METAPACKAGE_INSTALLED" == true ]]; }

OS_ID=ubuntu
OS_VERSION=24.04
ARCH=x86_64
KERNEL_VERSION=''
WORKLOAD=compute
PACKAGE_PROFILE=full
SKIP_SSH=true
DKMS_CLEANUP_POLICY=auto
ROOT_PASSWORD=''
INSTALL_METHOD=apt
DRIVER_MODE=auto
GPU_ARCHES=$valid_plan_gfxes
GPU_CLASSES=''
GPU_DETECTION_SOURCE=explicit
GPU_PRODUCT_NAMES=$'AMD Radeon 8060S Graphics\nAMD Radeon AI PRO R9700'
assert_success "install plan resolves from normalized GPU identity collections" resolve_install_plan
assert_eq "$valid_plan_gfxes" "${INSTALL_PLAN[gfxes]}" "resolved plan retains normalized GFX records"
assert_eq "$valid_plan_packages" "${INSTALL_PLAN[artifacts]}" "resolved APT plan retains one package per GFX"
assert_eq "$GPU_PRODUCT_NAMES" "${INSTALL_PLAN[product_names]}" "resolved plan retains normalized product-name records"
assert_eq "18" "${#INSTALL_PLAN[@]}" "resolved plan contains GPU inventory, lookup guidance, host, driver, actions, kernel, and product names"
assert_eq 0 "${INSTALL_PLAN[gpu_count]}" "explicit pre-provision plan records an unknown physical count"
assert_eq radeon "${INSTALL_PLAN[gpu_classes]}" "resolved plan records the Radeon policy class"
assert_eq explicit "${INSTALL_PLAN[gpu_source]}" "resolved plan records the explicit GPU source"
assert_eq "$ROCM_GPU_LOOKUP_URL" "${INSTALL_PLAN[lookup_url]}" "resolved plan records the official lookup URL"
assert_eq true "${INSTALL_PLAN[fallback_recommended]}" "heterogeneous GFX plan recommends Runfile all"
assert_eq dkms "${INSTALL_PLAN[driver_mode]}" "Ubuntu 24 Radeon auto mode resolves to DKMS"
assert_eq install-required "${INSTALL_PLAN[driver_status]}" "missing AMDGPU DKMS resolves install-required"
assert_eq 'kernel:install-required' "${INSTALL_PLAN[actions]}" "non-ready kernel blocks later actions"
assert_eq install-required "${INSTALL_PLAN[kernel_status]}" "mismatched or unavailable kernel metapackage requires installation"
assert_eq '6.8.*-generic' "${INSTALL_PLAN[kernel_target]}" "non-Ryzen Ubuntu 24 plan records the generic target"
assert_eq linux-generic "${INSTALL_PLAN[kernel_package]}" "non-Ryzen Ubuntu 24 plan records the generic metapackage"

expected_multi_plan=$'INSTALL PLAN\ngfx=gfx1200,gfx1201\ngpu_count=0\ngpu_class=radeon\ngpu_source=explicit\nlookup_url=https://rocm.docs.amd.com/en/latest/install/rocm.html?fam=all&w=compute&os=ubuntu&ubuntu-ver=24.04&i=runfile\nfallback_recommended=true\nos=Ubuntu 24.04.2 LTS\nos_policy=ubuntu-24.04.4\nmethod=apt\nartifact=amdrocm-core-sdk7.14-gfx1200,amdrocm-core-sdk7.14-gfx1201\ndriver_mode=dkms\ndriver_status=install-required\naction=kernel:install-required\nkernel_status=install-required\nkernel_target=6.8.*-generic\nkernel_package=linux-generic\nproduct_name=AMD Radeon 8060S Graphics,AMD Radeon AI PRO R9700\nrecommendation=--method runfile --gpu-arch all'
assert_command_output_eq "$expected_multi_plan" "multi-GFX install plan rendering includes GPU policy and omits repository internals" print_install_plan

GPU_ARCHES=gfx1201
GPU_CLASSES=radeon
GPU_DETECTION_SOURCE=kfd+unmapped-pci
GPU_DEVICE_COUNT=4
GPU_UNMAPPED_PCI=$'0000:01:00.0|1002:7001|0001\n0000:02:00.0|1002:7002|0001\n0000:03:00.0|1002:7003|0001\n0000:04:00.0|1002:7004|0001'
GPU_PRODUCT_NAMES='AMD Radeon AI PRO R9700'
KERNEL_VERSION=6.8.0-138-generic
assert_success "four-R9700 identity resolves an install plan" resolve_install_plan
assert_eq 4 "${INSTALL_PLAN[gpu_count]}" "four-R9700 plan preserves physical GPU count"
assert_eq kfd+unmapped-pci "${INSTALL_PLAN[gpu_source]}" "four-R9700 plan records unmapped PCI evidence"
assert_contains "${INSTALL_PLAN[unmapped_pci]}" "1002:7004" "four-R9700 plan retains every unmapped PCI record"
assert_eq false "${INSTALL_PLAN[fallback_recommended]}" "four identical R9700 cards need one gfx1201 artifact"

INSTALL_METHOD=runfile
GPU_RUNFILE_GFX=all
assert_success "four-R9700 identity resolves an explicit Runfile all plan" resolve_install_plan
assert_eq runfile "${INSTALL_PLAN[method]}" "Runfile plan records its method"
assert_eq all "${INSTALL_PLAN[runfile_gfx]}" "Runfile plan records gfx=all"
assert_eq "$ROCM_RUNFILE_URL" "${INSTALL_PLAN[artifacts]}" "Runfile plan pins the official artifact"
assert_contains "$(print_install_plan)" "runfile_gfx=all" "Runfile confirmation renders the all-architecture payload"
INSTALL_METHOD=apt
GPU_RUNFILE_GFX=''

GPU_ARCHES=$'gfx1151\ngfx1201'
GPU_CLASSES=''
GPU_DETECTION_SOURCE=explicit
GPU_DEVICE_COUNT=0
GPU_UNMAPPED_PCI=''
GPU_PRODUCT_NAMES=''
mixed_class_output="${TEST_TEMP_ROOT}/mixed-class-output"
if resolve_install_plan 2> "$mixed_class_output"; then
    fail "mixed Ryzen and Radeon classes fail closed"
fi
assert_contains "$(<"$mixed_class_output")" "--method runfile --gpu-arch all" "mixed-class failure prints the explicit Runfile fallback"

GPU_DEVICE_COUNT=0
GPU_UNMAPPED_PCI=''
GPU_DETECTION_SOURCE=explicit

GPU_CLASSES=''
GPU_ARCHES=gfx1151
GPU_PRODUCT_NAMES='AMD Radeon 8060S Graphics'
KERNEL_VERSION=6.14.0-1020-oem
MOCK_KERNEL_METAPACKAGE_INSTALLED=false
assert_success "matching Ryzen OEM kernel resolves a ready plan" resolve_install_plan
assert_eq ready "${INSTALL_PLAN[kernel_status]}" "matching uname is ready without a metapackage query"
assert_eq '6.14.*-oem' "${INSTALL_PLAN[kernel_target]}" "ready Ryzen plan retains the OEM target"
assert_eq linux-oem-6.14 "${INSTALL_PLAN[kernel_package]}" "ready Ryzen plan retains the OEM metapackage"

KERNEL_VERSION=6.8.0-101-generic
MOCK_KERNEL_METAPACKAGE_INSTALLED=true
assert_success "installed target metapackage with a mismatched uname requires reboot" resolve_install_plan
assert_eq install-required "${INSTALL_PLAN[kernel_status]}" "installed target metapackage without a verified boot image requires installation"

MOCK_KERNEL_METAPACKAGE_INSTALLED=false
assert_success "missing target metapackage with a mismatched uname requires installation" resolve_install_plan
assert_eq install-required "${INSTALL_PLAN[kernel_status]}" "missing target metapackage requires installation"

GPU_ARCHES=$valid_plan_gfxes
GPU_PRODUCT_NAMES=''
KERNEL_VERSION=''

set_valid_install_plan pip "$valid_plan_gfxes"
expected_pip_plan=$'INSTALL PLAN\ngfx=gfx1200,gfx1201\ngpu_count=0\ngpu_class=radeon\ngpu_source=explicit\nlookup_url=https://rocm.docs.amd.com/en/latest/install/rocm.html?fam=all&w=compute&os=ubuntu&ubuntu-ver=24.04&i=runfile\nfallback_recommended=true\nos=Ubuntu 24.04.2 LTS\nos_policy=ubuntu-24.04.4\nmethod=pip\nartifact="rocm[libraries,device-gfx1200,device-gfx1201]==7.14.0"\ndriver_mode=dkms\ndriver_status=install-required\naction=kernel:install-required\nkernel_status=install-required\nkernel_target=6.8.*-generic\nkernel_package=linux-generic\nrecommendation=--method runfile --gpu-arch all'
assert_command_output_eq "$expected_pip_plan" "pip plan renders GPU policy and quotes its comma-delimited requirement" print_install_plan

set_valid_install_plan tarball gfx1151
expected_single_plan=$'INSTALL PLAN\ngfx=gfx1151\ngpu_count=0\ngpu_class=ryzen\ngpu_source=explicit\nlookup_url=https://rocm.docs.amd.com/en/latest/install/rocm.html?fam=all&w=compute&os=ubuntu&ubuntu-ver=24.04&i=runfile\nfallback_recommended=false\nos=Ubuntu 24.04.2 LTS\nos_policy=ubuntu-24.04.4\nmethod=tarball\nartifact=therock-dist-linux-gfx1151-7.14.0.tar.gz\ndriver_mode=inbox\ndriver_status=install-required\naction=kernel:install-required\nkernel_status=install-required\nkernel_target=6.14.*-oem\nkernel_package=linux-oem-6.14'
assert_command_output_eq "$expected_single_plan" "single-GFX install plan renders its Ryzen policy" print_install_plan
assert_not_contains "$expected_single_plan" "repo_slug" "install plan rendering omits repo_slug"
assert_not_contains "$expected_single_plan" "product_name" "install plan rendering omits absent optional product names"

set_valid_install_plan apt gfx1151 $'AMD "Creator" Edition\nAMD Radeon, Pro'
expected_quoted_product_plan=$'INSTALL PLAN\ngfx=gfx1151\ngpu_count=0\ngpu_class=ryzen\ngpu_source=explicit\nlookup_url=https://rocm.docs.amd.com/en/latest/install/rocm.html?fam=all&w=compute&os=ubuntu&ubuntu-ver=24.04&i=runfile\nfallback_recommended=false\nos=Ubuntu 24.04.2 LTS\nos_policy=ubuntu-24.04.4\nmethod=apt\nartifact=amdrocm-core-sdk7.14-gfx1151\ndriver_mode=inbox\ndriver_status=install-required\naction=kernel:install-required\nkernel_status=install-required\nkernel_target=6.14.*-oem\nkernel_package=linux-oem-6.14\nproduct_name="AMD ""Creator"" Edition","AMD Radeon, Pro"'
assert_command_output_eq "$expected_quoted_product_plan" "product names containing commas and quotes render with GPU policy" print_install_plan

print_plan_to_full() {
    print_install_plan > /dev/full
}

set_valid_install_plan apt gfx1151
assert_fails "plan output errors propagate without product names" print_plan_to_full
set_valid_install_plan apt gfx1151 'AMD Radeon Graphics'
assert_fails "plan output errors propagate with product names" print_plan_to_full

GPU_ARCHES=$valid_plan_gfxes
GPU_PRODUCT_NAMES=''
assert_success "a valid plan resolves before stale-state regression" resolve_install_plan
GPU_ARCHES=$'gfx1151\ngfx9999'
assert_fails "invalid GPU architecture collection rejects plan resolution" resolve_install_plan
assert_eq "0" "${#INSTALL_PLAN[@]}" "failed plan resolution clears the previously valid plan"
assert_fails "no stale install plan can print after failed resolution" print_install_plan

assert_command_before() {
    local first=$1 second=$2 commands=$3 message=$4 prefix

    [[ "$commands" == *"$first"* && "$commands" == *"$second"* ]] || fail "$message (missing command)"
    prefix=${commands%%"$second"*}
    [[ "$prefix" == *"$first"* ]] || fail "$message (wrong order)"
    PASS_COUNT=$((PASS_COUNT + 1))
}

recorded_command_count() {
    local command_fragment=$1 commands=$2 count=0

    while [[ "$commands" == *"$command_fragment"* ]]; do
        commands=${commands#*"$command_fragment"}
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

assert_recorded_command_count() {
    local expected=$1 command_fragment=$2 commands=$3 message=$4

    assert_eq "$expected" "$(recorded_command_count "$command_fragment" "$commands")" "$message"
}

recorded_rocm_sdk_apt_install_commands() {
    local commands=$1 command

    while IFS= read -r command || [[ -n "$command" ]]; do
        [[ "$command" == apt-get\ install\ --yes\ amdrocm-core-sdk7.14-* ]] || continue
        printf '%s\n' "$command"
    done < <(printf '%s' "$commands")
}

recorded_rocm_sdk_apt_install_count() {
    local commands=$1 command count=0

    while IFS= read -r command || [[ -n "$command" ]]; do
        [[ "$command" == apt-get\ install\ --yes\ amdrocm-core-sdk7.14-* ]] || continue
        count=$((count + 1))
    done < <(printf '%s' "$commands")
    printf '%s\n' "$count"
}

set_installer_plan() {
    local method=$1 gfxes=$2 artifacts=$3

    INSTALL_PLAN=(
        [gfxes]="$gfxes"
        [os_key]=ubuntu-24.04.4
        [repo_slug]=ubuntu2404
        [method]="$method"
        [artifacts]="$artifacts"
        [driver_mode]=inbox
    )
}

MOCK_DPKG_QUERY_OUTPUT=""
dpkg-query() {
    [[ -n "$MOCK_DPKG_QUERY_OUTPUT" ]] || return 0
    printf '%s\n' "$MOCK_DPKG_QUERY_OUTPUT"
}

layout_root="${TEST_TEMP_ROOT}/rocm"
layout_run_cmd() {
    recording_run_cmd "$@"
    command "$@"
}

reset_test_state
normal_legacy_root="${layout_root}-7.1.0"
mkdir -p "${normal_legacy_root}/core-7.14"
ln -s "$normal_legacy_root" "$layout_root"
captured_legacy_root=$(capture_legacy_rocm_layout_target "$layout_root")
rm "$layout_root"
run_cmd() { layout_run_cmd "$@"; }
assert_success "legacy symlink target is restored after package purge" repair_legacy_rocm_layout "$layout_root" "$captured_legacy_root"
assert_success "restored legacy layout contains the APT verification root" rocm_apt_verification_root_exists "$layout_root"
assert_contains "$RECORDED_COMMANDS" "mv ${normal_legacy_root} ${layout_root}" "legacy symlink recovery atomically promotes the captured target"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0"
interrupted_legacy_root="${layout_root}-7.1.0"
mkdir -p "${interrupted_legacy_root}/core-7.14"
run_cmd() { layout_run_cmd "$@"; }
assert_success "interrupted legacy layout is recovered from one candidate" repair_legacy_rocm_layout "$layout_root" ""
assert_success "interrupted recovery creates the APT verification root" rocm_apt_verification_root_exists "$layout_root"
assert_contains "$RECORDED_COMMANDS" "mv ${interrupted_legacy_root} ${layout_root}" "interrupted recovery atomically promotes its only candidate"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0" "${layout_root}-7.1.1"
mkdir -p "${layout_root}-7.1.0/core-7.14" "${layout_root}-7.1.1/core-7.14"
run_cmd() { layout_run_cmd "$@"; }
assert_fails "multiple interrupted legacy layout candidates fail safely" repair_legacy_rocm_layout "$layout_root" ""
assert_fails "ambiguous recovery leaves the active ROCm root absent" test -e "$layout_root"
assert_not_contains "$RECORDED_COMMANDS" "mv " "ambiguous recovery does not move either candidate"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0" "${layout_root}-7.1.1"
mkdir -p "${layout_root}/core-7.14"
run_cmd() { layout_run_cmd "$@"; }
assert_success "existing correct ROCm root is left unchanged" repair_legacy_rocm_layout "$layout_root" ""
assert_eq "" "$RECORDED_COMMANDS" "existing correct ROCm root needs no layout command"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0"
mkdir -p "${layout_root}-7.1.0/core-7.14"
layout_move_fails() {
    recording_run_cmd "$@"
    [[ "$1" != mv ]] || return 23
    command "$@"
}
run_cmd() { layout_move_fails "$@"; }
assert_status 23 "legacy layout move failure propagates" repair_legacy_rocm_layout "$layout_root" ""
assert_fails "failed legacy layout move leaves the active root absent" test -e "$layout_root"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0"
run_cmd() { layout_run_cmd "$@"; }
assert_success "fresh APT host creates the active ROCm root" repair_legacy_rocm_layout "$layout_root" ""
assert_success "fresh APT host creates the active ROCm directory" test -d "$layout_root"
assert_contains "$RECORDED_COMMANDS" "install -d -m 0755 ${layout_root}" "fresh APT host creates its active ROCm directory"

reset_test_state
MOCK_DPKG_QUERY_OUTPUT=$'rocm-dev\tinstalled\nrocm\tinstalled\nrocm-core\tconfig-files\nrocmfoo\tinstalled\nrocm:amd64\tinstalled\namdrocm\tinstalled\namdrocm-core-sdk7.14-gfx1151\tinstalled'
assert_eq $'rocm\nrocm-dev' "$(detect_legacy_rocm_packages)" "legacy package detection selects only installed exact rocm names in deterministic order"

capture_legacy_rocm_layout_target() { printf '%s\n' /opt/rocm-7.1.0; }
repair_legacy_rocm_layout() { recording_run_cmd mv "$2" "$1"; }
rocm_apt_verification_root_exists() { return 0; }

reset_test_state
run_cmd() { recording_run_cmd "$@"; }
rocm_apt_verification_root_exists() { return 0; }
MOCK_DPKG_QUERY_OUTPUT=$'rocm-dev\tinstalled\nrocm\tinstalled\namdrocm-core-sdk7.14-gfx1151\tinstalled'
apt_transaction='apt-get install --yes amdrocm-core-sdk7.14-gfx1151 amdrocm-core-sdk7.14-gfx1201'
set_installer_plan apt "$multi_gfxes" "$multi_packages"
assert_success "multi-GFX APT installation configures the ROCm multi-arch repository" install_rocm_apt
assert_contains "$RECORDED_COMMANDS" "install -d -m 0755 /etc/apt/keyrings" "APT creates the keyring directory"
assert_contains "$RECORDED_COMMANDS" "${ROCM_GPG_KEY_URL}" "APT downloads the ROCm signing key"
assert_contains "$RECORDED_COMMANDS" "/etc/apt/keyrings/amdrocm.gpg" "APT stores the dearmored key at the required path"
assert_contains "$RECORDED_COMMANDS" "${ROCM_PACKAGES_ROOT}/ubuntu2404" "APT writes the Ubuntu 24.04 ROCm source URL"
assert_contains "$RECORDED_COMMANDS" 'stable\ main' "APT writes the stable ROCm source suite and component"
assert_contains "$RECORDED_COMMANDS" "apt-get update" "APT refreshes package metadata after repository setup"
assert_contains "$RECORDED_COMMANDS" "apt-get purge --yes rocm rocm-dev" "APT removes only installed legacy ROCm packages"
assert_not_contains "$RECORDED_COMMANDS" "apt-get purge --yes amdrocm" "APT never purges amdrocm packages during legacy migration"
assert_recorded_command_count "1" "${ROCM_PACKAGES_ROOT}/ubuntu2404" "$RECORDED_COMMANDS" "APT configures its repository once for all GFX packages"
assert_recorded_command_count "1" "apt-get update" "$RECORDED_COMMANDS" "APT refreshes package metadata once for all GFX packages"
assert_recorded_command_count "1" "apt-get purge --yes rocm rocm-dev" "$RECORDED_COMMANDS" "APT migrates legacy ROCm packages once for all GFX packages"
assert_recorded_command_count "1" "mv /opt/rocm-7.1.0 /opt/rocm" "$RECORDED_COMMANDS" "APT repairs the legacy layout once for all GFX packages"
assert_command_before "apt-get purge --yes rocm rocm-dev" "$apt_transaction" "$RECORDED_COMMANDS" "legacy ROCm purge happens before the current APT package install"
assert_command_before "apt-get purge --yes rocm rocm-dev" "mv /opt/rocm-7.1.0 /opt/rocm" "$RECORDED_COMMANDS" "legacy layout repair happens after package purge"
assert_command_before "mv /opt/rocm-7.1.0 /opt/rocm" "$apt_transaction" "$RECORDED_COMMANDS" "legacy layout repair happens before current package installation"
assert_eq "1" "$(recorded_rocm_sdk_apt_install_count "$RECORDED_COMMANDS")" "APT executes exactly one ROCm SDK install transaction"
assert_eq "$apt_transaction" "$(recorded_rocm_sdk_apt_install_commands "$RECORDED_COMMANDS")" "the sole ROCm SDK install transaction contains both exact packages"

reset_test_state
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan apt "$multi_gfxes" ''
assert_fails "APT rejects a zero-record artifact collection before repository mutation" install_rocm_apt
assert_eq '' "$RECORDED_COMMANDS" "zero-record APT artifact collection runs no commands"

reset_test_state
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan apt "$multi_gfxes" $'amdrocm-core-sdk7.14-gfx1151\n\namdrocm-core-sdk7.14-gfx1201'
assert_fails "APT rejects a blank artifact record before repository mutation" install_rocm_apt
assert_eq '' "$RECORDED_COMMANDS" "blank APT artifact record runs no commands"

reset_test_state
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan apt "$multi_gfxes" $'amdrocm-core-sdk7.14-gfx1151\r\namdrocm-core-sdk7.14-gfx1201'
assert_fails "APT rejects a carriage-return artifact record before repository mutation" install_rocm_apt
assert_eq '' "$RECORDED_COMMANDS" "carriage-return APT artifact record runs no commands"

reset_test_state
RUN_CMD_STATUS=23
set_installer_plan apt gfx1201 "$(resolve_package_name full gfx1201)"
assert_status 23 "a required APT repository command propagates its exact status" install_rocm_apt
assert_not_contains "$RECORDED_COMMANDS" "apt-get update" "APT does not continue after a repository failure"

apt_purge_fails() {
    recording_run_cmd "$@"
    [[ "$1 $2" != "apt-get purge" ]] || return 23
}

reset_test_state
MOCK_DPKG_QUERY_OUTPUT=$'rocm\tinstalled\namdrocm-core-sdk7.14-gfx1151\tinstalled'
run_cmd() { apt_purge_fails "$@"; }
set_installer_plan apt gfx1151 "$(resolve_package_name full gfx1151)"
assert_status 23 "legacy ROCm purge failure stops the current APT install" install_rocm_apt
assert_contains "$RECORDED_COMMANDS" "apt-get purge --yes rocm" "APT attempts the exact legacy package purge"
assert_not_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "APT does not install the current package after a legacy purge failure"

reset_test_state
RUN_CMD_STATUS=0
MOCK_DPKG_QUERY_OUTPUT=""
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan pip "$multi_gfxes" "$multi_requirement"
assert_success "pip installs the multi-GFX ROCm requirement into the fixed virtual environment" install_rocm_pip
assert_contains "$RECORDED_COMMANDS" "python3 -m venv /opt/rocm-7.14.0-venv" "pip creates the versioned virtual environment"
assert_contains "$RECORDED_COMMANDS" "/opt/rocm-7.14.0-venv/bin/pip install --index-url ${ROCM_WHL_INDEX}" "pip uses the multi-architecture wheel index"
assert_contains "$RECORDED_COMMANDS" 'rocm\[libraries\,device-gfx1151\,device-gfx1201\]==7.14.0' "pip installs one requirement containing both architecture extras"
assert_recorded_command_count "1" "/opt/rocm-7.14.0-venv/bin/pip install --index-url" "$RECORDED_COMMANDS" "pip executes exactly one install command"

reset_test_state
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan pip "$multi_gfxes" $'rocm[libraries,device-gfx1151]==7.14.0\nrocm[libraries,device-gfx1201]==7.14.0'
assert_fails "pip rejects multiple artifact records before virtual-environment mutation" install_rocm_pip
assert_eq '' "$RECORDED_COMMANDS" "multiple pip artifact records run no commands"

reset_test_state
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan pip "$multi_gfxes" ''
assert_fails "pip rejects a zero-record artifact collection before virtual-environment mutation" install_rocm_pip
assert_eq '' "$RECORDED_COMMANDS" "zero-record pip artifact collection runs no commands"

reset_test_state
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan pip "$multi_gfxes" "${multi_requirement}"$'\r'
assert_fails "pip rejects a carriage-return artifact record before virtual-environment mutation" install_rocm_pip
assert_eq '' "$RECORDED_COMMANDS" "carriage-return pip artifact record runs no commands"

tarball_temp_dir="${TEST_TEMP_ROOT}/tarball-work"
tarball_stage_dir="${tarball_temp_dir}/staging"
tarball_backup_dir="${tarball_temp_dir}/previous-rocm-7.14.0"
mktemp_call_count_file="${TEST_TEMP_ROOT}/mktemp-call-count"
reset_mktemp_call_count() {
    printf '0\n' > "$mktemp_call_count_file"
}

mktemp_call_count() {
    local count

    count=$(<"$mktemp_call_count_file")
    printf '%s\n' "$count"
}

mktemp() {
    local count

    [[ "$1" == -d ]] || return 1
    count=$(<"$mktemp_call_count_file")
    printf '%s\n' "$((count + 1))" > "$mktemp_call_count_file"
    printf '%s\n' "$tarball_temp_dir"
}

reset_test_state
reset_mktemp_call_count
tarball_artifact=$ROCM_MULTIARCH_TARBALL_ARTIFACT
set_installer_plan tarball "$multi_gfxes" "$tarball_artifact"
assert_success "tarball installation stages the one reviewed multiarch artifact" install_rocm_tarball
assert_contains "$RECORDED_COMMANDS" "${ROCM_TARBALL_ROOT}${tarball_artifact}" "tarball download uses the explicit artifact URL"
assert_contains "$RECORDED_COMMANDS" "tar -xzf ${tarball_temp_dir}/${tarball_artifact}" "tarball extraction uses the downloaded artifact"
assert_contains "$RECORDED_COMMANDS" "-C ${tarball_stage_dir}" "tarball extraction targets only temporary staging"
assert_command_before "tar -xzf" "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "tarball promotes staging only after extraction"
assert_command_before "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "ln -sfn /opt/rocm-7.14.0 /opt/rocm" "$RECORDED_COMMANDS" "tarball updates the active link only after promotion"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "tarball cleanup removes the temporary directory"
assert_recorded_command_count "1" "curl -fL --retry 0 --output" "$RECORDED_COMMANDS" "tarball downloads one multiarch archive"
assert_recorded_command_count "1" "tar -xzf" "$RECORDED_COMMANDS" "tarball extracts one multiarch archive"
assert_not_contains "$RECORDED_COMMANDS" 'therock-dist-linux-gfx1151' "tarball does not download a per-GFX archive"
assert_not_contains "$RECORDED_COMMANDS" 'therock-dist-linux-gfx120X-all' "tarball does not download a GFX-family archive"
assert_eq "1" "$(mktemp_call_count)" "tarball creates one staging directory for the one multiarch archive"

reset_test_state
reset_mktemp_call_count
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan tarball "$multi_gfxes" $'therock-dist-linux-multiarch-7.14.0.tar.gz\ntherock-dist-linux-gfx1151-7.14.0.tar.gz'
assert_fails "tarball rejects multiple artifact records before staging mutation" install_rocm_tarball
assert_eq '' "$RECORDED_COMMANDS" "multiple tarball artifact records run no commands"
assert_eq "0" "$(mktemp_call_count)" "multiple tarball artifact records do not create staging"

reset_test_state
reset_mktemp_call_count
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan tarball "$multi_gfxes" $'\t'
assert_fails "tarball rejects a blank artifact record before staging mutation" install_rocm_tarball
assert_eq '' "$RECORDED_COMMANDS" "blank tarball artifact record runs no commands"
assert_eq "0" "$(mktemp_call_count)" "blank tarball artifact record does not create staging"

reset_test_state
reset_mktemp_call_count
run_cmd() { recording_run_cmd "$@"; }
set_installer_plan tarball "$multi_gfxes" "${tarball_artifact}"$'\r'
assert_fails "tarball rejects a carriage-return artifact record before staging mutation" install_rocm_tarball
assert_eq '' "$RECORDED_COMMANDS" "carriage-return tarball artifact record runs no commands"
assert_eq "0" "$(mktemp_call_count)" "carriage-return tarball artifact record does not create staging"

tarball_extract_fails() {
    recording_run_cmd "$@"
    if [[ "$1" == tar ]]; then
        return 23
    fi
}

reset_test_state
set_installer_plan tarball "$multi_gfxes" "$tarball_artifact"
run_cmd() { tarball_extract_fails "$@"; }
assert_status 23 "tarball extraction failure propagates its exact status" install_rocm_tarball
assert_not_contains "$RECORDED_COMMANDS" "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "tarball extraction failure leaves the prior final root untouched"
assert_not_contains "$RECORDED_COMMANDS" "ln -sfn /opt/rocm-7.14.0 /opt/rocm" "tarball extraction failure leaves the active link untouched"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "tarball extraction failure still cleans the temporary directory"

tarball_move_fails() {
    recording_run_cmd "$@"
    if [[ "$1" == test ]]; then
        return 0
    fi
    if [[ "$1" == mv && "$2" == "$tarball_stage_dir" && "$3" == /opt/rocm-7.14.0 ]]; then
        return 23
    fi
}

reset_test_state
set_installer_plan tarball "$multi_gfxes" "$tarball_artifact"
run_cmd() { tarball_move_fails "$@"; }
assert_status 23 "tarball promotion failure propagates its exact status" install_rocm_tarball
assert_command_before "mv /opt/rocm-7.14.0 ${tarball_backup_dir}" "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "tarball saves the prior root before promotion"
assert_command_before "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "mv ${tarball_backup_dir} /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "tarball restores the prior root after promotion failure"
assert_not_contains "$RECORDED_COMMANDS" "ln -sfn /opt/rocm-7.14.0 /opt/rocm" "tarball promotion failure leaves the prior active link untouched"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "tarball promotion failure cleans staging and temporary files"

tarball_symlink_fails_with_existing_root() {
    recording_run_cmd "$@"
    if [[ "$1" == test ]]; then
        return 0
    fi
    if [[ "$1" == ln ]]; then
        return 23
    fi
}

reset_test_state
set_installer_plan tarball "$multi_gfxes" "$tarball_artifact"
run_cmd() { tarball_symlink_fails_with_existing_root "$@"; }
assert_status 23 "symlink activation failure preserves its original status after rollback" install_rocm_tarball
assert_command_before "ln -sfn /opt/rocm-7.14.0 /opt/rocm" "rm -rf /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "symlink failure removes the newly promoted root"
assert_command_before "rm -rf /opt/rocm-7.14.0" "mv ${tarball_backup_dir} /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "symlink failure restores the prior root after removing the new root"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "symlink rollback cleans temporary staging after restoring the prior root"

tarball_symlink_fails_without_existing_root() {
    recording_run_cmd "$@"
    if [[ "$1" == test ]]; then
        return 1
    fi
    if [[ "$1" == ln ]]; then
        return 23
    fi
}

reset_test_state
set_installer_plan tarball "$multi_gfxes" "$tarball_artifact"
run_cmd() { tarball_symlink_fails_without_existing_root "$@"; }
assert_status 23 "symlink activation failure preserves its original status without a prior root" install_rocm_tarball
assert_contains "$RECORDED_COMMANDS" "rm -rf /opt/rocm-7.14.0" "symlink failure without a prior root removes the new root"
assert_not_contains "$RECORDED_COMMANDS" "mv /opt/rocm-7.14.0 ${tarball_backup_dir}" "symlink failure without a prior root has no backup move"
assert_not_contains "$RECORDED_COMMANDS" "mv ${tarball_backup_dir} /opt/rocm-7.14.0" "symlink failure without a prior root has no restore move"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "symlink failure without a prior root cleans temporary staging"

tarball_symlink_rollback_fails() {
    recording_run_cmd "$@"
    if [[ "$1" == test ]]; then
        return 0
    fi
    if [[ "$1" == ln ]]; then
        return 23
    fi
    if [[ "$1" == mv && "$2" == "$tarball_backup_dir" && "$3" == /opt/rocm-7.14.0 ]]; then
        return 41
    fi
}

reset_test_state
set_installer_plan tarball "$multi_gfxes" "$tarball_artifact"
run_cmd() { tarball_symlink_rollback_fails "$@"; }
assert_status 41 "failed prior-root restoration reports the rollback failure" install_rocm_tarball
assert_contains "$RECORDED_COMMANDS" "mv ${tarball_backup_dir} /opt/rocm-7.14.0" "failed rollback attempts to restore the prior root"
assert_not_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "failed rollback preserves the temporary backup for recovery"

KERNEL_BOOT_DIR="${TEST_TEMP_ROOT}/boot"
KERNEL_CAPTURED_COMMANDS_FILE="${TEST_TEMP_ROOT}/kernel-captured-commands"
MOCK_KERNEL_CANDIDATE='6.14.0.1020.20'
MOCK_KERNEL_CANDIDATE_STATUS=0
MOCK_KERNEL_SIMULATION_OUTPUT='Inst linux-oem-6.14 [6.14.0.1020.20]'
MOCK_KERNEL_SIMULATION_STATUS=0
MOCK_KERNEL_UPDATE_STATUS=0
MOCK_KERNEL_INSTALL_STATUS=0
MOCK_KERNEL_CREATE_BOOT_IMAGE=true
MOCK_KERNEL_DF_OUTPUT=$'Filesystem     1024-blocks      Used Available Capacity Mounted on\n/dev/mock 1048576 1 1048575 1% /boot'
MOCK_KERNEL_DF_STATUS=0

record_kernel_command() {
    local argument quoted command_line=''

    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        command_line+="${command_line:+ }${quoted}"
    done
    printf '%s\n' "$command_line" >> "$KERNEL_CAPTURED_COMMANDS_FILE"
}

capture_cmd() {
    record_kernel_command "$@"
    case "$*" in
        env\ LC_ALL=C\ df\ -Pk\ *)
            printf '%s\n' "$MOCK_KERNEL_DF_OUTPUT"
            return "$MOCK_KERNEL_DF_STATUS"
            ;;
        env\ LC_ALL=C\ apt-cache\ policy\ linux-oem-6.14)
            printf 'Candidate: %s\n' "$MOCK_KERNEL_CANDIDATE"
            return "$MOCK_KERNEL_CANDIDATE_STATUS"
            ;;
        env\ LC_ALL=C\ apt-get\ --simulate\ --no-remove\ --install-recommends\ install\ linux-oem-6.14)
            printf '%s\n' "$MOCK_KERNEL_SIMULATION_OUTPUT"
            return "$MOCK_KERNEL_SIMULATION_STATUS"
            ;;
        *) return 1 ;;
    esac
}

run_cmd() {
    recording_run_cmd "$@" || return $?
    if [[ "$1 ${2:-}" == 'apt-get update' ]]; then
        return "$MOCK_KERNEL_UPDATE_STATUS"
    fi
    if [[ "$1 ${2:-} ${3:-} ${4:-} ${5:-} ${6:-}" == 'apt-get --yes --no-remove --install-recommends install linux-oem-6.14' ]]; then
        if [[ "$MOCK_KERNEL_INSTALL_STATUS" -eq 0 ]]; then
            MOCK_KERNEL_METAPACKAGE_INSTALLED=true
            if [[ "$MOCK_KERNEL_CREATE_BOOT_IMAGE" == true ]]; then
                mkdir -p "$KERNEL_BOOT_DIR"
                printf 'kernel image\n' > "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"
            fi
        fi
        return "$MOCK_KERNEL_INSTALL_STATUS"
    fi
}

set_kernel_install_plan() {
    INSTALL_PLAN=(
        [kernel_status]=install-required
        [kernel_target]='6.14.*-oem'
        [kernel_package]=linux-oem-6.14
    )
}

reset_kernel_install_state() {
    reset_test_state
    : > "$KERNEL_CAPTURED_COMMANDS_FILE"
    MOCK_KERNEL_METAPACKAGE_INSTALLED=false
    MOCK_KERNEL_CANDIDATE='6.14.0.1020.20'
    MOCK_KERNEL_CANDIDATE_STATUS=0
    MOCK_KERNEL_SIMULATION_OUTPUT='Inst linux-oem-6.14 [6.14.0.1020.20]'
    MOCK_KERNEL_SIMULATION_STATUS=0
    MOCK_KERNEL_UPDATE_STATUS=0
    MOCK_KERNEL_INSTALL_STATUS=0
    MOCK_KERNEL_CREATE_BOOT_IMAGE=true
    MOCK_KERNEL_DF_OUTPUT=$'Filesystem     1024-blocks      Used Available Capacity Mounted on\n/dev/mock 1048576 1 1048575 1% /boot'
    MOCK_KERNEL_DF_STATUS=0
    rm -rf "$KERNEL_BOOT_DIR"
    mkdir -p "$KERNEL_BOOT_DIR"
    set_kernel_install_plan
}

reset_kernel_install_state
assert_success "approved kernel installation uses the exact official metapackage transaction" install_approved_kernel
assert_contains "$(<"$KERNEL_CAPTURED_COMMANDS_FILE")" "env LC_ALL=C df -Pk ${KERNEL_BOOT_DIR}" "kernel preparation checks free /boot space with stable POSIX df output"
assert_contains "$RECORDED_COMMANDS" "apt-get update" "kernel preparation refreshes APT metadata"
assert_contains "$(<"$KERNEL_CAPTURED_COMMANDS_FILE")" "env LC_ALL=C apt-cache policy linux-oem-6.14" "kernel preparation confirms the exact metapackage candidate in the C locale"
assert_contains "$(<"$KERNEL_CAPTURED_COMMANDS_FILE")" "env LC_ALL=C apt-get --simulate --no-remove --install-recommends install linux-oem-6.14" "kernel preparation simulates a no-removal transaction in the C locale"
assert_contains "$RECORDED_COMMANDS" "apt-get --yes --no-remove --install-recommends install linux-oem-6.14" "kernel preparation installs only the approved metapackage with no removals"
assert_success "kernel preparation verifies the expected OEM boot image" test -e "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"

reset_kernel_install_state
assert_success "kernel preparation accepts the real GNU df header spacing" install_approved_kernel

: > "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"
assert_fails "an empty matching boot image is not valid for a reboot-required kernel" kernel_boot_image_exists '6.14.*-oem'

rm -f "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"
mkdir -p "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"
assert_fails "a matching boot-image directory is not valid for a reboot-required kernel" kernel_boot_image_exists '6.14.*-oem'

reset_kernel_install_state
MOCK_KERNEL_METAPACKAGE_INSTALLED=true
mkdir -p "$KERNEL_BOOT_DIR"
printf 'kernel image\n' > "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"
assert_eq reboot-required "$(resolve_kernel_status '6.14.*-oem' linux-oem-6.14 6.8.0-101-generic)" "installed metapackage and valid matching image require reboot"
rm "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"
assert_eq install-required "$(resolve_kernel_status '6.14.*-oem' linux-oem-6.14 6.8.0-101-generic)" "installed metapackage without a valid matching image requires repair installation"

OS_ID=ubuntu
OS_VERSION=24.04
ARCH=x86_64
WORKLOAD=compute
PACKAGE_PROFILE=full
SKIP_SSH=true
DKMS_CLEANUP_POLICY=auto
ROOT_PASSWORD=''
INSTALL_METHOD=apt
DRIVER_MODE=auto
GPU_ARCHES=gfx1151
GPU_PRODUCT_NAMES='AMD Radeon 8060S Graphics'
KERNEL_VERSION=6.8.0-101-generic
MOCK_KERNEL_METAPACKAGE_INSTALLED=true
assert_success "kernel plan resolves with an installed metapackage and missing image" resolve_install_plan
assert_eq install-required "${INSTALL_PLAN[kernel_status]}" "an installed metapackage without an image is not an inconsistent reboot plan"
INSTALL_PLAN[kernel_status]=reboot-required
assert_fails "validated plans reject a forged reboot-required status without a valid image" validate_install_plan

reset_kernel_install_state
MOCK_KERNEL_DF_OUTPUT=$'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/mock 1048576 524289 524287 51% /boot'
assert_fails "kernel preparation rejects /boot free space below 512 MiB" install_approved_kernel
assert_not_contains "$RECORDED_COMMANDS" "apt-get update" "low /boot space prevents every APT mutation"

reset_kernel_install_state
MOCK_KERNEL_DF_OUTPUT=$'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/mock 1048576 524288 524288 50% /boot'
assert_success "kernel preparation accepts exactly 512 MiB of free /boot space" install_approved_kernel

reset_kernel_install_state
MOCK_KERNEL_DF_OUTPUT='invalid df output'
assert_fails "kernel preparation rejects malformed POSIX df output" install_approved_kernel
assert_not_contains "$RECORDED_COMMANDS" "apt-get update" "malformed df output prevents every APT mutation"

reset_kernel_install_state
MOCK_KERNEL_DF_OUTPUT=$'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/mock 1048576 1 1048575 1% /boot'
assert_fails "kernel preparation rejects a df header with a missing field" install_approved_kernel

reset_kernel_install_state
MOCK_KERNEL_DF_OUTPUT=$'Filesystem 1024-blocks Used Available Capacity Mounted on extra\n/dev/mock 1048576 1 1048575 1% /boot'
assert_fails "kernel preparation rejects a df header with an extra field" install_approved_kernel

reset_kernel_install_state
MOCK_KERNEL_DF_STATUS=29
assert_status 29 "kernel free-space query failure preserves its status" install_approved_kernel
assert_not_contains "$RECORDED_COMMANDS" "apt-get update" "failed free-space query prevents every APT mutation"

reset_kernel_install_state
MOCK_KERNEL_CANDIDATE='(none)'
assert_fails "kernel preparation rejects a metapackage without an exact candidate" install_approved_kernel
assert_not_contains "$(<"$KERNEL_CAPTURED_COMMANDS_FILE")" "apt-get --simulate" "missing kernel candidate prevents simulation"
assert_not_contains "$RECORDED_COMMANDS" "apt-get --yes" "missing kernel candidate prevents installation"

reset_kernel_install_state
MOCK_KERNEL_CANDIDATE=$'6.14.0.1020.20\nCandidate: 6.14.0.1020.21'
assert_fails "kernel preparation rejects duplicate Candidate records" install_approved_kernel
assert_not_contains "$(<"$KERNEL_CAPTURED_COMMANDS_FILE")" "apt-get --simulate" "duplicate candidates prevent simulation"

reset_kernel_install_state
MOCK_KERNEL_CANDIDATE='6.14.0.1020.20 extra'
assert_fails "kernel preparation rejects a malformed Candidate record" install_approved_kernel

reset_kernel_install_state
MOCK_KERNEL_SIMULATION_OUTPUT=$'Inst linux-oem-6.14 [6.14.0.1020.20]\n  Remv unrelated-package [1.0]'
assert_fails "kernel preparation rejects a simulated package removal" install_approved_kernel
assert_not_contains "$RECORDED_COMMANDS" "apt-get --yes" "unsafe simulated removal prevents installation"

reset_kernel_install_state
MOCK_KERNEL_UPDATE_STATUS=23
assert_status 23 "kernel APT update failure preserves its status" install_approved_kernel
assert_not_contains "$(<"$KERNEL_CAPTURED_COMMANDS_FILE")" "apt-cache policy" "failed kernel metadata refresh does not continue to candidate lookup"

reset_kernel_install_state
MOCK_KERNEL_CANDIDATE_STATUS=41
assert_status 41 "kernel candidate lookup failure preserves its status" install_approved_kernel
assert_not_contains "$(<"$KERNEL_CAPTURED_COMMANDS_FILE")" "apt-get --simulate" "failed candidate lookup does not simulate installation"

reset_kernel_install_state
MOCK_KERNEL_SIMULATION_STATUS=43
assert_status 43 "kernel simulation failure preserves its status" install_approved_kernel
assert_not_contains "$RECORDED_COMMANDS" "apt-get --yes" "failed simulation does not install the kernel"

reset_kernel_install_state
MOCK_KERNEL_INSTALL_STATUS=47
assert_status 47 "kernel installation failure preserves its status" install_approved_kernel

reset_kernel_install_state
MOCK_KERNEL_CREATE_BOOT_IMAGE=false
assert_fails "kernel preparation requires the expected target boot image after installation" install_approved_kernel

reset_kernel_install_state
MOCK_KERNEL_METAPACKAGE_INSTALLED=true
printf '' > "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"
assert_success "kernel preparation repairs an installed metapackage with an invalid boot image" install_approved_kernel
assert_success "kernel repair leaves a readable nonempty matching boot image" test -f "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"
assert_success "kernel repair leaves a nonempty matching boot image" test -s "${KERNEL_BOOT_DIR}/vmlinuz-6.14.0-1020-oem"

finish_tests "artifact command"
