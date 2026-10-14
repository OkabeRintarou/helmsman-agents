#!/bin/sh
# Usage: check-release-version.sh TAG [VERSION_FILE]
#
# Release tags are v<VERSION>. Prints the version and exits 0 when TAG equals
# "v$(cat VERSION_FILE)"; exits 1 with a message on stderr otherwise.
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 TAG [VERSION_FILE]" >&2
  exit 2
fi

tag=$1
version_file=${2:-$(dirname "$0")/../VERSION}

if [ ! -r "$version_file" ]; then
  echo "cannot read $version_file" >&2
  exit 1
fi

version=$(tr -d ' \t\r\n' <"$version_file")

if [ -z "$version" ]; then
  echo "$version_file is empty" >&2
  exit 1
fi

case $version in
  *[!0-9A-Za-z.+-]*)
    echo "$version_file contains an invalid version: $version" >&2
    exit 1
    ;;
esac

if [ "$tag" != "v$version" ]; then
  echo "tag $tag does not match VERSION $version (expected v$version)" >&2
  exit 1
fi

echo "$version"
