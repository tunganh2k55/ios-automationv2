#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include "imgmatch.h"
#include "images.h"
#include "fbcap.h"
#include "touch.h"
#include "log.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

#define IMAGES_DIR "/var/jb/usr/local/iosauto/images"
#define MATCH_SCALE 0.5      // thu nhỏ thêm (trên nền fbcap 0.7) cho nhanh — áp CHUNG cho cả 2 ảnh
#define HAYSTACK_FB 0.7      // khớp scale với /api/screenshot (fbcap 0.7)

// Decode dữ liệu ảnh (JPEG/PNG) → buffer XÁM (row-major, stride=w), thu nhỏ theo MATCH_SCALE.
// caller free(). Trả NULL nếu lỗi.
static uint8_t *decode_gray(NSData *d, int *ow, int *oh) {
    if (!d) return NULL;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return NULL;
    size_t w0 = CGImageGetWidth(img), h0 = CGImageGetHeight(img);
    size_t w = (size_t)lround((double)w0 * MATCH_SCALE);
    size_t h = (size_t)lround((double)h0 * MATCH_SCALE);
    if (w < 1) w = 1; if (h < 1) h = 1;
    uint8_t *buf = calloc(w * h, 1);
    if (!buf) { CGImageRelease(img); return NULL; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w, cs, kCGImageAlphaNone);
    int ok = 0;
    if (ctx) { CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img); CGContextRelease(ctx); ok = 1; }
    CGColorSpaceRelease(cs); CGImageRelease(img);
    if (!ok) { free(buf); return NULL; }
    *ow = (int)w; *oh = (int)h;
    return buf;
}

// ===== Cache HAYSTACK XÁM (tái dùng 1 frame cho nhiều template trong cùng vòng logic) =====
// Nhiều lời gọi tapImage/waitForImage liên tiếp trong khoảng TTL sẽ DÙNG LẠI frame này thay vì
// chụp mới → giảm mạnh số lần render-server capture (nguyên nhân chính gây kill).
static pthread_mutex_t g_hay_mu = PTHREAD_MUTEX_INITIALIZER;
static uint8_t *g_hay = NULL;
static int g_hw = 0, g_hh = 0;
static long long g_hay_ms = 0;

static long long im_mono_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Trả BẢN SAO haystack xám hiện tại (caller free) + kích thước. Tái dùng nếu frame còn mới (< TTL);
// nếu hết hạn → chụp mới qua fbcap_jpeg_isolated (đã đi qua cổng min-interval). NULL nếu chụp lỗi.
static uint8_t *haystack_gray_copy(int *ow, int *oh) {
    pthread_mutex_lock(&g_hay_mu);
    long long now = im_mono_ms();
    int fresh = (g_hay && (now - g_hay_ms) <= fbcap_frame_ttl_ms());
    if (!fresh) {
        unsigned char *jpg = NULL; size_t jn = 0;
        if (fbcap_jpeg_isolated(&jpg, &jn, HAYSTACK_FB, 70) == 0 && jpg) {
            int w = 0, h = 0;
            uint8_t *g = decode_gray([NSData dataWithBytes:jpg length:jn], &w, &h);
            free(jpg);
            if (g) { free(g_hay); g_hay = g; g_hw = w; g_hh = h; g_hay_ms = im_mono_ms();
                     log_msg("imgmatch: CHỤP MỚI %dx%d", w, h); }
            else log_msg("imgmatch: decode haystack lỗi");
        } else {
            log_msg("imgmatch: chụp thất bại (con lỗi/kill) → dùng frame cũ nếu có");
        }
    } else {
        log_msg("imgmatch: tái dùng frame cache (tuổi %lldms)", now - g_hay_ms);
    }
    uint8_t *copy = NULL;
    if (g_hay) {
        size_t n = (size_t)g_hw * g_hh;
        copy = malloc(n);
        if (copy) { memcpy(copy, g_hay, n); *ow = g_hw; *oh = g_hh; }
    }
    pthread_mutex_unlock(&g_hay_mu);
    return copy;
}

