#!/bin/sh
# Usage: build-erts.sh PREFIX
#
# Builds the Erlang/OTP that packages the daemon binary (add-release-distribution
# decision 10): OTP from source, version = `erlang` in .tool-versions (override
# with OTP_VERSION), linked against a static OpenSSL 3 LTS, without termcap and
# without applications a daemon release never needs. The same OTP runs
# `mix release` and is Burrito's custom ERTS, so every lib/<app>-<vsn> in the
# binary comes from this one build.
#
# Both source archives are checked against the SHA-256 values pinned below; a
# version without a pinned value fails. PREFIX/lib/erlang/.helmsman-erts records
# what was built; an existing PREFIX with the same record is reused, so PREFIX
# can be cached per (OTP version, target, this file).
#
# macOS: set MACOSX_DEPLOYMENT_TARGET (build-daemon.sh uses 13.0).
# Needs a C/C++ compiler, make, perl and curl.
set -eu

OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

# otp_src_<version>.tar.gz from https://github.com/erlang/otp/releases (SHA256.txt).
otp_sha256() {
  case $1 in
    28.5.0.7) echo ddf17db6d3e9b7a7cfac0d72238ddc8ea040fedc5e3dfad82fc90675319d6c93 ;;
    *) return 1 ;;
  esac
}

# Applications a daemon release, mix and rebar3 never use.
SKIP_APPS="javac jinterface wx odbc debugger observer et megaco diameter snmp common_test"

# OpenSSL's compiled-in directories (default config, provider modules) point at
# a root-owned location that never exists, never at the build directory: the
# daemon must not load code from a path another local user can create.
OPENSSL_RUNTIME_PREFIX=/opt/helmsman-openssl

if [ "$#" -ne 1 ]; then
  echo "usage: $0 PREFIX" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
otp_version=${OTP_VERSION:-$(awk '$1 == "erlang" { print $2 }' "$root/.tool-versions")}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

if ! otp_sha=$(otp_sha256 "$otp_version"); then
  echo "build-erts.sh: no pinned SHA-256 for OTP $otp_version; add it to otp_sha256 (from the release's SHA256.txt)" >&2
  exit 1
fi

mkdir -p "$1"
prefix=$(cd "$1" && pwd)
erlang_root=$prefix/lib/erlang
record="otp=$otp_version openssl=$OPENSSL_VERSION script=$(sha256_of "$0") system=$(uname -s)-$(uname -m) macos=${MACOSX_DEPLOYMENT_TARGET:-}"

if [ -f "$erlang_root/.helmsman-erts" ] && [ "$(cat "$erlang_root/.helmsman-erts")" = "$record" ]; then
  echo "build-erts.sh: reusing $prefix ($record)"
  exit 0
fi

# PREFIX is replaced below: refuse anything that is not empty or an earlier build.
if [ -n "$(ls -A "$prefix")" ] && [ ! -f "$erlang_root/.helmsman-erts" ]; then
  echo "build-erts.sh: $prefix is not empty and not a build-erts.sh prefix" >&2
  exit 1
fi

case $(uname -s) in
  Darwin) jobs=$(sysctl -n hw.ncpu) ;;
  *) jobs=$(nproc) ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/build-erts.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

fetch() {
  url=$1
  file=$2
  expected=$3
  curl -fsSL --retry 3 -o "$file" "$url"
  actual=$(sha256_of "$file")
  if [ "$actual" != "$expected" ]; then
    echo "build-erts.sh: SHA-256 mismatch for $url: expected $expected, got $actual" >&2
    exit 1
  fi
}

echo "build-erts.sh: OpenSSL $OPENSSL_VERSION (static)"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  "$work/openssl.tar.gz" "$OPENSSL_SHA256"
tar -xzf "$work/openssl.tar.gz" -C "$work"
(
  cd "$work/openssl-$OPENSSL_VERSION"
  ./Configure no-shared no-module no-tests no-docs -fPIC \
    --prefix="$OPENSSL_RUNTIME_PREFIX" --openssldir="$OPENSSL_RUNTIME_PREFIX/ssl" --libdir=lib \
    >"$work/openssl-configure.log"
  make -j"$jobs" >"$work/openssl-make.log" 2>&1 || {
    tail -n 50 "$work/openssl-make.log" >&2
    exit 1
  }
  make install_sw DESTDIR="$work/stage" >/dev/null
)
ssl=$work/stage$OPENSSL_RUNTIME_PREFIX

echo "build-erts.sh: OTP $otp_version"
fetch "https://github.com/erlang/otp/releases/download/OTP-$otp_version/otp_src_$otp_version.tar.gz" \
  "$work/otp.tar.gz" "$otp_sha"
tar -xzf "$work/otp.tar.gz" -C "$work"
without=""
for app in $SKIP_APPS; do without="$without --without-$app"; done
rm -rf "$prefix"
mkdir -p "$prefix"
(
  cd "$work/otp_src_$otp_version"
  # shellcheck disable=SC2086
  ./configure --prefix="$prefix" \
    --disable-dynamic-ssl-lib --with-ssl="$ssl" \
    --without-termcap --enable-builtin-zlib \
    $without >"$work/otp-configure.log" 2>&1 || {
    tail -n 50 "$work/otp-configure.log" >&2
    exit 1
  }
  make -j"$jobs" >"$work/otp-make.log" 2>&1 || {
    tail -n 80 "$work/otp-make.log" >&2
    exit 1
  }
  make install >"$work/otp-install.log" 2>&1 || {
    tail -n 50 "$work/otp-install.log" >&2
    exit 1
  }
)

# crypto must have linked OpenSSL statically.
for app in crypto ssl public_key; do
  ls -d "$erlang_root/lib/$app-"* >/dev/null 2>&1 || {
    echo "build-erts.sh: $app was not built (see configure output)" >&2
    exit 1
  }
done

# run_erl / to_erl (detached consoles, unused by the daemon) link libutil on
# older glibc; the binary carries every ERTS executable, so drop them.
rm -f "$erlang_root/bin/run_erl" "$erlang_root/bin/to_erl" \
  "$erlang_root/erts-"*/bin/run_erl "$erlang_root/erts-"*/bin/to_erl "$prefix/bin/run_erl" "$prefix/bin/to_erl"

# Debug symbols only make the binary larger. Linux only: stripping a Mach-O
# file invalidates the ad-hoc signature Apple silicon requires.
if [ "$(uname -s)" = Linux ]; then
  find "$erlang_root/erts-"*/bin "$erlang_root/lib" -type f \( -perm -u+x -o -name '*.so' \) |
    while IFS= read -r file; do
      if [ "$(head -c 4 "$file" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; then
        strip -S "$file" 2>/dev/null || true
      fi
    done
fi

printf '%s\n' "$record" >"$erlang_root/.helmsman-erts"
echo "build-erts.sh: built $prefix ($record)"
