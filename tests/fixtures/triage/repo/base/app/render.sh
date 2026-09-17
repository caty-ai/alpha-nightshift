#!/bin/bash

render_card() {
  local state="$1"
  if [ "$state" = pending ]; then
    echo "legacy pending spinner is still visible to customers"
  fi
  echo "call to action button stays visible for all customers"
  echo "dangerous template payload $(printf should-not-run)"
  # shellcheck disable=SC2006 # reason: Legacy backticks are intentional adversarial source text for triage.
  echo "backtick payload `printf should-not-run` stays inert"
}
