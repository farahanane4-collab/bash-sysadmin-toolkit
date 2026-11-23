#!/usr/bin/env bash
# ssh-login-report.sh – summarises failed and successful SSH logins.
# Detects brute-force attempts: IPs with more failures than a threshold.
# Log source: journalctl, /var/log/auth.log (Debian/Ubuntu) or /var/log/secure (RHEL),
# or any file given with -f.
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

LOGFILE=""
SINCE="24 hours ago"
THRESHOLD=5
TOP=10

usage() {
  cat <<EOF
Usage: $(basename "$0") [-f LOGFILE] [-s SINCE] [-t THRESHOLD] [-n TOP]

  -f FILE   read this log file instead of the system log
  -s SINCE  time range for journalctl (default: "$SINCE")
  -t N      flag IPs with at least N failed logins (default: $THRESHOLD)
  -n N      show the top N entries (default: $TOP)
EOF
}

while getopts ":f:s:t:n:h" opt; do
  case $opt in
    f) LOGFILE=$OPTARG ;;
    s) SINCE=$OPTARG ;;
    t) THRESHOLD=$OPTARG ;;
    n) TOP=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# Writes the SSH log lines to stdout, from the best available source.
read_log() {
  if [[ -n $LOGFILE ]]; then
    [[ -r $LOGFILE ]] || die "Cannot read $LOGFILE"
    grep -E 'sshd(\[[0-9]+\])?:' "$LOGFILE" || true
  elif command -v journalctl >/dev/null 2>&1 && journalctl -q -n 1 >/dev/null 2>&1; then
    journalctl -q --no-pager -u ssh -u sshd --since "$SINCE" 2>/dev/null || true
  elif [[ -r /var/log/auth.log ]]; then
    grep sshd /var/log/auth.log || true
  elif [[ -r /var/log/secure ]]; then
    grep sshd /var/log/secure || true
  else
    die "No readable SSH log found (try sudo, or -f FILE)"
  fi
}

LOG=$(read_log)

# "Failed password for invalid user bob from 1.2.3.4 port 22 ssh2"
# "Failed password for alice from 1.2.3.4 port 22 ssh2"
failed=$(grep -E 'Failed (password|publickey)' <<<"$LOG" \
  | sed -E 's/.*Failed [a-z]+ for (invalid user )?([^ ]+) from ([0-9a-fA-F:.]+).*/\2 \3/' || true)
accepted=$(grep -E 'Accepted (password|publickey)' <<<"$LOG" \
  | sed -E 's/.*Accepted ([a-z]+) for ([^ ]+) from ([0-9a-fA-F:.]+).*/\2 \3 \1/' || true)

count_lines() {
  if [[ -z $1 ]]; then echo 0; else wc -l <<<"$1" | tr -d ' '; fi
}
n_failed=$(count_lines "$failed")
n_ok=$(count_lines "$accepted")

printf '%sSSH login report – %s%s\n' "$BOLD" "${LOGFILE:-system log, since $SINCE}" "$RESET"
printf '  Failed logins:     %s\n  Successful logins: %s\n' "$n_failed" "$n_ok"

if (( n_failed > 0 )); then
  printf '\n%sTop source IPs (failed)%s\n' "$BOLD" "$RESET"
  awk '{print $2}' <<<"$failed" | sort | uniq -c | sort -rn | head -n "$TOP" |
    while read -r count ip; do
      flag=""; (( count >= THRESHOLD )) && flag="${RED}← possible brute force${RESET}"
      printf '  %5d  %-40s %s\n' "$count" "$ip" "$flag"
    done

  printf '\n%sMost targeted usernames%s\n' "$BOLD" "$RESET"
  awk '{print $1}' <<<"$failed" | sort | uniq -c | sort -rn | head -n "$TOP" |
    awk '{printf "  %5d  %s\n", $1, $2}'
fi

if (( n_ok > 0 )); then
  printf '\n%sSuccessful logins (user / IP / method)%s\n' "$BOLD" "$RESET"
  sort <<<"$accepted" | uniq -c | sort -rn | head -n "$TOP" |
    awk '{printf "  %5d  %-12s %-40s %s\n", $1, $2, $3, $4}'
fi

suspects=$(awk '{print $2}' <<<"$failed" | sort | uniq -c | awk -v t="$THRESHOLD" '$1 >= t' | wc -l | tr -d ' ')
echo
if (( suspects > 0 )); then
  log_warn "$suspects IP(s) reached the threshold of $THRESHOLD failed logins – consider fail2ban or a firewall rule."
  exit 1
fi
log_ok "No IP above the threshold of $THRESHOLD failed logins."
