#include "video.h"
#include "touch.h"
#include "log.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#define INGEST_PORT 8398
#define MAX_WS 8

// ---------------- SHA1 (public domain, rút gọn) ----------------
typedef struct { uint32_t h[5]; uint64_t len; uint8_t buf[64]; size_t n; } sha1_ctx;
static uint32_t rol(uint32_t v, int b) { return (v << b) | (v >> (32 - b)); }
static void sha1_block(sha1_ctx *c, const uint8_t *p) {
    uint32_t w[80];
    for (int i = 0; i < 16; i++) w[i] = (p[i*4]<<24)|(p[i*4+1]<<16)|(p[i*4+2]<<8)|p[i*4+3];
    for (int i = 16; i < 80; i++) w[i] = rol(w[i-3]^w[i-8]^w[i-14]^w[i-16], 1);
    uint32_t a=c->h[0],b=c->h[1],d=c->h[2],e=c->h[3],f=c->h[4];
    for (int i = 0; i < 80; i++) {
        uint32_t k, t;
        if (i<20){k=0x5A827999;t=(b&d)|((~b)&e);}
        else if (i<40){k=0x6ED9EBA1;t=b^d^e;}
        else if (i<60){k=0x8F1BBCDC;t=(b&d)|(b&e)|(d&e);}
        else {k=0xCA62C1D6;t=b^d^e;}
        uint32_t tmp = rol(a,5)+t+f+k+w[i];
        f=e; e=d; d=rol(b,30); b=a; a=tmp;
    }
    c->h[0]+=a; c->h[1]+=b; c->h[2]+=d; c->h[3]+=e; c->h[4]+=f;
}
static void sha1_init(sha1_ctx *c){c->h[0]=0x67452301;c->h[1]=0xEFCDAB89;c->h[2]=0x98BADCFE;c->h[3]=0x10325476;c->h[4]=0xC3D2E1F0;c->len=0;c->n=0;}
static void sha1_update(sha1_ctx *c, const uint8_t *p, size_t len){
    c->len += len;
    while (len) { size_t k = 64 - c->n; if (k > len) k = len; memcpy(c->buf+c->n, p, k); c->n+=k; p+=k; len-=k; if (c->n==64){sha1_block(c,c->buf);c->n=0;} }
}
static void sha1_final(sha1_ctx *c, uint8_t out[20]){
    uint64_t bits = c->len*8; uint8_t pad=0x80; sha1_update(c,&pad,1);
    uint8_t z=0; while (c->n != 56) sha1_update(c,&z,1);
    uint8_t lb[8]; for (int i=0;i<8;i++) lb[i]=(bits>>(56-8*i))&0xff; sha1_update(c,lb,8);
    for (int i=0;i<5;i++){out[i*4]=(c->h[i]>>24)&0xff;out[i*4+1]=(c->h[i]>>16)&0xff;out[i*4+2]=(c->h[i]>>8)&0xff;out[i*4+3]=c->h[i]&0xff;}
}
static void b64(const uint8_t *in, size_t len, char *out){
    static const char t[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i,o=0;
    for (i=0;i+3<=len;i+=3){out[o++]=t[in[i]>>2];out[o++]=t[((in[i]&3)<<4)|(in[i+1]>>4)];out[o++]=t[((in[i+1]&15)<<2)|(in[i+2]>>6)];out[o++]=t[in[i+2]&63];}
    if (i<len){out[o++]=t[in[i]>>2];if(i+1<len){out[o++]=t[((in[i]&3)<<4)|(in[i+1]>>4)];out[o++]=t[(in[i+1]&15)<<2];}else{out[o++]=t[(in[i]&3)<<4];out[o++]='=';}out[o++]='=';}
    out[o]='\0';
}

// ---------------- WS client registry ----------------
typedef struct { int fd; int started; } ws_client;
static ws_client g_ws[MAX_WS];
static int g_nws = 0;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static int write_all(int fd, const uint8_t *b, size_t n){
    size_t o=0; while(o<n){ ssize_t k=write(fd,b+o,n-o); if(k<=0){ if(k<0&&errno==EINTR)continue; return 0;} o+=(size_t)k;} return 1;
}
// Gửi 1 WebSocket binary message (server→client, KHÔNG mask).
static int ws_send(int fd, const uint8_t *data, size_t len){
    uint8_t h[10]; size_t hl;
    h[0]=0x82;
    if (len<126){h[1]=(uint8_t)len;hl=2;}
    else if (len<65536){h[1]=126;h[2]=(len>>8)&0xff;h[3]=len&0xff;hl=4;}
    else {h[1]=127;for(int i=0;i<8;i++)h[2+i]=(uint8_t)((uint64_t)len>>(56-8*i));hl=10;}
    if(!write_all(fd,h,hl))return 0;
    return write_all(fd,data,len);
}

static void signal_stream(int on){
    char reply[128]={0};
    touch_video_stream(on, reply, sizeof(reply));
    log_msg("video: %s stream → tweak (%s)", on?"START":"STOP", reply[0]?reply:"?");
}

// ---------------- Ingest (tweak → daemon:8398) + fan-out ----------------
static int read_full(int fd, uint8_t *b, size_t n){
    size_t o=0; while(o<n){ ssize_t k=read(fd,b+o,n-o); if(k<=0){ if(k<0&&errno==EINTR)continue; return 0;} o+=(size_t)k;} return 1;
}
static void fanout(const uint8_t *payload, size_t n, int keyframe){
    pthread_mutex_lock(&g_mu);
    for (int i = g_nws-1; i>=0; i--){
        if (keyframe) g_ws[i].started = 1;           // client bắt đầu decode từ keyframe
        if (!g_ws[i].started) continue;
        if (!ws_send(g_ws[i].fd, payload, n)){        // client rớt → gỡ
            g_ws[i] = g_ws[--g_nws];
        }
    }
    pthread_mutex_unlock(&g_mu);
}

static void *ingest_loop(void *arg){
    (void)arg;
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv<0){ log_msg("video: socket ingest lỗi"); return NULL; }
    int one=1; setsockopt(srv,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    struct sockaddr_in a; memset(&a,0,sizeof(a));
    a.sin_family=AF_INET; a.sin_addr.s_addr=htonl(INADDR_LOOPBACK); a.sin_port=htons(INGEST_PORT);
    if (bind(srv,(struct sockaddr*)&a,sizeof(a))<0){ log_msg("video: bind :%d lỗi %s",INGEST_PORT,strerror(errno)); close(srv); return NULL; }
    if (listen(srv,4)<0){ close(srv); return NULL; }
    log_msg("video: ingest sẵn sàng (127.0.0.1:%d)", INGEST_PORT);

    uint8_t *buf = malloc(2*1024*1024);
    if (!buf){ close(srv); return NULL; }
    for (;;){
        int fd = accept(srv, NULL, NULL);
        if (fd<0){ if(errno==EINTR)continue; break; }
        int nd=1; setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&nd,sizeof(nd));
        log_msg("video: tweak push kết nối");
        for (;;){
            uint8_t hdr[4];
            if (!read_full(fd, hdr, 4)) break;
            uint32_t N = (hdr[0]<<24)|(hdr[1]<<16)|(hdr[2]<<8)|hdr[3];   // payload = [flags][annexb]
            if (N==0 || N>2*1024*1024) break;
            if (!read_full(fd, buf, N)) break;
            int keyframe = buf[0] & 1;
            fanout(buf, N, keyframe);   // gửi cả byte flags làm byte đầu message
        }
        close(fd);
        log_msg("video: tweak push ngắt");
    }
    free(buf); close(srv);
    return NULL;
}

