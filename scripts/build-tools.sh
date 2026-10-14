#!/bin/sh
# Usage: build-tools.sh DIR
#
# Installs the Elixir (precompiled, `elixir` in .tool-versions) and zig 0.15.2
# that build-daemon.sh packages the daemon with, into DIR/elixir-<version> and
# DIR/zig-<version>, checking the SHA-256 values pinned below. Prints the two
# bin directories to put on PATH (Elixir's first). Existing installs are reused.
set -eu

ZIG_VERSION=0.15.2

# elixir-otp-<major>.zip from https://github.com/elixir-lang/elixir/releases (.sha256sum).
elixir_sha256() {
  case $1 in
    1.20.4-otp-28) echo ea7ff98bc1ed76c663a5d034c863c6fd37e65c9c855b6bbf6ccb2034d806673c ;;
    *) return 1 ;;
  esac
}

# https://ziglang.org/download/index.json
zig_sha256() {
  case $1 in
    x86_64-linux) echo 02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 ;;
    aarch64-linux) echo 958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f ;;
    x86_64-macos) echo 375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f ;;
    aarch64-macos) echo 3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ;;
    *) return 1 ;;
  esac
}

if [ "$#" -ne 1 ]; then
  echo "usage: $0 DIR" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$1"
dir=$(cd "$1" && pwd)
elixir=$(awk '$1 == "elixir" { print $2 }' "$root/.tool-versions")

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

fetch() {
  curl -fsSL --retry 3 -o "$2" "$1"
  actual=$(sha256_of "$2")
  if [ "$actual" != "$3" ]; then
    rm -f "$2"
    echo "build-tools.sh: SHA-256 mismatch for $1: expected $3, got $actual" >&2
    exit 1
  fi
}

case $(uname -s)-$(uname -m) in
  Linux-x86_64 | Linux-amd64) zig_platform=x86_64-linux ;;
  Linux-aarch64 | Linux-arm64) zig_platform=aarch64-linux ;;
  Darwin-x86_64) zig_platform=x86_64-macos ;;
  Darwin-arm64 | Darwin-aarch64) zig_platform=aarch64-macos ;;
  *)
    echo "build-tools.sh: unsupported build machine $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

if [ ! -x "$dir/elixir-$elixir/bin/mix" ]; then
  sha=$(elixir_sha256 "$elixir") || {
    echo "build-tools.sh: no pinned SHA-256 for Elixir $elixir; add it to elixir_sha256" >&2
    exit 1
  }
  version=${elixir%-otp-*}
  otp=${elixir##*-otp-}
  fetch "https://github.com/elixir-lang/elixir/releases/download/v$version/elixir-otp-$otp.zip" \
    "$dir/elixir.zip" "$sha"
  rm -rf "$dir/elixir-$elixir.partial"
  mkdir -p "$dir/elixir-$elixir.partial"
  unzip -q "$dir/elixir.zip" -d "$dir/elixir-$elixir.partial"
  rm -f "$dir/elixir.zip"
  rm -rf "$dir/elixir-$elixir"
  mv "$dir/elixir-$elixir.partial" "$dir/elixir-$elixir"
fi

if [ ! -x "$dir/zig-$ZIG_VERSION/zig" ]; then
  sha=$(zig_sha256 "$zig_platform")
  fetch "https://ziglang.org/download/$ZIG_VERSION/zig-$zig_platform-$ZIG_VERSION.tar.xz" \
    "$dir/zig.tar.xz" "$sha"
  rm -rf "$dir/zig-$zig_platform-$ZIG_VERSION" "$dir/zig-$ZIG_VERSION"
  tar -xJf "$dir/zig.tar.xz" -C "$dir"
  rm -f "$dir/zig.tar.xz"
  mv "$dir/zig-$zig_platform-$ZIG_VERSION" "$dir/zig-$ZIG_VERSION"
fi

echo "$dir/elixir-$elixir/bin"
echo "$dir/zig-$ZIG_VERSION"
