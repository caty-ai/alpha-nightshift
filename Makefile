.PHONY: test lint

test:
	/bin/bash tests/run_tests.sh

# Lint is fail-closed: a missing shellcheck is an error, never a silent green
# (handbook checklist A3 — a lint that cannot fail must not sit behind a badge).
# SC2015 is excluded: pre-existing `A && B || C` style in guard/{common,gateway,
# publisher}.sh, flagged only by newer shellcheck builds (ubuntu runner) —
# style debt tracked in issue #46; the exclusion is mirrored in ci.yml so
# both lint lanes check the same thing. Everything else (incl. SC2086) fails.
lint:
	command -v shellcheck
	for f in guard/*.sh lanes/**/*.sh tests/*.sh; do bash -n "$$f" || exit 1; done
	shellcheck -e SC2015 \
		guard/common.sh \
		guard/broker.sh \
		guard/gateway.sh \
		guard/drift-monitor.sh \
		guard/publisher.sh \
		guard/publisher-lib.sh \
		guard/publisher-askpass.sh \
		guard/remote-preflight.sh \
		tests/test_guard_publisher.sh \
		tests/test_guard_drift_monitor.sh \
		tests/test_guard_revocation_runbook.sh \
		tests/test_publication_gate_selftest.sh \
		tests/test_publication_gate_repo.sh \
		tests/test_publication_denylist.sh \
		lanes/org-consistency/run.sh \
		tests/test_lane_org_consistency_core.sh \
		tests/test_lane_org_consistency_lifecycle.sh \
		tests/test_lane_org_consistency_mutation.sh \
		tests/test_lane_org_consistency_oc_a.sh \
		tests/test_lane_org_consistency_targets_mirrors.sh \
		tests/test_lane_org_consistency_timebox.sh \
		tests/fixtures/org-consistency/lib.sh \
		tests/run_tests.sh
