-- test_safari_clear.lua
-- Test safari.clear() = xoá Lịch sử + Dữ liệu Trang web của Safari (0.7.88).
--
-- CÁCH DÙNG:
--   1) Mở Safari, mở SẴN vài tab (vài trang web khác nhau) + lướt web cho có lịch sử.
--   2) Chạy script này.
--   3) Script tự kill Safari, gọi safari.clear(), rồi MỞ LẠI Safari để bạn nhìn kết quả.
--
-- KỲ VỌNG (PASS):
--   - Log in ra "safari.clear OK — đã xoá N mục".
--   - Safari mở lại NHƯ MỚI: không còn tab cũ, Lịch sử trống, ô tìm kiếm sạch.

local SAFARI = "com.apple.mobilesafari"

log("=== TEST safari.clear() — bắt đầu ===")
toast("Test safari.clear()…", 2)

-- Cho bạn 2 giây để buông máy (nếu đang cầm).
sleep(2)

-- 1) Xoá lịch sử + dữ liệu trang web. Hàm tự kill Safari trước khi xoá.
log("Đang gọi safari.clear() …")
local ok, info, diag = safari.clear()

-- diag = breakdown từng đường dẫn Safari: "Safari:del/got ... !lỗi" (X = thiếu thư mục).
-- Nhờ vậy biết BrowserState.db (tab/lịch sử) có thật sự bị xoá không, hay lỗi quyền.
log("CHI TIẾT xoá: " .. tostring(diag))

if ok then
    log("safari.clear OK — đã xoá " .. tostring(info) .. " mục.")
    toast("Đã xoá Safari (" .. tostring(info) .. " mục)", 3)
else
    log("safari.clear THẤT BẠI — lỗi: " .. tostring(info))
    toast("LỖI: " .. tostring(info), 4)
    log("=== TEST KẾT THÚC (FAIL) ===")
    return
end

-- 2) Mở lại Safari để kiểm tra bằng mắt (phải như mới: sạch tab + lịch sử).
sleep(1)
log("Mở lại Safari để kiểm tra…")
launch(SAFARI)
sleep(3)

log("=== TEST KẾT THÚC ===")
log("KIỂM TRA BẰNG MẮT:")
log("  • Không còn tab cũ (nút tab trống / chỉ 1 tab trắng)?")
log("  • Cài đặt → Safari → Lịch sử: TRỐNG?")
log("  • => nếu đúng cả 2 thì PASS.")
