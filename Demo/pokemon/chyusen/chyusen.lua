-- ============================================================================
-- chyusen.lua — LẤY 1 dòng thông tin "chyusen" rồi UPLOAD kết quả.
--
-- API (dự án imapicloud, host https://imapicloud.site — cùng key với reg-poke):
--   GET  /api/v1/chyusen/claim[?type=...]   -> { id, type, content, claimed_at, remaining }
--        Lấy 1 dòng CHƯA TỪNG lấy (one-time, đánh dấu claimed_at). Hết dòng -> HTTP 409.
--   GET  /api/v1/chyusen/code?id=<id>       -> { user, password, email_forward, app_password,
--        found, code, from, subject }. CHỈ ĐỌC (không claim) → gọi lại nhiều lần để POLL chờ mail.
--        code = passcode パスコード (mã xác thực bóc từ mail login). found:false/code null = mail chưa
--        tới, poll lại. Lỗi: 400 thiếu forward/app pass · 404 không thấy dòng · 502 sai app pass /
--        không nối được hộp thư. (Có thể chọn dòng bằng ?id / ?user=email / ?type.)
--   POST /api/v1/chyusen/result  body { id, result, status }  -> { ok, record }
--        Ghi kết quả vào ĐÚNG dòng đã claim (id lấy từ claim ở trên).
--   Header mọi request: x-api-key: <key>
--
-- LUỒNG mỗi lượt: (1) đổi IP 4G nếu use4g=1 → (2) lấy 1 dòng chyusen type=pokemon (content="email|
--   password") → (3) mở trang login lottery, GÕ email + mật khẩu (safari.type từng ký tự chống
--   anti-bot), bấm ログイン → (4) chờ trang パスコード入力 (ô #authCode) → (5) POLL /chyusen/code?id=<id>
--   lấy passcode → GÕ vào #authCode → bấm 認証する (#certify) → (6) chờ load → upload passcode vào
--   result (success). Không thấy trang passcode → thất bại. Bước nào hỏng → upload status "failed"
--   (tab Thất bại). safari.type cần daemon build có verb WEBTYPE.
--
-- Config: DÙNG CHUNG file với reg-poke.lua — config_reg_poke.txt (cùng apikey). CHỈ đọc đúng file
-- này trong thư mục scripts của iOSAuto; KHÔNG dò vị trí khác / không fallback (tránh đọc nhầm file cũ).
--   apikey=...   (bắt buộc)
--   use4g=0/1    (1 = đổi IP 4G trước mỗi lượt)
-- ============================================================================

local BASE = "https://imapicloud.site"

-- Path TUYỆT ĐỐI tới config trong scripts iOSAuto — cwd của engine Lua KHÔNG phải thư mục này nên
-- tên file trần io.open sẽ fail; phải dùng full path (giống reg-poke.lua). Dùng chung file với reg.
local CONFIG_PATH = "/var/jb/usr/local/iosauto/scripts/config_reg_poke.txt"

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- Gieo hạt ngẫu nhiên 1 lần (nếu env có os.time) → humanPause khác nhau mỗi phiên. Không có os → bỏ.
pcall(function() math.randomseed(os.time()) end)

-- humanPause: nghỉ NGẪU NHIÊN lo..hi giây (mặc định 0.6–1.6s) mô phỏng người thao tác — chèn GIỮA các
-- bước (load xong → gõ, gõ email → gõ mật khẩu, → bấm login) để tránh chuỗi hành động TỨC THÌ bị
-- anti-bot chấm là bot. Bổ sung cho jitter GIỮA từng phím trong safari.type (verb WEBTYPE ở daemon).
local function humanPause(lo, hi)
    lo = lo or 0.6; hi = hi or 1.6
    sleep(lo + math.random() * (hi - lo))
end

-- notify: vừa log vừa toast cùng 1 thông điệp (dur giây, mặc định 3).
local function notify(msg, dur)
    log(msg)
    toast(msg, dur or 3)
end

-- readConfig: đọc key=value trong config (bỏ dòng trống / bắt đầu bằng #). Trả bảng {key=value},
-- key hạ thường. Giá trị lấy nguyên phần sau dấu = / : (đã trim). Không mở được -> bảng rỗng.
local function readConfig()
    local cfg = {}
    local f = io.open(CONFIG_PATH, "r")
    if f then
        for line in f:lines() do
            local ln = trim(line)
            if ln ~= "" and ln:sub(1, 1) ~= "#" then
                local k, v = ln:match("^([%w%._%-]+)%s*[:=]%s*(.*)$")
                if k then cfg[k:lower()] = trim(v) end
            end
        end
        f:close()
    end
    return cfg
end

-- readUse4g: đọc cờ "use4g" trong config_reg_poke.txt (do tool Electron ghi: use4g=0/1). BẬT khi giá
-- trị là 1/true/on/yes (không phân biệt hoa thường). Không có khoá / không đọc được → false (tắt).
local function readUse4g()
    local f = io.open(CONFIG_PATH, "r")
    if not f then return false end
    local on = false
    for line in f:lines() do
        local ln = trim(line)
        if ln ~= "" and ln:sub(1, 1) ~= "#" then
            local k, v = ln:match("^([%w%._%-]+)%s*[:=]%s*(.*)$")
            if k and k:lower() == "use4g" then
                v = trim(v):lower()
                on = (v == "1" or v == "true" or v == "on" or v == "yes")
                break
            end
        end
    end
    f:close()
    return on
end

-- ===== Đổi IP 4G (tắt/bật sóng qua Airplane Mode) — port từ reg-poke.lua =====
local C4G_OFF_SECONDS = 5   -- giữ ngắt sóng bao lâu mỗi lần (giây) — đủ để PDP rớt → nhà mạng cấp IP mới
local C4G_NET_WAIT    = 40   -- chờ tối đa (giây) cho 4G lên lại + có IP công khai sau khi bật sóng
local C4G_IP_MAX_TRY  = 3    -- số lần thử tắt/bật lại nếu IP CHƯA đổi (đôi khi nhà mạng cấp lại IP cũ)
local C4G_READY_TRY   = 4    -- số lần thử BẬT airplane khi daemon báo "chưa sẵn sàng" (chưa có client)
local C4G_READY_WAIT  = 1.5  -- nghỉ (giây) giữa mỗi lần thử để SpringBoard tweak kịp nối lại socket

-- getIpWait: lấy IP công khai, CÓ CHỜ mạng (poll getPublicIp mỗi 2s tới `timeout` giây). Trả IP
-- (chuỗi) hoặc nil nếu hết giờ vẫn chưa có mạng / daemon không có getPublicIp.
local function getIpWait(timeout)
    if type(getPublicIp) ~= "function" then return nil end
    timeout = tonumber(timeout) or 30
    local tries = math.max(1, math.floor(timeout / 2))
    for _ = 1, tries do
        local ip = getPublicIp()
        if ip and ip ~= "" then return ip end
        sleep(2)
    end
    return nil
end

-- airplaneOn: BẬT airplane, CÓ chờ SpringBoard sẵn sàng. Lúc mới vào (máy vừa respring / màn khoá /
-- về home) daemon có thể CHƯA có client → setAirplane trả "chưa sẵn sàng" và chỉ ghi plist, KHÔNG cắt
-- sóng thật. Gặp đúng lỗi thiếu-client đó: wake() kéo SpringBoard active rồi thử lại (≤ C4G_READY_TRY).
-- Lỗi loại khác → trả ngay. Trả true nếu bật được; false + lỗi cuối nếu vẫn không có client.
local function airplaneOn()
    local ok, err
    for _ = 1, C4G_READY_TRY do
        ok, err = setAirplane(true)                   -- BẬT airplane (ngắt sóng)
        if ok then return true end
        local e = tostring(err)
        if not e:find("chưa sẵn sàng", 1, true) and not e:find("chưa có app", 1, true) then
            return false, err
        end
        wake()                                        -- kéo SpringBoard active → tweak nối lại daemon
        sleep(C4G_READY_WAIT)
    end
    return false, err
end

-- holdAirplane: BẬT airplane → GIỮ `secs` giây → LUÔN bật lại sóng, KỂ CẢ khi người dùng ấn Dừng giữa
-- chừng (bọc pcall để sleep ném "đã dừng" không thoát TRƯỚC khi tắt airplane → tránh kẹt máy bay).
local function holdAirplane(secs)
    local ok, err = airplaneOn()
    if not ok then return false, err end
    local held, herr = pcall(function() sleep(secs) end)
    setAirplane(false)                                -- LUÔN bật lại sóng dù bị dừng giữa chừng
    if not held then error(herr, 0) end               -- ném lại NGUYÊN lỗi (giữ "đã dừng") cho vòng ngoài
    return true
end

-- cycle4g: nếu config bật use4g → tắt/bật sóng để xin IP 4G mới, và XÁC MINH IP đã đổi (so IP
-- trước/sau); chưa đổi thì thử lại tối đa C4G_IP_MAX_TRY lần. Cần daemon có setAirplane; daemon cũ
-- không có → báo rồi bỏ qua. Ấn Dừng giữa chừng vẫn bật lại sóng an toàn.
local function cycle4g()
    if not readUse4g() then return end                 -- config tắt use4g → không đụng tới 4G
    if type(setAirplane) ~= "function" then
        notify("use4g BẬT nhưng daemon chưa hỗ trợ setAirplane — bỏ qua đổi 4G", 3)
        return
    end
    local oldIp = getIpWait(C4G_NET_WAIT)
    notify("Đổi 4G: IP hiện tại " .. tostring(oldIp or "?"), 2)
    for attempt = 1, C4G_IP_MAX_TRY do
        notify(string.format("Đổi 4G (lần %d/%d): ngắt sóng %ds rồi bật lại...",
            attempt, C4G_IP_MAX_TRY, C4G_OFF_SECONDS), 2)
        local ok, err = holdAirplane(C4G_OFF_SECONDS)
        if not ok then
            notify("Đổi 4G lỗi: " .. tostring(err) .. " — bỏ qua đổi 4G", 3)
            return
        end
        notify("Đổi 4G: đã bật lại sóng, chờ mạng...", 2)
        local newIp = getIpWait(C4G_NET_WAIT)
        if not newIp then
            notify("Đổi 4G: mạng chưa lên lại sau " .. C4G_NET_WAIT .. "s", 3)
        elseif not oldIp or newIp ~= oldIp then
            notify("Đổi 4G OK ✓ IP mới: " .. newIp, 3)
            return
        else
            notify(string.format("Đổi 4G: IP CHƯA đổi (vẫn %s)%s", newIp,
                attempt < C4G_IP_MAX_TRY and " — thử lại" or ""), 3)
            oldIp = newIp
        end
    end
    notify("Đổi 4G: thử " .. C4G_IP_MAX_TRY .. " lần chưa đổi được IP — vẫn tiếp tục", 3)
end

-- claimChyusen: GET /api/v1/chyusen/claim — lấy 1 dòng chyusen chưa dùng. `type` lọc loại (nil/""
-- = bất kỳ). Retry tối đa `tries` lần (mặc định 300), cách `gap` giây (mặc định 5) — chờ qua lỗi
-- mạng và cả 409 (bảng hết dòng -> đợi nạp thêm). Trả bảng { id, type, content, remaining } hoặc nil.
local function claimChyusen(key, ctype, tries, gap)
    tries = math.max(1, tonumber(tries) or 300)
    gap = tonumber(gap) or 5
    local url = BASE .. "/api/v1/chyusen/claim"
    if ctype and ctype ~= "" then url = url .. "?type=" .. ctype end
    for attempt = 1, tries do
        local body, st = httpGet(url, { ["x-api-key"] = key })
        if not body then
            notify(string.format("claimChyusen: lần %d/%d lỗi mạng %s", attempt, tries, tostring(st)), 2)
        elseif st == 200 then
            local d = jsonDecode(body) or {}
            if d.id then
                notify(string.format("claimChyusen: id=%s type=%s (còn lại %s)",
                    tostring(d.id), tostring(d.type), tostring(d.remaining)), 3)
                return d
            end
            notify("claimChyusen: HTTP 200 nhưng thiếu id: " .. tostring(body), 3)
        elseif st == 409 then
            notify(string.format("claimChyusen: lần %d/%d — đã hết dòng chyusen chưa lấy", attempt, tries), 2)
        else
            notify(string.format("claimChyusen: lần %d/%d HTTP %s %s", attempt, tries, tostring(st), tostring(body)), 3)
        end
        if attempt < tries then sleep(gap) end
    end
    notify("claimChyusen: hết " .. tries .. " lần vẫn không lấy được dòng chyusen", 3)
    return nil
end

-- uploadResult: POST /api/v1/chyusen/result { id, result, status } — ghi kết quả cho đúng dòng đã
-- claim. `status` = "success" (mặc định) | "failed", lưu vào cột result_status (tab Kết Quả tách
-- Thành công/Thất bại theo cột này). Trả bảng record đã cập nhật (hoặc nil nếu lỗi mạng/HTTP).
-- id + result bắt buộc (API 400 nếu thiếu).
local function uploadResult(key, id, result, status)
    if not id or id == "" then notify("uploadResult: thiếu id", 3); return nil end
    if not result or result == "" then notify("uploadResult: thiếu result", 3); return nil end
    status = (status == "failed") and "failed" or "success"
    local payload = jsonEncode({ id = id, result = result, status = status })
    local resp, st = httpPost(BASE .. "/api/v1/chyusen/result", payload,
        "application/json", { ["x-api-key"] = key })
    if not resp then notify("uploadResult: lỗi mạng " .. tostring(st), 3); return nil end
    local d = jsonDecode(resp) or {}
    if (st == 200 or st == 201) and d.ok then
        notify("uploadResult: đã lưu kết quả [" .. status .. "] cho id=" .. tostring(id), 3)
        return d.record or d
    end
    notify(string.format("uploadResult: HTTP %s %s", tostring(st), tostring(resp)), 3)
    return nil
end

-- getChyusenCode: GET /api/v1/chyusen/code?id=<id> — POLL passcode (code) bóc từ mail. CHỈ ĐỌC
-- (không claim) nên gọi lại nhiều lần chờ mail tới được. Trả code (chuỗi) khi found:true; hoặc
-- nil + lý do. Phân biệt 2 loại lỗi:
--   • HTTP 200 + found:false/code rỗng  → mail CHƯA tới → nghỉ `gap` giây rồi thử lại (≤ `tries` lần).
--   • 400 (thiếu forward/app pass) / 404 (không thấy dòng) → lỗi CỨNG, poll lại vô ích → DỪNG ngay.
--   • 502 / lỗi mạng khác → tạm thời (mất kết nối hộp thư) → vẫn thử lại tới hết `tries`.
local function getChyusenCode(key, id, tries, gap)
    if not id or id == "" then return nil, "thiếu id" end
    tries = math.max(1, tonumber(tries) or 20)
    gap = tonumber(gap) or 5
    local url = BASE .. "/api/v1/chyusen/code?id=" .. tostring(id)
    for attempt = 1, tries do
        local body, st = httpGet(url, { ["x-api-key"] = key })
        if not body then
            notify(string.format("getChyusenCode: lần %d/%d lỗi mạng %s", attempt, tries, tostring(st)), 2)
        elseif st == 200 then
            local d = jsonDecode(body) or {}
            if d.found and d.code and d.code ~= "" then
                notify(string.format("getChyusenCode: OK (lần %d) code=%s", attempt, tostring(d.code)), 3)
                return d.code
            end
            notify(string.format("getChyusenCode: lần %d/%d mail chưa tới (found=%s)",
                attempt, tries, tostring(d.found)), 2)
        elseif st == 400 or st == 404 then
            -- Thiếu email_forward/app_password (400) hoặc không thấy dòng (404) → poll lại vô ích.
            local reason = string.format("HTTP %s %s", tostring(st), tostring(body))
            notify("getChyusenCode: lỗi cứng " .. reason .. " — dừng poll", 3)
            return nil, reason
        else
            -- 502 (sai app pass / không nối được hộp thư) hoặc HTTP khác → coi là tạm thời, thử lại.
            notify(string.format("getChyusenCode: lần %d/%d HTTP %s %s — thử lại",
                attempt, tries, tostring(st), tostring(body)), 3)
        end
        if attempt < tries then sleep(gap) end
    end
    return nil, "hết " .. tries .. " lần vẫn chưa có code (mail chưa tới)"
end

-- ===== Safari web helpers (port từ reg-poke.lua) =====

-- ensureSafari: kéo Safari về foreground khi máy lỡ khoá / về màn hình chính (web-action cần Safari
-- foreground). wake() bật màn + mở khoá (nếu KHÔNG có passcode) rồi launch Safari.
local function ensureSafari()
    wake()
    sleep(0.5)
    launch("com.apple.mobilesafari")
    sleep(1.5)
end

-- waitLoad: CHỜ trang load XONG (safari.load → readyState=='complete') tối đa `timeout` giây
-- (mặc định 60). Daemon cũ chưa có safari.load → chờ cứng 3s dự phòng.
local function waitLoad(timeout)
    if safari and safari.load then
        local ok, diag = safari.load(timeout or 60)
        if ok then notify("Trang đã load xong", 2)
        else notify("safari.load chưa xong: " .. tostring(diag), 3) end
        return ok
    end
    sleep(3)
    return true
end

-- openAndWait: mở URL rồi CHỜ load xong (waitLoad). Tự thử lại nếu Safari treo launch (màn trắng):
-- ensureSafari kéo Safari dậy rồi mở lại, tối đa `tries` lần (mặc định 3).
local function openAndWait(url, timeout, tries)
    tries = tonumber(tries) or 3
    for attempt = 1, tries do
        openUrl(url)
        sleep(2)                                   -- chờ Safari foreground + bắt đầu tải trang
        if waitLoad(timeout) then return true end
        if attempt < tries then
            notify("Trang chưa load (lần " .. attempt .. "/" .. tries .. ") — mở lại Safari", 3)
            ensureSafari()
            sleep(2)
        end
    end
    notify("Mở trang thất bại sau " .. tries .. " lần", 3)
    return false
end

-- waitFor: gọi lại `fn` (trả ok, diag) tối đa `timeout` giây, mỗi `gap` giây, tới khi ok=true. Nếu
-- diag báo "foreground" (Safari rớt do khoá/về home) → tự kéo Safari lại rồi thử tiếp.
local function waitFor(fn, timeout, gap)
    timeout = tonumber(timeout) or 10
    gap = tonumber(gap) or 0.5
    local tries = math.max(1, math.floor(timeout / gap))
    local ok, diag
    for i = 1, tries do
        ok, diag = fn()
        if ok then return true, diag, i end
        if type(diag) == "string" and diag:find("foreground") then
            ensureSafari()
        elseif i < tries then
            sleep(gap)
        end
    end
    return false, tostring(diag), tries
end

-- fillWait / clickWait: safari.fill / safari.click CÓ chờ element (mặc định 10s). field nhận id trần
-- ("email") hoặc CSS selector ("a.loginBtn").
local function fillWait(field, value, timeout, gap)
    return waitFor(function() return safari.fill(field, value) end, timeout, gap)
end
local function clickWait(field, timeout, gap)
    return waitFor(function() return safari.click(field) end, timeout, gap)
end

-- typeWait: GÕ từng ký tự chống anti-bot (safari.type) CÓ chờ element. Cần daemon có verb WEBTYPE
-- (build mới); nếu chưa có (daemon cũ) → trả false + diag rõ để đánh dấu failed, KHÔNG tự set thẳng
-- (tránh lại bị detect như safari.fill).
local function typeWait(field, value, timeout, gap)
    if type(safari.type) ~= "function" then
        return false, "safari.type chưa có — cần deploy build daemon có WEBTYPE"
    end
    return waitFor(function() return safari.type(field, value) end, timeout, gap)
end

-- ===== Xoá dữ liệu Safari QUA CÀI ĐẶT (mô phỏng người: Cài đặt → Safari → Xóa Lịch sử & Dữ liệu) =====
-- Lý do: clearAppData("com.apple.mobilesafari") đôi khi CÒN SÓT tab cũ (phiên trước hiện lại). Nút
-- "Xóa Lịch sử và Dữ liệu Trang web" trong Cài đặt dọn CẢ tab + lịch sử + cookie + dữ liệu web sạch
-- như người bấm tay. Dùng tapDump (khớp nhãn accessibility native, KHÔNG phụ thuộc OCR/độ phân giải).
local PREFS = "com.apple.Preferences"

-- Nhãn nút MỞ hộp xoá trong Settings>Safari — đa ngôn ngữ (tapDump khớp CHỨA chuỗi con, không phân
-- biệt hoa/thường). Máy VI/EN/JA đều trúng 1 trong các chuỗi này.
local CLEAR_OPEN = { "Xóa Lịch sử và Dữ liệu", "Clear History and Website", "履歴とWebサイトデータを消去", "履歴とWeb" }
-- Nhãn nút XÁC NHẬN (đỏ) trên action sheet.
local CLEAR_CONFIRM = { "Xóa Lịch sử và Dữ liệu", "Clear History and Data", "履歴とデータを消去" }

-- scrollDownStep: vuốt LÊN 1 nấc để cuộn danh sách native XUỐNG. Toạ độ ĐIỂM (point) an toàn cho ≥
-- iPhone SE2 375×667; kéo có kiểm soát (0.35s) để tránh lướt quá đà.
local function scrollDownStep()
    swipe(188, 520, 188, 190, 0.35)
    sleep(0.6)
end

-- tapAnyDump: thử tapDump lần lượt từng nhãn trong `labels`; trả true NGAY khi tap được 1 nhãn.
local function tapAnyDump(labels)
    for _, s in ipairs(labels) do
        if tapDump(s) then return true end
    end
    return false
end

-- findTapScroll: thử tap các nhãn; chưa thấy thì cuộn xuống 1 nấc rồi thử lại, tối đa `maxScroll` nấc.
local function findTapScroll(labels, maxScroll)
    if tapAnyDump(labels) then return true end
    for _ = 1, (maxScroll or 10) do
        scrollDownStep()
        if tapAnyDump(labels) then return true end
    end
    return false
end

-- clearSafariViaSettings: MÔ PHỎNG người dùng: home → mở Cài đặt (kill trước để về gốc) → cuộn tới
-- Safari, tap → cuộn tới "Xóa Lịch sử và Dữ liệu Trang web", tap → xác nhận trên action sheet → home.
-- Trả true nếu bấm được nút XÁC NHẬN; false nếu kẹt bước nào (log rõ). Đa ngôn ngữ VI/EN/JA.
-- LƯU Ý iOS 16.4+: có thêm bước chọn "khoảng thời gian" trước khi xác nhận — máy test 16.2 không có;
-- nếu gặp bản mới mà kẹt, cần thêm nhãn "Tất cả thời gian / All history / すべての履歴" vào bước xác nhận.
local function clearSafariViaSettings()
    home(); sleep(0.6)
    kill(PREFS); sleep(0.4)                 -- kill để Cài đặt mở LẠI từ gốc (không kẹt màn trước đó)
    if not launch(PREFS) then notify("clearSafari: không mở được Cài đặt", 3); return false end
    sleep(1.6)
    -- 1) Vào mục Safari.
    if not findTapScroll({ "Safari" }, 12) then
        notify("clearSafari: không thấy mục Safari trong Cài đặt", 3); home(); return false
    end
    sleep(1.2)
    -- 2) Cuộn tới cuối, bấm "Xóa Lịch sử và Dữ liệu Trang web".
    if not findTapScroll(CLEAR_OPEN, 12) then
        notify("clearSafari: không thấy nút Xóa Lịch sử & Dữ liệu (trong Safari)", 3); home(); return false
    end
    sleep(1.0)
    -- 3) Xác nhận trên action sheet (có thể hiện chậm → thử 2 nhịp).
    local okc = tapAnyDump(CLEAR_CONFIRM)
    if not okc then sleep(0.8); okc = tapAnyDump(CLEAR_CONFIRM) end
    if not okc then
        notify("clearSafari: không thấy nút xác nhận Xóa (action sheet)", 3); home(); return false
    end
    sleep(1.2)
    notify("clearSafari: đã Xóa Lịch sử & Dữ liệu Safari qua Cài đặt ✓", 2)
    home(); sleep(0.5)
    return true
