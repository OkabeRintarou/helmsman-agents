#!/bin/sh
# Usage: build-daemon.sh TARGET OUT_DIR
#
# Builds the single-file daemon binary (Burrito) for TARGET and writes
# OUT_DIR/helmsman-TARGET and OUT_DIR/helmsman-TARGET.sha256 (sha256sum format).
# TARGET is one of linux-x64, linux-arm64, macos-x64, macos-arm64 and must be
# the platform of this machine: erlexec's port program is native code, so each
# target is built on its own runner.
#
# OTP is built from source by scripts/build-erts.sh (static OpenSSL) and is both
# the OTP running `mix release` and the ERTS inside the binary; Elixir and zig
# come from scripts/build-tools.sh. The machine's own Erlang/Elixir are unused.
#   Linux: runs inside the debian:bullseye image of daemon/build/Dockerfile as
#          the calling user (glibc 2.31 baseline); needs docker.
#   macOS: builds natively with MACOSX_DEPLOYMENT_TARGET=13.0; needs a C/C++
#          toolchain, make, perl, curl and xz.
#
# Environment:
#   HELMSMAN_BUILD_CACHE  cache root, default ${XDG_CACHE_HOME:-$HOME/.cache}/helmsman-build
#                         (erts/, tools/, mix/, home/)
#   HELMSMAN_ERTS_PREFIX  OTP prefix, default
#                         $HELMSMAN_BUILD_CACHE/erts/<target>-otp<version>-<sha256(build-erts.sh) 12>
#   HELMSMAN_BUILD_IMAGE  Linux builder image tag, default helmsman-daemon-build:local
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 TARGET OUT_DIR" >&2
  exit 2
fi

target=$1
out=$2

case $(uname -s)-$(uname -m) in
  Linux-x86_64 | Linux-amd64) host=linux-x64 ;;
  Linux-aarch64 | Linux-arm64) host=linux-arm64 ;;
  Darwin-x86_64) host=macos-x64 ;;
  Darwin-arm64 | Darwin-aarch64) host=macos-arm64 ;;
  *) host=unsupported ;;
esac

case $target in
  linux-x64 | linux-arm64 | macos-x64 | macos-arm64) ;;
  *)
    echo "unknown target $target (expected linux-x64, linux-arm64, macos-x64 or macos-arm64)" >&2
    exit 2
    ;;
esac

if [ "$target" != "$host" ]; then
  echo "target $target must be built on a $target machine (this one is $host)" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
cache=${HELMSMAN_BUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/helmsman-build}
mkdir -p "$cache"
cache=$(cd "$cache" && pwd)

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# Linux host: re-run this script inside the builder container.
if [ "${target%%-*}" = linux ] && [ "${HELMSMAN_IN_BUILDER:-}" != 1 ]; then
  image=${HELMSMAN_BUILD_IMAGE:-helmsman-daemon-build:local}
  docker build -q -t "$image" "$root/daemon/build" >/dev/null
  set -- --rm --user "$(id -u):$(id -g)" \
    -e HELMSMAN_IN_BUILDER=1 -e HELMSMAN_BUILD_CACHE=/cache -e HOME=/cache/home \
    -v "$root:/src" -v "$cache:/cache" -v "$out:/out" -w /src
  if [ -n "${HELMSMAN_ERTS_PREFIX:-}" ]; then
    mkdir -p "$HELMSMAN_ERTS_PREFIX"
    set -- "$@" -e HELMSMAN_ERTS_PREFIX=/erts -v "$(cd "$HELMSMAN_ERTS_PREFIX" && pwd):/erts"
  fi
  exec docker run "$@" "$image" sh scripts/build-daemon.sh "$target" /out
fi

case $target in
  macos-*) export MACOSX_DEPLOYMENT_TARGET=13.0 ;;
esac

otp=$(awk '$1 == "erlang" { print $2 }' "$root/.tool-versions")
erts=${HELMSMAN_ERTS_PREFIX:-$cache/erts/$target-otp$otp-$(sha256_of "$root/scripts/build-erts.sh" | cut -c 1-12)}
mkdir -p "$cache/home" "$cache/mix"

sh "$root/scripts/build-erts.sh" "$erts"
tools=$(sh "$root/scripts/build-tools.sh" "$cache/tools")
elixir_bin=$(printf '%s\n' "$tools" | sed -n 1p)
zig_dir=$(printf '%s\n' "$tools" | sed -n 2p)

export PATH="$erts/bin:$elixir_bin:$zig_dir:$PATH"
export MIX_ENV=prod MIX_HOME="$cache/mix/home" HEX_HOME="$cache/mix/hex"
export MIX_DEPS_PATH="$cache/mix/deps-$target" MIX_BUILD_ROOT="$cache/mix/build-$target"
unset MIX_BUILD_PATH || true
case $target in
  # erlexec's port program: no libstdc++ / libgcc_s requirement on the target.
  linux-*) export LDFLAGS="-static-libstdc++ -static-libgcc" ;;
esac

burrito_target=$(printf '%s' "$target" | tr - _)
binary="helmsman-$target"

cd "$root/daemon"
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get --only prod
BURRITO_TARGET=$burrito_target mix release helmsman --overwrite

cp "burrito_out/helmsman_$burrito_target" "$out/$binary"
chmod 0755 "$out/$binary"

cd "$out"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$binary" >"$binary.sha256"
else
  shasum -a 256 "$binary" >"$binary.sha256"
fi

echo "built $out/$binary"
cat "$binary.sha256"
