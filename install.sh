#!/usr/bin/env bash
set -Eeuo pipefail
readonly REPOSITORY="jejusee/rclone-manager"
readonly PROJECT="rclone-manager"
TEMP_DIR=""
cleanup(){ [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]] && rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT
log(){ printf '[rclone-manager] %s\n' "$*"; }
error(){ printf '[rclone-manager] ERROR: %s\n' "$*" >&2; }
die(){ error "$*"; exit 1; }
find_command(){ command -v "$1" 2>/dev/null || return 1; }
download(){ local url="$1" out="$2"; if find_command curl >/dev/null; then curl -fL --silent --show-error --retry 3 --connect-timeout 15 -o "$out" "$url"; elif find_command wget >/dev/null; then wget -q --tries=3 --timeout=15 -O "$out" "$url"; else die "curl or wget is required."; fi; }
normalize_version(){ local v="${1#v}"; [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die "Invalid version: $v"; printf '%s\n' "$v"; }
latest_version(){ local effective; if find_command curl >/dev/null; then effective="$(curl -fL --silent --show-error -o /dev/null -w '%{url_effective}' "https://github.com/${REPOSITORY}/releases/latest")"; else effective="$(wget --server-response --max-redirect=10 -O /dev/null "https://github.com/${REPOSITORY}/releases/latest" 2>&1 | awk '/^  Location:/ {x=$2} END {gsub(/\r/,"",x); print x}')"; fi; normalize_version "${effective##*/}"; }
verify(){ local version="$1" archive="$2" sums="$3" filename="${PROJECT}-${version}.tar.gz" expected actual; expected="$(awk -v f="$filename" '$2 == f || $2 == "*"f {print $1; exit}' "$sums")"; [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || die "Checksum entry not found."; if find_command sha256sum >/dev/null; then actual="$(sha256sum "$archive" | awk '{print $1}')"; elif find_command shasum >/dev/null; then actual="$(shasum -a 256 "$archive" | awk '{print $1}')"; else die "sha256sum or shasum is required."; fi; [[ "${actual,,}" == "${expected,,}" ]] || die "Checksum verification failed."; }
find_root(){ local d="$1" c; [[ -f "$d/install.sh" && -f "$d/VERSION" ]] && { printf '%s\n' "$d"; return; }; for c in "$d"/*; do [[ -d "$c" && -f "$c/install.sh" && -f "$c/VERSION" ]] && { printf '%s\n' "$c"; return; }; done; return 1; }
main(){
    [[ "$(uname -s)" == Linux ]] || die "Only Linux is supported."
    [[ "$EUID" -eq 0 ]] || die "Run this installer as root."
    find_command tar >/dev/null || die "tar is required."
    (( $# <= 1 )) || die "Usage: install.sh [version]"
    local version="${1:-${VERSION:-}}" archive sums extract root
    [[ -n "$version" ]] && version="$(normalize_version "$version")" || version="$(latest_version)"
    TEMP_DIR="$(mktemp -d -t rclone-manager-bootstrap.XXXXXXXX)"; archive="${TEMP_DIR}/${PROJECT}-${version}.tar.gz"; sums="${TEMP_DIR}/SHA256SUMS"; extract="${TEMP_DIR}/package"
    log "Installing version: $version"
    download "https://github.com/${REPOSITORY}/releases/download/v${version}/${PROJECT}-${version}.tar.gz" "$archive"
    download "https://github.com/${REPOSITORY}/releases/download/v${version}/SHA256SUMS" "$sums"
    verify "$version" "$archive" "$sums"
    mkdir -p "$extract"; tar -xzf "$archive" -C "$extract"; root="$(find_root "$extract")" || die "Invalid release package."
    [[ "$(head -n1 "$root/VERSION")" == "$version" ]] || die "Package version mismatch."
    bash "$root/install.sh"
}
main "$@"
