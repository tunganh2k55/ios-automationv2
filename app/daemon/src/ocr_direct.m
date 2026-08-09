// ocr_direct.m — Vision OCR chạy trực tiếp trong daemon (không cần tweak)
// Dùng framebuffer capture + Vision framework để OCR mà không phụ thuộc app foreground.
// QUAN TRỌNG: Vision OCR có thể crash daemon → chạy trong tiến trình CON (isolated).
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include "log.h"

#define DAEMON_BIN "/var/jb/usr/local/iosauto/bin/iosautod"
#define OCR_TMP_PREFIX "/var/jb/usr/local/iosauto/.ocr."

extern char **environ;

// Prototype từ fbcap.m
extern int fbcap_jpeg(unsigned char **out, size_t *out_len, double scale, int quality);

// JSON escape cho chuỗi text
static void json_esc(NSString *s, NSMutableString *out) {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"':  [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\n': [out appendString:@"\\n"];  break;
            case '\r': [out appendString:@"\\r"];  break;
            case '\t': [out appendString:@"\\t"];  break;
            default: if (c < 0x20) [out appendFormat:@"\\u%04x", c]; else [out appendFormat:@"%C", c]; break;
        }
    }
}

// Chạy Vision OCR trên CGImage, trả JSON array [{text,x,y,w,h,cx,cy,conf}]
// W, H = kích thước POINT màn hình (để quy đổi boundingBox)
// regionPt = vùng giới hạn (point, gốc trên-trái); w/h <= 0 = toàn màn
static NSString *run_vision_ocr(CGImageRef cg, CGFloat W, CGFloat H, NSString *langCSV, CGRect regionPt) {
    @try {
        if (!NSClassFromString(@"VNRecognizeTextRequest") || !NSClassFromString(@"VNImageRequestHandler"))
            return @"ERR Vision framework không khả dụng";

        // Vùng → ROI chuẩn hoá [0..1], lật trục y (Vision gốc dưới-trái)
        CGRect roi = CGRectMake(0, 0, 1, 1);
        BOOL useROI = NO;
        if (regionPt.size.width > 0.5 && regionPt.size.height > 0.5 && W > 0 && H > 0) {
            CGFloat nx = regionPt.origin.x / W, nw = regionPt.size.width / W;
            CGFloat nh = regionPt.size.height / H;
            CGFloat ny = 1.0 - (regionPt.origin.y + regionPt.size.height) / H;
            if (nx < 0) { nw += nx; nx = 0; }
            if (ny < 0) { nh += ny; ny = 0; }
            if (nx + nw > 1) nw = 1 - nx;
            if (ny + nh > 1) nh = 1 - ny;
            if (nw > 0.001 && nh > 0.001 && nx < 1 && ny < 1) { roi = CGRectMake(nx, ny, nw, nh); useROI = YES; }
        }

        NSArray *langs = (langCSV.length ? [langCSV componentsSeparatedByString:@","] : @[@"en-US", @"vi-VN"]);

        // Revision cao nhất máy hỗ trợ
        NSUInteger useRev = 0;
        @try {
            NSIndexSet *revs = [VNRecognizeTextRequest supportedRevisions];
            if (revs.count) useRev = [revs containsIndex:3] ? 3 : revs.lastIndex;
        } @catch (__unused NSException *e) {}

        // Lọc ngôn ngữ theo revision
        @try {
            NSArray *sup = [VNRecognizeTextRequest supportedRecognitionLanguagesForTextRecognitionLevel:VNRequestTextRecognitionLevelAccurate
                                                                                                revision:(useRev ?: 1) error:NULL];
            if (sup.count) {
                NSMutableArray *keep = [NSMutableArray array];
                for (NSString *l in langs) if ([sup containsObject:l]) [keep addObject:l];
                langs = keep.count ? keep : nil;
            }
        } @catch (__unused NSException *e) {}

        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.usesLanguageCorrection = YES;
        if (useRev) @try { req.revision = useRev; } @catch (__unused NSException *e) {}
        @try { req.minimumTextHeight = 0.008; } @catch (__unused NSException *e) {}
        if (langs) @try { req.recognitionLanguages = langs; } @catch (__unused NSException *e) {}
        if (useROI) { @try { req.regionOfInterest = roi; } @catch (__unused NSException *e) { useROI = NO; } }

        NSError *err = nil;
        BOOL ok = [handler performRequests:@[req] error:&err];
        if (!ok || err) {
            // Thử lại không set languages
            VNRecognizeTextRequest *r2 = [[VNRecognizeTextRequest alloc] init];
            r2.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            r2.usesLanguageCorrection = YES;
            if (useRev) @try { r2.revision = useRev; } @catch (__unused NSException *e) {}
            @try { r2.minimumTextHeight = 0.008; } @catch (__unused NSException *e) {}
            if (useROI) { @try { r2.regionOfInterest = roi; } @catch (__unused NSException *e) { useROI = NO; } }
            err = nil; ok = [handler performRequests:@[r2] error:&err];
            req = r2;
        }
        if (!ok || err)
            return [NSString stringWithFormat:@"ERR vision: %@", err.localizedDescription ?: @"performRequests fail"];

        // Build JSON array
        NSMutableString *js = [NSMutableString stringWithString:@"["];
        BOOL first = YES;
        for (VNRecognizedTextObservation *obs in req.results) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            NSString *s = top.string;
            if (!s.length) continue;
            CGRect bb = obs.boundingBox;
            if (useROI) {
                bb.origin.x = roi.origin.x + bb.origin.x * roi.size.width;
                bb.origin.y = roi.origin.y + bb.origin.y * roi.size.height;
                bb.size.width  *= roi.size.width;
                bb.size.height *= roi.size.height;
            }
            int x = (int)lround(bb.origin.x * W);
            int y = (int)lround((1.0 - bb.origin.y - bb.size.height) * H);
            int w = (int)lround(bb.size.width * W);
            int h = (int)lround(bb.size.height * H);
            if (!first) [js appendString:@","];
            first = NO;
            [js appendString:@"{\"text\":\""]; json_esc(s, js);
            [js appendFormat:@"\",\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"cx\":%d,\"cy\":%d,\"conf\":%.2f}",
                x, y, w, h, x + w / 2, y + h / 2, (double)top.confidence];
        }
        [js appendString:@"]"];
        return js;
    } @catch (NSException *e) { return [NSString stringWithFormat:@"ERR ocr exception: %@", e.reason ?: @"?"]; }
}

