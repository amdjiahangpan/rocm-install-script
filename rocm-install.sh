#!/bin/bash
#
# ROCm Unified Installation Script
# Supports: ROCm 6.x, 7.x and future versions
# Platforms: Ubuntu 22.04, 24.04, RHEL 9.x, Debian 12
#
# Features:
#   - Auto-detect latest ROCm version from AMD repository
#   - Interactive TUI menu for version selection
#   - Support for multiple Linux distributions
#   - Automatic GPU detection
#   - Complete environment configuration
#
# Usage: sudo ./rocm-install.sh [options]
#

set -e

#######################################
# Configuration
#######################################

SCRIPT_VERSION="2.0.0"
REPO_BASE_URL="https://repo.radeon.com/amdgpu-install"

# Colors (using $'...' syntax so bash interprets escape sequences at assignment)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# Default options
SKIP_SSH=false
REBOOT_DELAY=0  # 0=immediate, >0=delay in minutes, -1=skip
VERIFY_ONLY=false
UNINSTALL=false
NO_DKMS=false
USE_LATEST=false
ROCM_VERSION=""
NON_INTERACTIVE=false
ROOT_PASSWORD=""

# Extra packages to install
EXTRA_PACKAGES=(
    # Basic system utilities
    "sudo"
    "curl"
    "wget"
    "ca-certificates"
    "gnupg"
    "lsb-release"
    "software-properties-common"
    "apt-transport-https"
    # Development tools
    "build-essential"
    "cmake"
    "make"
    "gcc"
    "g++"
    "git"
    "pkg-config"
    # Python
    "python3"
    "python3-dev"
    "python3-pip"
    "python3-venv"
    "python3-setuptools"
    "python3-wheel"
    # Editor & tools
    "vim"
    "nano"
    "htop"
    "tmux"
    "screen"
    # Network & filesystem
    "net-tools"
    "iputils-ping"
    "dnsutils"
    "nfs-common"
    "sshfs"
    "rsync"
    # System utilities
    "pciutils"
    "usbutils"
    "lshw"
    "hwinfo"
    "dmidecode"
    "sysstat"
    "iotop"
    "unzip"
    "zip"
    "p7zip-full"
    "jq"
    # Libraries
    "libssl-dev"
    "libffi-dev"
    "libnuma-dev"
)

# Log file
LOG_FILE="/var/log/rocm-install-$(date +%Y%m%d-%H%M%S).log"

#######################################
# Utility Functions
#######################################

log() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null; exit 1; }
debug() { echo -e "${CYAN}[DEBUG]${NC} $1" >> "$LOG_FILE" 2>/dev/null; }

# Draw a box around text
draw_box() {
    local text="$1"
    local width=$((${#text} + 4))
    local border=$(printf '═%.0s' $(seq 1 $width))
    echo -e "${BLUE}╔${border}╗${NC}"
    echo -e "${BLUE}║${NC}  ${BOLD}$text${NC}  ${BLUE}║${NC}"
    echo -e "${BLUE}╚${border}╝${NC}"
}

# Print header
print_header() {
    clear
    echo ""
    echo -e "${CYAN}  ██████╗  ██████╗  ██████╗███╗   ███╗${NC}"
    echo -e "${CYAN}  ██╔══██╗██╔═══██╗██╔════╝████╗ ████║${NC}"
    echo -e "${CYAN}  ██████╔╝██║   ██║██║     ██╔████╔██║${NC}"
    echo -e "${CYAN}  ██╔══██╗██║   ██║██║     ██║╚██╔╝██║${NC}"
    echo -e "${CYAN}  ██║  ██║╚██████╔╝╚██████╗██║ ╚═╝ ██║${NC}"
    echo -e "${CYAN}  ╚═╝  ╚═╝ ╚═════╝  ╚═════╝╚═╝     ╚═╝${NC}"
    echo ""
    echo -e "${BOLD}  Unified Installation Script v${SCRIPT_VERSION}${NC}"
    echo -e "  ${MAGENTA}AMD ROCm Platform for GPU Computing${NC}"
    echo ""
    echo -e "  ─────────────────────────────────────────"
    echo ""
}

# Spinner animation
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " ${CYAN}[%c]${NC} " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

#######################################
# System Detection
#######################################

detect_system() {
    echo -e "\n${BOLD}Detecting System...${NC}\n"

    # Detect OS
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="${VERSION_CODENAME:-}"
        OS_NAME="$PRETTY_NAME"
    else
        error "Cannot detect OS. /etc/os-release not found."
    fi

    # Detect architecture
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        error "ROCm only supports x86_64 architecture. Detected: $ARCH"
    fi

    # Detect kernel
    KERNEL_VERSION=$(uname -r)

    # Detect package manager
    case "$OS_ID" in
        ubuntu|debian)
            PKG_MGR="apt"
            PKG_INSTALL="apt-get install -y"
            PKG_UPDATE="apt-get update"
            ;;
        rhel|centos|rocky|almalinux|ol)
            PKG_MGR="dnf"
            PKG_INSTALL="dnf install -y"
            PKG_UPDATE="dnf makecache"
            ;;
        fedora)
            PKG_MGR="dnf"
            PKG_INSTALL="dnf install -y"
            PKG_UPDATE="dnf makecache"
            ;;
        *)
            error "Unsupported distribution: $OS_ID"
            ;;
    esac

    echo -e "  ${GREEN}✓${NC} OS:           $OS_NAME"
    echo -e "  ${GREEN}✓${NC} Kernel:       $KERNEL_VERSION"
    echo -e "  ${GREEN}✓${NC} Architecture: $ARCH"
    echo -e "  ${GREEN}✓${NC} Package Mgr:  $PKG_MGR"
}

detect_gpu() {
    echo -e "\n${BOLD}Detecting AMD GPUs...${NC}\n"

    if ! command -v lspci &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq pciutils > /dev/null 2>&1
    fi

    GPU_LIST=$(lspci | grep -E "VGA|Display|3D" | grep -i amd || true)

    if [[ -z "$GPU_LIST" ]]; then
        echo -e "  ${YELLOW}!${NC} No AMD GPU detected"
        echo ""
        lspci | grep -E "VGA|Display|3D" | head -5 || true
        echo ""
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -p "  Continue anyway? (y/N): " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
        fi
    else
        while IFS= read -r line; do
            echo -e "  ${GREEN}✓${NC} $line"
        done <<< "$GPU_LIST"
    fi
}


#######################################
# FZF Detection & Installation
#######################################

# Install fzf if needed for better UI
install_fzf_if_needed() {
    if ! command -v fzf &> /dev/null; then
        echo -e "${CYAN}Installing fzf for better menu experience...${NC}"

        case "$PKG_MGR" in
            apt)
                apt-get update -qq && apt-get install -y -qq fzf > /dev/null 2>&1
                ;;
            dnf)
                dnf install -y -q fzf > /dev/null 2>&1
                ;;
        esac

        # Verify installation
        if command -v fzf &> /dev/null; then
            echo -e "${GREEN}✓${NC} fzf installed"
        fi
    fi
}

