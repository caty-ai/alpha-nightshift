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
held_rc=0
lock_acquire "$lockdir" || held_rc=$?
if [ "$held_rc" -eq 0 ]; then
  fail "second lock acquisition unexpectedly succeeded"
fi
[ "$held_rc" -eq 1 ] || fail "true lock contention returned $held_rc instead of 1"
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

integration_state="$TEST_TMP/integration-state"
integration_config="$TEST_TMP/integration.conf"
mkdir -p "$integration_state/locks/nightshift.lock"
printf 'pid=999999\nstarted_at=2000-01-01T00:00:00Z\n' \
  > "$integration_state/locks/nightshift.lock/meta"
printf '%s\n' \
  "NIGHTSHIFT_STATE_DIR='$integration_state'" \
  "LANE_CMD_1=':'" \
  "LANE_HOME_LINKS=''" \
  > "$integration_config"
NIGHTSHIFT_CONFIG="$integration_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null
NIGHT_ID=$(date -v-8H '+%F')
assert_ledger_record \
  "$integration_state/ledger/ledger.jsonl" \
  "$NIGHT_ID" \
  skip \
  lock_held

error_parent="$TEST_TMP/error-parent"
mkdir "$error_parent"
chmod a-w "$error_parent"
error_rc=0
lock_acquire "$error_parent/lock" || error_rc=$?
[ "$error_rc" -eq 2 ] ||
  fail "unwritable lock parent returned $error_rc instead of lock error 2"
chmod u+w "$error_parent"

printf 'test_lock: PASS\n'
