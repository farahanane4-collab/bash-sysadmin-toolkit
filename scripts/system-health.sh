#!/usr/bin/env bash
# system-health.sh – quick health report for CPU load, memory and disks.
# Works on Linux and macOS. Exit codes follow the Nagios/Icinga convention,
# so the script can be used directly as a monitoring check:
#   0 = OK, 1 = WARNING, 2 = CRITICAL, 3 = UNKNOWN
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

WARN=80
CRIT=90
QUIET=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [-w WARN%] [-c CRIT%] [-q] [-h]

  -w  warning threshold in percent  (default: $WARN)
  -c  critical threshold in percent (default: $CRIT)
  -q  quiet: print only one status line (for cron / monitoring)
  -h  show this help
EOF
}

while getopts ":w:c:qh" opt; do
  case $opt in
    w) WARN=$OPTARG ;;
    c) CRIT=$OPTARG ;;
    q) QUIET=true ;;
    h) usage; exit 0 ;;
    *) usage; exit 3 ;;
  esac
done

[[ $WARN =~ ^[0-9]+$ && $CRIT =~ ^[0-9]+$ ]] || { log_error "Thresholds must be integers"; exit 3; }
(( WARN < CRIT )) || { log_error "WARN must be lower than CRIT"; exit 3; }

OS=$(os_type)
STATUS=0           # worst status seen so far
SUMMARY=()

# Records a metric, prints it and raises the global status if needed.
check() {
  local name=$1 value=$2 level="OK" color=$GREEN
  if (( value >= CRIT )); then
    level="CRITICAL"; color=$RED; (( STATUS < 2 )) && STATUS=2
  elif (( value >= WARN )); then
    level="WARNING"; color=$YELLOW; (( STATUS < 1 )) && STATUS=1
  fi
  SUMMARY+=("$name=${value}%")
  $QUIET || printf '  %-28s %4s%%   %s%s%s\n' "$name" "$value" "$color" "$level" "$RESET"
}

# --- CPU load (1-minute load average relative to the number of cores) -------
cpu_load_percent() {
  local load cores
  if [[ $OS == linux ]]; then
    load=$(cut -d' ' -f1 /proc/loadavg)
    cores=$(nproc)
  else
    load=$(sysctl -n vm.loadavg | awk '{print $2}')
    cores=$(sysctl -n hw.ncpu)
  fi
  awk -v l="$load" -v c="$cores" 'BEGIN { printf "%d", (l / c) * 100 }'
}

# --- Memory usage -------------------------------------------------------------
mem_used_percent() {
  if [[ $OS == linux ]]; then
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2}
         END { printf "%d", (t - a) * 100 / t }' /proc/meminfo
  else
    local page total
    page=$(sysctl -n hw.pagesize)
    total=$(sysctl -n hw.memsize)
    vm_stat | awk -v p="$page" -v t="$total" '
      /Pages free/        {gsub("\\.","",$3); f+=$3}
      /Pages inactive/    {gsub("\\.","",$3); f+=$3}
      /Pages speculative/ {gsub("\\.","",$3); f+=$3}
      END { printf "%d", 100 - (f * p * 100 / t) }'
  fi
}

[[ $OS == unknown ]] && { log_error "Unsupported OS: $(uname -s)"; exit 3; }

$QUIET || {
  printf '%sSystem health – %s (%s) – %s%s\n' "$BOLD" "$(hostname)" "$OS" "$(date '+%F %T')" "$RESET"
  printf '  Uptime: %s\n\n' "$(uptime | sed 's/^ *//')"
}

check "CPU load (1 min)" "$(cpu_load_percent)"
check "Memory used" "$(mem_used_percent)"

# --- Disks: every real filesystem (lines starting with /dev/) ----------------
while read -r _ _ _ _ use mount; do
  check "Disk $mount" "${use%\%}"
done < <(df -P | awk 'NR > 1 && $1 ~ "^/dev/"')

# --- Top memory consumers (helps to find the cause of a warning) ------------
if ! $QUIET; then
  printf '\n  Top 5 processes by memory:\n'
  ps -A -o pid=,%mem=,comm= | sort -k2 -nr | head -5 |
    awk '{ printf "    PID %-7s %5s%%  %s\n", $1, $2, $3 }'
  echo
fi

case $STATUS in
  0) echo "OK - ${SUMMARY[*]}" ;;
  1) echo "WARNING - ${SUMMARY[*]}" ;;
  2) echo "CRITICAL - ${SUMMARY[*]}" ;;
esac
exit "$STATUS"
