#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurfaceRef.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/sysctl.h>
#include <pthread.h>
#include <time.h>
#include "fbcap.h"
#include "touch.h"
#include "log.h"
#include "lua_bind.h"

// Đường dẫn binary daemon (dùng để tự spawn tiến trình CON chụp biệt lập).
#define DAEMON_BIN "/var/jb/usr/local/iosauto/bin/iosautod"
// File tạm để tiến trình con ghi JPEG (thư mục daemon, root ghi được).
#define CAP_TMP "/var/jb/usr/local/iosauto/.cap.jpg"

static pthread_mutex_t g_fb_mu = PTHREAD_MUTEX_INITIALIZER;
extern char **environ;

// ===== CỔNG CAPTURE TOÀN CỤC =====
static pthread_mutex_t g_gate_mu = PTHREAD_MUTEX_INITIALIZER;
static long long g_last_cap_ms = 0;       // thời điểm CHỤP THẬT gần nhất (mọi đường)
static long g_min_interval_ms = 1200;     // tối thiểu giữa 2 lần chụp thật (khi automation chạy)
static long g_frame_ttl_ms = 1000;        // frame còn "mới" bao lâu (imgmatch tái dùng)

static long long fb_mono_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
long fbcap_frame_ttl_ms(void) { return g_frame_ttl_ms; }
void fbcap_set_capture_interval(double min_sec, double ttl_sec) {
    if (min_sec >= 0) g_min_interval_ms = (long)(min_sec * 1000.0);
    if (ttl_sec >= 0) g_frame_ttl_ms = (long)(ttl_sec * 1000.0);
}
void fbcap_gate_enter(void) {
    pthread_mutex_lock(&g_gate_mu);
    if (lua_run_is_busy()) {                 // chỉ giới hạn nhịp khi đang chạy script (idle stream mượt)
        long long now = fb_mono_ms();
        long long since = g_last_cap_ms ? (now - g_last_cap_ms) : g_min_interval_ms;
        if (since < g_min_interval_ms) {
            long waitms = g_min_interval_ms - (long)since;
            pthread_mutex_unlock(&g_gate_mu);
            for (long i = 0; i < waitms; i += 50) usleep(50 * 1000);   // chờ chia nhỏ
            pthread_mutex_lock(&g_gate_mu);
        }
    }
    g_last_cap_ms = fb_mono_ms();
    pthread_mutex_unlock(&g_gate_mu);
}

// Như TrollVNC: CARenderServerRenderDisplay(0,"LCD",src,0,0) → IOSurfaceAccelerator transfer → dst.
typedef void (*CARSRenderFn)(uint32_t, CFStringRef, IOSurfaceRef, int32_t, int32_t);
typedef struct __IOSurfaceAccelerator *AccelRef;

static CARSRenderFn pRender = NULL;
static int (*pACreate)(CFAllocatorRef, void *, AccelRef *) = NULL;
static int (*pXfer)(AccelRef, IOSurfaceRef, IOSurfaceRef, CFDictionaryRef, void *, void *, void *, void *) = NULL;
static int g_syms = 0;

static void load_syms(void) {
    if (g_syms) return;
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator", RTLD_LAZY);
    pRender  = (CARSRenderFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    pACreate = (int(*)(CFAllocatorRef,void*,AccelRef*))dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorCreate");
    pXfer    = (int(*)(AccelRef,IOSurfaceRef,IOSurfaceRef,CFDictionaryRef,void*,void*,void*,void*))dlsym(RTLD_DEFAULT, "IOSurfaceAcceleratorTransferSurface");
    g_syms = 1;
}

static IOSurfaceRef make_surface(size_t w, size_t h) {
    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4);
    size_t tot = IOSurfaceAlignProperty(kIOSurfaceAllocSize, h * bpr);
    NSDictionary *p = @{ (id)kIOSurfaceWidth:@(w), (id)kIOSurfaceHeight:@(h),
        (id)kIOSurfaceBytesPerElement:@(4), (id)kIOSurfaceBytesPerRow:@(bpr),
        (id)kIOSurfaceAllocSize:@(tot), (id)kIOSurfacePixelFormat:@((uint32_t)0x42475241) };
    return IOSurfaceCreate((__bridge CFDictionaryRef)p);
}