// ---------------- MJPEG: buffer khung mới nhất (tách khỏi relay điều khiển) ----------------
#define JPEG_PORT 8397
#define JPEG_MAX (1024*1024)
static uint8_t *g_jpeg = NULL; static size_t g_jpeg_len = 0; static uint32_t g_jpeg_ver = 0;
static pthread_mutex_t g_jpeg_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_shot_clients = 0;
static pthread_mutex_t g_shot_mu = PTHREAD_MUTEX_INITIALIZER;

// Copy khung JPEG mới nhất nếu version khác *ver. Trả độ dài (0 nếu chưa có/trùng).
int video_copy_jpeg(uint8_t *dst, size_t cap, uint32_t *ver){
    pthread_mutex_lock(&g_jpeg_mu);
    int n = 0;
    if (g_jpeg_len && g_jpeg_len <= cap && g_jpeg_ver != *ver){
        memcpy(dst, g_jpeg, g_jpeg_len); n = (int)g_jpeg_len; *ver = g_jpeg_ver;
    }
    pthread_mutex_unlock(&g_jpeg_mu);
    return n;
}
// Client stream MJPEG vào/ra → refcount, bật/tắt SHOTSTART trên SpringBoard.
void video_shotstream_join(void){
    pthread_mutex_lock(&g_shot_mu); int first = (g_shot_clients++ == 0); pthread_mutex_unlock(&g_shot_mu);
    if (first){ char r[64]={0}; touch_shot_stream(1, r, sizeof(r)); log_msg("video: SHOTSTART (%s)", r[0]?r:"?"); }
}
void video_shotstream_leave(void){
    pthread_mutex_lock(&g_shot_mu); int last = (--g_shot_clients <= 0); if (g_shot_clients < 0) g_shot_clients = 0; pthread_mutex_unlock(&g_shot_mu);
    if (last){ char r[64]={0}; touch_shot_stream(0, r, sizeof(r)); log_msg("video: SHOTSTOP (%s)", r[0]?r:"?"); }
}

