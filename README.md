# ROCm Unified Installation Script

A one-click installation script for AMD ROCm platform that supports multiple versions and Linux distributions.

## Features

- **Auto-detect latest ROCm version** from AMD repository
- **Interactive TUI menu** for version selection
- **Multi-distribution support**: Ubuntu 22.04/24.04, Debian 12, RHEL 9.x
- **Automatic GPU detection**
- **Kernel version locking** to prevent driver incompatibility
- **Complete environment configuration**
- **Non-interactive mode** for automation

## Quick Start

```bash
# Download and run
git clone https://github.com/amdjiahangpan/rocm-install-script.git
cd rocm-install-script
sudo ./rocm-install.sh
```

## Usage

### Interactive Mode (Recommended)

```bash
sudo ./rocm-install.sh
```

This will show an interactive menu where you can:
1. Select ROCm version (or use latest)
2. Configure installation options
3. Manage extra packages

### Command Line Options

```bash
sudo ./rocm-install.sh [options]

Options:
  --version VERSION    Install specific ROCm version (e.g., 7.2, 6.4.2)
  --latest             Install latest available version
  --skip-ssh           Skip SSH configuration
  --skip-reboot        Don't reboot after installation
  --verify-only        Only verify existing installation
  --uninstall          Remove ROCm
  --no-dkms            Skip DKMS driver (use pre-built)
  --non-interactive    Run without prompts
  --help               Show help message
```

### Examples

```bash
# Interactive installation
sudo ./rocm-install.sh

# Install latest version automatically
sudo ./rocm-install.sh --latest

# Install specific version
sudo ./rocm-install.sh --version 7.2

# Install without DKMS (for newer kernels)
sudo ./rocm-install.sh --latest --no-dkms

# Verify installation
sudo ./rocm-install.sh --verify-only

# Uninstall
sudo ./rocm-install.sh --uninstall

# Automated installation (for scripts)
sudo ./rocm-install.sh --latest --non-interactive --skip-reboot
```

## Supported Configurations

| Distribution | Versions | Status |
|-------------|----------|--------|
| Ubuntu | 22.04, 24.04 | ✅ Fully Supported |
| Debian | 12 | ✅ Supported |
| RHEL/Rocky/AlmaLinux | 9.x | ✅ Supported |

## What Gets Installed

### Core Packages
- AMDGPU driver (DKMS or pre-built)
- ROCm runtime and libraries
- rocminfo, rocm-smi, clinfo

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