end

-- ===== Cấu hình login lottery =====
local CHYUSEN_TYPE = "pokemon"        -- loại chyusen cần lấy (cố định type=pokemon)
local LOGIN_URL    = "https://www.pokemoncenter-online.com/lottery/login.html"
local SEL_EMAIL    = "email"          -- <input id="email">
local SEL_PASSWORD = "password"       -- <input id="password" name="current-password">
local SEL_LOGINBTN = "a.loginBtn"     -- <a class="btn loginBtn">ログイン</a>

-- main: 1 lượt: đổi IP → claim → mở login + điền email/mật khẩu + bấm ログイン → chờ trang passcode →
-- POLL /code?id=<id> lấy passcode → gõ vào #authCode → bấm 認証する → upload passcode (success). Trả
-- "empty" khi HẾT dòng để claim (dừng vòng); "ok" khi đã claim được 1 dòng (vòng ngoài tiếp tục sang
-- dòng kế). Bước web/lấy code hỏng → upload status "failed" rồi "ok" (dòng đó đã bị đánh dấu claimed).
local function main(key)
    -- (1) Nếu config bật use4g=1: TẮT/BẬT 4G xin IP mới trước. use4g=0 → thoát ngay, không đụng sóng.
    cycle4g()

    -- (2) Lấy 1 dòng thông tin chyusen type=pokemon.
    notify("Đang lấy 1 dòng thông tin chyusen (type=" .. CHYUSEN_TYPE .. ")...", 3)
    local rec = claimChyusen(key, CHYUSEN_TYPE)
    if not rec then
        notify("Không lấy được dòng chyusen (hết dữ liệu hoặc lỗi)", 3)
        return "empty"
    end
    notify(string.format("Chyusen #%s [%s]: %s (còn lại %s)",
        tostring(rec.id), tostring(rec.type), tostring(rec.content), tostring(rec.remaining)), 4)

    -- Tách content "email|password" (cho phép khoảng trắng quanh dấu |). Sai định dạng → failed.
    local content = tostring(rec.content or "")
    local email, password = content:match("^%s*(.-)%s*|%s*(.-)%s*$")
    if not email or email == "" or not password or password == "" then
        local reason = "content sai định dạng, cần email|password: " .. content
        notify(reason, 4)
        uploadResult(key, rec.id, "failed: " .. reason, "failed")
        return "ok"
    end

    -- (3) Fresh session: xoá dữ liệu Safari để không dính phiên/tab account trước (mỗi lượt 1 account
    -- khác). CHÍNH: bấm "Xóa Lịch sử & Dữ liệu" trong Cài đặt (dọn cả TAB cũ — clearAppData còn sót).
    -- Hỏng UI (đổi ngôn ngữ / iOS mới) → DỰ PHÒNG clearAppData (cần iOSAuto ≥ 0.7.65).
    if not clearSafariViaSettings() then
        local okc, nc = clearAppData("com.apple.mobilesafari")
        notify("clearSafari dự phòng clearAppData: " .. (okc and (tostring(nc) .. " mục") or ("lỗi " .. tostring(nc))), 2)
    end

    -- (4) Mở trang login lottery, chờ load xong (≤30s, tự thử lại nếu Safari treo launch).
    notify("Mở trang login lottery...", 3)
    if not openAndWait(LOGIN_URL, 30) then
        uploadResult(key, rec.id, "failed: mở trang login thất bại", "failed")
        return "ok"
    end

    -- (5) GÕ email từng ký tự (chống anti-bot) — chờ ô xuất hiện ≤10s. Nghỉ 1 nhịp "đọc trang" trước.
    humanPause(0.9, 2.2)
    local oke, de = typeWait(SEL_EMAIL, email, 10)
    if not oke then
        uploadResult(key, rec.id, "failed: gõ email lỗi (" .. tostring(de) .. ")", "failed")
        return "ok"
    end
    notify("Đã gõ email: " .. email, 2)

    -- (6) GÕ mật khẩu từng ký tự. Nghỉ 1 nhịp như người chuyển ô email → ô mật khẩu.
    humanPause(0.5, 1.3)
    local okp, dp = typeWait(SEL_PASSWORD, password, 10)
    if not okp then
        uploadResult(key, rec.id, "failed: gõ mật khẩu lỗi (" .. tostring(dp) .. ")", "failed")
        return "ok"
    end
    notify("Đã gõ mật khẩu", 2)

    -- (7) Bấm nút đăng nhập (ログイン). Nghỉ 1 nhịp trước khi bấm (người kiểm lại rồi mới nhấn).
    humanPause(0.6, 1.5)
    if not clickWait(SEL_LOGINBTN, 10) then
        uploadResult(key, rec.id, "failed: không bấm được nút đăng nhập", "failed")
        return "ok"
    end
    notify("Đã bấm đăng nhập — chờ web load (≤30s)...", 3)

    sleep(5)   -- chờ Safari bắt đầu điều hướng sau khi submit login

    -- (8) Chờ trang load xong (login → trang パスコード入力 nếu bật OTP).
    waitLoad(30)

    -- (9) PHẢI tới trang nhập passcode: chờ ô #authCode (<input id="authCode">) xuất hiện ≤12s.
    -- Không thấy = login không tới bước OTP (sai mật khẩu / trang không load) → thất bại.
    if not clickWait("#authCode", 12) then
        uploadResult(key, rec.id, "failed: không thấy trang passcode (#authCode)", "failed")
        return "ok"
    end
    notify("Trang パスコード入力 → chờ mail lấy passcode...", 3)

    -- (10) POLL /api/v1/chyusen/code?id=<id> tới found:true để bóc passcode (code) từ mail,
    -- tối đa 20 lần cách 5s (~100s chờ mail). Không lấy được → thất bại.
    local code, cerr = getChyusenCode(key, rec.id, 20, 5)
    if not code then
        notify("Không lấy được passcode: " .. tostring(cerr), 4)
        uploadResult(key, rec.id, "failed: không lấy được code (" .. tostring(cerr) .. ")", "failed")
        return "ok"
    end

    -- (11) GÕ passcode vào ô #authCode (từng ký tự chống anti-bot). Nghỉ 1 nhịp trước.
    humanPause(0.6, 1.5)
    local okc, dc = typeWait("#authCode", code, 10)
    if not okc then
        uploadResult(key, rec.id, "failed: gõ passcode lỗi (" .. tostring(dc) .. ")", "failed")
        return "ok"
    end
    notify("Đã gõ passcode: " .. code, 2)

    -- (12) Bấm 認証する (<a id="certify">認証する</a>) để xác thực. Nghỉ 1 nhịp trước.
    humanPause(0.6, 1.5)
    if not clickWait("#certify", 10) then
        uploadResult(key, rec.id, "failed: không bấm được nút 認証する", "failed")
        return "ok"
    end
    notify("Đã bấm 認証する — chờ web load (≤30s)...", 3)

    -- (13) Chờ web load sau xác thực.
    waitLoad(30)

    -- (14) Upload THÀNH CÔNG + passcode vừa nhập (status=success → tab "Thành công").
    if uploadResult(key, rec.id, code, "success") then
        notify("Đã upload [success] passcode cho id=" .. tostring(rec.id) .. ": " .. code, 4)
    else
        notify("Upload kết quả lỗi (mạng/HTTP) cho id=" .. tostring(rec.id), 4)
    end
    return "ok"