int imgmatch_find(const char *img_name, int rx, int ry, int rw, int rh,
                  int wantIdx, double threshold, int *out_cx, int *out_cy, double *out_score) {
    if (!img_name || !images_valid_name(img_name)) return 0;
    if (wantIdx < 1) wantIdx = 1;
    if (threshold <= 0) threshold = 0.8;

    @autoreleasepool {
        // 1) Ảnh mẫu (template)
        char tpath[600];
        snprintf(tpath, sizeof(tpath), "%s/%s", IMAGES_DIR, img_name);
        int Tw = 0, Th = 0;
        uint8_t *T = decode_gray([NSData dataWithContentsOfFile:@(tpath)], &Tw, &Th);
        if (!T || Tw < 2 || Th < 2) { free(T); return 0; }

        // 2) Haystack = màn hình hiện tại, lấy qua CACHE (tái dùng frame trong TTL, chụp qua cổng
        //    min-interval). Nhiều template kiểm liên tiếp → 1 lần chụp. Chụp lỗi → bỏ qua lần này.
        int Hw = 0, Hh = 0;
        uint8_t *H = haystack_gray_copy(&Hw, &Hh);
        if (!H || Tw > Hw || Th > Hh) { free(H); free(T); return 0; }

        long M = (long)Tw * Th;

        // 3) Template zero-mean + chuẩn ||Tp||
        double sumT = 0; for (long i = 0; i < M; i++) sumT += T[i];
        double meanT = sumT / (double)M;
        double *Tp = malloc(sizeof(double) * M);
        if (!Tp) { free(H); free(T); return 0; }   // OOM: phải chặn TRƯỚC vòng ghi Tp[i] (kẻo NULL-write crash)
        double normT2 = 0;
        for (long i = 0; i < M; i++) { double v = (double)T[i] - meanT; Tp[i] = v; normT2 += v * v; }
        double normT = sqrt(normT2);
        if (normT < 1e-6) { free(Tp); free(H); free(T); return 0; }   // template phẳng → bỏ

        // 4) Integral image của haystack (sum & sqSum) → tính mean/var mỗi cửa sổ O(1)
        int IW = Hw + 1, IH = Hh + 1;
        double *II = calloc((size_t)IW * IH, sizeof(double));
        double *II2 = calloc((size_t)IW * IH, sizeof(double));
        if (!II || !II2 || !Tp) { free(II); free(II2); free(Tp); free(H); free(T); return 0; }
        for (int y = 0; y < Hh; y++) {
            double rowS = 0, rowS2 = 0;
            for (int x = 0; x < Hw; x++) {
                double v = (double)H[(long)y * Hw + x];
                rowS += v; rowS2 += v * v;
                II[(long)(y + 1) * IW + (x + 1)]  = II[(long)y * IW + (x + 1)]  + rowS;
                II2[(long)(y + 1) * IW + (x + 1)] = II2[(long)y * IW + (x + 1)] + rowS2;
            }
        }
        #define RECT(A, x0, y0, x1, y1) (A[(long)(y1)*IW+(x1)] - A[(long)(y0)*IW+(x1)] - A[(long)(y1)*IW+(x0)] + A[(long)(y0)*IW+(x0)])

        // 5) Vùng giới hạn (điểm màn → pixel haystack). Ràng buộc TÂM match nằm trong vùng.
        int spw = 375, sph = 667; touch_screen_size(&spw, &sph);
        double sx = (double)Hw / (double)spw, sy = (double)Hh / (double)sph;
        int useRegion = (rw > 0 && rh > 0);
        int cbx0 = 0, cby0 = 0, cbx1 = Hw, cby1 = Hh;
        if (useRegion) {
            cbx0 = (int)floor(rx * sx); cby0 = (int)floor(ry * sy);
            cbx1 = (int)ceil((rx + rw) * sx); cby1 = (int)ceil((ry + rh) * sy);
        }

        // 6) Bản đồ ZNCC
        int MW = Hw - Tw + 1, MH = Hh - Th + 1;
        float *map = malloc(sizeof(float) * (size_t)MW * MH);
        if (!map) { free(II); free(II2); free(Tp); free(H); free(T); return 0; }
        for (long i = 0; i < (long)MW * MH; i++) map[i] = -2.0f;
        for (int py = 0; py < MH; py++) {
            int cy = py + Th / 2;
            if (useRegion && (cy < cby0 || cy > cby1)) continue;
            for (int px = 0; px < MW; px++) {
                int cx = px + Tw / 2;
                if (useRegion && (cx < cbx0 || cx > cbx1)) continue;
                double wSum  = RECT(II,  px, py, px + Tw, py + Th);
                double wSum2 = RECT(II2, px, py, px + Tw, py + Th);
                double denomW = wSum2 - wSum * wSum / (double)M;   // = ||W'||^2
                if (denomW < 1e-6) continue;
                // cross = Σ W(i,j)*Tp(i,j)  (Tp zero-mean nên không cần trừ mean của W)
                double cross = 0;
                for (int ty = 0; ty < Th; ty++) {
                    const uint8_t *hrow = &H[(long)(py + ty) * Hw + px];
                    const double *trow = &Tp[(long)ty * Tw];
                    for (int tx = 0; tx < Tw; tx++) cross += (double)hrow[tx] * trow[tx];
                }
                double ncc = cross / (sqrt(denomW) * normT);
                map[(long)py * MW + px] = (float)ncc;
            }
        }

        // 7) Non-max suppression: lấy đỉnh thứ wantIdx (giảm dần), triệt tiêu lân cận Tw×Th quanh mỗi đỉnh
        int found = 0; double bestScore = 0; int bcx = 0, bcy = 0;
        int supW = Tw > 2 ? Tw : 2, supH = Th > 2 ? Th : 2;
        for (int k = 0; k < wantIdx; k++) {
            long bi = -1; float bv = (float)threshold - 1e-6f;
            for (long i = 0; i < (long)MW * MH; i++) if (map[i] > bv) { bv = map[i]; bi = i; }
            if (bi < 0) break;
            int bpx = (int)(bi % MW), bpy = (int)(bi / MW);
            if (k == wantIdx - 1) {
                bestScore = bv; bcx = bpx + Tw / 2; bcy = bpy + Th / 2; found = 1;
                break;
            }
            // triệt tiêu vùng quanh đỉnh vừa lấy để tìm đỉnh kế
            for (int yy = bpy - supH / 2; yy <= bpy + supH / 2; yy++)
                for (int xx = bpx - supW / 2; xx <= bpx + supW / 2; xx++)
                    if (xx >= 0 && xx < MW && yy >= 0 && yy < MH) map[(long)yy * MW + xx] = -2.0f;
        }

        int cx_pt = 0, cy_pt = 0;
        if (found) {
            cx_pt = (int)lround((double)bcx * (double)spw / (double)Hw);
            cy_pt = (int)lround((double)bcy * (double)sph / (double)Hh);
            if (out_cx) *out_cx = cx_pt;
            if (out_cy) *out_cy = cy_pt;
            if (out_score) *out_score = bestScore;
        }
        #undef RECT
        free(map); free(II); free(II2); free(Tp); free(H); free(T);
        return found;
    }
}
