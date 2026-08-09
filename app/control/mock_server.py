#!/usr/bin/env python3
"""
Mock server cho iOSAuto — giả lập daemon native để dev/test web UI trên Windows.
KHÔNG chạm thật, KHÔNG mở app thật. Chỉ trả JSON đúng contract để làm UI.

Chạy:  python control/mock_server.py [port]
Mở:    http://127.0.0.1:8080
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Console Windows mặc định cp1252 → không in được tiếng Việt. Ép UTF-8.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(ROOT, "web")

STATE = {
    "start": time.time(),
    "running_app": None,
    "log": [],
    "screen": {"w": 390, "h": 844},
}

FAKE_APPS = [
    {"bundleId": "com.apple.mobilesafari", "name": "Safari"},
    {"bundleId": "com.apple.mobilecal", "name": "Lịch"},
    {"bundleId": "com.apple.Preferences", "name": "Cài đặt"},
    {"bundleId": "com.apple.calculator", "name": "Máy tính"},
    {"bundleId": "com.burbn.instagram", "name": "Instagram"},
]

MIME = {".html": "text/html", ".js": "application/javascript",
        ".css": "text/css", ".png": "image/png", ".ico": "image/x-icon"}


def log(msg):
    line = time.strftime("%H:%M:%S") + " " + msg
    STATE["log"].append(line)
    STATE["log"] = STATE["log"][-500:]
    print(line)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def _json_body(self):
        n = int(self.headers.get("Content-Length", 0))
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return {}

    def log_message(self, *a):
        pass  # tắt log mặc định của http.server

    # ---- GET ----
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path.startswith("/api/"):
            return self._api_get(path[5:])
        return self._static(path)

    def _static(self, path):
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        fp = os.path.normpath(os.path.join(WEB_DIR, rel))
        if not fp.startswith(WEB_DIR) or not os.path.isfile(fp):
            return self._send(404, b"not found", "text/plain")
        ext = os.path.splitext(fp)[1]
        with open(fp, "rb") as f:
            self._send(200, f.read(), MIME.get(ext, "application/octet-stream"))

    def _api_get(self, route):
        if route == "status":
            return self._send(200, {
                "ok": True,
                "device": {"name": "iPhone (mock)", "model": "sim", "ios": "16.5"},
                "ip": "127.0.0.1", "port": self.server.server_address[1],
                "screen": STATE["screen"],
                "runningApp": STATE["running_app"],
                "uptime": int(time.time() - STATE["start"]),
            })
        if route == "apps":
            return self._send(200, {"ok": True, "apps": FAKE_APPS})
        if route == "log":
            return self._send(200, {"ok": True, "lines": STATE["log"]})
        if route == "screenshot":
            return self._send(503, b"mock: no screenshot", "text/plain")
        return self._send(404, {"ok": False, "msg": "route không tồn tại"})

    # ---- POST ----
    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith("/api/"):
            return self._send(404, {"ok": False})
        route = path[5:]
        b = self._json_body()
        if route == "launch":
            STATE["running_app"] = b.get("bundleId")
            log(f"launch {b.get('bundleId')}")
            return self._send(200, {"ok": True, "msg": "đã mở " + str(b.get("bundleId"))})
        if route == "kill":
            log(f"kill {b.get('bundleId')}")
            if STATE["running_app"] == b.get("bundleId"):
                STATE["running_app"] = None
            return self._send(200, {"ok": True, "msg": "đã đóng " + str(b.get("bundleId"))})
        if route == "tap":
            log(f"tap ({b.get('x')}, {b.get('y')})")
            return self._send(200, {"ok": True, "msg": "tap (mock — chưa dispatch thật)"})
        if route == "swipe":
            log(f"swipe ({b.get('x1')},{b.get('y1')} → {b.get('x2')},{b.get('y2')})")
            return self._send(200, {"ok": True, "msg": "swipe (mock)"})
        if route == "type":
            log(f"type '{b.get('text')}'")
            return self._send(200, {"ok": True, "msg": "type (mock)"})
        if route == "home":
            log("home")
            STATE["running_app"] = None
            return self._send(200, {"ok": True, "msg": "home (mock)"})
        if route == "script":
            code = b.get("code", "")
            log(f"script {len(code)} ký tự")
            return self._send(200, {"ok": True, "output": f"(mock) nhận {len(code)} ký tự.\nLua engine sẽ có ở Phase 2."})
        return self._send(404, {"ok": False, "msg": "route không tồn tại"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    log(f"mock server chạy tại http://127.0.0.1:{port}  (web: {WEB_DIR})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\ndừng.")


if __name__ == "__main__":
    main()