end

-- ============================================================================
-- CHẠY: đọc key + type từ config rồi lặp LẤY→XỬ LÝ→UPLOAD tới khi hết dòng
-- (claimChyusen trả nil) hoặc người dùng ấn "Dừng". Lỗi bất ngờ 1 dòng KHÔNG
-- làm dừng vòng (log rồi sang dòng kế) — chỉ lệnh "Dừng" mới thoát.
-- ============================================================================
local cfg = readConfig()
local key = cfg.apikey or cfg.api_key or cfg["x-api-key"]
if not key or key == "" then
    notify("Không đọc được apikey từ config_reg_poke.txt — dừng", 5)
    return
end
local n = 0
while true do
    n = n + 1
    notify("===== Chyusen lượt #" .. n .. " =====", 2)
    local ok, err = pcall(main, key)
    if not ok then
        if type(err) == "string" and err:find("dừng", 1, true) then
            notify("Đã dừng theo yêu cầu người dùng (đã xong " .. (n - 1) .. " lượt).", 3)
            break
        end
        notify("Lượt #" .. n .. " lỗi bất ngờ: " .. tostring(err) .. " → sang dòng kế", 4)
    elseif err == "empty" then
        -- main báo HẾT dòng chyusen (claim nil) → dừng vòng cho gọn.
        notify("Hết dòng chyusen để xử lý — kết thúc.", 3)
        break
    end
    sleep(2)   -- nghỉ giữa 2 dòng (cũng là điểm để lệnh Dừng kịp thoát)
end