// LÕI chụp: render display → src, (transfer → dst), đọc, encode JPEG (scale/quality) → out/outlen.
// Trả 0 nếu OK. Dùng chung cho in-process (streaming) và tiến trình con (biệt lập).
static int capture_core(IOSurfaceRef src, IOSurfaceRef dst, AccelRef accel, size_t W, size_t H,
                        double scale, int quality, unsigned char **out, size_t *outlen) {
    if (!pRender || !src) return 10;
    pRender(0, CFSTR("LCD"), src, 0, 0);
    IOSurfaceRef rd = src;
    if (pXfer && accel && dst) { if (pXfer(accel, src, dst, NULL, NULL, NULL, NULL, NULL) == 0) rd = dst; }

    IOSurfaceLock(rd, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(rd); size_t sbpr = IOSurfaceGetBytesPerRow(rd);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bmp = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
    CGContextRef ctx = base ? CGBitmapContextCreate(base, W, H, 8, sbpr, cs, bmp) : NULL;
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    CGImageRef final = cg;
    if (cg && scale > 0 && scale < 1.0) {
        size_t tw = (size_t)(W * scale), th = (size_t)(H * scale);
        if (tw < 1) tw = 1; if (th < 1) th = 1;
        CGContextRef dc = CGBitmapContextCreate(NULL, tw, th, 8, 0, cs, bmp);
        if (dc) {
            CGContextSetInterpolationQuality(dc, kCGInterpolationLow);
            CGContextDrawImage(dc, CGRectMake(0, 0, tw, th), cg);
            CGImageRef s = CGBitmapContextCreateImage(dc);
            CGContextRelease(dc);
            if (s) { CGImageRelease(cg); final = s; }
        }
    }
    int rc = 6;
    if (final) {
        CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
        CGImageDestinationRef d2 = CGImageDestinationCreateWithData(data, CFSTR("public.jpeg"), 1, NULL);
        if (d2) {
            float q = (quality > 0 && quality <= 100) ? quality / 100.0f : 0.5f;
            CFNumberRef qn = CFNumberCreate(NULL, kCFNumberFloatType, &q);
            const void *keys[] = { kCGImageDestinationLossyCompressionQuality };
            const void *vals[] = { qn };
            CFDictionaryRef opt = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CGImageDestinationAddImage(d2, final, opt);
            if (CGImageDestinationFinalize(d2)) {
                size_t n = (size_t)CFDataGetLength(data);
                *out = malloc(n);
                if (*out) { memcpy(*out, CFDataGetBytePtr(data), n); *outlen = n; rc = 0; }
            }
            CFRelease(opt); CFRelease(qn); CFRelease(d2);
        }
        CFRelease(data);
        CGImageRelease(final);
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    IOSurfaceUnlock(rd, kIOSurfaceLockReadOnly, NULL);
    return rc;
}

// Máy RAM thấp (≤2GB: iPhone 7/8/X…) chụp IN-PROCESS rất dễ bị iOS JETSAM giết CẢ daemon
// (per-process-limit): CARenderServerRenderDisplay + IOSurface phình bộ nhớ vượt ngưỡng jetsam của
// một daemon nền → SIGKILL cứng, không backtrace, chỉ để lại JetsamEvent. Trên các máy này luôn chụp
// BIỆT LẬP (kể cả lúc IDLE/xem màn) để daemon KHÔNG chết → hết "không view được màn / mất kết nối daemon".
static int fb_low_mem_device(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    int64_t memsize = 0; size_t len = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &len, NULL, 0) == 0 && memsize > 0)
        cached = (memsize < 3000000000LL) ? 1 : 0;   // <~2.8GB (2GB device) → coi là yếu; 3GB+ (SE2…) giữ in-process
    else
        cached = 1;                                    // không đọc được → an toàn: coi là yếu
    return cached;
}

