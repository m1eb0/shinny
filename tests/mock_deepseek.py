#!/usr/bin/env python3
"""Mock DeepSeek Search + Chat API (streaming SSE and tool calls)."""

import json
import os
import time
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

RECORD = os.environ.get("MOCK_RECORD", "")
USAGE = {
    "prompt_tokens": 100,
    "completion_tokens": 12,
    "prompt_cache_hit_tokens": 40,
    "prompt_cache_miss_tokens": 60,
    "completion_tokens_details": {"reasoning_tokens": 5},
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for event in events:
            self.wfile.write(("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode("utf-8"))
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) or b"{}"
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            self._send(400, {"error": {"message": "invalid JSON"}})
            return

        if self.headers.get("Authorization", "") == "":
            self._send(401, {"error": {"message": "missing API key"}})
            return

        if self.path == "/v1/tools/search":
            self._send(
                200,
                {
                    "results": [
                        {
                            "rerank_score": 2.4,
                            "title": "DeepSeek result for " + body.get("query", ""),
                            "url": "https://deepseek.example/result",
                            "snippet": "A short snippet about the query.",
                            "summary": "A longer summary about the query.",
                            "content": "",
                            "site_name": "DeepSeek Docs",
                            "date": "2026-01-01T00:00:00+00:00",
                            "authority": 3,
                        }
                    ]
                },
            )
            return

        if self.path == "/chat/completions":
            if RECORD:
                with open(RECORD, "w", encoding="utf-8") as f:
                    json.dump(body, f, ensure_ascii=False, indent=2)

            messages = body.get("messages") or []
            last_user = ""
            has_tool_result = False
            for m in messages:
                if m.get("role") == "user":
                    last_user = m.get("content", "")
                if m.get("role") == "tool":
                    has_tool_result = True

            content = "你好，这是流式回答。"
            tool_call = False
            if has_tool_result:
                content = "已完成修改。"
            elif "工具" in last_user and "改写" in last_user:
                tool_call = True
            elif "英文" in last_user:
                content = "已处理。"

            if not body.get("stream"):
                message = {"role": "assistant", "content": None if tool_call else content}
                if tool_call:
                    message["tool_calls"] = [
                        {
                            "id": "call_mock",
                            "type": "function",
                            "function": {
                                "name": "replace_selection",
                                "arguments": json.dumps({"text": "工具改写后的文本"}, ensure_ascii=False),
                            },
                        }
                    ]
                self._send(200, {"choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if tool_call else "stop"}], "usage": USAGE})
                return

            slow = "slow" in last_user
            events = []
            if body.get("thinking", {}).get("type") == "enabled":
                events.append({"choices": [{"delta": {"reasoning_content": "先想一想。"}}]})
            if tool_call:
                events.append(
                    {
                        "choices": [
                            {
                                "delta": {
                                    "tool_calls": [
                                        {
                                            "index": 0,
                                            "id": "call_mock",
                                            "type": "function",
                                            "function": {"name": "replace_selection", "arguments": ""},
                                        }
                                    ]
                                }
                            }
                        ]
                    }
                )
                events.append(
                    {
                        "choices": [
                            {
                                "delta": {
                                    "tool_calls": [
                                        {
                                            "index": 0,
                                            "function": {
                                                "arguments": json.dumps({"text": "工具改写后的文本"}, ensure_ascii=False)
                                            },
                                        }
                                    ]
                                }
                            }
                        ]
                    }
                )
                events.append({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]})
            else:
                for part in (content[:3], content[3:]):
                    events.append({"choices": [{"delta": {"content": part}}]})
                events.append({"choices": [{"delta": {}, "finish_reason": "stop"}]})
            events.append({"choices": [], "usage": USAGE})
            if slow:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for event in events:
                    self.wfile.write(("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(0.6)
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return
            self._sse(events)
            return

        self._send(404, {"error": {"message": "not found"}})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8766
    server = HTTPServer(("127.0.0.1", port), Handler)
    print("ready", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
