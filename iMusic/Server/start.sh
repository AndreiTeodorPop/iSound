#!/bin/sh
# Start the bgutil PO token server in the background.
# yt-dlp-get-pot auto-discovers it and uses it to bypass YouTube bot detection.
echo "[startup] Starting bgutil PO token server..."
python -m bgutil_ytdlp_pot_provider serve &

# Wait for the server to initialize before accepting requests
echo "[startup] Waiting 8s for bgutil to initialize..."
sleep 8
echo "[startup] Starting gunicorn..."

exec gunicorn server:app \
    --bind "0.0.0.0:${PORT:-8080}" \
    --workers "${WORKERS:-1}" \
    --timeout 300
