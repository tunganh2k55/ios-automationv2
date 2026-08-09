#!/usr/bin/env python3
"""
Mở web UI của iOSAuto QUA USB cho MỘT hoặc NHIỀU iPhone cùng lúc (không cần WiFi —
chạy được cả khi bật chế độ máy bay).

Cơ chế: usbmuxd chuyển tiếp một cổng TCP trên PC → 127.0.0.1:<DEVICE> trên iPhone,
nơi daemon nghe cổng USB (mặc định 8081, bind loopback nên KHÔNG lộ ra WiFi/LAN).
Cổng phía iPhone LUÔN là 8081 trên MỌI máy (loopback riêng từng máy → không đụng nhau);
việc "chia cổng" chỉ ở phía PC: mỗi máy 1 cổng local, ghim theo UDID.

    python app/control/usb_web.py                 # tự dò MỌI máy cắm USB, gán 8081, 8082, 8083…
    python app/control/usb_web.py --base 9101     # bắt đầu dải từ 9101
    python app/control/usb_web.py --udid <UDID>   # chỉ 1 máy cụ thể (dùng cổng --base)
    python app/control/usb_web.py --device 8081   # đổi cổng phía iPhone (mặc định 8081)

Sau khi chạy, mở trình duyệt theo bảng in ra: http://localhost:<LOCAL>

Cần 1 trong hai công cụ (cài trên PC):
  - libimobiledevice (iproxy + idevice_id)  — Windows: scoop install libimobiledevice; macOS: brew install libimobiledevice; Linux: apt install libimobiledevice-utils
  - pymobiledevice3 (thuần Python)          — pip install pymobiledevice3
Điều kiện: iPhone cắm USB + đã "Tin cậy" (Trust) máy tính này.
"""
import argparse
import re
import shutil
import subprocess
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# UDID kiểu cũ (40 hex) hoặc kiểu mới (8 hex - 16 hex).
UDID_RE = re.compile(r"[0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}")


def have(tool):
    return shutil.which(tool) is not None


def list_devices_libimobile():
    """Danh sách UDID qua idevice_id -l (libimobiledevice)."""
    r = subprocess.run(["idevice_id", "-l"], capture_output=True, text=True)
    return [u.strip() for u in r.stdout.splitlines() if u.strip()]


def device_name_libimobile(udid):
    try:
        r = subprocess.run(["idevicename", "-u", udid], capture_output=True, text=True, timeout=5)
        return r.stdout.strip() or "?"
    except Exception:
        return "?"


def list_devices_pymd3():
    """Trích UDID từ `pymobiledevice3 usbmux list`."""
    r = subprocess.run(["pymobiledevice3", "usbmux", "list"], capture_output=True, text=True)
    return sorted(set(UDID_RE.findall(r.stdout)))


def pymd3_udid_flag():
    """pymobiledevice3 đổi cờ chọn máy giữa các bản (--udid vs --serial) → tự dò."""
    try:
        h = subprocess.run(["pymobiledevice3", "usbmux", "forward", "--help"],
                           capture_output=True, text=True, timeout=10).stdout
        if "--udid" in h:
            return "--udid"
        if "--serial" in h:
            return "--serial"
    except Exception:
        pass
    return "--udid"


def main():
    ap = argparse.ArgumentParser(description="Forward web UI iOSAuto qua USB cho nhiều iPhone.")
    ap.add_argument("--base", type=int, default=8081, help="cổng local BẮT ĐẦU trên PC (mặc định 8081)")
    ap.add_argument("--device", type=int, default=8081, help="cổng phía iPhone (mặc định 8081)")
    ap.add_argument("--udid", help="chỉ forward 1 máy có UDID này (dùng cổng --base)")
    args = ap.parse_args()

    use_iproxy = have("iproxy")
    use_pymd3 = have("pymobiledevice3")
    if not use_iproxy and not use_pymd3:
        print("Chưa có công cụ chuyển tiếp USB. Cài 1 trong hai:")
        print("  • libimobiledevice (iproxy + idevice_id) — vd: scoop install libimobiledevice")
        print("  • pymobiledevice3                          — pip install pymobiledevice3")
        return 1

    # 1) Liệt kê máy.
    if args.udid:
        devices = [args.udid]
    elif have("idevice_id"):
        devices = list_devices_libimobile()
    elif use_pymd3:
        devices = list_devices_pymd3()
    else:
        # có iproxy nhưng thiếu idevice_id để liệt kê → không tự dò được UDID.
        print("Có iproxy nhưng thiếu idevice_id để liệt kê máy. Cài đủ libimobiledevice,")
        print("hoặc truyền --udid <UDID> cho từng máy, hoặc dùng pymobiledevice3.")
        return 1

    if not devices:
        print("Không thấy iPhone nào cắm USB (đã Trust chưa?). Kiểm tra: idevice_id -l")
        return 1

    pymd3_flag = pymd3_udid_flag() if (use_pymd3 and not use_iproxy) else None

    # 2) Gán cổng + dựng lệnh forward cho từng máy.
    procs = []   # (local, udid, name, Popen)
    for i, udid in enumerate(devices):
        local = args.base + i
        name = device_name_libimobile(udid) if have("idevicename") else "?"
        if use_iproxy:
            cmd = ["iproxy", "-u", udid, str(local), str(args.device)]
        else:
            cmd = ["pymobiledevice3", "usbmux", "forward", str(local), str(args.device), pymd3_flag, udid]
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except FileNotFoundError:
            print("Không chạy được:", " ".join(cmd))
            continue
        procs.append((local, udid, name, p))

    if not procs:
        print("Không dựng được forward nào.")
        return 1

    # 3) In bảng.
    print(f"\nĐang forward {len(procs)} máy (cổng iPhone = {args.device}). Ctrl+C để dừng tất cả.\n")
    print(f"  {'LOCAL':<22} MÁY")
    for local, udid, name, _ in procs:
        short = (udid[:8] + "…" + udid[-4:]) if len(udid) > 14 else udid
        print(f"  http://localhost:{local:<7} {name}  ({short})")
    print()

    # 4) Chờ; báo nếu tiến trình nào chết (thường do cổng bận / mất kết nối USB).
    try:
        while True:
            time.sleep(1)
            for local, udid, name, p in procs:
                rc = p.poll()
                if rc is not None:
                    print(f"⚠️  Forward localhost:{local} ({name}) đã dừng (rc={rc}).")
            procs = [(l, u, n, p) for (l, u, n, p) in procs if p.poll() is None]
            if not procs:
                print("Tất cả forward đã dừng.")
                return 1
    except KeyboardInterrupt:
        print("\nDừng…")
        for _, _, _, p in procs:
            try:
                p.terminate()
            except Exception:
                pass
        return 0


if __name__ == "__main__":
    sys.exit(main())
