# -*- coding: utf-8 -*-
"""Mã hoá script Lua -> .luax NGOẠI TUYẾN (không cần daemon/license).

Tái hiện đúng thuật toán trong app/daemon/src/scriptcrypt.c (SEED nhúng compile-time):
  key_enc = SHA512(SEED || "iosauto-enc-v1")[0:32]
  nonce   = SHA512(plaintext)[0:12]
  ct      = ChaCha20(key_enc, nonce, counter=1) XOR plaintext
  bin     = "IOSX"(4) | ver=1(1) | nonce(12) | ctlen(4, little-endian) | ct | sig(64)
  sig     = Ed25519_sign(SEED, bin[0 : 21+ctlen])
  blob    = base64(bin)   (chuẩn, có padding)

ChaCha20 thuần Python (RFC 8439) để không phụ thuộc layout nonce của thư viện.
Ed25519 tất định (RFC 8032) qua thư viện `cryptography` — chữ ký khớp bản C.

Dùng:  python build/encrypt_script_offline.py
"""
import os, sys, struct, hashlib
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

HERE = os.path.dirname(os.path.abspath(__file__))
POKE = os.path.dirname(HERE)                                   # BuildToolElectron/Pokemon
ROOT = os.path.dirname(os.path.dirname(POKE))                  # repo gốc
SRC_DIR = os.path.join(ROOT, "Demo", "pokemon")
OUT_DIR = os.path.join(POKE, "scripts")
# Nguồn Lua đã tái cấu trúc vào thư mục con theo tool (reg/, chyusen/). src_name có thể chứa
# subpath — chỉ tên .luax đầu ra là phẳng trong scripts/ (điều exe bundle & iOSAuto resolve).
SCRIPTS = [("reg/reg-poke.lua", "reg-poke.luax")]

# SEED nhúng — trùng ENC_SEED[32] trong scriptcrypt.c
ENC_SEED = bytes([
    0xa5, 0xfb, 0xbe, 0xea, 0x04, 0x3b, 0x51, 0xb1, 0x3c, 0x93, 0x66, 0xcb, 0x9a, 0x50, 0xdf, 0xa4,
    0xa7, 0x47, 0x2f, 0xc2, 0x3a, 0xbe, 0xb7, 0x5b, 0x1f, 0x4f, 0x8d, 0xf1, 0x0b, 0x39, 0x95, 0xc3,
])


def _rotl32(v, c):
    v &= 0xffffffff
    return ((v << c) | (v >> (32 - c))) & 0xffffffff


def _qr(x, a, b, c, d):
    x[a] = (x[a] + x[b]) & 0xffffffff; x[d] ^= x[a]; x[d] = _rotl32(x[d], 16)
    x[c] = (x[c] + x[d]) & 0xffffffff; x[b] ^= x[c]; x[b] = _rotl32(x[b], 12)
    x[a] = (x[a] + x[b]) & 0xffffffff; x[d] ^= x[a]; x[d] = _rotl32(x[d], 8)
    x[c] = (x[c] + x[d]) & 0xffffffff; x[b] ^= x[c]; x[b] = _rotl32(x[b], 7)


def _chacha_block(key, counter, nonce):
    const = b"expand 32-byte k"
    state = list(struct.unpack("<4I", const))
    state += list(struct.unpack("<8I", key))
    state.append(counter & 0xffffffff)
    state += list(struct.unpack("<3I", nonce))
    work = state[:]
    for _ in range(10):
        _qr(work, 0, 4, 8, 12); _qr(work, 1, 5, 9, 13)
        _qr(work, 2, 6, 10, 14); _qr(work, 3, 7, 11, 15)
        _qr(work, 0, 5, 10, 15); _qr(work, 1, 6, 11, 12)
        _qr(work, 2, 7, 8, 13); _qr(work, 3, 4, 9, 14)
    out = [(work[i] + state[i]) & 0xffffffff for i in range(16)]
    return struct.pack("<16I", *out)


def chacha20_xor(data, key, nonce12, counter=1):
    out = bytearray(len(data))
    i = 0
    ctr = counter
    while i < len(data):
        ks = _chacha_block(key, ctr, nonce12)
        n = min(64, len(data) - i)
        for j in range(n):
            out[i + j] = data[i + j] ^ ks[j]
        i += 64
        ctr += 1
    return bytes(out)


def encrypt(plain: bytes) -> str:
    key = hashlib.sha512(ENC_SEED + b"iosauto-enc-v1").digest()[:32]
    nonce12 = hashlib.sha512(plain).digest()[:12]
    ct = chacha20_xor(plain, key, nonce12, counter=1)
    bin_ = b"IOSX" + bytes([1]) + nonce12 + struct.pack("<I", len(plain)) + ct
    sig = Ed25519PrivateKey.from_private_bytes(ENC_SEED).sign(bin_)
    import base64
    return base64.b64encode(bin_ + sig).decode("ascii")


def decrypt(blob: str) -> bytes:
    import base64
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    bin_ = base64.b64decode(blob)
    assert bin_[:4] == b"IOSX" and bin_[4] == 1, "magic/ver sai"
    ctl = struct.unpack("<I", bin_[17:21])[0]
    signed = bin_[:21 + ctl]
    sig = bin_[21 + ctl:21 + ctl + 64]
    pub = Ed25519PrivateKey.from_private_bytes(ENC_SEED).public_key()
    pub.verify(sig, signed)                      # ném lỗi nếu chữ ký sai
    nonce12 = bin_[5:17]
    ct = bin_[21:21 + ctl]
    plain = chacha20_xor(ct, hashlib.sha512(ENC_SEED + b"iosauto-enc-v1").digest()[:32], nonce12, 1)
    assert hashlib.sha512(plain).digest()[:12] == nonce12, "toàn vẹn nonce sai"
    return plain


def main():
    # --selftest: giải mã blob hiện có + mã hoá lại đúng plaintext đó -> phải trùng byte-for-byte
    if "--selftest" in sys.argv:
        cur = open(os.path.join(OUT_DIR, "reg-poke.luax"), "r", encoding="utf-8").read().strip()
        plain = decrypt(cur)
        re_enc = encrypt(plain)
        ok = re_enc == cur
        print(f"[selftest] decrypt OK ({len(plain)} bytes plaintext), re-encrypt {'MATCH' if ok else 'DIFF'}")
        sys.exit(0 if ok else 2)

    for src_name, out_name in SCRIPTS:
        plain = open(os.path.join(SRC_DIR, src_name), "rb").read()
        blob = encrypt(plain)
        # kiểm tra khép kín: giải mã lại phải ra đúng plaintext
        assert decrypt(blob) == plain, "round-trip thất bại"
        with open(os.path.join(OUT_DIR, out_name), "w", encoding="utf-8", newline="\n") as f:
            f.write(blob)
        print(f"[OK] {src_name} -> scripts/{out_name} ({len(blob)} bytes, plaintext {len(plain)} bytes)")


if __name__ == "__main__":
    main()
