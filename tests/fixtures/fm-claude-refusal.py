#!/usr/bin/env python3
"""Loopback-only Claude refusal fixture; no upstream model or credentials.

usage: fm-claude-refusal.py <port-file> <category>
Return an API refusal to a harmless prompt so the installed CLI renders its
own current recovery banner. Category 'none' omits structured stop details.
"""
import http.server
import json
import sys

port_file, category = sys.argv[1:]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        message = {
            "id": "msg_refusal_fixture",
            "type": "message",
            "role": "assistant",
            "model": "claude-sonnet-4-6",
            "content": [{"type": "text", "text": ""}],
            "stop_reason": "refusal",
            "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 0},
        }
        if category != "none":
            message["stop_details"] = {"category": category}
        reply = json.dumps(message).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as out:
    out.write(str(server.server_port))
server.serve_forever()
