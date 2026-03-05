#!/bin/bash

# Update-script for Semaphore-ui (.deb-package)
# Tested on Debian 13 (Trixie) and Ubuntu 24.04 (Noble Numbat)
#
# Author: Uber1337NL
# License: AGPL-3.5 license
#
# https://github.com/Uber1337NL
################################
# VERSION: 3.0 from 03.03.2026 #
################################

set -euo pipefail

# --- Configuration ---
VERBOSE=true
WORK_DIR="/root"
GITHUB_API="https://api.github.com/repos/semaphoreui/semaphore/releases/latest"
SERVICE_NAME="semaphore"
GITHUB_TOKEN=""  # Optional: fill in to avoid rate limiting

# --- Color codes ---
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[34m"
RESET="\e[0m"

# --- Functions ---

log_info()    { echo -e "${GREEN}[INFO]${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_verbose() { $VERBOSE && echo -e "${BLUE}[VERBOSE]${RESET} $*" || true; }

run_command() {
    log_verbose "Run: $*"
    "$@"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)."
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "dpkg" "awk" "grep" "systemctl" "file")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log_error "Required tool missing: $dep"
            exit 1
        fi
    done
}

check_disk_space() {
    local required_mb=100
    local available_mb
    available_mb=$(df -m "$WORK_DIR" | awk 'NR==2 {print $4}')
    if (( available_mb < required_mb )); then
        log_error "Insufficient disk space in $WORK_DIR (available: ${available_mb}MB, required: ${required_mb}MB)."
        exit 1
    fi
    log_verbose "Disk space OK: ${available_mb}MB available."
}

get_arch() {
    local arch
    arch=$(dpkg --print-architecture)
    # Normalize arm64 -> aarch64 for GitHub asset naming
    case "$arch" in
        arm64) echo "arm64" ;;   # semaphore uses arm64, not aarch64
        *)     echo "$arch" ;;
    esac
}

fetch_release_info() {
    local auth_args=()
    [[ -n "$GITHUB_TOKEN" ]] && auth_args=(-H "Authorization: Bearer $GITHUB_TOKEN")

    local tmpfile
    tmpfile=$(mktemp)

    local http_code
    http_code=$(curl -sS \
        --connect-timeout 5 \
        --max-time 20 \
        --retry 3 \
        --retry-delay 2 \
        --retry-all-errors \
        -H "Accept: application/vnd.github+json" \
        "${auth_args[@]}" \
        -o "$tmpfile" -w "%{http_code}" \
        "$GITHUB_API")
    local curl_exit=$?

    log_verbose "GitHub API HTTP status: $http_code"
    log_verbose "GitHub API bytes received: $(wc -c < "$tmpfile" 2>/dev/null || echo 0)"

    if [[ $curl_exit -ne 0 ]]; then
        rm -f "$tmpfile"
        log_error "curl failed (exit code: $curl_exit). Possible network/timeout issue."
        return 1
    fi

    local release_info
    release_info=$(cat "$tmpfile")
    rm -f "$tmpfile"

    case "$http_code" in
        200) ;;
        401|403)
            log_error "GitHub API denied the request (HTTP $http_code). Rate limit or auth issue."
            log_error "Response: $(echo "$release_info" | head -c 300)"
            return 1
            ;;
        404)
            log_error "GitHub API endpoint not found (HTTP 404). Check GITHUB_API URL."
            return 1
            ;;
        *)
            log_error "GitHub API unexpected HTTP status: $http_code"
            log_error "Response: $(echo "$release_info" | head -c 300)"
            return 1
            ;;
    esac

    if [[ -z "$release_info" ]]; then
        log_error "GitHub API returned an empty response."
        return 1
    fi

    echo "$release_info"
}

parse_release() {
    local release_info="$1"
    local arch="$2"

    RELEASE=$(echo "$release_info" | grep '"tag_name"' | awk -F'"' '{print $4}')
    if [[ -z "$RELEASE" ]]; then
        log_error "Could not parse tag_name from GitHub response."
        log_error "Response head: $(echo "$release_info" | head -c 300)"
        exit 1
    fi

    # Match browser_download_url for the correct arch .deb asset
    DOWNLOAD_URL=$(echo "$release_info" \
        | grep -o "\"browser_download_url\": \"[^\"]*${arch}\.deb\"" \
        | head -n 1 \
        | awk -F'"' '{print $4}')

    if [[ -z "$DOWNLOAD_URL" ]]; then
        log_error "Could not find a .deb download URL for architecture '${arch}'."
        log_error "Available assets:"
        echo "$release_info" | grep "browser_download_url" | awk -F'"' '{print $4}' >&2
        exit 1
    fi

    log_verbose "Release tag   : $RELEASE"
    log_verbose "Download URL  : $DOWNLOAD_URL"
}