USE_FZF=false

#######################################
# Version Detection & Selection
#######################################

# Fetch versions from AMD repository
fetch_versions_from_amd_repo() {
    local versions_html
    versions_html=$(curl -s --connect-timeout 10 "$REPO_BASE_URL/" 2>/dev/null || echo "")

    if [[ -z "$versions_html" ]]; then
        return 1
    fi

    # Parse version directories using compatible grep/sed (avoid grep -P for portability)
    # Include ROCm 6.x and above (supports pre-release versions like 7.9.0)
    local versions=()
    local raw_versions
    raw_versions=$(echo "$versions_html" | grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' | sed 's/href="//g;s/\/"//g' | sort -Vr | uniq)

    while IFS= read -r version; do
        # Support 6.x, 7.x, 8.x, etc. (major version >= 6)
        if [[ "$version" =~ ^([0-9]+)\.[0-9]+(\.[0-9]+)?$ ]]; then
            local major="${BASH_REMATCH[1]}"
            if [[ "$major" -ge 6 ]]; then
                versions+=("$version")
            fi
        fi
    done <<< "$raw_versions"

    if [[ ${#versions[@]} -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${versions[@]}"
}

# Fetch versions from GitHub releases
fetch_versions_from_github() {
    local releases_html
    releases_html=$(curl -sL --connect-timeout 10 "https://github.com/ROCm/ROCm/releases" 2>/dev/null || echo "")

    if [[ -z "$releases_html" ]]; then
        return 1
    fi

    # Parse rocm-X.Y.Z and therock-X.Y.Z tags using compatible grep/sed
    local versions=()
    local raw_versions
    raw_versions=$(echo "$releases_html" | grep -oE '(rocm|therock)-[0-9]+\.[0-9]+\.[0-9]+' | sed 's/rocm-//g;s/therock-//g' | sort -Vr | uniq)

    while IFS= read -r version; do
        # Support 6.x, 7.x, 8.x, etc. (major version >= 6)
        if [[ "$version" =~ ^([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
            local major="${BASH_REMATCH[1]}"
            if [[ "$major" -ge 6 ]]; then
                versions+=("$version")
            fi
        fi
    done <<< "$raw_versions"

    if [[ ${#versions[@]} -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${versions[@]}"
}

fetch_available_versions() {
    echo -e "\n${BOLD}Fetching available ROCm versions...${NC}"

    AVAILABLE_VERSIONS=()
    local source_used=""

    # Primary source: AMD repository
    echo -e "  Checking AMD repository..."
    local amd_versions
    if amd_versions=$(fetch_versions_from_amd_repo); then
        while IFS= read -r v; do
            AVAILABLE_VERSIONS+=("$v")
        done <<< "$amd_versions"
        source_used="AMD repo"
    fi

    # Backup source: GitHub releases (merge unique versions)
    echo -e "  Checking GitHub releases..."
    local github_versions
    if github_versions=$(fetch_versions_from_github); then
        while IFS= read -r v; do
            # Add if not already in list (check both X.Y.Z and X.Y formats)
            local base_ver="${v%.*}"  # X.Y.Z -> X.Y
            local found=false
            for existing in "${AVAILABLE_VERSIONS[@]}"; do
                if [[ "$existing" == "$v" ]] || [[ "$existing" == "$base_ver" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                AVAILABLE_VERSIONS+=("$v")
            fi
        done <<< "$github_versions"
        if [[ -z "$source_used" ]]; then
            source_used="GitHub"
        else
            source_used="$source_used + GitHub"
        fi
    fi

    # Re-sort after merging
    if [[ ${#AVAILABLE_VERSIONS[@]} -gt 0 ]]; then
        mapfile -t AVAILABLE_VERSIONS < <(printf '%s\n' "${AVAILABLE_VERSIONS[@]}" | sort -Vr | uniq)
    fi

    # Final fallback: hardcoded list
    if [[ ${#AVAILABLE_VERSIONS[@]} -eq 0 ]]; then
        warn "Cannot fetch versions from online sources. Using cached list."
        AVAILABLE_VERSIONS=("7.2" "7.1.1" "7.1" "7.0.3" "7.0.2" "7.0.1" "7.0" "6.4.3" "6.4.2" "6.4.1" "6.4")
        source_used="cached"
    fi

    echo -e "  ${GREEN}✓${NC} Found ${#AVAILABLE_VERSIONS[@]} versions (source: $source_used)"
}

get_latest_version() {
    # Get the latest stable version
    if [[ ${#AVAILABLE_VERSIONS[@]} -gt 0 ]]; then
        LATEST_VERSION="${AVAILABLE_VERSIONS[0]}"
    else
        LATEST_VERSION="7.2"
    fi
    echo "$LATEST_VERSION"
}

# Fetch package name directly from repository
fetch_package_name_from_repo() {
    local repo_url="$1"
    local pkg_pattern="$2"

    local pkg_list
    pkg_list=$(curl -s --connect-timeout 10 "$repo_url" 2>/dev/null || echo "")

    if [[ -n "$pkg_list" ]]; then
        echo "$pkg_list" | grep -oP "${pkg_pattern}" | head -1
    fi
}

# Build version string for package filename (fallback)
build_version_string() {
    local version="$1"
    local major minor patch

    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        patch="${BASH_REMATCH[3]}"

        # ROCm 7.x.z format: X.Y.Z.X0Y0Z (e.g., 7.0.3 -> 7.0.3.70003, 7.1.1 -> 7.1.1.70101)
        # ROCm 6.x.z format: X.Y.X0Y0Z (e.g., 6.4.3 -> 6.4.60403)
        if [[ "$major" -ge 7 ]]; then
            printf "%d.%d.%d.%d%02d%02d" "$major" "$minor" "$patch" "$major" "$minor" "$patch"
        else
            printf "%d.%d.%d%02d%02d" "$major" "$minor" "$major" "$minor" "$patch"
        fi
    elif [[ "$version" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        # X.Y format: X.Y.X0Y00 (e.g., 7.2 -> 7.2.70200, 6.4 -> 6.4.60400)
        printf "%d.%d.%d%02d00" "$major" "$minor" "$major" "$minor"
    else
        echo "$version"
    fi
}

get_package_url() {
    local version="$1"
    local dir_version

    # Directory version: use full version if exists, otherwise major.minor
    # First try exact version directory, then fall back to major.minor
    dir_version="$version"

    local codename=""
    local pkg_name=""
    local repo_dir_url=""

    case "$OS_ID" in
        ubuntu)
            case "$OS_VERSION" in
                "22.04") codename="jammy" ;;
                "24.04") codename="noble" ;;
                *) error "Unsupported Ubuntu version: $OS_VERSION" ;;
            esac

            # Try exact version directory first
            repo_dir_url="${REPO_BASE_URL}/${dir_version}/ubuntu/${codename}/"
            pkg_name=$(fetch_package_name_from_repo "$repo_dir_url" 'amdgpu-install_[^"]+\.deb')

            # If not found, try major.minor directory
            if [[ -z "$pkg_name" ]] && [[ "$version" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
                local major_minor="${BASH_REMATCH[1]}"
                repo_dir_url="${REPO_BASE_URL}/${major_minor}/ubuntu/${codename}/"
                pkg_name=$(fetch_package_name_from_repo "$repo_dir_url" 'amdgpu-install_[^"]+\.deb')
            fi

            # If found from repo, use it
            if [[ -n "$pkg_name" ]]; then
                AMDGPU_URL="${repo_dir_url}${pkg_name}"
                debug "Package URL from repo: $AMDGPU_URL"
                return 0
            fi

            # Fallback: construct URL based on version pattern
            local build_num
            build_num=$(build_version_string "$version")
            local major_minor
            if [[ "$version" =~ ^([0-9]+\.[0-9]+) ]]; then
                major_minor="${BASH_REMATCH[1]}"
            else
                major_minor="$version"
            fi
            AMDGPU_URL="${REPO_BASE_URL}/${major_minor}/ubuntu/${codename}/amdgpu-install_${build_num}-1_all.deb"
            debug "Package URL from fallback: $AMDGPU_URL"
            ;;

        debian)
            codename="bookworm"
            repo_dir_url="${REPO_BASE_URL}/${dir_version}/ubuntu/${codename}/"
            pkg_name=$(fetch_package_name_from_repo "$repo_dir_url" 'amdgpu-install_[^"]+\.deb')

            if [[ -n "$pkg_name" ]]; then
                AMDGPU_URL="${repo_dir_url}${pkg_name}"
                return 0
            fi

            # Fallback
            local build_num
            build_num=$(build_version_string "$version")
            local major_minor
            if [[ "$version" =~ ^([0-9]+\.[0-9]+) ]]; then
                major_minor="${BASH_REMATCH[1]}"
            else
                major_minor="$version"
            fi
            AMDGPU_URL="${REPO_BASE_URL}/${major_minor}/ubuntu/${codename}/amdgpu-install_${build_num}-1_all.deb"
            ;;

        rhel|centos|rocky|almalinux)
            local el_version
            el_version=$(echo "$OS_VERSION" | cut -d. -f1)
            repo_dir_url="${REPO_BASE_URL}/${dir_version}/rhel/${OS_VERSION}/"
            pkg_name=$(fetch_package_name_from_repo "$repo_dir_url" 'amdgpu-install-[^"]+\.rpm')

            if [[ -n "$pkg_name" ]]; then
                AMDGPU_URL="${repo_dir_url}${pkg_name}"
                return 0
            fi

            # Fallback
            local major_minor
            if [[ "$version" =~ ^([0-9]+\.[0-9]+) ]]; then
                major_minor="${BASH_REMATCH[1]}"
            else
                major_minor="$version"
            fi
            AMDGPU_URL="${REPO_BASE_URL}/${major_minor}/rhel/${OS_VERSION}/amdgpu-install-${version}-1.el${el_version}.noarch.rpm"
            ;;
    esac
}

# Interactive menu for version selection
show_version_menu() {
    local latest=$(get_latest_version)

    if [[ "$USE_FZF" == "true" ]]; then
        # FZF menu (modern, arrow-key navigation)
        local options=()
        options+=("$latest  ← Latest (Recommended)")

        for version in "${AVAILABLE_VERSIONS[@]}"; do
            if [[ "$version" != "$latest" ]]; then
                options+=("$version")
            fi
        done

        options+=("custom  → Enter custom version")
        options+=("back    ← Back to main menu")

        echo ""
        local selection
        selection=$(printf '%s\n' "${options[@]}" | fzf \
            --ansi \
            --layout=reverse \
            --border=rounded \
            --prompt="ROCm Version ❯ " \
            --header="Use ↑↓ arrows to navigate, Enter to select" \
            --color="fg:-1,bg:#1e1e1e,hl:#00d7ff,fg+:-1,bg+:#005f87,hl+:#00d7ff,info:#afaf87,prompt:#00d7ff,pointer:#00d7ff,marker:#00d7ff,spinner:#00d7ff,header:#87afaf")

        if [[ -z "$selection" ]]; then
            echo "Installation cancelled."
            exit 0
        fi

        # Extract version number
        if [[ "$selection" == "back"* ]]; then
            show_main_menu
            return
        elif [[ "$selection" == "custom"* ]]; then
            echo ""
            read -r -p "Enter ROCm version (e.g., 7.2, 6.4.2): " ROCM_VERSION
            if [[ -z "$ROCM_VERSION" ]]; then
                echo -e "${RED}No version entered${NC}"
                show_version_menu
                return
            fi
        else
            ROCM_VERSION=$(echo "$selection" | awk '{print $1}')
        fi
    else
        # Fallback: bash select menu
        local options=()
        options+=("$latest (Latest - Recommended)")

        for version in "${AVAILABLE_VERSIONS[@]}"; do
            if [[ "$version" != "$latest" ]]; then
                options+=("ROCm $version")
            fi
        done

        options+=("Enter custom version")
        options+=("Back to main menu")
        options+=("Quit")

        echo ""
        echo -e "${BOLD}Select ROCm Version to Install${NC}"
        echo ""

        PS3=$'\n\033[0;36mYour choice: \033[0m'

        select opt in "${options[@]}"; do
            case "$REPLY" in
                1)
                    ROCM_VERSION="$latest"
                    break
                    ;;
                $((${#options[@]}-2)))
                    # Enter custom version
                    echo ""
                    read -r -p "Enter ROCm version (e.g., 7.2, 6.4.2): " custom_version
                    if [[ -n "$custom_version" ]]; then
                        ROCM_VERSION="$custom_version"
                        break
                    else
                        echo -e "${RED}No version entered, try again${NC}"
                    fi
                    ;;
                $((${#options[@]}-1)))
                    # Back to main menu
                    show_main_menu
                    return
                    ;;
                ${#options[@]})
                    echo "Installation cancelled."
                    exit 0
                    ;;
                *)
                    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [[ $REPLY -gt 1 ]] && [[ $REPLY -lt $((${#options[@]}-2)) ]]; then
                        local selected="${options[$((REPLY-1))]}"
                        ROCM_VERSION="${selected#ROCm }"
                        break
                    else
                        echo -e "${RED}Invalid selection, try again${NC}"
                    fi
                    ;;
            esac
        done
    fi

    echo ""
    log "Selected ROCm version: $ROCM_VERSION"
}

#######################################
# Main Menu
#######################################

show_main_menu() {
    if [[ "$USE_FZF" == "true" ]]; then
        local latest=$(get_latest_version)
        local options=(
            "quick  ${GREEN}⚡ Quick Install${NC} (Latest: ${CYAN}$latest${NC}, recommended defaults)"
            "custom ${YELLOW}⚙  Custom Installation${NC} (choose version and options)"
            "verify ${GREEN}✓  Verify${NC} existing installation"
            "remove ${RED}✗  Uninstall${NC} ROCm"
            "quit   Exit"
        )

        echo ""
        local selection
        selection=$(for opt in "${options[@]}"; do echo -e "$opt"; done | fzf \
            --ansi \
            --layout=reverse \
            --border=rounded \
            --prompt="ROCm Installer ❯ " \
            --header="Press Enter for Quick Install, or ↑↓ to choose" \
            --color="fg:-1,bg:#1e1e1e,hl:#00d7ff,fg+:-1,bg+:#005f87,hl+:#00d7ff,info:#afaf87,prompt:#00d7ff,pointer:#00d7ff,marker:#00d7ff,spinner:#00d7ff,header:#87afaf")

        if [[ -z "$selection" ]]; then
            echo "Installation cancelled."
            exit 0
        fi

        local action=$(echo "$selection" | awk '{print $1}')

        case "$action" in
            quick)
                ROCM_VERSION=$(get_latest_version)
                echo ""
                echo -e "${GREEN}Quick Install Mode${NC}"
                echo -e "Version: ${CYAN}$ROCM_VERSION${NC}"
                echo -e "DKMS: ${GREEN}Enabled${NC}"
                echo -e "SSH: ${GREEN}Configure${NC}"
                echo -e "Reboot: ${GREEN}Immediate${NC}"
                echo ""
                return 0
                ;;
            custom)
                show_version_menu
                show_options_menu
                return 0
                ;;
            verify)
                verify_installation
                exit 0
                ;;
            remove)
                do_uninstall
                exit 0
                ;;
            quit)
                echo "Goodbye!"
                exit 0
                ;;
        esac
    else
        # Fallback: bash select
        local latest=$(get_latest_version)
        local options=(
            "⚡ Quick Install (Latest: $latest, recommended defaults)"
            "⚙  Custom Installation (choose version and options)"
            "✓  Verify existing installation"
            "✗  Uninstall ROCm"
            "Exit"
        )

        echo ""
        echo -e "${BOLD}ROCm Installer${NC}"
        echo ""

        PS3=$'\n\033[0;36mYour choice [Enter for Quick Install]: \033[0m'

        select opt in "${options[@]}"; do
            case "$REPLY" in
                ""|1)
                    ROCM_VERSION=$(get_latest_version)
                    echo ""
                    echo -e "${GREEN}Quick Install Mode${NC}"
                    echo -e "Version: ${CYAN}$ROCM_VERSION${NC}"
                    echo ""
                    return 0
                    ;;
                2)
                    show_version_menu
                    show_options_menu
                    return 0
                    ;;
                3)
                    verify_installation
                    exit 0
                    ;;
                4)
                    do_uninstall
                    exit 0
                    ;;
                5)
                    echo "Goodbye!"
                    exit 0
                    ;;
                *)
                    echo -e "${RED}Invalid selection${NC}"
                    ;;
            esac
        done
    fi
}

#######################################
# Installation Options Menu
#######################################

get_reboot_display() {
    if [[ "$REBOOT_DELAY" -eq -1 ]]; then
        echo "${YELLOW}Skip${NC}"
    elif [[ "$REBOOT_DELAY" -eq 0 ]]; then
        echo "${GREEN}Immediate${NC}"
    else
        echo "${CYAN}After ${REBOOT_DELAY} min${NC}"
    fi
}

show_options_menu() {
    local dkms_status=$(if [[ "$NO_DKMS" == "true" ]]; then echo "Disabled"; else echo "Enabled"; fi)
    local ssh_status=$(if [[ "$SKIP_SSH" == "true" ]]; then echo "Skip"; else echo "Configure"; fi)
    local reboot_status=$(get_reboot_display)

    if [[ "$USE_FZF" == "true" ]]; then
        # FZF menu
        local options=(
            "dkms     Toggle DKMS Driver (currently: $dkms_status)"
            "ssh      Toggle SSH Configuration (currently: $ssh_status)"
            "reboot   Change Reboot Strategy (currently: $reboot_status)"
            "packages Manage Extra Packages (${#EXTRA_PACKAGES[@]} packages)"
            "start    ▶ Start Installation"
            "version  ← Change version (currently: $ROCM_VERSION)"
            "main     ← Back to main menu"
            "quit     Exit"
        )

        echo ""
        local selection
        selection=$(printf '%s\n' "${options[@]}" | fzf \
            --ansi \
            --layout=reverse \
            --border=rounded \
            --prompt="Installation Options [ROCm $ROCM_VERSION] ❯ " \
            --header="Use ↑↓ to navigate, Enter to select" \
            --color="fg:-1,bg:#1e1e1e,hl:#00d7ff,fg+:-1,bg+:#005f87,hl+:#00d7ff,info:#afaf87,prompt:#00d7ff,pointer:#00d7ff,marker:#00d7ff,spinner:#00d7ff,header:#87afaf")

        if [[ -z "$selection" ]]; then
            echo "Installation cancelled."
            exit 0
        fi

        local action=$(echo "$selection" | awk '{print $1}')

        case "$action" in
            dkms)
                NO_DKMS=$(if [[ "$NO_DKMS" == "true" ]]; then echo "false"; else echo "true"; fi)
                echo -e "${GREEN}✓${NC} DKMS Driver: $(if [[ "$NO_DKMS" == "true" ]]; then echo "Disabled"; else echo "Enabled"; fi)"
                show_options_menu
                ;;
            ssh)
                SKIP_SSH=$(if [[ "$SKIP_SSH" == "true" ]]; then echo "false"; else echo "true"; fi)
                echo -e "${GREEN}✓${NC} SSH Configuration: $(if [[ "$SKIP_SSH" == "true" ]]; then echo "Skip"; else echo "Configure"; fi)"
                show_options_menu
                ;;
            reboot)
                show_reboot_menu
                ;;
            packages)
                show_packages_menu
                ;;
            start)
                echo ""
                return 0
                ;;
            version)
                show_version_menu
                show_options_menu
                ;;
            main)
                show_main_menu
                return
                ;;
            quit)
                echo "Installation cancelled."
                exit 0
                ;;
        esac
    else
        # Fallback: bash select
        local options=(
            "Toggle DKMS Driver (currently: $dkms_status)"
            "Toggle SSH Configuration (currently: $ssh_status)"
            "Change Reboot Strategy (currently: $reboot_status)"
            "Manage Extra Packages (${#EXTRA_PACKAGES[@]} packages)"
            "── Start Installation ──"
            "Change version (currently: $ROCM_VERSION)"
            "Back to main menu"
            "Quit"
        )

        echo ""
        echo -e "${BOLD}Installation Options${NC} ${GREEN}[ROCm $ROCM_VERSION]${NC}"
        echo ""

        PS3=$'\n\033[0;36mYour choice: \033[0m'

        select opt in "${options[@]}"; do
            case "$REPLY" in
                1)
                    NO_DKMS=$(if [[ "$NO_DKMS" == "true" ]]; then echo "false"; else echo "true"; fi)
                    echo -e "${GREEN}✓${NC} DKMS Driver: $(if [[ "$NO_DKMS" == "true" ]]; then echo "Disabled"; else echo "Enabled"; fi)"
                    show_options_menu
                    return
                    ;;
                2)
                    SKIP_SSH=$(if [[ "$SKIP_SSH" == "true" ]]; then echo "false"; else echo "true"; fi)
                    echo -e "${GREEN}✓${NC} SSH Configuration: $(if [[ "$SKIP_SSH" == "true" ]]; then echo "Skip"; else echo "Configure"; fi)"
                    show_options_menu
                    return
                    ;;
                3)
                    show_reboot_menu
                    return
                    ;;
                4)
                    show_packages_menu
                    return
                    ;;
                5)
                    echo ""
                    return 0
                    ;;
                6)
                    show_version_menu
                    show_options_menu
                    return
                    ;;
                7)
                    show_main_menu
                    return
                    ;;
                8)
                    echo "Installation cancelled."
                    exit 0
                    ;;
                *)
                    echo -e "${RED}Invalid selection, try again${NC}"
                    ;;
            esac
        done
    fi
}

show_reboot_menu() {
    if [[ "$USE_FZF" == "true" ]]; then
        # FZF menu
        local options=(
            "0      Reboot immediately ← Recommended"
            "5      Reboot after 5 minutes"
            "10     Reboot after 10 minutes"
            "30     Reboot after 30 minutes"
            "60     Reboot after 60 minutes"
            "-1     Skip reboot (manual)"
            "custom Enter custom delay (1-120 min)"
            "back   ← Back"
        )

        echo ""
        local selection
        selection=$(printf '%s\n' "${options[@]}" | fzf \
            --ansi \
            --layout=reverse \
            --border=rounded \
            --prompt="Reboot Strategy ❯ " \
            --header="Use ↑↓ to navigate, Enter to select" \
            --color="fg:-1,bg:#1e1e1e,hl:#00d7ff,fg+:-1,bg+:#005f87,hl+:#00d7ff,info:#afaf87,prompt:#00d7ff,pointer:#00d7ff,marker:#00d7ff,spinner:#00d7ff,header:#87afaf")

        if [[ -z "$selection" ]]; then
            show_options_menu
            return
        fi

        local delay=$(echo "$selection" | awk '{print $1}')

        if [[ "$delay" == "custom" ]]; then
            echo ""
            read -r -p "Enter delay in minutes (1-120): " custom_delay
            if [[ "$custom_delay" =~ ^[0-9]+$ ]] && [[ $custom_delay -ge 1 ]] && [[ $custom_delay -le 120 ]]; then
                REBOOT_DELAY=$custom_delay
                log "Reboot strategy: Delayed $REBOOT_DELAY minutes"
            else
                echo -e "${RED}Invalid delay${NC}"
                REBOOT_DELAY=0
                log "Reboot strategy: Immediate (fallback)"
            fi
        elif [[ "$delay" == "back" ]]; then
            show_options_menu
            return
        else
            REBOOT_DELAY=$delay
            if [[ "$REBOOT_DELAY" -eq -1 ]]; then
                log "Reboot strategy: Skip"
            elif [[ "$REBOOT_DELAY" -eq 0 ]]; then
                log "Reboot strategy: Immediate"
            else
                log "Reboot strategy: Delayed $REBOOT_DELAY minutes"
            fi
        fi

        show_options_menu
    else
        # Fallback: bash select
        local options=(
            "Reboot immediately (Recommended)"
            "Reboot after 5 minutes"
            "Reboot after 10 minutes"
            "Reboot after 30 minutes"
            "Reboot after 60 minutes"
            "Skip reboot (manual)"
            "Custom delay (1-120 min)"
            "Back"
        )

        echo ""
        echo -e "${BOLD}Reboot Strategy${NC}"
        echo ""

        PS3=$'\n\033[0;36mYour choice: \033[0m'

        select opt in "${options[@]}"; do
            case "$REPLY" in
                1)
                    REBOOT_DELAY=0
                    log "Reboot strategy: Immediate"
                    show_options_menu
                    return
                    ;;
                2)
                    REBOOT_DELAY=5
                    log "Reboot strategy: Delayed 5 minutes"
                    show_options_menu
                    return
                    ;;
                3)
                    REBOOT_DELAY=10
                    log "Reboot strategy: Delayed 10 minutes"
                    show_options_menu
                    return
                    ;;
                4)
                    REBOOT_DELAY=30
                    log "Reboot strategy: Delayed 30 minutes"
                    show_options_menu
                    return
                    ;;
                5)
                    REBOOT_DELAY=60
                    log "Reboot strategy: Delayed 60 minutes"
                    show_options_menu
                    return
                    ;;
                6)
                    REBOOT_DELAY=-1
                    log "Reboot strategy: Skip"
                    show_options_menu
                    return
                    ;;
                7)
                    echo ""
                    read -r -p "Enter delay in minutes (1-120): " custom_delay
                    if [[ "$custom_delay" =~ ^[0-9]+$ ]] && [[ $custom_delay -ge 1 ]] && [[ $custom_delay -le 120 ]]; then
                        REBOOT_DELAY=$custom_delay
                        log "Reboot strategy: Delayed $REBOOT_DELAY minutes"
                        show_options_menu
                        return
                    else
                        echo -e "${RED}Invalid delay, try again${NC}"
                    fi
                    ;;
                8)
                    show_options_menu
                    return
                    ;;
                *)
                    echo -e "${RED}Invalid selection, try again${NC}"
                    ;;
            esac
        done
    fi
}

