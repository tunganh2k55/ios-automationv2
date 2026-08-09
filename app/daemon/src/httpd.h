#ifndef IOSAUTO_HTTPD_H
#define IOSAUTO_HTTPD_H
#include <stddef.h>

typedef struct {
    char method[8];
    char path[512];     // đường dẫn (đã bỏ query string)
    const char *body;   // trỏ vào buffer request, không sở hữu
    size_t body_len;
} http_req;

typedef struct {
    int status;                 // 200, 404, 500…
    const char *content_type;   // vd "application/json"
    char *body;                 // dữ liệu trả về
    size_t body_len;
    int body_owned;             // 1 = httpd sẽ free(body) sau khi gửi
} http_resp;

// api.c cài đặt: xử lý route /api/*. Trả 1 nếu đã xử lý, 0 nếu không phải route API.
int api_handle(const http_req *req, http_resp *resp);

// api.c: stream MJPEG liên tục ra fd (chiếm cả kết nối tới khi client rớt).
void api_stream_mjpeg(int fd);

// Vòng lặp server (blocking). web_dir = thư mục chứa index.html… (có thể NULL).
//   port     : cổng LAN/WiFi, bind 0.0.0.0 (truy cập qua IP máy trong mạng).
//   usb_port : cổng USB, bind 127.0.0.1 (chỉ vào được qua usbmuxd/iproxy). <=0 hoặc == port → tắt.
int httpd_run(int port, int usb_port, const char *web_dir);

#endif