get_current_version() {
    local version
    version=$(dpkg -s "$SERVICE_NAME" 2>/dev/null | grep 'Version:' | awk '{print $2}')
    if [[ -z "$version" ]]; then
        log_warn "Semaphore does not appear to be installed via dpkg."
        echo "0.0.0"
    else
        echo "${version#v}"
    fi
}

service_action() {
    local action="$1"
    log_verbose "Service '$SERVICE_NAME': $action..."
    if ! run_command systemctl "$action" "$SERVICE_NAME"; then
        log_warn "Could not $action service '$SERVICE_NAME'. Check service status manually."
    fi
}

cleanup() {
    local package="$1"
    if [[ -f "$package" ]]; then
        log_verbose "Cleaning up: removing $package"
        rm -f "$package"
    fi
}

# --- Main script ---

echo -e "${GREEN}=== Semaphore Update Script ===${RESET}"

check_root
check_dependencies

cd "$WORK_DIR" || { log_error "Cannot change to $WORK_DIR."; exit 1; }

check_disk_space

ARCH=$(get_arch)
log_verbose "Detected architecture: $ARCH"

log_verbose "Fetching release information from GitHub..."
if ! RELEASE_INFO=$(fetch_release_info); then
    log_error "Failed to fetch release info. Aborting."
    exit 1
fi

parse_release "$RELEASE_INFO" "$ARCH"

CURRENT_VERSION=$(get_current_version)
LATEST_VERSION="${RELEASE#v}"

log_info "Current version : $CURRENT_VERSION"
log_info "Latest version  : $LATEST_VERSION"

if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    log_warn "You are already running the latest version ($CURRENT_VERSION). No update needed."
    exit 0
fi

read -rp "$(echo -e "${YELLOW}New version available ($LATEST_VERSION). Proceed with update? (y/n): ${RESET}")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_warn "Update aborted by user."
    exit 0
fi

PACKAGE_NAME=$(basename "$DOWNLOAD_URL")

service_action "stop"

# 1. Download
log_verbose "Downloading: $DOWNLOAD_URL"
if ! run_command curl -L --fail --progress-bar \
    --connect-timeout 5 \
    --max-time 120 \
    -H "Accept: application/octet-stream" \
    -o "$PACKAGE_NAME" "$DOWNLOAD_URL"; then
    log_error "Download failed."
    service_action "start"
    exit 1
fi

# 2. Validate
if ! file "$PACKAGE_NAME" | grep -q "Debian binary package"; then
    log_error "Downloaded file is not a valid .deb package."
    log_error "Content: $(head -c 200 "$PACKAGE_NAME")"
    cleanup "$PACKAGE_NAME"
    service_action "start"
    exit 1
fi
log_verbose "Package validated as a valid Debian binary."

# 3. Install
log_verbose "Installing package: $PACKAGE_NAME"
if run_command dpkg -i "$PACKAGE_NAME"; then
    log_info "Installation successful."
    cleanup "$PACKAGE_NAME"
else
    log_error "Installation failed. Package '$PACKAGE_NAME' retained for inspection."
    log_warn "To restore manually: sudo dpkg -i <old-package>.deb"
    service_action "start"
    exit 1
fi

service_action "start"

# 4. Verify installed version
INSTALLED_VERSION=$(dpkg -s "$SERVICE_NAME" 2>/dev/null | grep 'Version:' | awk '{print $2}')
INSTALLED_VERSION="${INSTALLED_VERSION#v}"
if [[ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]]; then
    log_info "Verified: Semaphore $INSTALLED_VERSION is now active."
else
    log_warn "Version mismatch after install. Expected $LATEST_VERSION, got $INSTALLED_VERSION."
fi

echo -e "${GREEN}=== Update completed! ===${RESET}"