show_packages_menu() {
    if [[ "$USE_FZF" == "true" ]]; then
        # FZF menu
        local options=(
            "view   View all packages"
            "add    Add package"
            "remove Remove package"
            "back   ← Back"
        )

        echo ""
        local selection
        selection=$(printf '%s\n' "${options[@]}" | fzf \
            --ansi \
            --layout=reverse \
            --border=rounded \
            --prompt="Extra Packages (${#EXTRA_PACKAGES[@]}) ❯ " \
            --header="Use ↑↓ to navigate, Enter to select" \
            --color="fg:-1,bg:#1e1e1e,hl:#00d7ff,fg+:-1,bg+:#005f87,hl+:#00d7ff,info:#afaf87,prompt:#00d7ff,pointer:#00d7ff,marker:#00d7ff,spinner:#00d7ff,header:#87afaf")

        if [[ -z "$selection" ]]; then
            show_options_menu
            return
        fi

        local action=$(echo "$selection" | awk '{print $1}')

        case "$action" in
            view)
                echo ""
                echo -e "${BOLD}Extra packages to install:${NC}"
                echo ""
                printf '%s\n' "${EXTRA_PACKAGES[@]}" | column -c 100
                echo ""
                read -r -p "Press Enter to continue..."
                show_packages_menu
                ;;
            add)
                echo ""
                read -r -p "Package name: " new_pkg
                if [[ -n "$new_pkg" ]]; then
                    EXTRA_PACKAGES+=("$new_pkg")
                    echo -e "${GREEN}✓${NC} Added: $new_pkg"
                fi
                show_packages_menu
                ;;
            remove)
                echo ""
                local pkg_to_remove
                pkg_to_remove=$(printf '%s\n' "${EXTRA_PACKAGES[@]}" | fzf \
                    --ansi \
                    --layout=reverse \
                    --border=rounded \
                    --prompt="Select package to remove ❯ " \
                    --header="Use ↑↓ to navigate, type to search" \
                    --color="fg:-1,bg:#1e1e1e,hl:#00d7ff,fg+:-1,bg+:#005f87,hl+:#00d7ff,info:#afaf87,prompt:#00d7ff,pointer:#00d7ff,marker:#00d7ff,spinner:#00d7ff,header:#87afaf")

                if [[ -n "$pkg_to_remove" ]]; then
                    for i in "${!EXTRA_PACKAGES[@]}"; do
                        if [[ "${EXTRA_PACKAGES[$i]}" == "$pkg_to_remove" ]]; then
                            unset 'EXTRA_PACKAGES[$i]'
                            EXTRA_PACKAGES=("${EXTRA_PACKAGES[@]}")
                            echo -e "${GREEN}✓${NC} Removed: $pkg_to_remove"
                            break
                        fi
                    done
                fi
                show_packages_menu
                ;;
            back)
                show_options_menu
                ;;
        esac
    else
        # Fallback: bash select
        echo ""
        echo -e "${BOLD}Extra Packages${NC} ${CYAN}(${#EXTRA_PACKAGES[@]} packages)${NC}"
        echo ""

        local options=(
            "View all packages"
            "Add package"
            "Remove package"
            "Back"
        )

        PS3=$'\n\033[0;36mYour choice: \033[0m'

        select opt in "${options[@]}"; do
            case "$REPLY" in
                1)
                    echo ""
                    echo -e "${BOLD}Installed packages:${NC}"
                    printf '%s\n' "${EXTRA_PACKAGES[@]}" | column -c 80
                    echo ""
                    read -r -p "Press Enter to continue..."
                    show_packages_menu
                    return
                    ;;
                2)
                    echo ""
                    read -r -p "Package name: " new_pkg
                    if [[ -n "$new_pkg" ]]; then
                        EXTRA_PACKAGES+=("$new_pkg")
                        echo -e "${GREEN}✓${NC} Added: $new_pkg"
                    fi
                    show_packages_menu
                    return
                    ;;
                3)
                    echo ""
                    echo "Enter package name or number (1-${#EXTRA_PACKAGES[@]}):"
                    read -r -p "> " pkg_ref
                    if [[ "$pkg_ref" =~ ^[0-9]+$ ]] && [[ $pkg_ref -ge 1 ]] && [[ $pkg_ref -le ${#EXTRA_PACKAGES[@]} ]]; then
                        local removed="${EXTRA_PACKAGES[$((pkg_ref-1))]}"
                        unset 'EXTRA_PACKAGES[$((pkg_ref-1))]'
                        EXTRA_PACKAGES=("${EXTRA_PACKAGES[@]}")
                        echo -e "${GREEN}✓${NC} Removed: $removed"
                    else
                        for i in "${!EXTRA_PACKAGES[@]}"; do
                            if [[ "${EXTRA_PACKAGES[$i]}" == "$pkg_ref" ]]; then
                                unset 'EXTRA_PACKAGES[$i]'
                                EXTRA_PACKAGES=("${EXTRA_PACKAGES[@]}")
                                echo -e "${GREEN}✓${NC} Removed: $pkg_ref"
                                break
                            fi
                        done
                    fi
                    show_packages_menu
                    return
                    ;;
                4)
                    show_options_menu
                    return
                    ;;
                *)
                    echo -e "${RED}Invalid selection${NC}"
                    ;;
            esac
        done
    fi
}

