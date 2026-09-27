#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Rclone Manager - Bootstrap Installer
# ==============================================================================
#
# Downloads the latest Rclone Manager release and runs the package installer.
#
# Repository:
#   https://github.com/jejusee/rclone-manager
#
# ==============================================================================

readonly REPOSITORY="jejusee/rclone-manager"
readonly PROJECT="rclone-manager"

TEMP_DIR=""

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT

log() {
    printf '[rclone-manager] %s\n' "$*"
}

error() {
    printf '[rclone-manager] ERROR: %s\n' "$*" >&2
}

die() {
    error "$*"
    exit 1
}

find_command() {
    command -v "$1" 2>/dev/null || return 1
}

download() {
    local url="$1"
    local output="$2"

    if find_command curl >/dev/null; then
        curl \
            --fail \
            --location \
            --silent \
            --show-error \
            --retry 3 \
            --connect-timeout 15 \
            --output "$output" \
            "$url"

    elif find_command wget >/dev/null; then
        wget \
            --quiet \
            --tries=3 \
            --timeout=15 \
            --output-document="$output" \
            "$url"

    else
        die "curl or wget is required."
    fi
}

get_latest_version() {
    local effective_url

    if find_command curl >/dev/null; then
        effective_url="$(
            curl \
                --fail \
                --location \
                --silent \
                --show-error \
                --output /dev/null \
                --write-out '%{url_effective}' \
                "https://github.com/${REPOSITORY}/releases/latest"
        )"

    elif find_command wget >/dev/null; then
        effective_url="$(
            wget \
                --server-response \
                --max-redirect=10 \
                --output-document=/dev/null \
                "https://github.com/${REPOSITORY}/releases/latest" \
                2>&1 |
            awk '/^  Location:/ {url=$2} END {gsub(/\r/, "", url); print url}'
        )"

    else
        die "curl or wget is required."
    fi

    local version="${effective_url##*/}"
    version="${version#v}"

    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] ||
        die "Unable to determine the latest release version."

    printf '%s\n' "$version"
}

verify_checksum() {
    local version="$1"
    local archive="$2"
    local sums="$3"

    local filename="${PROJECT}-${version}.tar.gz"
    local expected
    local actual

    expected="$(
        awk -v file="$filename" \
            '$2 == file || $2 == "*"file {print $1; exit}' \
            "$sums"
    )"

    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] ||
        die "Checksum entry not found for ${filename}."

    if find_command sha256sum >/dev/null; then
        actual="$(
            sha256sum "$archive" |
            awk '{print $1}'
        )"

    elif find_command shasum >/dev/null; then
        actual="$(
            shasum -a 256 "$archive" |
            awk '{print $1}'
        )"

    else
        die "sha256sum or shasum is required."
    fi

    [[ "${actual,,}" == "${expected,,}" ]] ||
        die "Checksum verification failed."

    log "Checksum verified."
}

find_package_root() {
    local directory="$1"
    local candidate

    if [[ -f "${directory}/scripts/install.sh" ]]; then
        printf '%s\n' "$directory"
        return 0
    fi

    for candidate in "$directory"/*; do
        [[ -d "$candidate" ]] || continue

        if [[ -f "${candidate}/scripts/install.sh" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

main() {
    local version
    local archive
    local sums
    local extract_dir
    local package_root

    [[ "$(uname -s)" == "Linux" ]] ||
        die "Only Linux is supported."

    [[ "$EUID" -eq 0 ]] ||
        die "Run this installer as root."

    find_command tar >/dev/null ||
        die "tar is required."

    version="$(get_latest_version)"

    TEMP_DIR="$(mktemp -d -t rclone-manager-bootstrap.XXXXXXXX)"

    archive="${TEMP_DIR}/${PROJECT}-${version}.tar.gz"
    sums="${TEMP_DIR}/SHA256SUMS"
    extract_dir="${TEMP_DIR}/package"

    log "Latest release: ${version}"
    log "Downloading release package..."

    download \
        "https://github.com/${REPOSITORY}/releases/download/v${version}/${PROJECT}-${version}.tar.gz" \
        "$archive"

    download \
        "https://github.com/${REPOSITORY}/releases/download/v${version}/SHA256SUMS" \
        "$sums"

    verify_checksum \
        "$version" \
        "$archive" \
        "$sums"

    mkdir -p "$extract_dir"

    tar -xzf "$archive" -C "$extract_dir"

    package_root="$(find_package_root "$extract_dir")" ||
        die "Invalid release package."

    [[ -f "${package_root}/scripts/install.sh" ]] ||
        die "Package installer not found."

    log "Starting package installer..."

    VERSION="$version" \
    RCLONE_MANAGER_REPO="$REPOSITORY" \
        bash "${package_root}/scripts/install.sh"
}

main "$@"
