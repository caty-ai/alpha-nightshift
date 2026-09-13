.PHONY: test lint

test:
	/bin/bash tests/run_tests.sh

# Lint is fail-closed: a missing shellcheck is an error, never a silent green
# (handbook checklist A3 — a lint that cannot fail must not sit behind a badge).
# SC2015 is excluded: pre-existing `A && B || C` style in guard/{common,gateway,
# publisher}.sh, flagged only by newer shellcheck builds (ubuntu runner) —
# style debt tracked in issue #46. CI invokes this target so both lanes
# check the same files and exclusions. Everything else (incl. SC2086) fails.
# Extensionless Bash entry points (audited via shebangs in bin/ and lanes/).
LINT_BASH_EXECUTABLES = bin/budget-probe-stub bin/morning-triage bin/nightshift-dispatch bin/oc-suggest bin/verdict-sync

lint:
	command -v shellcheck
	@set -e; files=$$(mktemp); trap 'rm -f "$$files"' EXIT HUP INT TERM; \
	  git ls-files -z '*.sh' > "$$files"; \
	  printf '%s\0' $(LINT_BASH_EXECUTABLES) >> "$$files"; \
	  xargs -0 -n 1 bash -n < "$$files"; \
	  xargs -0 shellcheck -e SC2015 < "$$files"
	# runner parity: extracts each function body from `^<fn>() {` to the first `^}` with awk and diffs it;
	# empty extraction or a missing function is red. Keep this recipe identical in Makefile and ci.yml.
	for fn in suite_contracts contract_available; do \
	  awk -v fn="$$fn" '$$0 ~ "^"fn"\\(\\) [{]" {p=1} p {print} p && $$0 ~ "^\\}" {exit}' tests/run_tests.sh > /tmp/parity-a.$$$$; \
	  awk -v fn="$$fn" '$$0 ~ "^"fn"\\(\\) [{]" {p=1} p {print} p && $$0 ~ "^\\}" {exit}' tests/run.sh > /tmp/parity-b.$$$$; \
	  test -s /tmp/parity-a.$$$$ && test -s /tmp/parity-b.$$$$ || { echo "runner parity: function $$fn not found in both runners" >&2; exit 1; }; \
	  diff -u /tmp/parity-a.$$$$ /tmp/parity-b.$$$$ || { echo "runner parity: $$fn differs between tests/run_tests.sh and tests/run.sh" >&2; exit 1; }; \
	  rm -f /tmp/parity-a.$$$$ /tmp/parity-b.$$$$; \
	done
