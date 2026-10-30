#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

assert_command_output_eq() {
    local expected=$1 message=$2 output status
    shift 2
    if output=$("$@"); then :; else
        status=$?
        fail "${message} (command failed with status ${status})"
    fi
    assert_eq "$expected" "$output" "$message"
}

assert_command_output_eq "apt|ubuntu2404" "Ubuntu 24.04 uses the multi-arch APT repository" resolve_os_record ubuntu-24.04.5
assert_command_output_eq "apt|ubuntu2604" "Ubuntu 26.04 uses the multi-arch APT repository" resolve_os_record ubuntu-26.04.1
assert_eq "https://stable.repo.amd.com/rocm/core/packages/ubuntu2404" "${ROCM_PACKAGES_ROOT}/ubuntu2404" "Ubuntu 24.04 repository URL is exact"
supported_gfxes=$'gfx1030\ngfx1100\ngfx1101\ngfx1102\ngfx1103\ngfx1150\ngfx1151\ngfx1152\ngfx1153\ngfx1200\ngfx1201\ngfx908\ngfx90a\ngfx942\ngfx950'
while IFS= read -r gfx; do
    assert_command_output_eq "amdrocm-core-sdk10.1-${gfx}" "${gfx} selects the ROCm 10 meta package" resolve_package_name full "$gfx"
done <<< "$supported_gfxes"
assert_fails "unknown architecture has no package fallback" resolve_package_name full gfx9999
assert_fails "all is not an APT package architecture" resolve_package_name full all

multi_gfxes=$'gfx1151\ngfx1201'
multi_packages=$'amdrocm-core-sdk10.1-gfx1151\namdrocm-core-sdk10.1-gfx1201'
assert_command_output_eq "$multi_packages" "APT plans one ROCm 10 package per normalized GFX" resolve_plan_artifacts apt "$multi_gfxes"
assert_command_output_eq "$ROCM_RUNFILE_URL" "Runfile plans the pinned official installer" resolve_plan_artifacts runfile "$multi_gfxes"
assert_fails "removed pip method has no artifacts" resolve_plan_artifacts pip gfx1201
assert_fails "removed tarball method has no artifacts" resolve_plan_artifacts tarball gfx1201

r9700_pci_signature=$'0000:03:00.0|1002:7551|00C0\n0000:23:00.0|1002:7551|00C0\n0000:d3:00.0|1002:7551|00C0\n0000:f3:00.0|1002:7551|00C0'
assert_command_output_eq 'install-required|qualified' "kernel 6.7 is rejected" resolve_kernel_support_record dkms ubuntu-24.04.5 radeon gfx1201 4 "$r9700_pci_signature" 6.7.12-generic '7.0.*-generic' linux-generic-hwe-24.04
assert_command_output_eq 'ready|qualified' "recommended HWE kernel 7.0 is qualified" resolve_kernel_support_record dkms ubuntu-24.04.5 radeon gfx1201 4 "$r9700_pci_signature" 7.0.0-28-generic '7.0.*-generic' linux-generic-hwe-24.04
assert_command_output_eq 'ready-unqualified|unqualified' "GA kernel 6.8 is advisory and allowed" resolve_kernel_support_record dkms ubuntu-24.04.5 radeon gfx1201 4 "$r9700_pci_signature" 6.8.0-138-generic '7.0.*-generic' linux-generic-hwe-24.04

finish_tests "artifact commands"
