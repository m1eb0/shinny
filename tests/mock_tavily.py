#!/usr/bin/env python3
"""Tiny Tavily-compatible endpoint used by the integration test."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

EXPECTED_KEY = "Bearer tvly-test-key"


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
        if self.path != "/search":
            self._send(404, {"detail": {"error": "not found"}})
            return

        if self.headers.get("Authorization") != EXPECTED_KEY:
            self._send(401, {"detail": {"error": "Unauthorized: bad or missing API key"}})
            return

        length = int(self.headers.get("Content-Length") or 0)
        try:
            request = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send(400, {"detail": {"error": "invalid JSON body"}})
            return

        query = request.get("query")
        if not isinstance(query, str) or not query.strip():
            self._send(400, {"detail": {"error": "missing query"}})
            return

        self._send(
            200,
            {
                "query": query,
                "answer": "Mock answer about " + query,
                "response_time": 0.01,
                "results": [
                    {
                        "title": "Mock result for " + query,
                        "url": "https://example.test/integration",
                        "content": 'A "quoted" snippet with a newline\nand a tab\tfor good measure.',
                        "score": 0.99,
                    }
                ],
            },
        )


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    server = HTTPServer(("127.0.0.1", port), Handler)
    print("ready", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