#######################################
# Installation Steps
#######################################

step_prerequisites() {
    echo ""
    draw_box "Step 1: Installing Prerequisites"
    echo ""

    $PKG_UPDATE

    case "$PKG_MGR" in
        apt)
            # Install extra packages (Ubuntu/Debian)
            $PKG_INSTALL "${EXTRA_PACKAGES[@]}" || true

            # Install kernel headers
            $PKG_INSTALL "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)" 2>/dev/null || \
                $PKG_INSTALL "linux-headers-$(uname -r)" || true
            ;;
        dnf)
            # RHEL/Rocky/AlmaLinux equivalent packages
            local DNF_PACKAGES=(
                # Basic system utilities
                "sudo"
                "curl"
                "wget"
                "ca-certificates"
                "gnupg2"
                "redhat-lsb-core"
                # Development tools
                "gcc"
                "gcc-c++"
                "make"
                "cmake"
                "git"
                "pkgconfig"
                "@development-tools"
                # Python
                "python3"
                "python3-devel"
                "python3-pip"
                "python3-setuptools"
                "python3-wheel"
                # Editor & tools
                "vim-enhanced"
                "nano"
                "htop"
                "tmux"
                "screen"
                # Network & filesystem
                "net-tools"
                "iputils"
                "bind-utils"
                "nfs-utils"
                "fuse-sshfs"
                "rsync"
                # System utilities
                "pciutils"
                "usbutils"
                "lshw"
                "dmidecode"
                "sysstat"
                "iotop"
                "unzip"
                "zip"
                "p7zip"
                "jq"
                # Libraries
                "openssl-devel"
                "libffi-devel"
                "numactl-devel"
            )
            $PKG_INSTALL "${DNF_PACKAGES[@]}" || true
            $PKG_INSTALL "kernel-headers-$(uname -r)" "kernel-devel-$(uname -r)" || true
            ;;
    esac

    echo -e "\n  ${GREEN}✓${NC} Prerequisites installed"
}

