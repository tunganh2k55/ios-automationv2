"use strict";
// ============================================================================
//  Bảng tra HÀM LUA — đọc doc + bấm hàm ra ví dụ chạy thử.
//  Dữ liệu bám theo daemon/src/lua_bind.c + luaext.m + crane.m (kèm bảng crane.*).
//  Dùng cầu nối window.iosauto.{insertCode, runCode, isRunning} do app.js cung cấp.
// ============================================================================
(function () {
  const $ = (s) => document.querySelector(s);

  // Mỗi nhóm mang một màu ngữ nghĩa: màu = LOẠI hành động (structure is information).
  const GROUPS = [
    {
      cat: "Chạm & vuốt", color: "#818cf8",
      fns: [
        {
          name: "tap", sig: "tap(x, y)",
          desc: "Chạm 1 điểm theo toạ độ logic (điểm), gốc trên-trái.",
          params: [["x, y", "toạ độ điểm — xem kích thước màn ở góc trên (vd 375×667)"]],
          ret: "không trả về",
          ex: `-- Chạm vào giữa màn hình\ntap(187, 333)`,
        },
        {
          name: "swipe", sig: "swipe(x1, y1, x2, y2 [, dur])",
          desc: "Vuốt từ (x1,y1) tới (x2,y2). dur = thời lượng cử chỉ (giây, mặc định 0.3) — giống ngón tay thật: dur NHỎ = flick nhanh, cuộn XA hơn quãng kéo (quán tính); dur LỚN = kéo rê chậm, cuộn đúng quãng kéo.",
          params: [
            ["x1, y1", "điểm bắt đầu"],
            ["x2, y2", "điểm kết thúc"],
            ["dur", "0.05–3 giây · 0.1 = flick mạnh (xa ~3×) · 0.3 = thường · 1.5+ = kéo chậm chính xác"],
          ],
          ret: "không trả về",
          ex: `-- Flick nhanh cuộn xa (quán tính lớn)\nswipe(187, 550, 187, 200, 0.1)\n\n-- Kéo chậm, cuộn đúng bằng quãng kéo\nswipe(187, 550, 187, 200, 1.5)`,
        },
      ],
    },
    {
      cat: "Nhập liệu", color: "#38bdf8",
      fns: [
        {
          name: "input", sig: 'input("chữ")',
          desc: "Gõ chuỗi vào ô nhập ĐANG focus trên thiết bị (tap vào ô trước).",
          params: [["chữ", "nội dung cần gõ (hỗ trợ Unicode / tiếng Việt)"]],
          ret: "không trả về",
          ex: `-- Mở Ghi chú, tap ô soạn thảo rồi gõ chữ\nlaunch("com.apple.mobilenotes")\nsleep(1.5)\ntap(187, 140)\ninput("Xin chào từ iOSAuto")`,
        },
      ],
    },
    {
      cat: "Ứng dụng", color: "#a78bfa",
      fns: [
        {
          name: "launch", sig: 'launch("bundleId")',
          desc: "Mở app theo bundle id. Danh sách app: Helper › 📱 App đã cài.",
          params: [["bundleId", 'vd "com.apple.Preferences"']],
          ret: "true nếu mở được, false nếu lỗi",
          ex: `-- Mở app Cài đặt\nlocal ok = launch("com.apple.Preferences")\nprint("mở được:", ok)`,
        },
        {
          name: "kill", sig: 'kill("bundleId")',
          desc: "Tắt hẳn app đang chạy nền.",
          params: [["bundleId", "bundle id của app cần tắt"]],
          ret: "true nếu tắt được, false nếu lỗi",
          ex: `-- Tắt app Cài đặt\nkill("com.apple.Preferences")`,
        },
        {
          name: "clearAppData", sig: 'clearAppData("bundleId")',
          desc: "Xoá TOÀN BỘ dữ liệu app (reset về như mới cài — MẤT đăng nhập). Tự kill app trước, xoá sạch Documents/Library/tmp (gồm cả Preferences), giữ container. Khác crane.clearData (chỉ dọn cache, giữ đăng nhập).",
          params: [["bundleId", 'vd "com.facebook.Facebook"']],
          ret: "true, số_mục_đã_xoá  ·  hoặc false, lỗi",
          ex: `-- Reset dữ liệu Facebook rồi mở lại\nlocal ok, n = clearAppData("com.facebook.Facebook")\nlog("đã xoá " .. tostring(n) .. " mục")\nif ok then launch("com.facebook.Facebook") end`,
        },
        {
          name: "home", sig: "home()",
          desc: "Về màn hình chính (như bấm nút Home).",
          params: [],
          ret: "không trả về",
          ex: `-- Về màn hình chính\nhome()`,
        },
        {
          name: "wake", sig: "wake()",
          desc: "Đánh thức / bật màn hình nếu đang tắt.",
          params: [],
          ret: "không trả về",
          ex: `-- Bật màn rồi chờ nửa giây\nwake()\nsleep(0.5)`,
        },
      ],
    },
    {
      cat: "Luồng & log", color: "#fbbf24",
      fns: [
        {
          name: "sleep", sig: "sleep(giây)",
          desc: "Tạm dừng script. Nhận số thập phân. Dừng được giữa chừng bằng nút ⏹.",
          params: [["giây", "thời gian chờ, vd 1.5"]],
          ret: "không trả về",
          ex: `-- Chờ 2 giây rồi in\nsleep(2)\nprint("đã chờ xong")`,
        },
        {
          name: "setCaptureDelay", sig: "setCaptureDelay(giây)",
          desc: "Đặt khoảng nghỉ GIỮA các lần thử (tries) TRONG một lời gọi waitForImage/tapImage/tapText… Mặc định 1s.",
          params: [["giây", "0–10; vd 0.5"]],
          ret: "delay đã đặt (giây)",
          ex: `setCaptureDelay(0.6)\ntapImage("op1-ok.png", 10, nil, 1)`,
        },
        {
          name: "setCaptureInterval", sig: "setCaptureInterval(minGiây [, ttlGiây])",
          desc: "CỔNG CHỤP TOÀN CỤC (chống crash): min = tối thiểu giữa 2 lần CHỤP THẬT bất kỳ khi " +
                "script đang chạy (áp cho cả matching lẫn stream). ttl = frame vừa chụp còn 'mới' bao lâu → " +
                "nhiều lời gọi image liên tiếp DÙNG LẠI 1 frame thay vì chụp lại. Mặc định min=1.2s, ttl=1.0s.",
          params: [
            ["minGiây", "tối thiểu giữa 2 lần chụp thật (vd 1.2–1.5). Máy yếu để cao hơn."],
            ["ttlGiây", "tuỳ chọn — thời gian tái dùng frame (vd 0.8–1.0)"],
          ],
          ret: "true",
          ex: `-- Máy A13 yếu: chụp thật cách nhau ≥1.5s, tái dùng frame trong 1s\nsetCaptureInterval(1.5, 1.0)`,
        },
        {
          name: "log", sig: "log(...)",
          desc: "Ghi 1 dòng vào khung log. Nhận mọi kiểu (chuỗi/số/bool/nil).",
          params: [["...", "một hoặc nhiều giá trị"]],
          ret: "không trả về",
          ex: `log("Bắt đầu chạy")\nlog("x =", 10, "ok?", true)`,
        },
        {
          name: "toast", sig: 'toast("noi dung" [, giay=2])',
          desc: "Hien thi thong bao noi tren man hinh thiet bi.",
          params: [
            ["noi dung", "chuoi can hien thi"],
            ["giay", "thoi gian hien thi, mac dinh 2s"],
          ],
          ret: "true neu gui duoc",
          ex: `toast("Dang chay buoc login", 2)`,
        },
        {
          name: "print", sig: "print(...)",
          desc: "In ra log, các tham số cách nhau bằng dấu cách (như Lua chuẩn).",
          params: [["...", "một hoặc nhiều giá trị"]],
          ret: "không trả về",
          ex: `print("Hello", 123, true)`,
        },
      ],
    },
    {
      cat: "Thị giác", color: "#2dd4bf",
      fns: [
        {
          name: "dump", sig: "dump()",
          desc: "Lấy cây giao diện (XML) của app đang mở — để dò toạ độ / tên nút.",
          params: [],
          ret: "chuỗi XML",
          ex: `-- In cây view của app foreground\nlocal xml = dump()\nprint(xml)`,
        },
        {
          name: "ocr", sig: "ocr([lang])",
          desc: "Nhận dạng chữ trên màn → JSON [{text, x, y, w, h, cx, cy, conf}].",
          params: [["lang", 'ngôn ngữ, vd "en-US,vi-VN" (mặc định Anh+Việt)']],
          ret: "chuỗi JSON các dòng chữ",
          ex: `-- Đọc chữ trên màn hiện tại\nlocal json = ocr("en-US,vi-VN")\nprint(json)`,
        },
        {
          name: "ocrTextRegion", sig: "ocrTextRegion(x, y, w, h [, lang])",
          desc: "Đọc CHỮ trong khung (x, y, w, h) → chuỗi các dòng nối bằng xuống dòng. Chỉ nhận dạng TRONG vùng (vùng nhỏ → nhanh hơn nhiều so với OCR cả màn).",
          params: [
            ["x, y, w, h", "vùng giới hạn (điểm) cần đọc chữ"],
            ["lang", 'ngôn ngữ OCR, vd "en-US,vi-VN"'],
          ],
          ret: "chuỗi các dòng chữ (rỗng nếu không có)",
          ex: `-- Đọc chữ ở NỬA TRÊN màn hình\nlocal txt = ocrTextRegion(0, 0, 375, 333)\nprint(txt)`,
        },
      ],
    },
    {
      cat: "Chờ xuất hiện", color: "#22d3ee",
      fns: [
        {
          name: "waitForText", sig: 'waitForText("chữ" [, tries=1 [, delay [, lang [, x, y, w, h]]]])',
          desc: "Chụp+OCR MỖI LẦN 1 tấm để tìm “chữ” (KHÔNG chạm). Lặp tối đa `tries` lần, nghỉ `delay` giây sau mỗi lần.",
          params: [
            ["chữ", "đoạn chữ cần chờ (không phân biệt hoa/thường với ASCII)"],
            ["tries", "số lần chụp+dò, mặc định 1 (chỉ chụp 1 lần)"],
            ["delay", "nghỉ giữa các lần chụp (giây), mặc định = setCaptureDelay"],
            ["lang", 'ngôn ngữ OCR, vd "en-US,vi-VN"'],
            ["x, y, w, h", "chỉ tìm trong vùng này (tuỳ chọn)"],
          ],
          ret: "true, cx, cy nếu xuất hiện · false nếu hết tries",
          ex: `-- Chờ chữ "Đăng nhập" — dò tối đa 10 lần, mỗi lần cách 0.5s\nif waitForText("Đăng nhập", 10, 0.5) then\n  print("đã thấy")\nend`,
        },
        {
          name: "waitForImage", sig: 'waitForImage("ten.jpg" [, tries=1 [, delay [, threshold [, x, y, w, h]]]])',
          desc: "Chụp+khớp ảnh mẫu MỖI LẦN 1 tấm (KHÔNG chạm). Lặp tối đa `tries` lần, nghỉ `delay` giây sau mỗi lần.",
          params: [
            ["ten.jpg", "tên ảnh đã lưu"],
            ["tries", "số lần chụp+dò, mặc định 1"],
            ["delay", "nghỉ giữa các lần chụp (giây), mặc định = setCaptureDelay"],
            ["threshold", "ngưỡng khớp 0–1, mặc định 0.8"],
            ["x, y, w, h", "chỉ dò trong vùng này (tuỳ chọn)"],
          ],
          ret: "true, cx, cy, score nếu thấy · false nếu hết tries",
          ex: `-- Dò ảnh loading_done.jpg tối đa 15 lần, mỗi lần cách 0.4s\nlocal ok = waitForImage("loading_done.jpg", 15, 0.4, 0.85)\nprint("xong:", ok)`,
        },
      ],
    },
    {
      cat: "Chạm theo chữ", color: "#fb7185",
      fns: [
        {
          name: "tapText", sig: 'tapText("chữ" [, tries=1 [, delay [, lang]]])',
          desc: "Chụp+OCR MỖI LẦN 1 tấm; thấy dòng CHỨA “chữ” thì chạm. Lặp tối đa `tries` lần, nghỉ `delay` giây sau mỗi lần.",
          params: [
            ["chữ", "đoạn chữ cần tìm (không phân biệt hoa/thường với ASCII)"],
            ["tries", "số lần chụp+dò, mặc định 1"],
            ["delay", "nghỉ giữa các lần chụp (giây), mặc định = setCaptureDelay"],
            ["lang", "ngôn ngữ OCR, vd \"en-US,vi-VN\""],
          ],
          ret: "true, cx, cy nếu chạm được · false nếu hết tries",
          ex: `-- Mở Cài đặt rồi chạm dòng "Wi-Fi" (dò tối đa 8 lần)\nlaunch("com.apple.Preferences")\nsleep(1.5)\nlocal ok, x, y = tapText("Wi-Fi", 8, 0.5)\nprint("chạm:", ok, x, y)`,
        },
        {
          name: "tapTextIndex", sig: 'tapTextIndex("chữ" [, tries=1 [, index=1 [, delay [, lang]]]])',
          desc: "Như tapText nhưng chọn lần xuất hiện thứ index (1 = đầu tiên).",
          params: [
            ["chữ", "đoạn chữ cần tìm"],
            ["tries", "số lần chụp+dò, mặc định 1"],
            ["index", "thứ tự occurrence, mặc định 1"],
            ["delay", "nghỉ giữa các lần chụp (giây)"],
          ],
          ret: "true, cx, cy · hoặc false",
          ex: `-- Chạm chữ "Chung" lần thứ 2, dò tối đa 6 lần\ntapTextIndex("Chung", 6, 2, 0.5)`,
        },
        {
          name: "tapTextRegion", sig: 'tapTextRegion("chữ", x, y, w, h [, tries=1 [, delay [, index=1 [, lang]]]])',
          desc: "Chỉ tìm & chạm “chữ” nằm trong khung chữ nhật (x, y, w, h). Chụp mỗi lần 1 tấm, lặp tối đa `tries`. Chỉ nhận dạng TRONG vùng (vùng nhỏ → nhanh hơn nhiều so với OCR cả màn).",
          params: [
            ["chữ", "đoạn chữ cần tìm"],
            ["x, y, w, h", "vùng giới hạn (điểm) để dò"],
            ["tries", "số lần chụp+dò, mặc định 1"],
            ["delay", "nghỉ giữa các lần chụp (giây)"],
            ["index", "thứ tự occurrence trong vùng, mặc định 1"],
          ],
          ret: "true, cx, cy · hoặc false",
          ex: `-- Tìm chữ "Chung" ở NỬA TRÊN màn, dò tối đa 6 lần\ntapTextRegion("Chung", 0, 0, 375, 333, 6, 0.5)\n\n-- CẦN NHANH? Nới cổng chụp + rút delay (máy khoẻ; máy yếu dễ bị GPU kill):\nsetCaptureInterval(0.3, 0.3)\nsetCaptureDelay(0.2)\ntapTextRegion("Chung", 0, 0, 375, 333, 10, 0.2)`,
        },
      ],
    },
    {
      cat: "Chạm theo ảnh", color: "#4ade80",
      fns: [
        {
          name: "tapImage", sig: 'tapImage("ten.jpg" [, tries=1 [, delay [, threshold]]])',
          desc: "Chụp+khớp ảnh mẫu MỖI LẦN 1 tấm; khớp thì chạm. Lặp tối đa `tries` lần, nghỉ `delay` giây sau mỗi lần. Lưu ảnh ở Helper › 📸.",
          params: [
            ["ten.jpg", "tên ảnh đã lưu (dùng nút 📋 để copy tên)"],
            ["tries", "số lần chụp+dò, mặc định 1 (chỉ chụp 1 lần)"],
            ["delay", "nghỉ giữa các lần chụp (giây), mặc định = setCaptureDelay"],
            ["threshold", "ngưỡng khớp 0–1, mặc định 0.8 (cao = khắt khe hơn)"],
          ],
          ret: "true, cx, cy, score nếu thấy · false nếu hết tries",
          ex: `-- Dò ảnh nut_like.jpg tối đa 8 lần, mỗi lần cách 0.4s\nlocal ok = tapImage("nut_like.jpg", 8, 0.4, 0.85)\nprint("thấy ảnh:", ok)`,
        },
        {
          name: "tapImageIndex", sig: 'tapImageIndex("ten.jpg" [, tries=1 [, index=1 [, delay [, threshold]]]])',
          desc: "Như tapImage nhưng chọn ảnh khớp thứ index trên màn.",
          params: [
            ["ten.jpg", "tên ảnh đã lưu"],
            ["tries", "số lần chụp+dò, mặc định 1"],
            ["index", "thứ tự khớp, mặc định 1"],
            ["delay", "nghỉ giữa các lần chụp (giây)"],
            ["threshold", "ngưỡng khớp, mặc định 0.8"],
          ],
          ret: "true, cx, cy · hoặc false",
          ex: `-- Chạm ảnh tim.jpg khớp thứ 2, dò tối đa 6 lần\ntapImageIndex("tim.jpg", 6, 2, 0.5, 0.85)`,
        },
        {
          name: "tapImageRegion", sig: 'tapImageRegion("ten.jpg", x, y, w, h [, tries=1 [, delay [, threshold]]])',
          desc: "Chỉ dò ảnh trong khung (x, y, w, h) rồi chạm. Chụp mỗi lần 1 tấm, lặp tối đa `tries`.",
          params: [
            ["ten.jpg", "tên ảnh đã lưu"],
            ["x, y, w, h", "vùng giới hạn (điểm)"],
            ["tries", "số lần chụp+dò, mặc định 1"],
            ["delay", "nghỉ giữa các lần chụp (giây)"],
            ["threshold", "ngưỡng khớp, mặc định 0.8"],
          ],
          ret: "true, cx, cy · hoặc false",
          ex: `-- Dò ảnh góc dưới-phải, tối đa 6 lần\ntapImageRegion("nut_gui.jpg", 250, 500, 125, 167, 6, 0.5, 0.85)`,
        },
      ],
    },
    {
      cat: "Clipboard & URL", color: "#f472b6",
      fns: [
        {
          name: "copyText", sig: 'copyText("text")',
          desc: "Đặt nội dung vào clipboard (bộ nhớ tạm) của iPhone.",
          params: [["text", "chuỗi cần sao chép (hỗ trợ nhiều dòng / Unicode)"]],
          ret: "true nếu OK",
          ex: `-- Sao chép rồi dán vào ô nhập\ncopyText("Xin chào từ iOSAuto")\ntap(187, 140)\ninput(clipText())`,
        },
        {
          name: "clipText", sig: "clipText()",
          desc: "Lấy nội dung đang có trong clipboard của iPhone.",
          params: [],
          ret: "chuỗi trong clipboard · hoặc nil, lỗi",
          ex: `-- In nội dung đang copy\nprint(clipText())`,
        },
        {
          name: "openUrl", sig: 'openUrl("https://…")',
          desc: "Mở một URL (web / deeplink app) như bấm vào link.",
          params: [["url", 'vd "https://google.com" hoặc "tg://…"']],
          ret: "true nếu mở được",
          ex: `-- Mở trang web\nopenUrl("https://example.com")`,
        },
      ],
    },
    {
      cat: "Dữ liệu", color: "#c084fc",
      fns: [
        {
          name: "convertBase64", sig: "convertBase64(chuỗi [, giải_mã])",
          desc: "Mã hoá base64 (mặc định). Truyền true ở tham số 2 để GIẢI mã.",
          params: [
            ["chuỗi", "dữ liệu cần mã hoá / giải mã"],
            ["giải_mã", "true = giải mã base64 → chuỗi gốc"],
          ],
          ret: "chuỗi kết quả (giải mã lỗi → nil, lỗi)",
          ex: `local e = convertBase64("hello")\nprint(e)                      -- aGVsbG8=\nprint(convertBase64(e, true))  -- hello`,
        },
        {
          name: "jsonDecode", sig: "jsonDecode(chuỗi)",
          desc: "Phân tích chuỗi JSON → bảng Lua.",
          params: [["chuỗi", "chuỗi JSON hợp lệ"]],
          ret: "bảng/giá trị Lua · hoặc nil, lỗi",
          ex: `local t = jsonDecode('{"name":"An","age":20}')\nprint(t.name, t.age)`,
        },
        {
          name: "jsonEncode", sig: "jsonEncode(bảng [, đẹp])",
          desc: "Chuyển bảng Lua → chuỗi JSON. Truyền true để in đẹp (xuống dòng).",
          params: [
            ["bảng", "bảng/mảng Lua"],
            ["đẹp", "true = định dạng đẹp"],
          ],
          ret: "chuỗi JSON · hoặc nil, lỗi",
          ex: `local s = jsonEncode({name="An", age=20})\nprint(s)`,
        },
      ],
    },
    {
      cat: "Mạng & thiết bị", color: "#34d399",
      fns: [
        {
          name: "httpGet", sig: 'httpGet(url [, headers])',
          desc: "Gửi HTTP(S) GET. headers là bảng {tên = giá_trị} tuỳ chọn.",
          params: [
            ["url", 'vd "https://api.example.com/x"'],
            ["headers", "bảng header tuỳ chọn"],
          ],
          ret: "nội_dung, mã_trạng_thái · hoặc nil, lỗi",
          ex: `local body, code = httpGet("https://api.ipify.org")\nprint(code, body)`,
        },
        {
          name: "httpPost", sig: 'httpPost(url [, body [, contentType [, headers]]])',
          desc: "Gửi HTTP(S) POST. contentType mặc định form-urlencoded.",
          params: [
            ["url", "địa chỉ đích"],
            ["body", "nội dung gửi lên"],
            ["contentType", 'vd "application/json"'],
            ["headers", "bảng header tuỳ chọn"],
          ],
          ret: "nội_dung, mã_trạng_thái · hoặc nil, lỗi",
          ex: `local body, code = httpPost("https://httpbin.org/post",\n  jsonEncode({a=1}), "application/json")\nprint(code, body)`,
        },
        {
          name: "getDeviceInfo", sig: "getDeviceInfo()",
          desc: "Thông tin máy: {name, model, ios, screenW, screenH}.",
          params: [],
          ret: "bảng thông tin thiết bị",
          ex: `local d = getDeviceInfo()\nprint(d.name, d.model, d.ios)`,
        },
        {
          name: "getSN", sig: "getSN()",
          desc: "Serial number (SN) của thiết bị, lấy qua MobileGestalt. Rỗng nếu không lấy được.",
          params: [],
          ret: "chuỗi serial (rỗng nếu không có)",
          ex: `print("Serial:", getSN())`,
        },
        {
          name: "getLocalIp", sig: "getLocalIp()",
          desc: "Địa chỉ IP nội bộ (LAN) của iPhone, ưu tiên Wi‑Fi (en0).",
          params: [],
          ret: "chuỗi IP · hoặc nil, lỗi",
          ex: `print("IP LAN:", getLocalIp())`,
        },
        {
          name: "getPublicIp", sig: "getPublicIp()",
          desc: "IP công cộng (gọi api.ipify.org qua mạng).",
          params: [],
          ret: "chuỗi IP · hoặc nil, lỗi",
          ex: `print("IP public:", getPublicIp())`,
        },
        {
          name: "setProxySystem", sig: "setProxySystem(host, port)",
          desc: "Đặt proxy HTTP/HTTPS TOÀN MÁY (mọi app đi qua host:port).",
          params: [
            ["host", 'IP/tên máy proxy, vd "192.168.1.50"'],
            ["port", "cổng proxy, vd 8888"],
          ],
          ret: "true nếu OK · hoặc false, lỗi",
          ex: `-- Bật proxy về máy tính chạy MITM\nsetProxySystem("192.168.1.50", 8888)`,
        },
        {
          name: "clearProxySystem", sig: "clearProxySystem()",
          desc: "Tắt proxy hệ thống (về “Tắt”).",
          params: [],
          ret: "true nếu OK · hoặc false, lỗi",
          ex: `clearProxySystem()`,
        },
      ],
    },
    {
      cat: "Crane (đa tài khoản)", color: "#fb923c",
      fns: [
        {
          name: "crane.list", sig: 'crane.list([bundleId])',
          desc: "Liệt kê container (tài khoản) của app. Cần cài tweak Crane (opa334).",
          params: [["bundleId", 'vd "com.facebook.Facebook" — bỏ trống = tất cả']],
          ret: "mảng {name, id} · hoặc nil, lỗi",
          ex: `local c = crane.list("com.facebook.Facebook")\nfor i, v in ipairs(c) do\n  log(v.name .. " (" .. v.id .. ")")\nend`,
        },
        {
          name: "crane.switch", sig: 'crane.switch(bundleId, tênHoặcId)',
          desc: "Đổi sang container (tài khoản) khác. TỰ kill app trước; mở lại app sau bằng appRun.",
          params: [["bundleId", "app cần đổi"], ["tênHoặcId", 'tên container hoặc id']],
          ret: "true nếu OK",
          ex: `crane.switch("com.facebook.Facebook", "Account1")\nsleep(2)\nappRun("com.facebook.Facebook")`,
        },
        {
          name: "crane.create", sig: 'crane.create(bundleId, tên)',
          desc: "Tạo container (tài khoản/bản clone) mới, rỗng.",
          params: [["bundleId", "app"], ["tên", "tên container mới"]],
          ret: "id container mới · hoặc nil, lỗi",
          ex: `crane.create("com.facebook.Facebook", "NewAccount")`,
        },
        {
          name: "crane.delete", sig: 'crane.delete(bundleId, tênHoặcId)',
          desc: "Xoá hẳn một container.",
          params: [["bundleId", "app"], ["tênHoặcId", "container cần xoá"]],
          ret: "true nếu OK",
          ex: `crane.delete("com.facebook.Facebook", "OldAccount")`,
        },
        {
          name: "crane.wipe", sig: 'crane.wipe(bundleId, tênHoặcId)',
          desc: "Xoá sạch DỮ LIỆU trong container (giữ container).",
          params: [["bundleId", "app"], ["tênHoặcId", "container cần dọn"]],
          ret: "true nếu OK",
          ex: `crane.wipe("com.facebook.Facebook", "Account1")`,
        },
        {
          name: "crane.rename", sig: 'crane.rename(bundleId, tênCũ, tênMới)',
          desc: "Đổi tên container.",
          params: [["bundleId", "app"], ["tênCũ", "tên hiện tại"], ["tênMới", "tên mới"]],
          ret: "true nếu OK",
          ex: `crane.rename("com.facebook.Facebook", "Test1", "MainAccount")`,
        },
        {
          name: "crane.clearData", sig: 'crane.clearData(bundleId)',
          desc: "Xoá cache/tmp của container ĐANG dùng để giảm dung lượng — KHÔNG mất đăng nhập.",
          params: [["bundleId", "app cần dọn"]],
          ret: "true, số_mục_đã_xoá",
          ex: `local ok, count = crane.clearData("com.facebook.Facebook")\nlog("Đã dọn " .. count .. " mục")`,
        },
        {
          name: "crane.backup", sig: 'crane.backup(bundleId [, container [, tên]])',
          desc: "Sao lưu container đang dùng ra .tar.gz (trong /var/mobile/Library/IOSControl/Backups).",
          params: [
            ["bundleId", "app"],
            ["container", "container cần backup (nil = đang dùng)"],
            ["tên", "tên file backup (mặc định = bundleId)"],
          ],
          ret: "true, đường_dẫn · hoặc false, lỗi",
          ex: `local ok, path = crane.backup("com.facebook.Facebook", nil, "fb")\nlog("Backup: " .. path)`,
        },
        {
          name: "crane.restore", sig: 'crane.restore(bundleId, đườngDẫn)',
          desc: "Phục hồi container từ file .tar.gz (kill app + ghi đè dữ liệu container đang dùng).",
          params: [["bundleId", "app"], ["đườngDẫn", "file .tar.gz đã backup"]],
          ret: "true nếu OK",
          ex: `crane.restore("com.facebook.Facebook",\n  "/var/mobile/Library/IOSControl/Backups/fb.tar.gz")`,
        },
      ],
    },
  ];

  // Xuất danh sách hàm (phẳng) cho editor.js dùng làm GỢI Ý Monaco (DRY: chung 1 nguồn với bảng tra).
  window.IOSAUTO_FUNCS = GROUPS.flatMap((g) =>
    g.fns.map((f) => ({ name: f.name, sig: f.sig, desc: f.desc, ex: f.ex, cat: g.cat }))
  );

  // ---- Tô màu cú pháp Lua (nhẹ, an toàn: escape HTML rồi quét token) ----
  const KW = new Set(["local", "if", "then", "else", "elseif", "end", "for", "while",
    "do", "return", "true", "false", "nil", "and", "or", "not", "function", "in", "repeat", "until"]);
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  function highlight(src) {
    let out = "", i = 0;
    while (i < src.length) {
      const c = src[i];
      if (c === "-" && src[i + 1] === "-") {                 // bình luận tới cuối dòng
        let j = src.indexOf("\n", i); if (j < 0) j = src.length;
        out += `<span class="c">${esc(src.slice(i, j))}</span>`; i = j; continue;
      }
      if (c === '"' || c === "'") {                          // chuỗi
        let j = i + 1;
        while (j < src.length && src[j] !== c) { if (src[j] === "\\") j++; j++; }
        j++; out += `<span class="s">${esc(src.slice(i, Math.min(j, src.length)))}</span>`; i = j; continue;
      }
      if (/[0-9]/.test(c) && !/[A-Za-z0-9_]/.test(src[i - 1] || "")) {   // số
        let j = i; while (j < src.length && /[0-9.]/.test(src[j])) j++;
        out += `<span class="n">${esc(src.slice(i, j))}</span>`; i = j; continue;
      }
      if (/[A-Za-z_]/.test(c)) {                             // định danh / từ khoá / lời gọi hàm
        let j = i; while (j < src.length && /[A-Za-z0-9_]/.test(src[j])) j++;
        const w = src.slice(i, j);
        const cls = KW.has(w) ? "k" : (src[j] === "(" ? "f" : "");
        out += cls ? `<span class="${cls}">${esc(w)}</span>` : esc(w);
        i = j; continue;
      }
      out += esc(c); i++;
    }
    return out;
  }

  // ---- Render ----
  const listEl = $("#docsList");
  const countEl = $("#docsCount");
  const searchEl = $("#docsSearch");
  let openKey = null;   // hàm đang mở ví dụ

  function flash(btn, txt) {
    const old = btn.textContent; btn.textContent = txt;
    setTimeout(() => (btn.textContent = old), 900);
  }

  function render(filter) {
    const q = (filter || "").trim().toLowerCase();
    listEl.innerHTML = "";
    let total = 0, shown = 0;

    const intro = document.createElement("div");
    intro.className = "docs-intro";
    intro.innerHTML =
      "Bấm một hàm để xem ví dụ, rồi <b>Chèn vào editor</b> hoặc <b>Chạy thử</b> ngay. " +
      "Toạ độ tính theo <b>điểm logic</b> (kích thước màn hiện ở góc trên).";
    listEl.appendChild(intro);

    GROUPS.forEach((g) => {
      const fns = g.fns.filter((f) => {
        total++;
        if (!q) return true;
        return (f.name + " " + f.sig + " " + f.desc + " " + g.cat).toLowerCase().includes(q);
      });
      if (!fns.length) return;

      const head = document.createElement("div");
      head.className = "docs-cat";
      head.style.setProperty("--cat", g.color);
      head.textContent = g.cat;
      const cnt = document.createElement("span");
      cnt.className = "muted"; cnt.style.fontWeight = "400"; cnt.style.letterSpacing = "0";
      cnt.textContent = " (" + fns.length + ")";
      head.appendChild(cnt);
      listEl.appendChild(head);

      fns.forEach((f) => {
        shown++;
        const key = f.name;
        const item = document.createElement("div");
        item.className = "docs-fn" + (openKey === key ? " open" : "");
        item.style.setProperty("--cat", g.color);

        const sig = document.createElement("div");
        sig.className = "docs-fn-sig";
        sig.innerHTML = f.sig.replace(f.name, `<span class="fn">${f.name}</span>`);
        const desc = document.createElement("div");
        desc.className = "docs-fn-desc"; desc.textContent = f.desc;
        item.appendChild(sig); item.appendChild(desc);

        if (openKey === key) item.appendChild(buildBody(f, g.color));

        item.addEventListener("click", (e) => {
          if (e.target.closest(".docs-actions")) return;   // bấm nút bên trong không đóng/mở
          openKey = openKey === key ? null : key;
          render(searchEl.value);
        });
        listEl.appendChild(item);
      });
    });

    if (!shown && q) {
      const e = document.createElement("div");
      e.className = "docs-empty"; e.textContent = "Không thấy hàm khớp “" + filter + "”.";
      listEl.appendChild(e);
    }
    countEl.textContent = "(" + total + ")";
  }

  function buildBody(f, color) {
    const body = document.createElement("div");
    body.className = "docs-body";

    if (f.params.length) {
      const tbl = document.createElement("div");
      tbl.className = "docs-params";
      f.params.forEach(([k, v]) => {
        const row = document.createElement("div"); row.className = "docs-prow";
        const a = document.createElement("code"); a.textContent = k;
        const b = document.createElement("span"); b.textContent = v;
        row.appendChild(a); row.appendChild(b); tbl.appendChild(row);
      });
      body.appendChild(tbl);
    }

    const ret = document.createElement("div");
    ret.className = "docs-ret";
    ret.innerHTML = "↩ <b>Trả về:</b> " + esc(f.ret);
    body.appendChild(ret);

    const code = document.createElement("pre");
    code.className = "docs-code";
    code.innerHTML = highlight(f.ex);
    body.appendChild(code);

    const act = document.createElement("div");
    act.className = "docs-actions";
    const bIns = mkBtn("⌵ Chèn vào editor", "primary");
    const bRun = mkBtn("▶ Chạy thử", "run");
    const bCopy = mkBtn("⧉ Copy", "");
    bIns.addEventListener("click", () => {
      if (window.iosauto?.insertCode) { window.iosauto.insertCode(f.ex); flash(bIns, "✓ Đã chèn"); }
    });
    bRun.addEventListener("click", () => {
      if (window.iosauto?.runCode) { if (window.iosauto.runCode(f.ex)) flash(bRun, "▶ Đang chạy…"); }
    });
    bCopy.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(f.ex); flash(bCopy, "✓ Đã copy"); } catch (_) {}
    });
    act.appendChild(bIns); act.appendChild(bRun); act.appendChild(bCopy);
    body.appendChild(act);
    return body;
  }

  function mkBtn(txt, cls) {
    const b = document.createElement("button");
    b.className = "mini docs-btn" + (cls ? " " + cls : "");
    b.textContent = txt;
    return b;
  }

  // ---- Mở / đóng panel + wiring ----
  const panel = $("#docsPanel");
  let built = false;
  function openDocs() {
    panel.hidden = false;
    if (!built) { render(""); built = true; }
    searchEl.focus();
  }
  function closeDocs() { panel.hidden = true; }

  $("#miDocs")?.addEventListener("click", () => { $("#helperMenu").hidden = true; openDocs(); });
  $("#btnDocs")?.addEventListener("click", () => (panel.hidden ? openDocs() : closeDocs()));
  $("#docsClose")?.addEventListener("click", closeDocs);
  $("#docsWide")?.addEventListener("click", () => panel.classList.toggle("wide"));
  searchEl?.addEventListener("input", () => render(searchEl.value));
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !panel.hidden) closeDocs(); });
})();
