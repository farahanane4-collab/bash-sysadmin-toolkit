#!/usr/bin/env bash
# lib/common.sh – shared helpers for all scripts in this toolkit.
# Source it with:  source "$(dirname "$0")/../lib/common.sh"

# Colors only when writing to a terminal (keeps log files and pipes clean).
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi
export RED GREEN YELLOW BLUE BOLD RESET

log_info()  { printf '%s[INFO]%s  %s\n' "$BLUE"   "$RESET" "$*"; }
log_ok()    { printf '%s[OK]%s    %s\n' "$GREEN"  "$RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n' "$YELLOW" "$RESET" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED"    "$RESET" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# Abort unless the script runs as root.
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This action needs root privileges (try: sudo $0 ...)"
}

# Abort if a required command is missing.
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

# Prints "linux", "macos" or "unknown".
os_type() {
  case "$(uname -s)" in
    Linux)  echo linux ;;
    Darwin) echo macos ;;
    *)      echo unknown ;;
  esac
}

# Portable SHA-256 (Linux: sha256sum, macOS: shasum -a 256).
sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

timestamp() { date '+%Y%m%d-%H%M%S'; }
