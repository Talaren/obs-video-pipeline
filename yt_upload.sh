#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UPLOAD_PYTHON="${YT_UPLOAD_PYTHON:-$SCRIPT_DIR/.venv-youtube-upload/bin/python3}"
UPLOAD_SCRIPT="$SCRIPT_DIR/yt_upload.py"

if [ ! -x "$UPLOAD_PYTHON" ]; then
  echo "Fehler: Python im Upload-venv fehlt ($UPLOAD_PYTHON)." >&2
  echo "Bitte richte das venv ein oder setze YT_UPLOAD_PYTHON." >&2
  exit 1
fi

if [ ! -f "$UPLOAD_SCRIPT" ]; then
  echo "Fehler: Upload-Skript fehlt ($UPLOAD_SCRIPT)." >&2
  exit 1
fi

exec "$UPLOAD_PYTHON" "$UPLOAD_SCRIPT" "$@"
