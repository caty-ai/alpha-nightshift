#!/bin/bash
set -euo pipefail

OC_SEAT_CMD=${OC_SEAT_CMD:?OC_SEAT_CMD is required}
OC_SEAT_TIMEOUT_SEC=${OC_SEAT_TIMEOUT_SEC:-900}

case "$OC_SEAT_TIMEOUT_SEC" in
  ''|*[!0-9]*|0)
    printf '%s\n' 'org-consistency seat: OC_SEAT_TIMEOUT_SEC must be a positive integer' >&2
    exit 2
    ;;
esac

# Python's start_new_session gives each configured command its own process
# group. A timeout can therefore terminate the complete CLI tree without
# process-name inspection, while stdout remains the only delivery channel.
exec /usr/bin/python3 - "$OC_SEAT_CMD" "$OC_SEAT_TIMEOUT_SEC" 3<&0 <<'PY'
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile

command = sys.argv[1]
timeout = int(sys.argv[2])
with os.fdopen(3, "rb") as prompt_stream:
    prompt = prompt_stream.read()
scratch = pathlib.Path(
    tempfile.mkdtemp(prefix="oc-seat.", dir=os.environ.get("TMPDIR") or "/tmp")
)
process = None
try:
    process = subprocess.Popen(
        ["/bin/bash", "-c", command],
        cwd=scratch,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(prompt, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        sys.stdout.buffer.write(stdout)
        sys.stderr.buffer.write(stderr)
        print(f"org-consistency seat: timed out after {timeout}s", file=sys.stderr)
        raise SystemExit(124)
    sys.stdout.buffer.write(stdout)
    sys.stderr.buffer.write(stderr)
    raise SystemExit(process.returncode)
finally:
    shutil.rmtree(scratch, ignore_errors=True)
PY