// ===== TIẾN TRÌNH CON: chạy OCR thực sự (được gọi từ iosautod --ocr) =====
// Chụp framebuffer + Vision OCR → ghi JSON ra file → exit.
// Tiến trình con bị crash thì daemon VẪN SỐNG.
int ocr_direct_run_child(const char *lang, int rx, int ry, int rw, int rh,
                          int screen_w, int screen_h, const char *out_path) {
    @autoreleasepool {
        // 1) Chụp framebuffer (scale=1.0, quality=90 cho OCR rõ)
        unsigned char *jpg = NULL; size_t jpg_len = 0;
        int rc = fbcap_jpeg(&jpg, &jpg_len, 1.0, 90);
        if (rc != 0 || !jpg) {
            free(jpg);
            return 1;
        }

        // 2) Decode JPEG → CGImage
        NSData *data = [[NSData alloc] initWithBytesNoCopy:jpg length:jpg_len freeWhenDone:YES];
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!src) return 2;
        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        CFRelease(src);
        if (!cg) return 3;

        // 3) Chạy Vision OCR
        NSString *langStr = lang ? [NSString stringWithUTF8String:lang] : @"en-US,vi-VN";
        CGRect region = (rw > 0 && rh > 0) ? CGRectMake(rx, ry, rw, rh) : CGRectZero;
        CGFloat W = screen_w > 0 ? screen_w : 390;
        CGFloat H = screen_h > 0 ? screen_h : 844;

        NSString *result = run_vision_ocr(cg, W, H, langStr, region);
        CGImageRelease(cg);

        // 4) Ghi kết quả ra file
        const char *utf = [result UTF8String];
        if (!utf) return 4;
        FILE *f = fopen(out_path, "w");
        if (!f) return 5;
        fputs(utf, f);
        fclose(f);

        return 0;
    }
}

