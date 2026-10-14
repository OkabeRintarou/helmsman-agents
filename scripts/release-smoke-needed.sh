#!/bin/sh
# Usage: release-smoke-needed.sh BASE HEAD
#
# Prints "release=true" when the release smoke test must run for the commits
# BASE..HEAD, "release=false" otherwise (append the output to $GITHUB_OUTPUT).
# An unknown BASE (new branch, force push, shallow history) runs the smoke test.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 BASE HEAD" >&2
  exit 2
fi

base=$1
head=$2

pattern='^(VERSION|\.tool-versions|Dockerfile|\.dockerignore|daemon/mix\.(exs|lock)|daemon/build/.*|daemon/c_src/.*|daemon/rel/.*|server/rel/.*|deploy/.*|\.github/workflows/(ci|release)\.yml|scripts/(release-smoke-needed|smoke-daemon-binary|smoke-release-server|build-daemon|build-erts|build-tools)\.sh)$'

case $base in
  "" | *[!0]*) ;;
  *) base="" ;;
esac

if [ -z "$base" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null ||
  ! changed=$(git diff --name-only "$base" "$head" 2>/dev/null); then
  echo "release=true"
  exit 0
fi

if printf '%s\n' "$changed" | grep -Eq "$pattern"; then
  echo "release=true"
else
  echo "release=false"
fi
