#!/bin/sh
set -eu
test_root=$(mktemp -d "${TMPDIR:-/tmp}/spacemanager-tests.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
cd "$(dirname "$0")/.."
CFFIXED_USER_HOME="$test_root" swift test "$@"
