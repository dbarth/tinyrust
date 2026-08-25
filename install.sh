#!/bin/sh
#
# tinyrust installer.
#
#   curl -sSfL https://raw.githubusercontent.com/dbarth/tinyrust/master/install.sh | sh
#
# Fetches trustup and installs the toolchain into ~/.rustup/toolchains/tinyrust,
# linking the binaries into ~/.cargo/bin the way rustup does. No prompt: there
# is one profile and it is the small one.
#
# Testing against a working copy instead of GitHub:
#
#   TINYRUST_SOURCE=/path/to/tinyrust TINYRUST_DIST=/path/to/dist sh install.sh
#
set -eu

REPO="${TINYRUST_REPO:-dbarth/tinyrust}"
REF="${TINYRUST_REF:-master}"
RAW="https://raw.githubusercontent.com/$REPO/$REF"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

# A local checkout is used as-is; nothing is downloaded. This is the path used
# to test the installer before it is published.
if [ -n "${TINYRUST_SOURCE:-}" ]; then
  [ -x "$TINYRUST_SOURCE/trustup" ] || { echo "no trustup in $TINYRUST_SOURCE" >&2; exit 1; }
  TRUSTUP="$TINYRUST_SOURCE/trustup"
  say "tinyrust from $TINYRUST_SOURCE"
else
  dir="${TINYRUST_HOME:-$HOME/.tinyrust}"
  mkdir -p "$dir"
  say "fetching trustup from $REPO@$REF"
  curl -sSfL "$RAW/trustup" -o "$dir/trustup" || {
    echo "could not fetch $RAW/trustup" >&2; exit 1; }
  chmod +x "$dir/trustup"
  TRUSTUP="$dir/trustup"
fi

# TINYRUST_DIST points trustup at locally built packages; unset it installs the
# published ones.
if [ -n "${TINYRUST_DIST:-}" ]; then
  TRUSTUP_DIST="$TINYRUST_DIST" "$TRUSTUP" install
else
  "$TRUSTUP" install
fi
