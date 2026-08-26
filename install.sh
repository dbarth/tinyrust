#!/bin/sh
#
# tinyrust installer.
#
#   curl -sSfL https://raw.githubusercontent.com/dbarth/tinyrust/master/install.sh | sh
#
# Fetches trustup and installs the tinyrust toolchain.
#

set -eu

# Testing against a working copy instead of GitHub:
#
#   TINYRUST_SOURCE=/path/to/tinyrust TINYRUST_DIST=/path/to/dist sh install.sh
#

REPO="${TINYRUST_REPO:-dbarth/tinyrust}"
REF="${TINYRUST_REF:-master}"
RAW="https://raw.githubusercontent.com/$REPO/$REF"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

if [ -n "${TINYRUST_SOURCE:-}" ]; then
  # path used to test the installer before it is published.
  [ -x "$TINYRUST_SOURCE/trustup" ] || { echo "no trustup in $TINYRUST_SOURCE" >&2; exit 1; }
  TRUSTUP="$TINYRUST_SOURCE/trustup"
  say "tinyrust from $TINYRUST_SOURCE"
else
  # a staging copy: trustup installs itself into the toolchain, and the
  # ~/.cargo/bin links point there, so nothing permanent lives here.
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  say "fetching trustup from $REPO@$REF"
  curl -sSfL "$RAW/trustup" -o "$dir/trustup" || {
    echo "could not fetch $RAW/trustup" >&2; exit 1; }
  chmod +x "$dir/trustup"
  TRUSTUP="$dir/trustup"
fi

# TINYRUST_DIST points trustup at locally built packages
# unset it installs the published ones.

if [ -n "${TINYRUST_DIST:-}" ]; then
  TRUSTUP_DIST="$TINYRUST_DIST" "$TRUSTUP" install
else
  "$TRUSTUP" install
fi
