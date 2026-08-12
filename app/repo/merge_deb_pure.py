#!/usr/bin/env python3
"""
Gộp 3 .deb con (daemon + touch + app) thành MỘT gói `com.iosauto`.
Dùng Python thuần (ar + tarfile), KHÔNG cần dpkg-deb.
"""
import glob
import os
import shutil
import sys
import tarfile
import tempfile
import struct
import gzip
import io

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(APP_DIR, "dist")
SUB_PREFIXES = ("com.iosauto.daemon", "com.iosauto.touch", "com.iosauto.app")


def ctrl_field(path, key):
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith(key + ":"):
                return line.split(":", 1)[1].strip()
    return None


def read_ar(path):
    """Đọc ar archive, trả list (name, data)."""
    members = []
    with open(path, "rb") as f:
        magic = f.read(8)
        if magic != b"!<arch>\n":
            raise ValueError("Not an ar archive")
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                break
            name = hdr[0:16].decode("ascii").strip().rstrip("/")
            size = int(hdr[48:58].decode("ascii").strip())
            data = f.read(size)
            if size % 2 == 1:
                f.read(1)  # padding
            members.append((name, data))
    return members


def extract_data_tar(deb_path, dest_dir):
    """Extract data.tar.* từ .deb vào dest_dir."""
    import lzma
    members = read_ar(deb_path)
    for name, data in members:
        if name.startswith("data.tar"):
            bio = io.BytesIO(data)
            if name.endswith(".gz"):
                tf = tarfile.open(fileobj=bio, mode="r:gz")
            elif name.endswith(".xz") or name.endswith(".lzma"):
                bio2 = io.BytesIO(lzma.decompress(data))
                tf = tarfile.open(fileobj=bio2, mode="r:")
            elif name.endswith(".zst"):
                try:
                    import zstandard
                    dctx = zstandard.ZstdDecompressor()
                    bio2 = io.BytesIO(dctx.decompress(data))
                    tf = tarfile.open(fileobj=bio2, mode="r:")
                except ImportError:
                    raise RuntimeError("Need zstandard for .zst")
            else:
                tf = tarfile.open(fileobj=bio, mode="r:")
            tf.extractall(dest_dir)
            tf.close()
            return
    raise ValueError("No data.tar found in deb")


def write_ar(path, members):
    """Ghi ar archive. members = list of (name, data)."""
    with open(path, "wb") as f:
        f.write(b"!<arch>\n")
        for name, data in members:
            name_b = (name + "/").encode("ascii")
            if len(name_b) > 16:
                name_b = name_b[:16]
            hdr = (
                name_b.ljust(16) +
                b"0           " +  # mtime
                b"0     " +        # owner
                b"0     " +        # group
                b"100644  " +      # mode
                str(len(data)).encode().ljust(10) +
                b"\x60\n"
            )
            f.write(hdr)
            f.write(data)
            if len(data) % 2 == 1:
                f.write(b"\n")


def build_deb(root_dir, out_deb):
    """Đóng gói root_dir thành .deb."""
    # control.tar.gz - postinst/prerm cần 0o755, control cần 0o644
    # QUAN TRỌNG: dùng GNU_FORMAT, không dùng PAX (dpkg iOS không hỗ trợ PAX headers)
    ctrl_bio = io.BytesIO()
    with tarfile.open(fileobj=ctrl_bio, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        deb_dir = os.path.join(root_dir, "DEBIAN")
        for fn in os.listdir(deb_dir):
            fp = os.path.join(deb_dir, fn)
            ti = tf.gettarinfo(fp, arcname="./" + fn)
            ti.uid = 0
            ti.gid = 0
            ti.uname = "root"
            ti.gname = "root"
            # postinst/prerm cần executable
            if fn in ("postinst", "prerm", "postrm", "preinst"):
                ti.mode = 0o755
            else:
                ti.mode = 0o644
            with open(fp, "rb") as ff:
                tf.addfile(ti, ff)
    ctrl_data = ctrl_bio.getvalue()

    # data.tar.gz - set mode đúng cho Unix
    # QUAN TRỌNG: dùng GNU_FORMAT, không dùng PAX (dpkg iOS không hỗ trợ PAX headers)
    data_bio = io.BytesIO()
    with tarfile.open(fileobj=data_bio, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        for dirpath, dirnames, filenames in os.walk(root_dir):
            if "DEBIAN" in dirpath:
                continue
            for fn in filenames:
                fp = os.path.join(dirpath, fn)
                arcname = "./" + os.path.relpath(fp, root_dir).replace("\\", "/")
                ti = tf.gettarinfo(fp, arcname=arcname)
                ti.uid = 0
                ti.gid = 0
                ti.uname = "root"
                ti.gname = "root"
                # Executables (bin, dylib, no extension in bin/) get 0o755
                is_exec = (fn.endswith(('.dylib', '.so')) or
                           '/bin/' in arcname or
                           fn in ('iosautod', 'iOSAutoApp'))
                ti.mode = 0o755 if is_exec else 0o644
                with open(fp, "rb") as ff:
                    tf.addfile(ti, ff)
            for dn in dirnames:
                if dn == "DEBIAN":
                    continue
                dp = os.path.join(dirpath, dn)
                arcname = "./" + os.path.relpath(dp, root_dir).replace("\\", "/") + "/"
                ti = tf.gettarinfo(dp, arcname=arcname)
                ti.uid = 0
                ti.gid = 0
                ti.uname = "root"
                ti.gname = "root"
                ti.mode = 0o755  # directories always 0o755
                tf.addfile(ti)
    data_data = data_bio.getvalue()

    # debian-binary
    deb_binary = b"2.0\n"

    write_ar(out_deb, [
        ("debian-binary", deb_binary),
        ("control.tar.gz", ctrl_data),
        ("data.tar.gz", data_data),
    ])


def main():
    if len(sys.argv) < 3:
        print("Dùng: merge_deb_pure.py <debs_dir> <out_dir>")
        return 2
    debs_dir, out_dir = sys.argv[1], sys.argv[2]

    # Lấy file mới nhất cho mỗi component
    latest = {}
    for deb in sorted(glob.glob(os.path.join(debs_dir, "*.deb"))):
        bn = os.path.basename(deb)
        for prefix in SUB_PREFIXES:
            if bn.startswith(prefix):
                latest[prefix] = deb
                break

    if len(latest) < 3:
        print("Thiếu .deb con (cần daemon + touch + app). Thấy:", list(latest.keys()))
        return 1

    version = ctrl_field(os.path.join(DIST, "control"), "Version")
    os.makedirs(out_dir, exist_ok=True)
    out_deb = os.path.join(out_dir, f"com.iosauto_{version}_iphoneos-arm64.deb")

    root = tempfile.mkdtemp()
    try:
        for prefix, deb in latest.items():
            print("  bung", os.path.basename(deb))
            extract_data_tar(deb, root)

        deb_dir = os.path.join(root, "DEBIAN")
        os.makedirs(deb_dir, exist_ok=True)
        shutil.copy(os.path.join(DIST, "control"), os.path.join(deb_dir, "control"))

        for s in ("postinst", "prerm"):
            src = os.path.join(DIST, s)
            if os.path.isfile(src):
                txt = open(src, encoding="utf-8").read().replace("\r\n", "\n").replace("\r", "\n")
                dst = os.path.join(deb_dir, s)
                with open(dst, "w", encoding="utf-8", newline="\n") as f:
                    f.write(txt)
                os.chmod(dst, 0o755)

        build_deb(root, out_deb)
        print("[OK] Merged ->", out_deb, f"({os.path.getsize(out_deb)} bytes)")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
