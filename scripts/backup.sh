#!/usr/bin/env bash
# backup.sh – compressed backups with checksum, rotation and verification.
# Works on Linux and macOS.
#
#   backup.sh -n etc -d /backups /etc            # back up /etc, keep 7
#   backup.sh -n home -k 14 -d /backups /home    # keep 14 versions
#   backup.sh --verify -d /backups               # check all checksums
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

NAME="backup"
DEST=""
KEEP=7
VERIFY=false
SOURCES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") -d DEST [-n NAME] [-k KEEP] SOURCE...
       $(basename "$0") --verify -d DEST

  -d DIR     destination directory
  -n NAME    backup name prefix (default: $NAME)
  -k N       number of backups to keep for this name (default: $KEEP)
  --verify   verify the SHA-256 checksum of every backup in DEST
  -h         show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -d) DEST=${2:?missing value}; shift ;;
    -n) NAME=${2:?missing value}; shift ;;
    -k) KEEP=${2:?missing value}; shift ;;
    --verify) VERIFY=true ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 1 ;;
    *) SOURCES+=("$1") ;;
  esac
  shift
done

[[ -n $DEST ]] || { usage; exit 1; }
require_cmd tar

# --- Verify mode ---------------------------------------------------------------
if $VERIFY; then
  [[ -d $DEST ]] || die "Destination not found: $DEST"
  failed=0; checked=0
  for sum in "$DEST"/*.sha256; do
    [[ -e $sum ]] || continue
    ((++checked))
    if (cd "$DEST" && sha256_cmd -c "$(basename "$sum")" >/dev/null 2>&1); then
      log_ok "$(basename "${sum%.sha256}")"
    else
      log_error "Checksum mismatch: $(basename "${sum%.sha256}")"; ((++failed))
    fi
  done
  (( checked > 0 )) || die "No backups found in $DEST"
  (( failed == 0 )) || exit 1
  exit 0
fi

# --- Backup mode -----------------------------------------------------------------
(( ${#SOURCES[@]} > 0 )) || { usage; exit 1; }
[[ $KEEP =~ ^[1-9][0-9]*$ ]] || die "-k must be a positive number"
[[ $NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid name: $NAME"
for src in "${SOURCES[@]}"; do [[ -e $src ]] || die "Source not found: $src"; done
mkdir -p "$DEST"

# Lock (portable: mkdir is atomic) – prevents two runs at the same time, e.g. from cron.
LOCK="$DEST/.$NAME.lock"
mkdir "$LOCK" 2>/dev/null || die "Another backup '$NAME' is running (lock: $LOCK)"
trap 'rm -rf "$LOCK"' EXIT

ARCHIVE="$NAME-$(timestamp).tar.gz"
log_info "Creating $DEST/$ARCHIVE from: ${SOURCES[*]}"
start=$SECONDS
tar -czf "$DEST/$ARCHIVE" "${SOURCES[@]}" 2> >(grep -v "Removing leading" >&2)
(cd "$DEST" && sha256_cmd "$ARCHIVE" > "$ARCHIVE.sha256")
size=$(du -h "$DEST/$ARCHIVE" | cut -f1)
log_ok "Backup done: $ARCHIVE ($size, $((SECONDS - start)) s)"

# Rotation: keep only the newest $KEEP archives of this name.
# Names contain a sortable timestamp, so alphabetical order = chronological order.
# (Written without mapfile / "head -n -N" so it also runs on macOS' bash 3.2.)
total=$(find "$DEST" -maxdepth 1 -name "$NAME-*.tar.gz" | wc -l | tr -d ' ')
remove=$(( total - KEEP ))
if (( remove > 0 )); then
  find "$DEST" -maxdepth 1 -name "$NAME-*.tar.gz" | sort | head -n "$remove" |
    while read -r f; do
      rm -f "$f" "$f.sha256"
      log_info "Rotated out: $(basename "$f")"
    done
fi
