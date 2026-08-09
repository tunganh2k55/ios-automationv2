// ocr_direct.m — Vision OCR chạy trực tiếp trong daemon (không cần tweak)
// Dùng framebuffer capture + Vision framework để OCR mà không phụ thuộc app foreground.
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

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

// C interface cho daemon
// Chụp framebuffer + OCR trực tiếp, không cần tweak
// Trả chuỗi JSON array (caller free), hoặc NULL nếu lỗi (lỗi ghi vào err_out)
char *ocr_direct_run(const char *lang, int rx, int ry, int rw, int rh,
                     int screen_w, int screen_h, char *err_out, size_t err_len) {
    @autoreleasepool {
        // 1) Chụp framebuffer
        unsigned char *jpg = NULL; size_t jpg_len = 0;
        int rc = fbcap_jpeg(&jpg, &jpg_len, 1.0, 85);
        if (rc != 0 || !jpg) {
            if (err_out) snprintf(err_out, err_len, "fbcap failed rc=%d", rc);
            free(jpg);
            return NULL;
        }

        // 2) Decode JPEG → CGImage
        NSData *data = [[NSData alloc] initWithBytesNoCopy:jpg length:jpg_len freeWhenDone:YES];
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!src) {
            if (err_out) snprintf(err_out, err_len, "CGImageSourceCreateWithData failed");
            return NULL;
        }
        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        CFRelease(src);
        if (!cg) {
            if (err_out) snprintf(err_out, err_len, "CGImageSourceCreateImageAtIndex failed");
            return NULL;
        }

        // 3) Chạy Vision OCR
        NSString *langStr = lang ? [NSString stringWithUTF8String:lang] : @"en-US,vi-VN";
        CGRect region = (rw > 0 && rh > 0) ? CGRectMake(rx, ry, rw, rh) : CGRectZero;
        CGFloat W = screen_w > 0 ? screen_w : 390;  // fallback
        CGFloat H = screen_h > 0 ? screen_h : 844;

        NSString *result = run_vision_ocr(cg, W, H, langStr, region);
        CGImageRelease(cg);

        // 4) Kiểm tra lỗi
        if ([result hasPrefix:@"ERR"]) {
            if (err_out) {
                const char *utf = [result UTF8String];
                snprintf(err_out, err_len, "%s", utf ? utf : "unknown error");
            }
            return NULL;
        }

        // 5) Trả JSON (copy để caller free)
        const char *utf = [result UTF8String];
        return utf ? strdup(utf) : NULL;
    }
}