step_ssh_config() {
    if [[ "$SKIP_SSH" == "true" ]]; then
        log "Skipping SSH configuration"
        return
    fi

    echo ""
    draw_box "Step 2: SSH & System Configuration"
    echo ""

    case "$PKG_MGR" in
        apt)
            # Install time sync and SSH
            $PKG_INSTALL ntpdate openssh-server util-linux-extra || true

            # Sync time with China NTP server
            ntpdate ntp.aliyun.com 2>/dev/null || ntpdate pool.ntp.org 2>/dev/null || true
            hwclock -w 2>/dev/null || true
            ;;
        dnf)
            $PKG_INSTALL chrony openssh-server || true
            systemctl enable chronyd 2>/dev/null || true
            systemctl start chronyd 2>/dev/null || true
            ;;
    esac

    # Configure SSH for root login
    if [[ -f /etc/ssh/sshd_config ]]; then
        sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi

    # Optional: Set root password if provided
    if [[ -n "$ROOT_PASSWORD" ]]; then
        echo "root:$ROOT_PASSWORD" | chpasswd
        log "Root password updated"
    fi

    echo -e "\n  ${GREEN}✓${NC} SSH configured"
}

step_lock_kernel() {
    echo ""
    draw_box "Step 3: Kernel Management"
    echo ""

    log "Locking kernel version: $(uname -r)"

    case "$PKG_MGR" in
        apt)
            # Lock current kernel version with apt-mark
            local kernel_ver
            kernel_ver=$(uname -r)
            apt-mark hold "linux-image-${kernel_ver}" 2>/dev/null || true
            apt-mark hold "linux-image-${kernel_ver}-generic" 2>/dev/null || true
            apt-mark hold "linux-headers-${kernel_ver}" 2>/dev/null || true
            apt-mark hold linux-image-generic linux-headers-generic 2>/dev/null || true

            # Disable kernel updates in unattended-upgrades
            local conf_file="/etc/apt/apt.conf.d/50unattended-upgrades"
            if [[ -f "$conf_file" ]]; then
                # Comment out Ubuntu:Linux origin to prevent kernel updates
                sed -i 's/^.*"Ubuntu:Linux";/\/\/ "Ubuntu:Linux";/g' "$conf_file" 2>/dev/null || true

                # Add to blacklist if not already present
                if ! grep -q '"linux-image\*"' "$conf_file"; then
                    sed -i '/Unattended-Upgrade::Package-Blacklist/a\    "linux-image*";\n    "linux-headers*";\n    "linux-modules*";' \
                        "$conf_file" 2>/dev/null || true
                fi
            fi
            ;;
        dnf)
            if ! grep -q "exclude=kernel" /etc/dnf/dnf.conf 2>/dev/null; then
                echo "exclude=kernel*" >> /etc/dnf/dnf.conf
            fi
            ;;
    esac

    echo -e "\n  ${GREEN}✓${NC} Kernel locked"
}

