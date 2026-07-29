#!/usr/bin/python3
"""Exec a command after restoring SIGINT's default disposition."""

import os
import signal
import sys


signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execve(sys.argv[1], sys.argv[1:], os.environ)
