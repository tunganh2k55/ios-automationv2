#ifndef IOSAUTO_OCR_DIRECT_H
#define IOSAUTO_OCR_DIRECT_H

#include <stddef.h>

// OCR trực tiếp trong daemon (không cần tweak)
// Chụp framebuffer + Vision OCR, trả JSON array [{text,x,y,w,h,cx,cy,conf}]
// lang: "en-US,vi-VN" (NULL = mặc định)
// rx,ry,rw,rh: vùng giới hạn (point); rw/rh <= 0 = toàn màn
// screen_w/h: kích thước màn (point)
// Trả chuỗi JSON (caller free), hoặc NULL nếu lỗi (lỗi ghi vào err_out)
char *ocr_direct_run(const char *lang, int rx, int ry, int rw, int rh,
                     int screen_w, int screen_h, char *err_out, size_t err_len);

#endif