// ===== C interface cho daemon (ISOLATED: spawn tiến trình con) =====
// Spawn tiến trình con chạy OCR → đọc kết quả từ file.
// Con bị crash thì daemon VẪN SỐNG, chỉ trả lỗi.
char *ocr_direct_run(const char *lang, int rx, int ry, int rw, int rh,
                     int screen_w, int screen_h, char *err_out, size_t err_len) {
    // Tạo file tạm duy nhất cho mỗi lần OCR
    static unsigned g_ocr_seq = 0;
    unsigned seq = __sync_fetch_and_add(&g_ocr_seq, 1);
    char tmp_path[256];
    snprintf(tmp_path, sizeof(tmp_path), "%s%u.json", OCR_TMP_PREFIX, seq);
    unlink(tmp_path);

    // Chuẩn bị arguments cho tiến trình con
    char s_lang[80], s_rx[16], s_ry[16], s_rw[16], s_rh[16], s_sw[16], s_sh[16];
    snprintf(s_lang, sizeof(s_lang), "%s", lang ? lang : "en-US,vi-VN");
    snprintf(s_rx, sizeof(s_rx), "%d", rx);
    snprintf(s_ry, sizeof(s_ry), "%d", ry);
    snprintf(s_rw, sizeof(s_rw), "%d", rw);
    snprintf(s_rh, sizeof(s_rh), "%d", rh);
    snprintf(s_sw, sizeof(s_sw), "%d", screen_w);
    snprintf(s_sh, sizeof(s_sh), "%d", screen_h);

    char *argv[] = { (char *)DAEMON_BIN, "--ocr", s_lang, s_rx, s_ry, s_rw, s_rh, s_sw, s_sh, tmp_path, NULL };

    pid_t pid = 0;
    if (posix_spawn(&pid, DAEMON_BIN, NULL, NULL, argv, environ) != 0) {
        if (err_out) snprintf(err_out, err_len, "posix_spawn OCR thất bại");
        return NULL;
    }

    // Chờ tiến trình con tối đa 15s (OCR có thể chậm trên màn nhiều chữ)
    int status = 0, done = 0;
    for (int i = 0; i < 300; i++) {   // 300 × 50ms = 15s
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) { done = 1; break; }
        if (r < 0) break;
        usleep(50 * 1000);
    }
    if (!done) {
        log_msg("ocr: tiến trình con quá 15s → kill");
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        unlink(tmp_path);
        if (err_out) snprintf(err_out, err_len, "OCR timeout (15s)");
        return NULL;
    }

    // Kiểm tra exit status
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        int sig = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        if (sig) {
            log_msg("ocr: tiến trình con bị signal %d (daemon vẫn sống)", sig);
            if (err_out) snprintf(err_out, err_len, "OCR bị crash (signal %d)", sig);
        } else {
            log_msg("ocr: tiến trình con exit code %d", code);
            if (err_out) snprintf(err_out, err_len, "OCR lỗi (code %d)", code);
        }
        unlink(tmp_path);
        return NULL;
    }

    // Đọc kết quả từ file
    FILE *f = fopen(tmp_path, "r");
    if (!f) {
        unlink(tmp_path);
        if (err_out) snprintf(err_out, err_len, "không đọc được file OCR");
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) {
        fclose(f);
        unlink(tmp_path);
        if (err_out) snprintf(err_out, err_len, "file OCR rỗng");
        return NULL;
    }

    char *buf = malloc((size_t)sz + 1);
    if (!buf) {
        fclose(f);
        unlink(tmp_path);
        if (err_out) snprintf(err_out, err_len, "oom");
        return NULL;
    }
    size_t got = fread(buf, 1, (size_t)sz, f);
    buf[got] = '\0';
    fclose(f);
    unlink(tmp_path);

    // Kiểm tra lỗi từ kết quả
    if (strncmp(buf, "ERR", 3) == 0) {
        if (err_out) snprintf(err_out, err_len, "%s", buf);
        free(buf);
        return NULL;
    }

    return buf;
}
