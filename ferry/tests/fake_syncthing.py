"""Fake Syncthing REST API for the CLI tests: python3 fake_syncthing.py PORT_FILE STATE_FILE API_KEY.

Listens on 127.0.0.1 only (ephemeral port, written to PORT_FILE). STATE_FILE is a JSON object
re-read on every request: {"connected": bool, "state": "idle", "needFiles": 0}.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, state_file, api_key = sys.argv[1:4]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.headers.get("X-API-Key") != api_key:
            return self.reply(403, {"error": "CSRF Error"})
        st = json.load(open(state_file))
        if self.path.startswith("/rest/config/folders/pixel-screenshots"):
            self.reply(200, {"devices": [{"deviceID": "PHONE"}, {"deviceID": "MAC"}]})
        elif self.path.startswith("/rest/system/connections"):
            self.reply(200, {"connections": {"PHONE": {"connected": st["connected"]}}})
        elif self.path.startswith("/rest/db/status?folder=pixel-screenshots"):
            self.reply(200, {"state": st["state"], "needFiles": st["needFiles"]})
        else:
            self.reply(404, {})


srv = HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