// ---- IN-PROCESS (dùng cho STREAMING/screenshot): surfaces tĩnh + mutex ----
int fbcap_jpeg(unsigned char **outbuf, size_t *outlen, double scale, int quality) {
    // *** CHỐNG CRASH DAEMON ***
    // Chụp IN-PROCESS gọi CARenderServerRenderDisplay + IOSurfaceAcceleratorTransferSurface NGAY trong
    // daemon. Khi app đích RENDER NẶNG (vd Safari cold-launch + tải trang lớn lúc chạy reg) hệ đồ hoạ
    // có thể KILL CỨNG (SIGKILL) tiến trình đang chụp → CẢ DAEMON chết (không bắt được → không backtrace,
    // không atexit — đúng triệu chứng daemon "biến mất" giữa chừng reg). Trên máy RAM thấp còn bị JETSAM
    // (per-process-limit) ngay cả lúc IDLE khi mở viewer xem màn.
    // → Chụp BIỆT LẬP qua tiến trình con khi: (a) automation ĐANG CHẠY (app render nặng, rủi ro cao nhất),
    //   HOẶC (b) máy RAM thấp (jetsam kể cả lúc idle). Con bị kill thì daemon VẪN SỐNG (chỉ trả lỗi,
    //   caller/stream thử lại khung sau). Máy khoẻ + idle mới giữ in-process cho stream mượt.
    if (lua_run_is_busy() || fb_low_mem_device())
        return fbcap_jpeg_isolated(outbuf, outlen, scale, quality);

    static AccelRef accel = NULL;
    static IOSurfaceRef src = NULL, dst = NULL;
    static size_t W = 0, H = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        load_syms();
        if (pACreate) pACreate(kCFAllocatorDefault, NULL, &accel);
        int pw = 375, ph = 667; touch_screen_size(&pw, &ph);
        W = (size_t)pw * 2; H = (size_t)ph * 2;
        if (W < 320 || W > 2000) { W = 750; H = 1334; }
        src = make_surface(W, H);
        dst = make_surface(W, H);
    });
    if (!pRender || !src) return 10;
    fbcap_gate_enter();                 // cổng toàn cục: giới hạn nhịp chụp khi automation chạy
    pthread_mutex_lock(&g_fb_mu);
    int rc = capture_core(src, dst, accel, W, H, scale, quality, outbuf, outlen);
    pthread_mutex_unlock(&g_fb_mu);
    return rc;
}

// ---- Chụp ra FILE: chạy TRONG TIẾN TRÌNH CON (iosautod --capture). Tự khởi tạo mọi thứ rồi exit. ----
int fbcap_capture_to_file(const char *path, double scale, int quality, int pw, int ph) {
    @autoreleasepool {
        load_syms();
        AccelRef accel = NULL;
        if (pACreate) pACreate(kCFAllocatorDefault, NULL, &accel);
        size_t W = (size_t)pw * 2, H = (size_t)ph * 2;
        if (W < 320 || W > 2000) { W = 750; H = 1334; }
        IOSurfaceRef src = make_surface(W, H), dst = make_surface(W, H);
        unsigned char *buf = NULL; size_t n = 0;
        int rc = capture_core(src, dst, accel, W, H, scale, quality, &buf, &n);
        if (rc == 0 && buf && n) {
            FILE *f = fopen(path, "wb");
            if (f) { size_t wr = fwrite(buf, 1, n, f); fclose(f); if (wr != n) rc = 20; }
            else rc = 21;
        } else if (rc == 0) rc = 22;
        free(buf);
        return rc;   // tiến trình con sắp _exit → không cần giải phóng surface/accel
    }
}

