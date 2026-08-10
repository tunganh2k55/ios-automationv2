#import <Foundation/Foundation.h>
#include "httpd.h"
#include "api.h"
#include "touch.h"
#include "video.h"
#include "scripts.h"
#include "images.h"
#include "license.h"
#include "log.h"
#include "crashlog.h"
#include "fbcap.h"
#include "ocr_direct.h"
#include "vnc.h"
#include <stdlib.h>
#include <string.h>

#define DEFAULT_PORT 8080
#define DEFAULT_USB_PORT 8081   // cổng USB (bind 127.0.0.1) — qua usbmuxd/iproxy; đặt 0 để tắt
#define WEB_DIR_DEFAULT "/var/jb/usr/local/iosauto/web"

int main(int argc, char **argv) {
    @autoreleasepool {
        // CHẾ ĐỘ CHỤP BIỆT LẬP: iosautod --capture <scale> <quality> <pw> <ph> <path>
        // Do fbcap_jpeg_isolated() spawn. Chụp 1 frame ra file rồi THOÁT — KHÔNG khởi động daemon.
        // Nếu bước chụp GPU bị kill cứng, chỉ tiến trình con này chết; daemon cha vẫn sống.
        if (argc >= 7 && strcmp(argv[1], "--capture") == 0) {
            double scale = atof(argv[2]);
            int quality  = atoi(argv[3]);
            int pw = atoi(argv[4]), ph = atoi(argv[5]);
            return fbcap_capture_to_file(argv[6], scale, quality, pw, ph);
        }

        // CHẾ ĐỘ OCR BIỆT LẬP: iosautod --ocr <lang> <rx> <ry> <rw> <rh> <sw> <sh> <out_path>
        // Do ocr_direct_run() spawn. Chụp + Vision OCR → ghi JSON ra file rồi THOÁT.
        // Vision có thể crash → chạy biệt lập để daemon cha vẫn sống.
        if (argc >= 10 && strcmp(argv[1], "--ocr") == 0) {
            const char *lang = argv[2];
            int rx = atoi(argv[3]), ry = atoi(argv[4]);
            int rw = atoi(argv[5]), rh = atoi(argv[6]);
            int sw = atoi(argv[7]), sh = atoi(argv[8]);
            const char *out_path = argv[9];
            return ocr_direct_run_child(lang, rx, ry, rw, rh, sw, sh, out_path);
        }

        int port = DEFAULT_PORT;
        int usb_port = DEFAULT_USB_PORT;
        const char *web_dir = WEB_DIR_DEFAULT;

        // Cho phép override khi chạy tay: iosautod [port] [web_dir] [-u usb_port]
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "-p") && i + 1 < argc) port = atoi(argv[++i]);
            else if (!strcmp(argv[i], "-u") && i + 1 < argc) usb_port = atoi(argv[++i]);
            else if (!strcmp(argv[i], "-w") && i + 1 < argc) web_dir = argv[++i];
            else if (atoi(argv[i]) > 0) port = atoi(argv[i]);
            else web_dir = argv[i];
        }
        const char *env_port = getenv("IOSAUTO_PORT");
        if (env_port && atoi(env_port) > 0) port = atoi(env_port);
        const char *env_usb = getenv("IOSAUTO_USB_PORT");   // "0" = tắt cổng USB
        if (env_usb && env_usb[0]) usb_port = atoi(env_usb);

        log_init();
        crashlog_install();          // bắt tín hiệu + backtrace + phân biệt crash/kill (chẩn đoán)
        iosauto_mem_log("startup");
        api_init(port, usb_port);
        touch_init();
        video_init();
        scripts_init();
        images_init();
        license_init();

        // VNC server (port 5900)
        const char *vnc_pass = getenv("IOSAUTO_VNC_PASS");  // NULL = không mật khẩu
        if (vnc_init(5900, vnc_pass) == 0) {
            log_msg("vnc: server sẵn sàng port 5900");
        }

        log_msg("iosautod khởi động (port=%d, usb_port=%d, web=%s)", port, usb_port, web_dir);

        int rc = httpd_run(port, usb_port, web_dir);
        log_msg("iosautod thoát rc=%d", rc);
        return rc;
    }
}
