#!/usr/bin/env bash
# Revo CLI - Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/jippylong12/revo/main/install.sh | bash
# Override version: REVO_VERSION=0.2.0 curl -fsSL ... | bash

set -euo pipefail

# Configuration
REVO_VERSION="${REVO_VERSION:-latest}"
REVO_INSTALL_DIR="${REVO_INSTALL_DIR:-$HOME/.revo}"
REVO_BIN_DIR="$REVO_INSTALL_DIR/bin"
REVO_REPO="jippylong12/revo"

# Colors (if terminal supports it)
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    CYAN='\033[36m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    DIM=''
    RESET=''
fi

info() {
    printf "${CYAN}info${RESET}  %s\n" "$1"
}

success() {
    printf "${GREEN}done${RESET}  %s\n" "$1"
}

warn() {
    printf "${YELLOW}warn${RESET}  %s\n" "$1"
}

error() {
    printf "${RED}error${RESET} %s\n" "$1" >&2
}

# Detect shell
detect_shell() {
    local shell_name
    shell_name="$(basename "${SHELL:-/bin/bash}")"

    case "$shell_name" in
        bash)
            echo "$HOME/.bashrc"
            ;;
        zsh)
            echo "$HOME/.zshrc"
            ;;
        fish)
            echo "$HOME/.config/fish/config.fish"
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

# Check for required tools
check_requirements() {
    local missing=()

    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        missing+=("curl or wget")
    fi

    if ! command -v git &> /dev/null; then
        missing+=("git")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

# Download file
download() {
    local url="$1"
    local output="$2"

    if command -v curl &> /dev/null; then
        curl -fsSL "$url" -o "$output"
    elif command -v wget &> /dev/null; then
        wget -qO "$output" "$url"
    else
        error "No download tool available (need curl or wget)"
        exit 1
    fi
}

# Build download URL based on version
get_download_url() {
    if [[ "$REVO_VERSION" == "latest" ]]; then
        echo "https://github.com/$REVO_REPO/releases/latest/download/revo"
    else
        echo "https://github.com/$REVO_REPO/releases/download/v$REVO_VERSION/revo"
    fi
}

# Add to PATH in shell config
add_to_path() {
    local rc_file="$1"
    local path_line="export PATH=\"\$PATH:$REVO_BIN_DIR\""

    # Check if already added
    if [[ -f "$rc_file" ]] && grep -qF "$REVO_BIN_DIR" "$rc_file"; then
        return 0
    fi

    # Add to rc file
    {
        echo ""
        echo "# Revo CLI"
        echo "$path_line"
    } >> "$rc_file"

    return 0
}

# Main installation
main() {
    printf "\n"
    printf "${CYAN}┌${RESET}  Revo - Claude-first Multi-Repo Workspace Manager Installer\n"
    printf "${DIM}│${RESET}\n"

    # Check requirements
    info "Checking requirements..."
    check_requirements
    success "Requirements met"

    # Create directories
    info "Creating installation directory..."
    mkdir -p "$REVO_BIN_DIR"
    success "Created $REVO_BIN_DIR"

    # Download revo
    local revo_path="$REVO_BIN_DIR/revo"
    local release_url
    release_url="$(get_download_url)"

    if [[ "$REVO_VERSION" == "latest" ]]; then
        info "Downloading Revo CLI (latest release)..."
    else
        info "Downloading Revo CLI v${REVO_VERSION}..."
    fi

    if download "$release_url" "$revo_path"; then
        chmod +x "$revo_path"
        success "Downloaded revo executable"
    else
        # Fallback to raw.githubusercontent.com
        local fallback_url="https://raw.githubusercontent.com/$REVO_REPO/main/dist/revo"
        warn "Release download failed, trying fallback..."
        if download "$fallback_url" "$revo_path"; then
            chmod +x "$revo_path"
            warn "Downloaded from fallback (unversioned). Consider installing a tagged release."
        else
            error "Failed to download Revo CLI"
            error "Tried: $release_url"
            error "Fallback: $fallback_url"
            exit 1
        fi
    fi

    # Add to PATH
    info "Configuring shell..."
    local rc_file
    rc_file=$(detect_shell)

    if add_to_path "$rc_file"; then
        success "Added to PATH in $rc_file"
    else
        warn "Could not add to PATH automatically"
        warn "Add this to your shell config:"
        printf '  export PATH="$PATH:%s"\n' "$REVO_BIN_DIR"
    fi

    # Verify installation
    printf "${DIM}│${RESET}\n"
    local installed_version
    if installed_version=$("$revo_path" --version 2>/dev/null); then
        success "Installed $installed_version"
    else
        warn "Installation may have issues - please check $revo_path"
    fi

    # Done
    printf "${DIM}│${RESET}\n"
    printf "${CYAN}└${RESET}  ${GREEN}Installation complete!${RESET}\n"
    printf "\n"
    printf "  To get started:\n"
    printf "    1. Restart your shell or run: ${CYAN}source %s${RESET}\n" "$rc_file"
    printf "    2. Create a workspace: ${CYAN}revo init${RESET}\n"
    printf "\n"
    printf "  Documentation: https://github.com/%s\n" "$REVO_REPO"
    printf "\n"
}

main "$@"
