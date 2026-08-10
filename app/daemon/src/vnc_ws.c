#include "vnc_ws.h"
#include "log.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <CommonCrypto/CommonDigest.h>

#define VNC_HOST "127.0.0.1"
#define VNC_PORT 5900
#define WS_MAGIC "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Base64 encode
static const char b64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void base64_encode(const unsigned char *in, size_t len, char *out) {
    size_t i, j;
    for (i = 0, j = 0; i < len; i += 3) {
        unsigned int a = in[i];
        unsigned int b = (i + 1 < len) ? in[i + 1] : 0;
        unsigned int c = (i + 2 < len) ? in[i + 2] : 0;
        unsigned int triple = (a << 16) | (b << 8) | c;
        out[j++] = b64_table[(triple >> 18) & 0x3f];
        out[j++] = b64_table[(triple >> 12) & 0x3f];
        out[j++] = (i + 1 < len) ? b64_table[(triple >> 6) & 0x3f] : '=';
        out[j++] = (i + 2 < len) ? b64_table[triple & 0x3f] : '=';
    }
    out[j] = '\0';
}

// Tính Sec-WebSocket-Accept
static void ws_accept_key(const char *client_key, char *out, size_t out_len) {
    char concat[128];
    snprintf(concat, sizeof(concat), "%s%s", client_key, WS_MAGIC);

    unsigned char sha1[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(concat, (CC_LONG)strlen(concat), sha1);

    base64_encode(sha1, CC_SHA1_DIGEST_LENGTH, out);
}

// Parse Sec-WebSocket-Key từ headers
static int parse_ws_key(const char *headers, char *key, size_t key_len) {
    const char *p = strcasestr(headers, "Sec-WebSocket-Key:");
    if (!p) return 0;
    p += 18;
    while (*p == ' ') p++;
    size_t i = 0;
    while (*p && *p != '\r' && *p != '\n' && i < key_len - 1) {
        key[i++] = *p++;
    }
    key[i] = '\0';
    return i > 0;
}

// WebSocket frame decode: trả payload length, mask (nếu có), payload start.
// Chỉ hỗ trợ frame ≤65535 bytes (đủ cho VNC).
static int ws_decode_frame(const unsigned char *buf, size_t len,
                           int *opcode, size_t *payload_len,
                           unsigned char *mask, const unsigned char **payload) {
    if (len < 2) return -1;  // chưa đủ header

    *opcode = buf[0] & 0x0f;
    int masked = (buf[1] & 0x80) != 0;
    size_t plen = buf[1] & 0x7f;
    size_t hdr_len = 2;

    if (plen == 126) {
        if (len < 4) return -1;
        plen = ((size_t)buf[2] << 8) | buf[3];
        hdr_len = 4;
    } else if (plen == 127) {
        // 64-bit length - không hỗ trợ (quá lớn)
        return -2;
    }

    if (masked) {
        if (len < hdr_len + 4) return -1;
        memcpy(mask, buf + hdr_len, 4);
        hdr_len += 4;
    }

    if (len < hdr_len + plen) return -1;  // chưa đủ payload

    *payload_len = plen;
    *payload = buf + hdr_len;
    return (int)(hdr_len + plen);  // tổng frame size
}

// WebSocket frame encode (server → client: không mask)
static size_t ws_encode_frame(int opcode, const unsigned char *data, size_t len,
                               unsigned char *out, size_t out_cap) {
    size_t hdr = 2;
    if (len >= 126 && len <= 65535) hdr = 4;
    else if (len > 65535) return 0;  // không hỗ trợ

    if (out_cap < hdr + len) return 0;

    out[0] = 0x80 | (opcode & 0x0f);  // FIN + opcode
    if (len < 126) {
        out[1] = (unsigned char)len;
    } else {
        out[1] = 126;
        out[2] = (unsigned char)(len >> 8);
        out[3] = (unsigned char)(len & 0xff);
    }

    memcpy(out + hdr, data, len);
    return hdr + len;
}

// Proxy thread context
typedef struct {
    int ws_fd;    // WebSocket client
    int vnc_fd;   // VNC server TCP
} proxy_ctx_t;

// Proxy thread: bridge WS ↔ VNC
static void *proxy_thread(void *arg) {
    proxy_ctx_t *ctx = (proxy_ctx_t *)arg;
    int ws_fd = ctx->ws_fd;
    int vnc_fd = ctx->vnc_fd;
    free(ctx);

    unsigned char ws_buf[65536];
    unsigned char vnc_buf[65536];
    size_t ws_pos = 0;

    fd_set rfds;
    int maxfd = (ws_fd > vnc_fd) ? ws_fd : vnc_fd;

    while (1) {
        FD_ZERO(&rfds);
        FD_SET(ws_fd, &rfds);
        FD_SET(vnc_fd, &rfds);

        struct timeval tv = { .tv_sec = 60, .tv_usec = 0 };
        int ret = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (ret <= 0) break;  // timeout hoặc lỗi

        // WS → VNC
        if (FD_ISSET(ws_fd, &rfds)) {
            ssize_t n = recv(ws_fd, ws_buf + ws_pos, sizeof(ws_buf) - ws_pos, 0);
            if (n <= 0) break;
            ws_pos += (size_t)n;

            // Decode WS frames
            while (ws_pos > 0) {
                int opcode;
                size_t payload_len;
                unsigned char mask[4];
                const unsigned char *payload;
                int frame_len = ws_decode_frame(ws_buf, ws_pos, &opcode, &payload_len, mask, &payload);

                if (frame_len < 0) break;  // chưa đủ data

                if (opcode == 0x08) {
                    // Close frame
                    goto cleanup;
                } else if (opcode == 0x09) {
                    // Ping → Pong
                    unsigned char pong[128];
                    size_t pong_len = ws_encode_frame(0x0A, payload, payload_len, pong, sizeof(pong));
                    if (pong_len > 0) send(ws_fd, pong, pong_len, 0);
                } else if (opcode == 0x02 || opcode == 0x00) {
                    // Binary frame hoặc continuation → VNC
                    unsigned char *decoded = malloc(payload_len);
                    if (decoded) {
                        for (size_t i = 0; i < payload_len; i++) {
                            decoded[i] = payload[i] ^ mask[i % 4];
                        }
                        send(vnc_fd, decoded, payload_len, 0);
                        free(decoded);
                    }
                }

                // Shift buffer
                memmove(ws_buf, ws_buf + frame_len, ws_pos - (size_t)frame_len);
                ws_pos -= (size_t)frame_len;
            }
        }

        // VNC → WS
        if (FD_ISSET(vnc_fd, &rfds)) {
            ssize_t n = recv(vnc_fd, vnc_buf, sizeof(vnc_buf) - 10, 0);  // để chừa header
            if (n <= 0) break;

            unsigned char ws_frame[65546];
            size_t frame_len = ws_encode_frame(0x02, vnc_buf, (size_t)n, ws_frame, sizeof(ws_frame));
            if (frame_len > 0) {
                send(ws_fd, ws_frame, frame_len, 0);
            }
        }
    }

cleanup:
    close(ws_fd);
    close(vnc_fd);
    log_msg("vnc_ws: proxy thread kết thúc");
    return NULL;
}

int vnc_ws_is_vnc_path(const char *path) {
    return path && (strcmp(path, "/vnc") == 0 || strcmp(path, "/vnc/") == 0);
}

int vnc_ws_handle_upgrade(int client_fd, const char *headers) {
    // Kiểm tra có phải WebSocket upgrade không
    if (!strcasestr(headers, "Upgrade: websocket")) {
        return 0;
    }

    // Parse key
    char key[64];
    if (!parse_ws_key(headers, key, sizeof(key))) {
        log_msg("vnc_ws: không tìm thấy Sec-WebSocket-Key");
        return -1;
    }

    // Tính accept key
    char accept[64];
    ws_accept_key(key, accept, sizeof(accept));

    // Kết nối tới VNC server
    int vnc_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (vnc_fd < 0) {
        log_msg("vnc_ws: không tạo được socket VNC");
        return -1;
    }

    struct sockaddr_in vnc_addr;
    memset(&vnc_addr, 0, sizeof(vnc_addr));
    vnc_addr.sin_family = AF_INET;
    vnc_addr.sin_port = htons(VNC_PORT);
    inet_pton(AF_INET, VNC_HOST, &vnc_addr.sin_addr);

    if (connect(vnc_fd, (struct sockaddr *)&vnc_addr, sizeof(vnc_addr)) < 0) {
        log_msg("vnc_ws: không kết nối được VNC server port %d", VNC_PORT);
        close(vnc_fd);
        return -1;
    }

    // Gửi WebSocket handshake response
    char response[512];
    int rlen = snprintf(response, sizeof(response),
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n"
        "\r\n",
        accept);

    if (send(client_fd, response, (size_t)rlen, 0) != rlen) {
        log_msg("vnc_ws: không gửi được handshake response");
        close(vnc_fd);
        return -1;
    }

    // Spawn proxy thread
    proxy_ctx_t *ctx = malloc(sizeof(proxy_ctx_t));
    if (!ctx) {
        close(vnc_fd);
        return -1;
    }
    ctx->ws_fd = client_fd;
    ctx->vnc_fd = vnc_fd;

    pthread_t tid;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

    if (pthread_create(&tid, &attr, proxy_thread, ctx) != 0) {
        log_msg("vnc_ws: không tạo được proxy thread");
        free(ctx);
        close(vnc_fd);
        pthread_attr_destroy(&attr);
        return -1;
    }

    pthread_attr_destroy(&attr);
    log_msg("vnc_ws: proxy started, WS fd=%d ↔ VNC fd=%d", client_fd, vnc_fd);

    return 1;  // success, thread đang chạy
}
