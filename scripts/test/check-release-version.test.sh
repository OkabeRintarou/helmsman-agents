#!/bin/sh
# Tests for scripts/check-release-version.sh. Run: sh scripts/test/check-release-version.test.sh
set -eu

script=$(cd "$(dirname "$0")/.." && pwd)/check-release-version.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
failures=0

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# check NAME EXPECTED_STATUS EXPECTED_STDOUT VERSION_CONTENT TAG
check() {
  name=$1 want_status=$2 want_out=$3
  printf '%s' "$4" >"$tmp/VERSION"
  status=0
  out=$(sh "$script" "$5" "$tmp/VERSION" 2>"$tmp/err") || status=$?

  if [ "$status" = "$want_status" ] && [ "$out" = "$want_out" ]; then
    pass "$name"
  else
    fail "$name: status $status (want $want_status), stdout '$out' (want '$want_out'), stderr: $(cat "$tmp/err")"
  fi
}

check "matching tag" 0 "0.11.0" "0.11.0
" v0.11.0
check "whitespace around VERSION" 0 "0.11.0" " 0.11.0
" v0.11.0
check "prerelease" 0 "0.12.0-rc.1" "0.12.0-rc.1" v0.12.0-rc.1
check "tag ahead of VERSION" 1 "" "0.11.0" v0.12.0
check "tag without v" 1 "" "0.11.0" 0.11.0
check "tag with suffix" 1 "" "0.11.0" v0.11.0.1
check "empty VERSION" 1 "" "" v
check "invalid VERSION" 1 "" "0.11.0;id" "v0.11.0;id"

printf '0.11.0\n' >"$tmp/VERSION"
sh "$script" v0.12.0 "$tmp/VERSION" >/dev/null 2>"$tmp/err" || true
if grep -q "tag v0.12.0 does not match VERSION 0.11.0" "$tmp/err"; then
  pass "mismatch message"
else
  fail "mismatch message: $(cat "$tmp/err")"
fi

status=0
sh "$script" v0.11.0 "$tmp/missing" >/dev/null 2>&1 || status=$?
if [ "$status" = 1 ]; then pass "missing VERSION file"; else fail "missing VERSION file: status $status"; fi

status=0
sh "$script" >/dev/null 2>&1 || status=$?
if [ "$status" = 2 ]; then pass "usage"; else fail "usage: status $status"; fi

status=0
out=$(sh "$script" "v$(tr -d ' \t\r\n' <"$(dirname "$script")/../VERSION")") || status=$?
if [ "$status" = 0 ] && [ -n "$out" ]; then pass "repository VERSION by default"; else
  fail "repository VERSION by default: status $status"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
