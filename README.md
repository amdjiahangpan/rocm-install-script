# ROCm Unified Installation Script

A one-click installation script for AMD ROCm platform that supports multiple versions and Linux distributions.

## Features

- **Auto-detect latest ROCm version** from AMD repository
- **Interactive TUI menu** for version selection
- **Multi-distribution support**: Ubuntu 22.04/24.04/26.04, Debian 12/13, RHEL 9.x
- **Automatic GPU detection**
- **Kernel version locking** to prevent driver incompatibility
- **Complete environment configuration**
- **Non-interactive mode** for automation

## Quick Start

### One-Line Installation (Recommended)

```bash
# Install latest ROCm version
curl -fsSL https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/unified-installer/rocm-install.sh | sudo bash -s -- --latest

# Or download first, then run
wget https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/unified-installer/rocm-install.sh
chmod +x rocm-install.sh
sudo ./rocm-install.sh
```

### Clone Repository (For Development)

```bash
git clone https://github.com/amdjiahangpan/rocm-install-script.git
cd rocm-install-script
git checkout unified-installer
sudo ./rocm-install.sh
```

## Usage

### Interactive Mode (Recommended)

```bash
sudo ./rocm-install.sh
```

This will show an interactive menu where you can:
1. Select ROCm version (or use latest)
2. Configure installation options, including driver mode and DKMS cleanup policy
3. Manage extra packages

### Command Line Options

```bash
sudo ./rocm-install.sh [options]

Options:
  --version VERSION      Install specific ROCm version (e.g., 7.13.0, 7.2.4)
  --latest               Install latest available version
  --skip-ssh             Skip SSH configuration
  --skip-reboot          Skip reboot after installation
  --reboot-delay MIN     Delay reboot for MIN minutes (0=immediate, default: 0)
  --verify-only          Only verify existing installation
  --uninstall            Remove ROCm
  --driver-mode MODE     Driver mode: auto (default), inbox, or dkms
  --no-dkms              Skip DKMS driver (use pre-built)
  --dkms-cleanup POLICY   DKMS cleanup policy: auto (default), ask, always, or never
  --non-interactive      Run without prompts
  --help                 Show help message
```

### Examples

```bash
# Interactive installation with menu
wget https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/unified-installer/rocm-install.sh
sudo bash rocm-install.sh

# One-line: Install latest version
curl -fsSL https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/unified-installer/rocm-install.sh | sudo bash -s -- --latest

# One-line: Install specific version
curl -fsSL https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/unified-installer/rocm-install.sh | sudo bash -s -- --version 7.13.0

# One-line: Install with 10-minute delayed reboot
curl -fsSL https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/unified-installer/rocm-install.sh | sudo bash -s -- --latest --reboot-delay 10

# Explicit driver mode selection
sudo ./rocm-install.sh --latest --driver-mode dkms

# Install without DKMS (for newer kernels)
sudo ./rocm-install.sh --latest --no-dkms

# Ryzen AI APUs should use inbox driver mode
sudo ./rocm-install.sh --latest --driver-mode inbox

# Remove existing amdgpu-dkms before switching a Ryzen APU to inbox mode
sudo ./rocm-install.sh --latest --driver-mode inbox --dkms-cleanup always

# Verify installation
sudo ./rocm-install.sh --verify-only

# Uninstall
sudo ./rocm-install.sh --uninstall

# Automated installation for scripts (no interactive prompts)
curl -fsSL https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/unified-installer/rocm-install.sh | sudo bash -s -- --latest --non-interactive --skip-reboot
```

## Supported Configurations

| Distribution | Versions | Status |
|-------------|----------|--------|
| Ubuntu | 22.04, 24.04, 26.04 | ✅ Supported |
| Debian | 12, 13 | ✅ Supported |
| RHEL/Rocky/AlmaLinux | 9.x | ✅ Supported |

## What Gets Installed

### Core Packages
- AMDGPU driver (DKMS or pre-built)
- ROCm runtime and libraries
- rocminfo, rocm-smi, clinfo

For ROCm 7.13 on apt-based Ryzen systems, the script follows AMD's technology
preview package-manager path: it configures AMD's native ROCm package repository
(`repo.amd.com/rocm/packages/<distro>`) and installs the matching architecture
meta-package, such as `amdrocm7.13-gfx110x` for `gfx1103` APUs. If DKMS driver
mode is selected, the AMDGPU driver installer still comes from AMD's matching
`amdgpu-install` 31.30 repository; inbox driver mode skips that driver installer.
Older production releases keep the existing `amdgpu-install` repository
bootstrap path for ROCm packages too.

### Extra Packages (configurable)
- python3-setuptools, python3-wheel, python3-pip
- build-essential, cmake, git
- vim, htop, nfs-common

### System Configuration
- User added to `video` and `render` groups
- Udev rules for GPU permissions
- ROCm paths in `/etc/profile.d/rocm.sh`
- Library paths in `/etc/ld.so.conf.d/rocm.conf`
- Kernel version locked to prevent updates

## Post-Installation

After installation completes:

1. **Reboot** your system
2. **Verify** installation:
   ```bash
   rocminfo
   rocm-smi
   ```
3. **Test** GPU access:
   ```bash
   /opt/rocm/bin/rocminfo | grep "Name:"
   ```

## Troubleshooting

### GPU not detected after reboot
```bash
# Check if driver is loaded
lsmod | grep amdgpu

# Check kernel messages
dmesg | grep amdgpu
```

### Permission denied
```bash
# Verify group membership
groups $USER

# Re-login or run
newgrp video
newgrp render
```

### DKMS build fails
Use `--no-dkms` flag:
```bash
sudo ./rocm-install.sh --latest --no-dkms
```

### Ryzen AI APU systems
Driver mode defaults to `auto`, which uses inbox driver mode when a Ryzen APU is
detected. The script treats exact Ryzen APU targets such as `gfx1150`,
`gfx1151`, `gfx1152`, `gfx1153`, and `gfx1103` conservatively. To force the AMD-recommended
Ryzen APU path explicitly:
```bash
sudo ./rocm-install.sh --latest --driver-mode inbox
```

If you are migrating from an older DKMS-based install on a Ryzen APU, use the
cleanup policy to remove `amdgpu-dkms` before installation:
```bash
sudo ./rocm-install.sh --latest --driver-mode inbox --dkms-cleanup always
```

Cleanup policy behavior:
- `auto`: prompt in interactive mode, skip in non-interactive mode
- `ask`: prompt in interactive mode, skip in non-interactive mode
- `always`: remove without prompting
- `never`: warn only, do not remove

For standard non-APU installs, resolved driver mode stays `dkms`, so cleanup does
not run unless inbox mode is selected.

For ROCm 7.13 native apt installs, the script refuses to use AMD's generic
`amdrocm7.13` package when the GPU architecture cannot be determined, because
that package pulls every supported gfx architecture. If auto-detection is
ambiguous, specify the target explicitly, for example:

```bash
sudo ./rocm-install.sh --version 7.13.0 --gpu-arch gfx1150 --driver-mode inbox
sudo ./rocm-install.sh --version 7.13.0 --gpu-arch gfx1103 --driver-mode inbox
```

## Legacy Branches

For specific older configurations, legacy branches are still available:
- `ROCm_6.4.x_ubuntu_24.04`
- `ROCm_7.x.x_ubuntu_24.04`

Use `git checkout <branch>` to access them.

## Resources

- [Official ROCm Documentation](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/)
- [AMD GPU Driver Repository](https://repo.radeon.com/amdgpu-install/)
- [ROCm GitHub](https://github.com/ROCm)

## License

MIT License