step_install_amdgpu() {
    echo ""
    draw_box "Step 4: Installing AMDGPU Driver"
    echo ""

    get_package_url "$ROCM_VERSION"
    log "Downloading from: $AMDGPU_URL"

    local temp_dir=$(mktemp -d)
    cd "$temp_dir"

    echo -e "  Downloading AMDGPU installer..."
    if ! wget -q --show-progress "$AMDGPU_URL" -O amdgpu-install.pkg 2>&1; then
        # Try with latest symlink as fallback
        warn "Direct download failed, trying latest..."
        case "$OS_ID" in
            ubuntu)
                local codename
                [[ "$OS_VERSION" == "22.04" ]] && codename="jammy" || codename="noble"
                AMDGPU_URL="${REPO_BASE_URL}/latest/ubuntu/${codename}/"
                local pkg_name=$(curl -s "$AMDGPU_URL" | grep -oP 'amdgpu-install_[^"]+\.deb' | head -1)
                wget -q --show-progress "${AMDGPU_URL}${pkg_name}" -O amdgpu-install.pkg
                ;;
        esac
    fi

    case "$PKG_MGR" in
        apt)
            dpkg -i amdgpu-install.pkg 2>/dev/null || apt-get install -f -y
            apt-get update
            ;;
        dnf)
            dnf install -y ./amdgpu-install.pkg
            ;;
    esac

    rm -rf "$temp_dir"
    echo -e "\n  ${GREEN}✓${NC} AMDGPU installer installed"
}

