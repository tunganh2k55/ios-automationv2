-- test_change_ip4g.lua — KIỂM TRA đổi IP 4G bằng cách TẮT/BẬT sóng (Airplane Mode).
-- Mỗi vòng: lấy IP hiện tại → BẬT airplane (ngắt sóng) OFF_SECONDS giây → TẮT airplane (bật lại sóng)
-- → chờ mạng lên lại → lấy IP mới → so sánh có ĐỔI hay không. Lặp ROUNDS vòng rồi tổng kết.
--
-- YÊU CẦU: daemon có setAirplane(on, offDelay) (iOSAuto ≥ 0.7.82). Máy phải đang dùng DATA 4G (không WiFi)
-- thì tắt/bật sóng mới đổi IP — nếu đang WiFi thì IP công cộng do WiFi quyết định, sẽ KHÔNG đổi.

local ROUNDS = 3          -- số vòng test
local OFF_SECONDS = 10     -- thời gian giữ ngắt sóng (airplane ON) mỗi vòng
local NET_WAIT = 40        -- chờ tối đa (giây) cho mạng lên lại sau khi bật sóng

-- notify: vừa log (hiện ở panel output) vừa toast trên máy.
local function notify(msg, dur)
    log(msg)
    toast(msg, dur or 3)
end

-- getIpWait: lấy IP công cộng, CÓ CHỜ mạng (poll getPublicIp mỗi 2s tới `timeout` giây). Trả IP
-- (chuỗi) hoặc nil nếu hết giờ vẫn chưa có mạng.
local function getIpWait(timeout)
    timeout = tonumber(timeout) or 30
    local tries = math.max(1, math.floor(timeout / 2))
    for i = 1, tries do
        local ip = getPublicIp()          -- trả IP, hoặc nil + lỗi
        if ip and ip ~= "" then return ip end
        sleep(2)
    end
    return nil
end

-- ===== Bắt đầu =====
if type(setAirplane) ~= "function" then
    notify("✗ Daemon chưa hỗ trợ setAirplane — cập nhật iOSAuto ≥ 0.7.82 rồi chạy lại", 6)
    return
end

notify("=== TEST ĐỔI IP 4G: " .. ROUNDS .. " vòng, ngắt sóng " .. OFF_SECONDS .. "s/vòng ===", 4)

-- IP khởi điểm (trước khi test) — để so vòng đầu.
local prevIp = getIpWait(NET_WAIT)
if not prevIp then
    notify("✗ Không lấy được IP ban đầu (mất mạng?) — dừng test", 6)
    return
end
notify("IP ban đầu: " .. prevIp, 4)

local changed, same, failed = 0, 0, 0

for round = 1, ROUNDS do
    notify("----- Vòng " .. round .. "/" .. ROUNDS .. " -----", 2)

    -- 1) BẬT máy bay OFF_SECONDS giây rồi TỰ TẮT (1 lệnh: setAirplane(true, OFF_SECONDS)).
    notify("Vòng " .. round .. ": BẬT máy bay " .. OFF_SECONDS .. "s rồi tự tắt...", 2)
    local ok, err = setAirplane(true, OFF_SECONDS)
    if not ok then
        notify("Vòng " .. round .. ": setAirplane LỖI: " .. tostring(err) .. " — bỏ qua vòng này", 4)
        failed = failed + 1
    else
        -- 2) máy bay đã tự tắt (sóng bật lại) → chờ mạng lên lại + lấy IP mới
        notify("Vòng " .. round .. ": máy bay đã tắt, chờ mạng...", 2)
        local newIp = getIpWait(NET_WAIT)
        if not newIp then
            notify("Vòng " .. round .. ": ✗ mạng chưa lên lại sau " .. NET_WAIT .. "s", 4)
            failed = failed + 1
        else
            -- 3) so sánh
            if newIp ~= prevIp then
                notify("Vòng " .. round .. ": ✓ IP ĐỔI  " .. prevIp .. "  →  " .. newIp, 5)
                changed = changed + 1
            else
                notify("Vòng " .. round .. ": ⚠ IP KHÔNG đổi (vẫn " .. newIp .. ")", 5)
                same = same + 1
            end
            prevIp = newIp
        end
    end

    if round < ROUNDS then sleep(3) end   -- nghỉ ngắn giữa 2 vòng
end

notify(string.format("=== XONG: %d đổi IP · %d không đổi · %d lỗi (IP cuối: %s) ===",
    changed, same, failed, tostring(prevIp)), 6)
