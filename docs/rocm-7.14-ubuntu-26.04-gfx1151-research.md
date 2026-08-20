# AMD ROCm 7.14.0: Ubuntu 26.04 / gfx1151

Research date: 2026-07-28. Scope: AMD’s current Ryzen / compute / Ubuntu 26.04 / apt selector.

## Decision

Use ROCm Core SDK **7.14.0**, not "7.1.4". AMD’s release history lists 7.14.0 (2026-07-15), then 7.2.4 through 7.2.0, then 7.1.1 and 7.1.0; it has no 7.1.4 entry: [release history source](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/release/versions.rst#L11-L39). ROCm 7.14.0 explicitly adds Ryzen AI Max PRO 485 (gfx1151): [release notes](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/about/release-notes.md#L24-L34).

## Supported configuration and caveats

* Ryzen AI Max PRO 485 is a Ryzen AI Max PRO 400-series APU with Radeon 8050S iGPU; gfx1151 is RDNA 3.5: [matrix](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/compatibility/include/system-ryzen.rst#L10-L17), [iGPU](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/compatibility/include/system-ryzen.rst#L64-L74), [target](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/compatibility/include/system-ryzen.rst#L102-L117).
* Supported Ubuntu versions are 26.04 GA kernel 7.0 and 24.04.4 HWE kernel 6.17. On Ubuntu 26.04, AMD requires the **inbox** kernel driver: [matrix](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/compatibility/include/system-ryzen.rst#L131-L158), [installer selector](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/install/include/200-install.rst#L129-L155).
* Therefore do not install DKMS or `linux-oem-24.04c` on this 26.04 path. The OEM-kernel instructions are gated to Ubuntu 24.04: [prerequisites](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/install/include/100-prerequisites.rst#L172-L190). The `amdgpu-install` bootstrap is gated to the **graphics** selector, not compute: [source](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/install/include/200-install.rst#L39-L64).

## Upstream selector reference and installer package choice

```bash
# Register AMD’s 26.04 multi-arch ROCm repository
sudo mkdir --parents --mode=0755 /etc/apt/keyrings
wget https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg -O - | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/amdrocm.gpg > /dev/null
sudo tee /etc/apt/sources.list.d/rocm.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/packages-multi-arch/ubuntu2604 stable main
EOF
sudo apt update

# This installer selects the full Core SDK package
sudo apt install amdrocm-core-sdk7.14-gfx1151
```

The repository instructions are verbatim from AMD’s current selector: [repository setup](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/install/include/200-install.rst#L287-L328). AMD's selector may show `amdrocm7.14-gfx1151`, the ROCm Base meta package; this installer intentionally selects `amdrocm-core-sdk7.14-gfx1151`.

Optional packages: `amdrocm-core-dev7.14-gfx1151` adds compiler/CMake/static-library/header development assets; `amdrocm-developer-tools7.14` provides profiler tools; `amdrocm-opencl7.14` provides OpenCL: [development package](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/install/include/200-install.rst#L1192-L1202), [contents](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/install/include/200-install.rst#L1287-L1352), [extras](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/install/include/200-install.rst#L1374-L1396).

## Permissions, reboot, and verification

Choose one permissions method, then reboot:

```bash
# Per-user
sudo usermod -a -G render,video $LOGNAME

# Or system-wide udev access
sudo tee /etc/udev/rules.d/70-amdgpu.rules << EOF
KERNEL=="kfd", GROUP="render", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0666"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo reboot
```

AMD documents both alternatives and says reboot applies all settings: [permissions](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/install/include/100-prerequisites.rst#L680-L725). After reboot:

```bash
rocminfo
amd-smi version
```

AMD specifies `rocminfo` for device/runtime/driver discovery and `amd-smi version` for system validation; the 7.14.0 example reports `ROCm version: 7.14.0`: [verification](https://github.com/ROCm/ROCm/blob/bb3fc48a563d72f993fa6aa8d4350f75da830551/docs/install/include/300-post-install.rst#L118-L182).

## Downstream encoding rules

Assert the `repo.amd.com/rocm/packages-multi-arch/ubuntu2604 stable main` source and GPG key location. This implementation selects packages only from a unique KFD gfx target or explicit `--gpu-arch`; marketing names from DRM sysfs or `amdgpu.ids` are informational and never identify an SKU. `rocminfo` is post-install verification only. Also assert inbox-driver/no-DKMS behavior, permissions, reboot, and both verification commands.
