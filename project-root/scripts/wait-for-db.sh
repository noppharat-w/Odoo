#!/usr/bin/env sh
set -eu

HOST="${1:-db}"
PORT="${2:-5432}"
TIMEOUT="${3:-60}"

START="$(date +%s)"

while :; do
  if python3 - "$HOST" "$PORT" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

with socket.create_connection((host, port), timeout=3):
    pass
PY
  then
    exit 0
  fi

  NOW="$(date +%s)"
  if [ $((NOW - START)) -ge "$TIMEOUT" ]; then
    echo "Timed out waiting for ${HOST}:${PORT}" >&2
    exit 1
  fi

  sleep 2
done
