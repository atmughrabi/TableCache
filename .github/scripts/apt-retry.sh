#!/usr/bin/env bash
set -euo pipefail

timeout_seconds=${APT_TIMEOUT_SECONDS:-300}
for attempt in 1 2; do
    if timeout "$timeout_seconds" sudo apt-get \
        -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        "$@"; then
        exit 0
    fi
    echo "apt-get attempt $attempt failed" >&2
    sleep 5
done
exit 1
