
# security-check.sh – basic security baseline check for a Linux server.
# Read-only: reports findings with PASS / WARN / FAIL and a final score.
# Checks: SSH config, firewall, pending updates, critical file permissions,
# extra UID-0 accounts, world-writable files and unusual SUID binaries.
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

[[ ${1:-} == -h || ${1:-} == --help ]] && {
  echo "Usage: sudo $(basename "$0")   (read-only, root recommended for full results)"; exit 0; }
[[ $(os_type) == linux ]] || die "security-check.sh supports Linux only"

PASS=0; WARN=0; FAIL=0
pass() { printf '  %s[PASS]%s %s\n' "$GREEN"  "$RESET" "$*"; ((++PASS)); }
warn() { printf '  %s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; ((++WARN)); }
fail() { printf '  %s[FAIL]%s %s\n' "$RED"    "$RESET" "$*"; ((++FAIL)); }
section() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }

printf '%sSecurity check – %s – %s%s\n' "$BOLD" "$(hostname)" "$(date '+%F %T')" "$RESET"
[[ $(id -u) -eq 0 ]] || log_warn "Not running as root – some checks will be incomplete."

# --- 1. SSH ------------------------------------------------------------------
section "SSH server"
ssh_value() {
  # Prefer the effective config (sshd -T), fall back to the config file.
  local key=$1
  if command -v sshd >/dev/null 2>&1 && sshd -T >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk -v k="$key" 'tolower($1)==tolower(k) {print $2; exit}'
  elif [[ -r /etc/ssh/sshd_config ]]; then
    awk -v k="$key" 'tolower($1)==tolower(k) {print $2; exit}' /etc/ssh/sshd_config
  fi
}
if [[ -e /etc/ssh/sshd_config ]]; then
  case $(ssh_value PermitRootLogin) in
    no) pass "Root login via SSH disabled" ;;
    prohibit-password|without-password) warn "Root login allowed with SSH key only" ;;
    *) fail "Root login via SSH allowed (PermitRootLogin)" ;;
  esac
  if [[ $(ssh_value PasswordAuthentication) == no ]]; then
    pass "SSH password authentication disabled (keys only)"
  else
    warn "SSH password authentication enabled"
  fi
else
  pass "No SSH server installed"
fi

# --- 2. Firewall ---------------------------------------------------------------
section "Firewall"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  pass "ufw firewall active"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  pass "firewalld active"
elif command -v nft >/dev/null 2>&1 && [[ -n $(nft list ruleset 2>/dev/null) ]]; then
  pass "nftables rules present"
else
  fail "No active firewall found (ufw / firewalld / nftables)"
fi

# --- 3. Updates --------------------------------------------------------------
section "Updates"
if command -v apt >/dev/null 2>&1; then
  n=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
  if (( n == 0 )); then pass "No pending package updates"; else warn "$n package update(s) pending (apt)"; fi
elif command -v dnf >/dev/null 2>&1; then
  n=$(dnf -q check-update 2>/dev/null | grep -c '^[[:alnum:]]' || true)
  if (( n == 0 )); then pass "No pending package updates"; else warn "$n package update(s) pending (dnf)"; fi
else
  warn "Unknown package manager – updates not checked"
fi

# --- 4. Accounts & critical files --------------------------------------------
section "Accounts and file permissions"
extra_root=$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd)
if [[ -z $extra_root ]]; then pass "Only 'root' has UID 0"; else fail "Other accounts with UID 0: $extra_root"; fi

check_perm() {  # file, maximum allowed octal mode
  local file=$1 max=$2 mode
  [[ -e $file ]] || return 0
  mode=$(stat -c '%a' "$file")
  if (( 8#$mode & ~8#$max )); then fail "$file has mode $mode (expected ≤ $max)"
  else pass "$file mode $mode"; fi
}
check_perm /etc/passwd 644
check_perm /etc/shadow 640
check_perm /etc/sudoers 440

if [[ $(stat -c '%A' /tmp) == *t ]]; then pass "/tmp has sticky bit"; else fail "/tmp is missing the sticky bit"; fi

# --- 5. Dangerous files --------------------------------------------------------
section "World-writable and SUID files"
ww=$(find /etc /usr/local /opt -xdev -type f -perm -0002 2>/dev/null | head -20 || true)
if [[ -z $ww ]]; then
  pass "No world-writable files in /etc, /usr/local, /opt"
else
  fail "World-writable files found:"; printf '         %s\n' "$ww"
fi

# SUID binaries outside the standard system directories are suspicious.
suid=$(find / -xdev -type f -perm -4000 2>/dev/null \
       | grep -Ev '^/(usr/)?(s)?bin/|^/usr/lib(exec)?/|^/snap/' | head -20 || true)
if [[ -z $suid ]]; then
  pass "No SUID binaries outside system directories"
else
  warn "Unusual SUID binaries:"; printf '         %s\n' "$suid"
fi

# --- Score ---------------------------------------------------------------------
total=$((PASS + WARN + FAIL))
score=$(( total > 0 ? PASS * 100 / total : 0 ))
printf '\n%sResult:%s %d PASS, %d WARN, %d FAIL  →  score %d%%\n' "$BOLD" "$RESET" "$PASS" "$WARN" "$FAIL" "$score"
(( FAIL == 0 ))