static void *jpeg_ingest_loop(void *arg){
    (void)arg;
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv<0) return NULL;
    int one=1; setsockopt(srv,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    struct sockaddr_in a; memset(&a,0,sizeof(a));
    a.sin_family=AF_INET; a.sin_addr.s_addr=htonl(INADDR_LOOPBACK); a.sin_port=htons(JPEG_PORT);
    if (bind(srv,(struct sockaddr*)&a,sizeof(a))<0){ log_msg("video: bind jpeg :%d lỗi %s",JPEG_PORT,strerror(errno)); close(srv); return NULL; }
    if (listen(srv,4)<0){ close(srv); return NULL; }
    if (!g_jpeg) g_jpeg = malloc(JPEG_MAX);
    log_msg("video: jpeg ingest sẵn sàng (127.0.0.1:%d)", JPEG_PORT);
    uint8_t *tmp = malloc(JPEG_MAX);
    if (!tmp || !g_jpeg){ close(srv); return NULL; }
    for (;;){
        int fd = accept(srv, NULL, NULL);
        if (fd<0){ if(errno==EINTR)continue; break; }
        int nd=1; setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&nd,sizeof(nd));
        log_msg("video: shot push kết nối");
        for (;;){
            uint8_t hdr[4];
            if (!read_full(fd, hdr, 4)) break;
            uint32_t N = (hdr[0]<<24)|(hdr[1]<<16)|(hdr[2]<<8)|hdr[3];
            if (N==0 || N>JPEG_MAX) break;
            if (!read_full(fd, tmp, N)) break;
            pthread_mutex_lock(&g_jpeg_mu);
            memcpy(g_jpeg, tmp, N); g_jpeg_len = N; g_jpeg_ver++;
            pthread_mutex_unlock(&g_jpeg_mu);
        }
        close(fd);
        log_msg("video: shot push ngắt");
    }
    free(tmp); close(srv);
    return NULL;
}

void video_init(void){
    pthread_t th;
    if (pthread_create(&th,NULL,ingest_loop,NULL)==0) pthread_detach(th);
    else log_msg("video: không tạo được ingest thread");
    pthread_t th2;
    if (pthread_create(&th2,NULL,jpeg_ingest_loop,NULL)==0) pthread_detach(th2);
    else log_msg("video: không tạo được jpeg ingest thread");
}

int video_is_ws_path(const char *path){ return path && strcmp(path,"/ws/video")==0; }
int video_is_control_path(const char *path){ return path && strcmp(path,"/ws/control")==0; }

// Bắt tay WebSocket (RFC6455). Trả 1 nếu OK.
static int ws_handshake(int fd, const char *req){
    const char *k = strcasestr(req, "Sec-WebSocket-Key:");
    if (!k){ const char *m="HTTP/1.1 400 Bad Request\r\n\r\n"; write_all(fd,(const uint8_t*)m,strlen(m)); return 0; }
    k += 18; while (*k==' ') k++;
    char key[128]; size_t i=0; while (*k && *k!='\r' && *k!='\n' && i<sizeof(key)-1) key[i++]=*k++; key[i]='\0';
    char concat[200]; snprintf(concat,sizeof(concat),"%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11",key);
    sha1_ctx c; sha1_init(&c); sha1_update(&c,(const uint8_t*)concat,strlen(concat));
    uint8_t dig[20]; sha1_final(&c,dig);
    char accept[40]; b64(dig,20,accept);
    char resp[256];
    int rn = snprintf(resp,sizeof(resp),
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept);
    return write_all(fd,(const uint8_t*)resp,(size_t)rn);
}

