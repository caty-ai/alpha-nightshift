#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/lock.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-lock.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
lockdir="$TEST_TMP/lock"

lock_acquire "$lockdir" || fail "first lock acquisition failed"
if lock_acquire "$lockdir"; then
  fail "second lock acquisition unexpectedly succeeded"
fi
lock_release "$lockdir" || fail "owned lock did not release"
[ ! -d "$lockdir" ] || fail "released lock directory still exists"

lock_acquire "$lockdir" || fail "lock acquisition for ownership test failed"
sed 's/^pid=.*/pid=999999/' "$lockdir/meta" > "$lockdir/meta.new"
mv "$lockdir/meta.new" "$lockdir/meta"
if lock_release "$lockdir"; then
  fail "lock release accepted a different pid"
fi
[ -d "$lockdir" ] || fail "foreign-owned lock was removed"
rm -f "$lockdir/meta"
rmdir "$lockdir"

mkdir "$lockdir"
printf 'pid=999999\nstarted_at=2000-01-01T00:00:00Z\n' > "$lockdir/meta"
if lock_acquire "$lockdir"; then
  fail "stale lock was removed automatically"
fi
[ -f "$lockdir/meta" ] || fail "stale lock metadata was removed"

printf 'test_lock: PASS\n'
