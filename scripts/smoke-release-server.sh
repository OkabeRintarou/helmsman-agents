#!/bin/sh
# Usage: smoke-release-server.sh BASE_URL TARGET [LOCAL_BINARY]
#
# Smoke test of a running release image: waits until BASE_URL/readyz is 200
# (at most SMOKE_TIMEOUT seconds, default 120) and reports VERSION, checks
# /healthz and /install.sh, downloads the TARGET daemon binary with its .sha256
# and verifies the checksum. With LOCAL_BINARY, the download must also be
# byte-identical to it.
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 BASE_URL TARGET [LOCAL_BINARY]" >&2
  exit 2
fi

base_url=${1%/}
target=$2
local_binary=${3:-}
timeout=${SMOKE_TIMEOUT:-120}
version=$(tr -d ' \t\r\n' <"$(dirname "$0")/../VERSION")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
  echo "smoke: $*" >&2
  exit 1
}

elapsed=0
until status=$(curl -s -o "$tmp/readyz" -w '%{http_code}' "$base_url/readyz") &&
  [ "$status" = 200 ]; do
  if [ "$elapsed" -ge "$timeout" ]; then
    fail "/readyz not ready after ${timeout}s (last status ${status:-none})"
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done
echo "smoke: /readyz 200 after ~${elapsed}s: $(cat "$tmp/readyz")"

grep -qF "\"version\":\"$version\"" "$tmp/readyz" || fail "/readyz does not report version $version"

curl -fsS -o /dev/null "$base_url/healthz" || fail "/healthz failed"

curl -fsS -o "$tmp/install.sh" "$base_url/install.sh" || fail "/install.sh failed"
sh -n "$tmp/install.sh" || fail "/install.sh is not valid sh"
grep -qF "$version" "$tmp/install.sh" || fail "/install.sh does not embed version $version"
echo "smoke: /install.sh ok"

binary="helmsman-$target"
curl -fsS -o "$tmp/$binary" "$base_url/downloads/daemon/$target" || fail "download of $binary failed"
curl -fsS -o "$tmp/$binary.sha256" "$base_url/downloads/daemon/$target.sha256" ||
  fail "download of $binary.sha256 failed"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$tmp" && sha256sum -c "$binary.sha256" >/dev/null) || fail "$binary does not match its checksum"
else
  (cd "$tmp" && shasum -a 256 -c "$binary.sha256" >/dev/null) || fail "$binary does not match its checksum"
fi
echo "smoke: $binary matches $binary.sha256"

if [ -n "$local_binary" ]; then
  cmp -s "$tmp/$binary" "$local_binary" || fail "downloaded $binary differs from $local_binary"
  echo "smoke: $binary is identical to the built binary"
fi