// ---- BIỆT LẬP: spawn tiến trình con để chụp → đọc file. Con bị kill thì daemon VẪN SỐNG. ----
// Trả 0 + outbuf/outlen nếu OK; !=0 nếu chụp thất bại (con crash/timeout/lỗi file).
int fbcap_jpeg_isolated(unsigned char **outbuf, size_t *outlen, double scale, int quality) {
    fbcap_gate_enter();                 // cổng toàn cục (chung với đường in-process)
    int pw = 375, ph = 667; touch_screen_size(&pw, &ph);

    // File tạm DUY NHẤT mỗi lần chụp: khi automation chạy, luồng stream + luồng script (imgmatch) có
    // thể chụp biệt lập ĐỒNG THỜI (chụp mất tới 5s > cổng 1.2s) → nếu dùng chung 1 file thì 2 tiến
    // trình con ghi/đọc đè nhau → khung rác. Thêm seq (atomic) để mỗi lần 1 path riêng.
    static unsigned g_cap_seq = 0;
    unsigned seq = __sync_fetch_and_add(&g_cap_seq, 1);
    char cap_tmp[160];
    snprintf(cap_tmp, sizeof(cap_tmp), "/var/jb/usr/local/iosauto/.cap.%u.jpg", seq);
    unlink(cap_tmp);

    char s_scale[32], s_q[16], s_pw[16], s_ph[16];
    snprintf(s_scale, sizeof(s_scale), "%.6f", scale);
    snprintf(s_q, sizeof(s_q), "%d", quality);
    snprintf(s_pw, sizeof(s_pw), "%d", pw);
    snprintf(s_ph, sizeof(s_ph), "%d", ph);
    char *argv[] = { (char *)DAEMON_BIN, "--capture", s_scale, s_q, s_pw, s_ph, cap_tmp, NULL };

    pid_t pid = 0;
    if (posix_spawn(&pid, DAEMON_BIN, NULL, NULL, argv, environ) != 0) {
        log_msg("fbcap: posix_spawn con thất bại");
        return 30;
    }

    // Chờ con tối đa ~5s (poll WNOHANG). Quá hạn → kill con, coi như chụp thất bại (daemon sống).
    int status = 0, done = 0;
    for (int i = 0; i < 100; i++) {   // 100 × 50ms = 5s
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) { done = 1; break; }
        if (r < 0) break;
        usleep(50 * 1000);
    }
    if (!done) {
        log_msg("fbcap: con chụp quá 5s → kill");
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        unlink(cap_tmp);
        return 31;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        // Con bị SIGKILL (WIFSIGNALED) hoặc lỗi chụp → KHÔNG làm chết daemon; báo thất bại để thử lại.
        if (WIFSIGNALED(status))
            log_msg("fbcap: con chụp bị tín hiệu %d (daemon vẫn sống)", WTERMSIG(status));
        unlink(cap_tmp);
        return 40;
    }

    FILE *f = fopen(cap_tmp, "rb");
    if (!f) return 41;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); unlink(cap_tmp); return 42; }
    unsigned char *b = malloc((size_t)sz);
    size_t got = b ? fread(b, 1, (size_t)sz, f) : 0;
    fclose(f);
    unlink(cap_tmp);
    if (!b || got != (size_t)sz) { free(b); return 43; }
    *outbuf = b; *outlen = got;
    return 0;
}

// ===== RAW FRAMEBUFFER (cho VNC) =====
// Chụp framebuffer → raw BGRA buffer (không encode). Dùng cho VNC server.
int fbcap_raw(unsigned char **outbuf, size_t *outlen, int *out_w, int *out_h, size_t *out_bpr) {
    // Dùng chung cơ chế với fbcap_jpeg, nhưng không encode. Chụp IN-PROCESS (VNC dùng trên máy đủ RAM).

    load_syms();
    if (!pRender) return 10;

    int pw = 375, ph = 667;
    touch_screen_size(&pw, &ph);
    size_t W = (size_t)pw * 2, H = (size_t)ph * 2;
    if (W < 320 || W > 2000) { W = 750; H = 1334; }

    fbcap_gate_enter();

    pthread_mutex_lock(&g_fb_mu);

    // Surface TÁI DÙNG giữa các frame (VNC gọi ~30fps): tạo/hủy mỗi lần gây alloc/free churn +
    // tăng áp lực jetsam. Giữ tĩnh, chỉ cấp lại khi kích thước màn đổi (xoay ngang/dọc).
    static IOSurfaceRef s_src = NULL;
    static size_t s_W = 0, s_H = 0;
    if (!s_src || s_W != W || s_H != H) {
        if (s_src) { CFRelease(s_src); s_src = NULL; }
        s_src = make_surface(W, H);
        s_W = W; s_H = H;
    }
    if (!s_src) {
        pthread_mutex_unlock(&g_fb_mu);
        return 11;
    }

    // Render
    pRender(0, CFSTR("LCD"), s_src, 0, 0);

    // Lock và copy raw data
    IOSurfaceLock(s_src, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(s_src);
    size_t bpr = IOSurfaceGetBytesPerRow(s_src);
    size_t total = bpr * H;

    unsigned char *buf = malloc(total);
    if (buf && base) {
        memcpy(buf, base, total);
    }

    IOSurfaceUnlock(s_src, kIOSurfaceLockReadOnly, NULL);

    pthread_mutex_unlock(&g_fb_mu);

    if (!buf) return 12;

    *outbuf = buf;
    *outlen = total;
    *out_w = (int)W;
    *out_h = (int)H;
    *out_bpr = bpr;

    return 0;
}
