#!/bin/sh
# Tests for scripts/release-smoke-needed.sh. Run: sh scripts/test/release-smoke-needed.test.sh
set -eu

script=$(cd "$(dirname "$0")/.." && pwd)/release-smoke-needed.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
failures=0

# Isolate from the caller's git configuration and hooks.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

cd "$tmp"
git init -q .
echo base >README.md
git add README.md
git commit -qm base
root=$(git rev-parse HEAD)

# expect NAME WANT PATH... : commits the paths on top of root and checks the result.
expect() {
  name=$1 want=$2
  shift 2
  git checkout -q --detach "$root"
  for path in "$@"; do
    mkdir -p "$(dirname "$path")"
    echo "$name" >>"$path"
    git add "$path"
  done
  git commit -qm "$name"
  got=$(sh "$script" "$root" "$(git rev-parse HEAD)")

  if [ "$got" = "release=$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: got '$got', want 'release=$want'"
    failures=$((failures + 1))
  fi
}

expect "docs only" false docs/INSTALL.md
expect "server code only" false server/lib/helmsman.ex
expect "daemon code only" false daemon/lib/helmsman_daemon/cli.ex
expect "VERSION" true VERSION
expect "Dockerfile" true Dockerfile
expect ".dockerignore" true .dockerignore
expect "server/rel" true server/rel/overlays/bin/start
expect "deploy" true deploy/docker-compose.yml
expect "daemon/mix.exs" true daemon/mix.exs
expect "daemon/mix.lock" true daemon/mix.lock
expect "ci workflow" true .github/workflows/ci.yml
expect "release workflow" true .github/workflows/release.yml
expect "smoke script" true scripts/smoke-release-server.sh
expect "tool versions" true .tool-versions
expect "erts build script" true scripts/build-erts.sh
expect "tools build script" true scripts/build-tools.sh
expect "daemon native helper" true daemon/c_src/credentials_lock.c
expect "daemon builder image" true daemon/build/Dockerfile
expect "daemon release overlay" true daemon/rel/vm.args.eex
expect "mixed" true docs/DEPLOY.md Dockerfile
expect "similar names" false server/mix.exs Dockerfile.bak deploy.md

head=$(git rev-parse HEAD)
for base in "" 0000000000000000000000000000000000000000 1234567890abcdef1234567890abcdef12345678; do
  got=$(sh "$script" "$base" "$head")
  if [ "$got" = "release=true" ]; then
    echo "ok   unknown base '$base'"
  else
    echo "FAIL unknown base '$base': got '$got'"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