step_install_rocm() {
    echo ""
    draw_box "Step 5: Installing ROCm Stack"
    echo ""

    case "$PKG_MGR" in
        apt)
            if [[ "$NO_DKMS" != "true" ]]; then
                echo -e "  Installing AMDGPU DKMS driver..."
                if ! apt-get install -y amdgpu-dkms 2>&1; then
                    warn "DKMS failed, continuing without it..."
                    NO_DKMS=true
                fi
            fi

            echo -e "  Installing ROCm packages..."
            apt-get install -y rocm
            ;;
        dnf)
            if [[ "$NO_DKMS" == "true" ]]; then
                amdgpu-install -y --usecase=rocm --no-dkms
            else
                amdgpu-install -y --usecase=rocm
            fi
            ;;
    esac

    echo -e "\n  ${GREEN}✓${NC} ROCm installed"
}

step_configure_env() {
    echo ""
    draw_box "Step 6: Environment Configuration"
    echo ""

    # Add user to groups
    local actual_user=${SUDO_USER:-$USER}
    usermod -aG video,render "$actual_user" 2>/dev/null || true
    log "User '$actual_user' added to video,render groups"

    # Configure permanent group membership
    if [[ -f /etc/adduser.conf ]]; then
        grep -q 'ADD_EXTRA_GROUPS=1' /etc/adduser.conf || echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
        grep -q 'EXTRA_GROUPS=video' /etc/adduser.conf || echo 'EXTRA_GROUPS=video' >> /etc/adduser.conf
        grep -q 'EXTRA_GROUPS=render' /etc/adduser.conf || echo 'EXTRA_GROUPS=render' >> /etc/adduser.conf
    fi

    # Udev rules
    cat > /etc/udev/rules.d/70-amdgpu.rules << 'EOF'
KERNEL=="kfd", GROUP="render", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0666"
EOF
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true

    # Library paths
    cat > /etc/ld.so.conf.d/rocm.conf << 'EOF'
/opt/rocm/lib
/opt/rocm/lib64
EOF
    ldconfig

    # Environment script
    cat > /etc/profile.d/rocm.sh << 'EOF'
# ROCm Environment
export PATH=$PATH:/opt/rocm/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/rocm/lib:/opt/rocm/lib64
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
EOF
    chmod +x /etc/profile.d/rocm.sh

    # Also add to user's bashrc
    local user_home=$(eval echo ~$actual_user)
    if [[ -f "$user_home/.bashrc" ]]; then
        if ! grep -q "ROCM_PATH" "$user_home/.bashrc"; then
            cat >> "$user_home/.bashrc" << 'EOF'

# ROCm Environment
export PATH=$PATH:/opt/rocm/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/rocm/lib:/opt/rocm/lib64
export ROCM_PATH=/opt/rocm
EOF
        fi
    fi

    echo -e "\n  ${GREEN}✓${NC} Environment configured"
}

#######################################
# Verification
#######################################

verify_installation() {
    echo ""
    draw_box "Verifying Installation"
    echo ""

    export PATH=$PATH:/opt/rocm/bin
    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/rocm/lib:/opt/rocm/lib64

    local all_pass=true

    # rocminfo
    echo -n "  Checking rocminfo... "
    if command -v rocminfo &> /dev/null && rocminfo > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC}"
        all_pass=false
    fi

    # rocm-smi
    echo -n "  Checking rocm-smi... "
    if command -v rocm-smi &> /dev/null && rocm-smi > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${YELLOW}WARN${NC} (may need reboot)"
    fi

    # KFD device
    echo -n "  Checking /dev/kfd... "
    if [[ -e /dev/kfd ]]; then
        echo -e "${GREEN}PRESENT${NC}"
    else
        echo -e "${YELLOW}MISSING${NC} (will appear after reboot)"
    fi

    # clinfo
    echo -n "  Checking clinfo... "
    if command -v clinfo &> /dev/null; then
        echo -e "${GREEN}AVAILABLE${NC}"
    else
        echo -e "${YELLOW}NOT INSTALLED${NC} (optional: apt install clinfo)"
    fi

    echo ""
    if [[ "$all_pass" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} Verification complete"
    else
        echo -e "  ${YELLOW}!${NC} Some checks failed - reboot may be required"
    fi
}

