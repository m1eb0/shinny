#!/usr/bin/env bash
# End-to-end tests: real curl commands against local Tavily and DeepSeek mocks.
set -euo pipefail

cd "$(dirname "$0")/.."

PORT_TAVILY="${PORT_TAVILY:-8765}"
PORT_DEEPSEEK="${PORT_DEEPSEEK:-8766}"

python3 tests/mock_tavily.py "$PORT_TAVILY" >/dev/null 2>&1 &
tavily_pid=$!
python3 tests/mock_deepseek.py "$PORT_DEEPSEEK" >/dev/null 2>&1 &
deepseek_pid=$!
trap 'kill "$tavily_pid" "$deepseek_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
	if curl -s -o /dev/null "http://127.0.0.1:${PORT_TAVILY}/" &&
		curl -s -o /dev/null "http://127.0.0.1:${PORT_DEEPSEEK}/"; then
		break
	fi
	sleep 0.1
done

lua5.4 tests/run.lua --integration \
	"http://127.0.0.1:${PORT_TAVILY}/search" \
	"http://127.0.0.1:${PORT_DEEPSEEK}/v1/tools/search" \
	"http://127.0.0.1:${PORT_DEEPSEEK}/chat/completions"