// Đọc 1 WebSocket message text từ client (client LUÔN mask). Trả độ dài, -1 nếu đóng/lỗi.
static int ws_recv_text(int fd, char *out, size_t cap){
    uint8_t h[2];
    if (!read_full(fd,h,2)) return -1;
    int op = h[0]&0x0f, masked = h[1]&0x80;
    uint64_t len = h[1]&0x7f;
    if (len==126){ uint8_t e[2]; if(!read_full(fd,e,2))return -1; len=(e[0]<<8)|e[1]; }
    else if (len==127){ uint8_t e[8]; if(!read_full(fd,e,8))return -1; len=0; for(int i=0;i<8;i++)len=(len<<8)|e[i]; }
    // Message điều khiển vốn nhỏ (vài chục byte). Client khai `len` khổng lồ (tới 2^63) mà không gửi
    // đủ data → vòng đọc-bỏ-phần-dư ở dưới quay read_full mãi (treo thread điều khiển). Chặn trên: quá
    // 1MB coi như client hỏng/độc → đóng.
    if (len > (1u<<20)) return -1;
    uint8_t mask[4]={0,0,0,0};
    if (masked && !read_full(fd,mask,4)) return -1;
    if (op==0x8) return -1;   // close
    // đọc payload; nếu quá cap thì đọc & bỏ phần dư (message điều khiển vốn nhỏ)
    uint64_t take = len < cap-1 ? len : cap-1;
    if (take && !read_full(fd,(uint8_t*)out,take)) return -1;
    for (uint64_t r = take; r < len; ){ uint8_t junk[256]; uint64_t c2 = (len-r)<sizeof(junk)?(len-r):sizeof(junk); if(!read_full(fd,junk,c2))return -1; r+=c2; }
    if (masked) for (uint64_t i=0;i<take;i++) out[i]^=mask[i&3];
    out[take]='\0';
    return (int)take;
}

// WebSocket điều khiển: nhận "phase x y" (d/m/u) → PTR tới app foreground.
void control_handle_ws(int fd, const char *req){
    if (!ws_handshake(fd, req)) return;
    log_msg("control: WS client vào");
    char msg[256];
    for (;;){
        int n = ws_recv_text(fd, msg, sizeof(msg));
        if (n < 0) break;
        if (n == 0) continue;
        char ph; int x, y;
        if (sscanf(msg, "%c %d %d", &ph, &x, &y) == 3){
            char err[64];
            touch_pointer(ph, x, y, err, sizeof(err));
        }
    }
    log_msg("control: WS client ra");
}

void video_handle_ws(int fd, const char *req){
    if (!ws_handshake(fd, req)) return;

    // Đăng ký client; nếu là client đầu → bật stream.
    int first=0;
    pthread_mutex_lock(&g_mu);
    if (g_nws < MAX_WS){ g_ws[g_nws].fd=fd; g_ws[g_nws].started=0; g_nws++; if(g_nws==1) first=1; }
    else { pthread_mutex_unlock(&g_mu); return; }
    pthread_mutex_unlock(&g_mu);
    if (first) signal_stream(1);
    log_msg("video: WS client vào (tổng=%d)", g_nws);

    // BLOCK: đọc socket để phát hiện client đóng (bỏ qua nội dung — browser chỉ có thể gửi close).
    uint8_t tmp[512];
    for (;;){ ssize_t n = read(fd, tmp, sizeof(tmp)); if (n<=0) break; }

    // Gỡ client; nếu hết → tắt stream.
    int last=0;
    pthread_mutex_lock(&g_mu);
    for (int j=0;j<g_nws;j++){ if (g_ws[j].fd==fd){ g_ws[j]=g_ws[--g_nws]; break; } }
    if (g_nws==0) last=1;
    pthread_mutex_unlock(&g_mu);
    if (last) signal_stream(0);
    log_msg("video: WS client ra (còn=%d)", g_nws);
}
