#!/usr/bin/env python3
"""Mock DeepSeek Search + Chat API used by shinny's integration tests."""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

RECORD = os.environ.get("MOCK_RECORD", "")


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
                            "summary": "A longer summary about the query, meant for models.",
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
            for m in messages:
                if m.get("role") == "user":
                    last_user = m.get("content", "")
            if "改写" in last_user:
                content = (
                    "好的，我把选区改写得更专业了。\n"
                    "<<<SHINNY_EDIT selection>>>\n"
                    "重写后的专业表述。\n"
                    "<<<SHINNY_EDIT_END>>>"
                )
            elif "插入" in last_user:
                content = (
                    "解释如下。\n"
                    "<<<SHINNY_EDIT cursor>>>\n"
                    "这是插入的解释。\n"
                    "<<<SHINNY_EDIT_END>>>"
                )
            elif "英文" in last_user:
                content = (
                    "已改写这一行。\n"
                    "<<<SHINNY_EDIT line>>>\n"
                    "This line has been translated.\n"
                    "<<<SHINNY_EDIT_END>>>"
                )
            else:
                content = "我看到了上下文里的文件，可以开始修改。"
            self._send(
                200,
                {
                    "id": "mock",
                    "model": body.get("model", "deepseek-chat"),
                    "choices": [
                        {"index": 0, "message": {"role": "assistant", "content": content}}
                    ],
                },
            )
            return

        self._send(404, {"error": {"message": "not found"}})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8766
    server = HTTPServer(("127.0.0.1", port), Handler)
    print("ready", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
