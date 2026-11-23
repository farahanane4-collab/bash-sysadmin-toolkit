#!/usr/bin/env bash
# bulk-users.sh – create, lock or remove many Linux user accounts from a CSV file.
# Typical use: onboarding/offboarding of a whole group (e.g. new students).
#
# CSV format (header line required):
#   username,full_name,groups,action
#   mmuster,Max Mustermann,developers;docker,create
#
# Safety first: runs in DRY-RUN mode by default and only prints what it
# would do. Use --apply to really change the system.
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

APPLY=false
CSV_FILE=""
ARCHIVE_DIR="/var/backups/user-homes"
CRED_FILE="/root/new-user-credentials-$(timestamp).txt"
MIN_UID=1000

usage() {
  cat <<EOF
Usage: $(basename "$0") [--apply] [--archive-dir DIR] FILE.csv

  --apply           really execute the changes (default: dry run)
  --archive-dir D   where home directories are archived before deletion
                    (default: $ARCHIVE_DIR)
  -h, --help        show this help

Actions per line: create | lock | delete
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --apply) APPLY=true ;;
    --archive-dir) ARCHIVE_DIR=${2:?missing value}; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 1 ;;
    *) CSV_FILE=$1 ;;
  esac
  shift
done

[[ -n $CSV_FILE ]] || { usage; exit 1; }
[[ -r $CSV_FILE ]] || die "Cannot read file: $CSV_FILE"
[[ $(os_type) == linux ]] || die "bulk-users.sh supports Linux only"

if $APPLY; then
  require_root
  require_cmd useradd usermod userdel chpasswd chage openssl tar
  log_warn "APPLY mode – the system will be changed."
else
  log_info "DRY RUN – nothing will be changed. Use --apply to execute."
fi

# Prints the command in dry-run mode, executes it in apply mode.
run() {
  if $APPLY; then "$@"; else printf '    would run: %s\n' "$*"; fi
}

valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

# Never touch system accounts or root, even if they appear in the CSV.
is_protected() {
  local uid
  uid=$(id -u "$1" 2>/dev/null) || return 1
  (( uid < MIN_UID ))
}

create_user() {
  local user=$1 name=$2 groups=$3 password
  if id "$user" >/dev/null 2>&1; then log_warn "$user already exists – skipped"; return; fi
  local group_opt=()
  if [[ -n $groups ]]; then
    local g
    for g in ${groups//;/ }; do
      getent group "$g" >/dev/null || run groupadd "$g"
    done
    group_opt=(-G "${groups//;/,}")
  fi
  run useradd -m -s /bin/bash -c "$name" "${group_opt[@]}" "$user"
  if $APPLY; then
    password=$(openssl rand -base64 12)
    echo "$user:$password" | chpasswd
    chage -d 0 "$user"            # force password change at first login
    ( umask 077; echo "$user  $password" >> "$CRED_FILE" )
  else
    echo "    would set a random initial password (change forced at first login)"
  fi
  log_ok "create $user"
}

lock_user() {
  local user=$1
  id "$user" >/dev/null 2>&1 || { log_warn "$user does not exist – skipped"; return; }
  run usermod -L "$user"          # lock the password
  run chage -E 0 "$user"          # expire the account (blocks SSH keys too)
  log_ok "lock $user"
}

delete_user() {
  local user=$1 home
  id "$user" >/dev/null 2>&1 || { log_warn "$user does not exist – skipped"; return; }
  home=$(getent passwd "$user" | cut -d: -f6)
  run mkdir -p "$ARCHIVE_DIR"
  [[ -d $home ]] && run tar -czf "$ARCHIVE_DIR/$user-$(timestamp).tar.gz" -C "$(dirname "$home")" "$(basename "$home")"
  run userdel -r "$user"
  log_ok "delete $user (home archived)"
}

line_no=0; errors=0
while IFS=, read -r user name groups action || [[ -n $user ]]; do
  ((++line_no))
  (( line_no == 1 )) && continue                 # skip header
  [[ -z $user || $user == \#* ]] && continue     # skip empty lines / comments
  action=${action//$'\r'/}                       # tolerate Windows line endings

  if ! valid_username "$user"; then
    log_error "line $line_no: invalid username '$user'"; ((++errors)); continue
  fi
  if is_protected "$user"; then
    log_error "line $line_no: '$user' is a system account – refused"; ((++errors)); continue
  fi

  case $action in
    create) create_user "$user" "$name" "$groups" ;;
    lock)   lock_user "$user" ;;
    delete) delete_user "$user" ;;
    *) log_error "line $line_no: unknown action '$action'"; ((++errors)) ;;
  esac
done < "$CSV_FILE"

$APPLY && [[ -f $CRED_FILE ]] && log_info "Initial passwords saved to $CRED_FILE (root only)"
(( errors == 0 )) || { log_error "$errors line(s) with errors"; exit 1; }
