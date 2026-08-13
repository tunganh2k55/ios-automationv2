# -*- coding: utf-8 -*-
"""Sinh lại các file .luax (script đã MÃ HOÁ) nhúng trong tool, để KHÔNG lộ mã nguồn trong .exe.
Cơ chế: gửi plaintext Lua tới daemon /api/script_encrypt (khoá nhúng trong daemon) → nhận blob
base64 .luax → lưu vào scripts/. Blob mã hoá bởi 1 daemon chạy được trên MỌI daemon cùng khoá.

Dùng:
    python build/encrypt_script.py 192.168.1.197            # cổng 8080 mặc định
    python build/encrypt_script.py 127.0.0.1 8081           # qua USB (iproxy/pymobiledevice3)

Nguồn plaintext lấy từ Demo/pokemon/<tên>.lua; xuất scripts/<tên>.luax.
"""
import json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
POKE = os.path.dirname(HERE)                                   # BuildToolElectron/Pokemon
ROOT = os.path.dirname(os.path.dirname(POKE))                  # repo gốc
SRC_DIR = os.path.join(ROOT, "Demo", "pokemon")
OUT_DIR = os.path.join(POKE, "scripts")

# (đường dẫn nguồn .lua tương đối từ Demo/pokemon, tên đích .luax trong scripts/)
SCRIPTS = [
    ("reg/reg-poke.lua", "reg-poke.luax"),
    ("chyusen/chyusen_honin.lua", "chyusen_honin.luax"),
    ("chyusen/chyu_246.lua", "chyu_246.luax"),
]


def encrypt(base, src):
    # BẮT BUỘC ensure_ascii=False: gửi UTF-8 thô, KHÔNG escape \uXXXX. Parser JSON của daemon
    # không giải mã \uXXXX → nếu escape sẽ làm hỏng tiếng Việt trong script (vd "Bắt" -> "Bu1eaft").
    body = json.dumps({"content": src}, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(base + "/api/script_encrypt", data=body,
                                 headers={"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=20).read())
    if not r.get("ok") or not r.get("blob"):
        raise SystemExit("script_encrypt lỗi: " + json.dumps(r, ensure_ascii=False))
    return r["blob"]


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.197"
    port = sys.argv[2] if len(sys.argv) > 2 else "8080"
    base = f"http://{host}:{port}"
    for src_name, out_name in SCRIPTS:
        src = open(os.path.join(SRC_DIR, src_name), "r", encoding="utf-8").read()
        blob = encrypt(base, src)
        with open(os.path.join(OUT_DIR, out_name), "w", encoding="utf-8", newline="\n") as f:
            f.write(blob)
        print(f"[OK] {src_name} -> scripts/{out_name} ({len(blob)} bytes)")


if __name__ == "__main__":
    main()
