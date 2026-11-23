#!/usr/bin/env bash
# user-audit.sh – audit of local user accounts on a Linux system.
# Reports: human accounts, admin rights, extra UID-0 accounts, empty or locked
# passwords, last login and home-directory permissions.
# Read-only: the script never changes anything.
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

CSV=false
MIN_UID=1000

usage() {
  cat <<EOF
Usage: $(basename "$0") [--csv] [--min-uid N] [-h]

  --csv        output as CSV (e.g. for Excel or a ticket attachment)
  --min-uid N  lowest UID treated as a human account (default: $MIN_UID)
  -h, --help   show this help

Run as root to also check password status (/etc/shadow).
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --csv) CSV=true ;;
    --min-uid) MIN_UID=${2:?missing value}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  shift
done

[[ $(os_type) == linux ]] || die "user-audit.sh supports Linux only"
require_cmd getent awk stat

IS_ROOT=false
[[ $(id -u) -eq 0 ]] && IS_ROOT=true

# Members of the usual admin groups (Debian/Ubuntu: sudo, RHEL/Fedora: wheel).
ADMINS=" "
for grp in sudo wheel admin; do
  members=$(getent group "$grp" | cut -d: -f4 | tr ',' ' ') || true
  ADMINS+="$members "
done

password_status() {
  local user=$1 hash
  $IS_ROOT || { echo "n/a"; return; }
  hash=$(getent shadow "$user" | cut -d: -f2)
  case $hash in
    "")      echo "EMPTY" ;;
    '!'*|'*'*) echo "locked" ;;
    *)       echo "set" ;;
  esac
}

last_login() {
  local user=$1 out
  if command -v lastlog >/dev/null 2>&1; then
    out=$(lastlog -u "$user" 2>/dev/null | awk 'NR==2')
    [[ $out == *"Never logged in"* || -z $out ]] && { echo "never"; return; }
    echo "$out" | awk '{print $(NF-5), $(NF-4), $(NF-3), $NF}'
  elif command -v last >/dev/null 2>&1; then
    out=$(last -n 1 "$user" 2>/dev/null | awk 'NR==1 && $1 != "" && $1 != "wtmp" {print $4, $5, $6, $7}')
    echo "${out:-never}"
  else
    echo "n/a"
  fi
}

ISSUES=0

if $CSV; then
  echo "user,uid,shell,admin,password,last_login,home,home_perms,remarks"
else
  printf '%sUser audit – %s – %s%s\n\n' "$BOLD" "$(hostname)" "$(date '+%F %T')" "$RESET"
  printf '%-14s %-6s %-6s %-8s %-22s %-6s %s\n' USER UID ADMIN PASSWORD "LAST LOGIN" PERMS REMARKS
fi

while IFS=: read -r user _ uid _ _ home shell; do
  # Extra UID 0 accounts are always reported – a classic backdoor.
  if (( uid == 0 )) && [[ $user != root ]]; then
    log_warn "Account '$user' has UID 0 (root rights)!"; ((ISSUES++)) || true
  fi
  (( uid >= MIN_UID && uid != 65534 )) || continue
  [[ $shell == */nologin || $shell == */false ]] && continue

  admin="no"; [[ $ADMINS == *" $user "* ]] && admin="YES"
  pw=$(password_status "$user")
  login=$(last_login "$user")
  perms="-"; remarks=""
  if [[ -d $home ]]; then
    perms=$(stat -c '%a' "$home")
    # "others" may read or write the home directory?
    (( ${perms: -1} & 6 )) && remarks+="home readable by others; "
  else
    remarks+="home missing; "
  fi
  [[ $pw == EMPTY ]] && remarks+="EMPTY PASSWORD; "
  if [[ -n $remarks ]]; then ((++ISSUES)); fi

  if $CSV; then
    printf '%s,%s,%s,%s,%s,"%s",%s,%s,"%s"\n' "$user" "$uid" "$shell" "$admin" "$pw" "$login" "$home" "$perms" "$remarks"
  else
    printf '%-14s %-6s %-6s %-8s %-22s %-6s %s\n' "$user" "$uid" "$admin" "$pw" "$login" "$perms" "$remarks"
  fi
done < <(getent passwd)

if ! $CSV; then
  echo
  $IS_ROOT || log_warn "Not running as root: password status not checked."
  if (( ISSUES == 0 )); then log_ok "No issues found."; else log_warn "$ISSUES issue(s) found."; fi
fi
