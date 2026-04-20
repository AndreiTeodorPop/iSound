#!/bin/sh
exec gunicorn server:app \
    --bind "0.0.0.0:${PORT:-8080}" \
    --workers "${WORKERS:-1}" \
    --timeout 300
