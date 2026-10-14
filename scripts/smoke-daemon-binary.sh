#!/bin/sh
# Usage: smoke-daemon-binary.sh BINARY TARGET
#
# Smoke test of a daemon binary built by build-daemon.sh, on its own platform:
#   - `--version` reports VERSION, the protocol and TARGET;
#   - `runtimes` with an empty HELMSMAN_HOME exits 0 and creates machine_id;
#   - no native file (the wrapper or anything it unpacked) has an ELF
#     interpreter under /tmp;
#   - Linux: native files only link the base glibc libraries and need at most
#     GLIBC_2.31; macOS: only system libraries and a minimum macOS of 13.0.
# Burrito unpacks under the user's data directory, so HOME and XDG_DATA_HOME
# point into a temporary directory that is removed afterwards.
#
# With SMOKE_IMAGES="debian:bullseye ubuntu:24.04" (Linux only), `--version` and
# `runtimes` also run as a non-root user in each of these container images.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 BINARY TARGET" >&2
  exit 2
fi

binary=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
target=$2
version=$(tr -d ' \t\r\n' <"$(dirname "$0")/../VERSION")
max_glibc=2.31
min_macos=13.0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
  echo "smoke: $*" >&2
  exit 1
}

# version_le A B: A <= B in version order.
version_le() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

export HOME="$tmp/home" XDG_DATA_HOME="$tmp/data" HELMSMAN_HOME="$tmp/helmsman"
unset HELMSMAN_INSTALL_DIR || true
mkdir -p "$HOME" "$XDG_DATA_HOME"

out=$("$binary" --version) || fail "--version failed: $out"
case $out in
  "helmsman $version (protocol "*", $target)") echo "smoke: $out" ;;
  *) fail "--version printed '$out', expected 'helmsman $version (protocol N, $target)'" ;;
esac

# A minimal PATH: agent CLIs installed on this machine are not probed (they
# would unpack their own native modules into the temporary HOME).
PATH=/usr/bin:/bin "$binary" runtimes >"$tmp/runtimes.log" 2>&1 || {
  cat "$tmp/runtimes.log" >&2
  fail "runtimes failed"
}
[ -s "$HELMSMAN_HOME/machine_id" ] || fail "runtimes did not create machine_id"
echo "smoke: runtimes exited 0 and created machine_id"

# The wrapper itself plus every file it unpacked (Burrito's payload: under
# XDG_DATA_HOME on Linux, ~/Library/Application Support on macOS).
payload="$tmp/data"
[ -d "$HOME/Library/Application Support/.burrito" ] && payload="$HOME/Library/Application Support/.burrito"
find "$binary" "$payload" -type f >"$tmp/files"
helper=$(find "$payload" -type f -path '*/priv/credentials_lock' | head -n 1)
[ -n "$helper" ] || fail "credential lock helper missing from payload"
# EOF releases the lock; also exercise real packaged credential read/delete.
"$helper" "$HELMSMAN_HOME/credentials.lock" </dev/null >"$tmp/lock.log" || fail "credential lock helper failed"
grep -qx locked "$tmp/lock.log" || fail "credential lock helper did not acquire the lock"
PATH=/usr/bin:/bin "$binary" logout >"$tmp/logout.log" 2>&1 || fail "credential logout failed"
grep -q 'Logged out' "$tmp/logout.log" || fail "credential logout did not finish"
echo "smoke: bundled credential lock and logout passed"
checked=0
bad=""

case $target in
  linux-*)
    while IFS= read -r file; do
      readelf -h "$file" >/dev/null 2>&1 || continue
      checked=$((checked + 1))
      name=${file#"$tmp"/}

      interp=$(readelf -l "$file" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
      case $interp in
        /tmp/* | /var/tmp/* | /dev/shm/*) bad="$bad
  $name: interpreter $interp" ;;
      esac

      needed=$(readelf -d "$file" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
      for lib in $needed; do
        case $lib in
          ld-linux*.so.* | libc.so.* | libm.so.* | libpthread.so.* | libdl.so.* | \
            librt.so.* | libstdc++.so.* | libgcc_s.so.*) ;;
          *) bad="$bad
  $name: links $lib" ;;
        esac
      done

      newest=$(readelf -V "$file" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1)
      if [ -n "$newest" ] && ! version_le "$newest" "$max_glibc"; then
        bad="$bad
  $name: needs GLIBC_$newest (at most GLIBC_$max_glibc)"
      fi
    done <"$tmp/files"
    ;;
  macos-*)
    while IFS= read -r file; do
      libs=$(otool -L "$file" 2>/dev/null) || continue
      case $libs in *"is not an object file"* | "") continue ;; esac
      checked=$((checked + 1))
      name=${file#"$tmp"/}

      for lib in $(printf '%s\n' "$libs" | tail -n +2 | awk '{print $1}'); do
        case $lib in
          /usr/lib/* | /System/Library/*) ;;
          *) bad="$bad
  $name: links $lib" ;;
        esac
      done

      minos=$(otool -l "$file" 2>/dev/null | awk '$1 == "minos" {print $2}' | sort -V | tail -n 1)
      if [ -n "$minos" ] && ! version_le "$minos" "$min_macos"; then
        bad="$bad
  $name: minimum macOS $minos (at most $min_macos)"
      fi
    done <"$tmp/files"
    ;;
  *) fail "unknown target $target" ;;
esac

[ "$checked" -gt 0 ] || fail "found no native files to check"
[ -z "$bad" ] || fail "unexpected native dependencies:$bad"
echo "smoke: $checked native files: no /tmp interpreter, only base system libraries"

case $target in
  linux-*)
    for image in ${SMOKE_IMAGES:-}; do
      docker run --rm --user 65534:65534 --network none \
        -e HOME=/tmp/smoke/home -e XDG_DATA_HOME=/tmp/smoke/data -e HELMSMAN_HOME=/tmp/smoke/helmsman \
        -v "$binary:/usr/local/bin/helmsman:ro" "$image" sh -c '
          set -eu
          mkdir -p "$HOME" "$XDG_DATA_HOME"
          helmsman --version
          helmsman runtimes >/dev/null
          helmsman logout >/dev/null
          test -s "$HELMSMAN_HOME/machine_id"
        ' >"$tmp/container.log" 2>&1 || {
        cat "$tmp/container.log" >&2
        fail "--version or runtimes failed in $image"
      }
      echo "smoke: $image: $(head -n 1 "$tmp/container.log"); runtimes exited 0"
    done
    ;;
esac
