#!/usr/bin/env bash
# run-tests.sh – lint + functional tests for the toolkit.
# Runs without root and without changing the system (uses a temp directory).
set -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

passed=0; failed=0
ok()   { printf '  \e[32m✔\e[0m %s\n' "$*"; ((++passed)); }
nok()  { printf '  \e[31m✘\e[0m %s\n' "$*"; ((++failed)); }
assert() { local desc=$1; shift; if "$@"; then ok "$desc"; else nok "$desc"; fi; }

echo "== Syntax & ShellCheck"
for f in "$ROOT"/scripts/*.sh "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do
  assert "bash -n $(basename "$f")" bash -n "$f"
done
if command -v shellcheck >/dev/null 2>&1; then
  assert "shellcheck (all scripts)" bash -c "cd '$ROOT' && shellcheck -x scripts/*.sh lib/*.sh tests/*.sh"
else
  echo "  (shellcheck not installed – skipped)"
fi

echo "== system-health.sh"
"$ROOT/scripts/system-health.sh" -q >"$TMP/health" ; rc=$?
assert "exit code is 0, 1 or 2 (got $rc)" test "$rc" -le 2
assert "status line starts with OK/WARNING/CRITICAL" grep -Eq '^(OK|WARNING|CRITICAL) - ' "$TMP/health"
"$ROOT/scripts/system-health.sh" -w 95 -c 90 >/dev/null 2>&1; rc=$?
assert "rejects WARN >= CRIT (exit 3)" test "$rc" -eq 3

echo "== ssh-login-report.sh (fixture)"
"$ROOT/scripts/ssh-login-report.sh" -f "$ROOT/tests/fixtures/auth.log" -t 5 >"$TMP/ssh" 2>&1; rc=$?
assert "counts 9 failed logins"      grep -q "Failed logins:     9" "$TMP/ssh"
assert "counts 3 successful logins"  grep -q "Successful logins: 3" "$TMP/ssh"
assert "flags 203.0.113.7 (6 fails)" grep -Eq "6  203\.0\.113\.7 .*brute force" "$TMP/ssh"
assert "exit 1 when an IP is above threshold" test "$rc" -eq 1
"$ROOT/scripts/ssh-login-report.sh" -f "$ROOT/tests/fixtures/auth.log" -t 50 >/dev/null 2>&1
assert "exit 0 with high threshold" test $? -eq 0

echo "== backup.sh"
mkdir -p "$TMP/src/sub" && echo "hello" >"$TMP/src/sub/file.txt"
for _ in 1 2 3; do
  "$ROOT/scripts/backup.sh" -n test -k 2 -d "$TMP/dest" "$TMP/src" >/dev/null 2>&1
  sleep 1   # different timestamps
done
n=$(find "$TMP/dest" -name 'test-*.tar.gz' | wc -l | tr -d ' ')
assert "rotation keeps exactly 2 archives (found $n)" test "$n" -eq 2
assert "verify succeeds on intact backups" "$ROOT/scripts/backup.sh" --verify -d "$TMP/dest"
first=$(find "$TMP/dest" -name 'test-*.tar.gz' | sort | head -1)
assert "archive contains the file" bash -c "tar -tzf '$first' | grep -q 'sub/file.txt'"
echo "corrupt" >>"$first"
"$ROOT/scripts/backup.sh" --verify -d "$TMP/dest" >/dev/null 2>&1
assert "verify detects a corrupted archive" test $? -eq 1

if [[ $(uname -s) == Linux ]]; then
  echo "== bulk-users.sh (dry run)"
  "$ROOT/scripts/bulk-users.sh" "$ROOT/examples/users.csv" >"$TMP/bulk" 2>&1; rc=$?
  assert "dry run succeeds on example CSV" test "$rc" -eq 0
  assert "dry run prints planned useradd" grep -q "would run: useradd" "$TMP/bulk"
  printf 'username,full_name,groups,action\nBad User!,x,,create\nroot,Root,,delete\n' >"$TMP/bad.csv"
  "$ROOT/scripts/bulk-users.sh" "$TMP/bad.csv" >"$TMP/bad" 2>&1; rc=$?
  assert "rejects invalid username" grep -q "invalid username" "$TMP/bad"
  assert "refuses to touch root"   grep -q "system account" "$TMP/bad"
  assert "exit 1 on invalid lines" test "$rc" -eq 1

  echo "== user-audit.sh / security-check.sh (smoke test)"
  assert "user-audit runs" bash -c "'$ROOT/scripts/user-audit.sh' >/dev/null 2>&1"
  assert "user-audit CSV header" bash -c "'$ROOT/scripts/user-audit.sh' --csv 2>/dev/null | head -1 | grep -q '^user,uid'"
  "$ROOT/scripts/security-check.sh" >"$TMP/sec" 2>&1
  assert "security-check prints a score" grep -q "score" "$TMP/sec"
fi

echo
echo "Result: $passed passed, $failed failed"
(( failed == 0 ))