#######################################
# Uninstall
#######################################

do_uninstall() {
    print_header

    echo -e "${BOLD}  Uninstall ROCm${NC}"
    echo ""

    read -p "  Are you sure? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

    case "$PKG_MGR" in
        apt)
            apt-get purge -y 'rocm*' 'amdgpu*' 2>/dev/null || true
            apt-get autoremove -y
            ;;
        dnf)
            amdgpu-uninstall -y 2>/dev/null || true
            dnf remove -y 'rocm*' 'amdgpu*' 2>/dev/null || true
            ;;
    esac

    rm -f /etc/ld.so.conf.d/rocm.conf
    rm -f /etc/profile.d/rocm.sh
    rm -f /etc/udev/rules.d/70-amdgpu.rules
    ldconfig

    echo -e "\n  ${GREEN}✓${NC} ROCm uninstalled"
}

#######################################
# Help
#######################################

show_help() {
    cat << EOF
ROCm Unified Installation Script v${SCRIPT_VERSION}

Usage: sudo $0 [options]

Options:
  --version VERSION      Install specific ROCm version (e.g., 7.2, 6.4.2)
  --latest               Install latest available version
  --root-password PASS   Set root password during installation
  --skip-ssh             Skip SSH configuration
  --skip-reboot          Skip reboot after installation
  --reboot-delay MIN     Delay reboot for MIN minutes (0=immediate, default: 0)
  --verify-only          Only verify existing installation
  --uninstall            Remove ROCm
  --no-dkms              Skip DKMS driver (use pre-built)
  --non-interactive      Run without prompts (use with --version or --latest)
  --help                 Show this help

Examples:
  sudo $0                                      # Interactive mode
  sudo $0 --latest                             # Install latest, reboot immediately
  sudo $0 --version 7.2 --reboot-delay 10      # Install ROCm 7.2, reboot in 10 min
  sudo $0 --latest --skip-reboot               # Install without reboot
  sudo $0 --latest --root-password 123         # Set root password
  sudo $0 --verify-only                        # Check installation
  sudo $0 --uninstall                          # Remove ROCm

  # Automated installation for scripts
  sudo $0 --latest --non-interactive --reboot-delay 5

Supported:
  Ubuntu 22.04, 24.04 | Debian 12 | RHEL/Rocky 9.x

EOF
}

#######################################
# Argument Parsing
#######################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version) ROCM_VERSION="$2"; shift 2 ;;
            --latest) USE_LATEST=true; shift ;;
            --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
            --skip-ssh) SKIP_SSH=true; shift ;;
            --skip-reboot) REBOOT_DELAY=-1; shift ;;
            --reboot-delay) REBOOT_DELAY="$2"; shift 2 ;;
            --verify-only) VERIFY_ONLY=true; shift ;;
            --uninstall) UNINSTALL=true; shift ;;
            --no-dkms) NO_DKMS=true; shift ;;
            --non-interactive) NON_INTERACTIVE=true; shift ;;
            --help|-h) show_help; exit 0 ;;
            *) error "Unknown option: $1" ;;
        esac
    done
}

#######################################
# Main
#######################################

main() {
    parse_args "$@"

    # Check root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi

    # Initialize log
    mkdir -p /var/log
    echo "ROCm Installation - $(date)" > "$LOG_FILE"

    # Handle special modes
    if [[ "$VERIFY_ONLY" == "true" ]]; then
        print_header
        detect_system
        verify_installation
        exit 0
    fi

    if [[ "$UNINSTALL" == "true" ]]; then
        detect_system
        do_uninstall
        exit 0
    fi

    # Main flow
    print_header
    detect_system

    # Install fzf for better UI (only in interactive mode)
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        install_fzf_if_needed
        if command -v fzf &> /dev/null; then
            USE_FZF=true
        fi
    fi

    detect_gpu
    fetch_available_versions

    # Interactive mode: show main menu
    if [[ "$USE_LATEST" == "true" ]]; then
        ROCM_VERSION=$(get_latest_version)
        log "Using latest version: $ROCM_VERSION"
    elif [[ -z "$ROCM_VERSION" ]] && [[ "$NON_INTERACTIVE" != "true" ]]; then
        show_main_menu
    elif [[ -z "$ROCM_VERSION" ]]; then
        ROCM_VERSION=$(get_latest_version)
    fi

    # Installation
    echo ""
    echo -e "${BOLD}Starting installation of ROCm $ROCM_VERSION...${NC}"
    echo ""

    step_prerequisites
    step_ssh_config
    step_lock_kernel
    step_install_amdgpu
    step_install_rocm
    step_configure_env

    verify_installation

    # Final
    echo ""
    draw_box "Installation Complete!"
    echo ""
    echo -e "  ROCm $ROCM_VERSION installed successfully."
    echo ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo -e "  1. Reboot your system"
    echo -e "  2. Run: ${CYAN}$0 --verify-only${NC}"
    echo -e "  3. Test: ${CYAN}rocminfo && rocm-smi${NC}"
    echo ""
    log "Installation complete. Log: $LOG_FILE"

    # Execute reboot strategy (non-interactive mode skips reboot)
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        echo ""
        if [[ "$REBOOT_DELAY" -eq -1 ]]; then
            # Skip reboot
            echo -e "  ${YELLOW}⚠ Reboot skipped.${NC} Remember to reboot manually later."
            echo -e "  Run: ${CYAN}sudo reboot${NC}"
        elif [[ "$REBOOT_DELAY" -eq 0 ]]; then
            # Immediate reboot
            echo -e "  ${GREEN}Rebooting now...${NC}"
            sleep 2
            reboot
        else
            # Delayed reboot
            echo -e "  ${CYAN}System will reboot in $REBOOT_DELAY minute(s).${NC}"
            echo -e "  ${YELLOW}You can cancel with: ${CYAN}sudo shutdown -c${NC}"

            # Schedule reboot
            if shutdown -r +"$REBOOT_DELAY" "ROCm installation complete. System rebooting for driver activation." 2>/dev/null; then
                log "Scheduled reboot in $REBOOT_DELAY minutes using shutdown command"
            else
                # Fallback: use background sleep + reboot
                (sleep $((REBOOT_DELAY * 60)) && reboot) &
                log "Scheduled reboot in $REBOOT_DELAY minutes using background task (PID: $!)"
                echo -e "  ${YELLOW}Note: Using background reboot task${NC}"
            fi
        fi
    fi
}

main "$@"
