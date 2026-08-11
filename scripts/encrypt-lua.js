#!/usr/bin/env node
/**
 * encrypt-lua.js - Mã hóa file Lua theo format của ios-autos (scriptcrypt.c)
 *
 * Format: base64(magic "IOSX"(4) | ver(1)=1 | nonce(12) | ct_len(4, LE) | ciphertext | sig(64))
 * - key_enc = SHA512(SEED || "iosauto-enc-v1")[0:32]
 * - nonce = SHA512(plaintext)[0:12]
 * - ct = ChaCha20(key_enc, nonce, ctr=1) XOR plaintext
 * - sig = Ed25519_sign(SEED, magic..ciphertext)
 *
 * Usage: node encrypt-lua.js <input.lua> [output.luax]
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// SEED giống hệt trong scriptcrypt.c
const ENC_SEED = Buffer.from([
    0xa5, 0xfb, 0xbe, 0xea, 0x04, 0x3b, 0x51, 0xb1, 0x3c, 0x93, 0x66, 0xcb, 0x9a, 0x50, 0xdf, 0xa4,
    0xa7, 0x47, 0x2f, 0xc2, 0x3a, 0xbe, 0xb7, 0x5b, 0x1f, 0x4f, 0x8d, 0xf1, 0x0b, 0x39, 0x95, 0xc3
]);

const SC_MAGIC = Buffer.from('IOSX');
const SC_VER = 1;

// Derive encryption key = SHA512(SEED || "iosauto-enc-v1")[0:32]
function deriveEncKey() {
    const tag = Buffer.from('iosauto-enc-v1');
    const buf = Buffer.concat([ENC_SEED, tag]);
    const hash = crypto.createHash('sha512').update(buf).digest();
    return hash.subarray(0, 32);
}

// Derive Ed25519 keypair from seed
function deriveKeypair() {
    // Node.js crypto uses seed directly for Ed25519
    const privateKey = crypto.createPrivateKey({
        key: Buffer.concat([
            // Ed25519 PKCS8 header
            Buffer.from('302e020100300506032b657004220420', 'hex'),
            ENC_SEED
        ]),
        format: 'der',
        type: 'pkcs8'
    });
    return privateKey;
}

// ChaCha20 encrypt/decrypt (XOR mode)
function chacha20Xor(data, key, nonce, counter = 1) {
    // Node.js chacha20 requires 16-byte nonce (actually uses first 12 for chacha20)
    // But chacha20-poly1305 uses 12-byte nonce
    // We need plain chacha20 with counter

    // Use chacha20 cipher (not poly1305)
    const cipher = crypto.createCipheriv('chacha20', key, Buffer.concat([
        Buffer.alloc(4), // counter as 4 bytes LE
        nonce
    ]));

    // Skip first block if counter > 0 (chacha20 starts at counter 0 in Node)
    if (counter > 0) {
        cipher.update(Buffer.alloc(64 * counter));
    }

    return cipher.update(data);
}

// Alternative: manual ChaCha20 implementation for exact compatibility
function chacha20Manual(data, key, nonce, counter) {
    // Simple XOR cipher using ChaCha20 keystream
    // Node's chacha20 uses 16-byte IV: 4-byte counter (LE) + 12-byte nonce
    const iv = Buffer.alloc(16);
    iv.writeUInt32LE(counter, 0);
    nonce.copy(iv, 4);

    const cipher = crypto.createCipheriv('chacha20', key, iv);
    return cipher.update(data);
}

function encrypt(plaintext) {
    const plain = Buffer.isBuffer(plaintext) ? plaintext : Buffer.from(plaintext, 'utf8');
    const plen = plain.length;

    // Derive keys
    const encKey = deriveEncKey();
    const privateKey = deriveKeypair();

    // nonce = SHA512(plain)[0:12]
    const nonceHash = crypto.createHash('sha512').update(plain).digest();
    const nonce = nonceHash.subarray(0, 12);

    // Build header: magic(4) + ver(1) + nonce(12) = 17 bytes
    const header = Buffer.alloc(17);
    SC_MAGIC.copy(header, 0);
    header[4] = SC_VER;
    nonce.copy(header, 5);

    // ct_len as 4 bytes LE
    const ctLenBuf = Buffer.alloc(4);
    ctLenBuf.writeUInt32LE(plen, 0);

    // Encrypt: ciphertext = ChaCha20(key, nonce, ctr=1) XOR plain
    const ciphertext = chacha20Manual(plain, encKey, nonce, 1);

    // Data to sign: header + ctlen + ciphertext
    const toSign = Buffer.concat([header, ctLenBuf, ciphertext]);

    // Sign with Ed25519
    const sig = crypto.sign(null, toSign, privateKey);

    // Final binary: header + ctlen + ciphertext + sig
    const binData = Buffer.concat([toSign, sig]);

    // Return base64
    return binData.toString('base64');
}

// Main
const args = process.argv.slice(2);
if (args.length < 1) {
    console.log('Usage: node encrypt-lua.js <input.lua> [output.luax]');
    console.log('  If output not specified, prints to stdout');
    process.exit(1);
}

const inputFile = args[0];
const outputFile = args[1];

if (!fs.existsSync(inputFile)) {
    console.error(`Error: File not found: ${inputFile}`);
    process.exit(1);
}

const plaintext = fs.readFileSync(inputFile, 'utf8');
console.error(`Encrypting ${inputFile} (${plaintext.length} bytes)...`);

try {
    const encrypted = encrypt(plaintext);

    if (outputFile) {
        fs.writeFileSync(outputFile, encrypted);
        console.error(`Encrypted to ${outputFile} (${encrypted.length} bytes)`);
    } else {
        console.log(encrypted);
    }
} catch (err) {
    console.error('Encryption failed:', err.message);
    process.exit(1);
}
