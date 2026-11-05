#!/usr/bin/env bash
# End-to-end test: run the real curl command against a local Tavily mock.
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${PORT:-8765}"
python3 tests/mock_tavily.py "$PORT" >/dev/null 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
	if curl -s -o /dev/null "http://127.0.0.1:${PORT}/"; then
		break
	fi
	sleep 0.1
done

lua5.4 tests/run.lua --integration "http://127.0.0.1:${PORT}/search"
