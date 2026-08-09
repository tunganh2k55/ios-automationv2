local function contains_ci(h, n)
    return h and n and n ~= "" and string.find(h:lower(), n:lower(), 1, true) ~= nil
end

function FindTextRegion(text, region, tries, lang)
    assert(type(text) == "string" and text ~= "", "FindTextRegion: 'text' phải là chuỗi khác rỗng")
    region = region or {}
    local lang = "ja" or lang
    local x = region.x or region[1] or 0
    local y = region.y or region[2] or 0
    local w = region.w or region[3] or 0
    local h = region.h or region[4] or 0
    tries = math.max(1, tonumber(tries) or 5)

    for attempt = 1, tries do
        local ocrText, err = ocrTextRegion(x, y, w, h, lang)
        if ocrText then
            for line in (ocrText .. "\n"):gmatch("(.-)\n") do
                if contains_ci(line, text) then return true, line, attempt end
            end
        else
            print(string.format("FindTextRegion: lần %d OCR lỗi: %s", attempt, tostring(err)))
        end
        if attempt < tries then sleep(2) end
    end
    return false, nil, tries
end






-- ================= IMAP API (imapicloud.site) =================
-- API key đọc từ config_reg_poke.txt (dòng "apikey=..." ; bỏ dòng trống / bắt đầu bằng #).

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- CHỈ đọc đúng file config trong thư mục scripts của iOSAuto — cùng tên tool đang upload lên
-- (config_reg_poke.txt). Không dò các vị trí local/khác để tránh đọc nhầm file cũ.
local CONFIG_PATH = "/var/jb/usr/local/iosauto/scripts/config_reg_poke.txt"
local function readApiKey()
    local paths = { CONFIG_PATH }
    -- Ưu tiên ĐÚNG khoá "apikey" (hoặc api_key/x-api-key); BỎ QUA các dòng khác (use4g, licensekey…).
    -- Dòng "chỉ mình key" (không có := ) làm dự phòng cho config.txt bản cũ.
    for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then
            local hit, bare = nil, nil
            for line in f:lines() do
                local ln = trim(line)
                if ln ~= "" and ln:sub(1, 1) ~= "#" then
                    local k, v = ln:match("^([%w%._%-]+)%s*[:=]%s*(.*)$")
                    if k then
                        k = k:lower()
                        if k == "apikey" or k == "api_key" or k == "x-api-key" then
                            local tok = trim(v):match("%S+")     -- token đầu tiên sau dấu = / :
                            if tok then hit = tok; break end     -- đúng khoá + có giá trị
                        end
                        -- khoá khác (use4g / licensekey …) -> bỏ qua, KHÔNG nhận nhầm làm key
                    elseif not bare then
                        bare = trim(ln):match("%S+")             -- file chỉ chứa mỗi key (bản cũ)
                    end
                end
            end
            f:close()
            local v = hit or bare
            if v and v ~= "" then return v end
        end
    end
    return nil
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

-- get-link-poke: đọc link xác nhận Pokémon của email (?type=pokemon). Thử tối đa `tries` lần
-- (mặc định 5); mỗi lần response chưa có link thì nghỉ `gap` giây (mặc định 3) rồi thử lại
-- (đợi thư tới). Trả về link (hoặc nil).
function getLinkPoke(email, tries, gap)
    if not email or email == "" then log("getLinkPoke: thiếu email"); return nil end
    local key = readApiKey()
    if not key then log("getLinkPoke: không đọc được API key từ config_reg_poke.txt"); return nil end
    tries = math.max(1, tonumber(tries) or 5)
    gap = tonumber(gap) or 3
    local url = "https://imapicloud.site/api/v1/mail/" .. email .. "?type=pokemon"
    for attempt = 1, tries do
        local body, st = httpGet(url, { ["x-api-key"] = key })
        if body then
            local d = jsonDecode(body) or {}
            if st == 200 and d.found and d.link and d.link ~= "" then
                log("getLinkPoke: OK (lần " .. attempt .. ") " .. d.link)
                return d.link
            end
            local msg = string.format("getLinkPoke: lần %d/%d chưa có link (HTTP %s, found=%s)",
                attempt, tries, tostring(st), tostring(d.found))
            log(msg); toast(msg, 2)
        else
            local msg = string.format("getLinkPoke: lần %d/%d lỗi mạng %s", attempt, tries, tostring(st))
            log(msg); toast(msg, 2)
        end
        if attempt < tries then sleep(gap) end
    end
    log("getLinkPoke: hết " .. tries .. " lần vẫn chưa có link")
    return nil
end

-- claim-record: lấy 1 dòng thông tin đăng ký chưa dùng (one-time, GET /api/v1/records/claim) —
-- giống get_info.lua. Retry tối đa `tries` lần (mặc định 300), mỗi lần cách `gap` giây (mặc định 5)
-- — chờ qua lỗi mạng và cả 409 (bảng tạm hết → đợi nạp thêm). Trả bảng record (email, nickname,
-- name_tv, name_tn, birth_*, gender, postal_code, address1/2, phone, password, remaining…) hoặc nil.
function claimRecord(tries, gap)
    tries = math.max(1, tonumber(tries) or 300)
    gap = tonumber(gap) or 5
    local key = readApiKey()
    if not key then log("claimRecord: không đọc được API key từ config_reg_poke.txt"); return nil end
    for attempt = 1, tries do
        local body, st = httpGet("https://imapicloud.site/api/v1/records/claim", { ["x-api-key"] = key })
        if not body then
            log(string.format("claimRecord: lần %d/%d lỗi mạng %s", attempt, tries, tostring(st)))
        elseif st == 200 then
            local d = jsonDecode(body) or {}
            log(string.format("claimRecord: %s | %s (còn lại %s)",
                tostring(d.nickname), tostring(d.name_tv), tostring(d.remaining)))
            return d
        elseif st == 409 then
            log(string.format("claimRecord: lần %d/%d Bảng thông tin đã reg hết dữ liệu", attempt, tries))
        else
            log(string.format("claimRecord: lần %d/%d HTTP %s %s", attempt, tries, tostring(st), tostring(body)))
        end
        if attempt < tries then sleep(gap) end
    end
    log("claimRecord: hết " .. tries .. " lần vẫn không lấy được record")
    return nil
end

-- upload-account: lưu 1 account (POST /api/v1/created-accounts) theo x-api-key.
--   status : "success" (mặc định) hoặc "failed".
--   reason : lý do thất bại (chỉ dùng khi status="failed" → hiện ở cột "Lý do").
--   content: chuỗi account nguyên văn; với "failed" có thể rỗng.
-- Trả bảng account (hoặc nil nếu lỗi mạng/HTTP).
function uploadAccount(content, status, reason)
    status = status or "success"
    local key = readApiKey()
    if not key then log("uploadAccount: không đọc được API key từ config_reg_poke.txt"); return nil end
    local payload = { content = content or "", status = status }
    if reason and reason ~= "" then payload.reason = reason end
    local body = jsonEncode(payload)
    local resp, st = httpPost("https://imapicloud.site/api/v1/created-accounts", body,
        "application/json", { ["x-api-key"] = key })
    if not resp then log("uploadAccount: lỗi mạng " .. tostring(st)); return nil end
    local d = jsonDecode(resp) or {}
    if st ~= 200 and st ~= 201 then
        log("uploadAccount: HTTP " .. tostring(st) .. " " .. tostring(resp)); return nil
    end
    log(string.format("uploadAccount: đã lưu %s account [%s]%s",
        tostring(d.inserted or 1), status, reason and (" reason=" .. reason) or ""))
    return (d.accounts and d.accounts[1]) or d
end

-- notify: vừa ghi log vừa hiện toast cùng 1 thông điệp (dur giây, mặc định 3).
local function notify(msg, dur)
    log(msg)
    toast(msg, dur or 3)
end

-- regFailed: reg THẤT BẠI → toast/log + upload account "failed" kèm lý do (content = email nếu có).
-- Dùng ở mọi điểm main return sớm. Luôn trả false để tiện: `if not ok then return regFailed(...) end`.
local function regFailed(reason, content)
    notify("Reg thất bại: " .. reason, 4)
    uploadAccount(content or "", "failed", reason)
    return false
end

-- ===== Đổi IP 4G (tắt/bật sóng qua Airplane Mode) =====
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

-- airplaneOn: BẬT airplane, CÓ chờ SpringBoard sẵn sàng. cycle4g chạy ở dòng ĐẦU main() — TRƯỚC khi
-- mở app nào — nên lúc mới vào tài khoản (máy vừa respring / màn khoá / về home) daemon có thể CHƯA có
-- client nào kết nối → setAirplane trả "SpringBoard chưa sẵn sàng (chưa có app foreground...)" và chỉ
-- ghi plist, KHÔNG cắt sóng thật. Khi gặp đúng lỗi thiếu-client đó: gọi wake() để kéo SpringBoard
-- active cho tweak nối lại socket rồi thử lại, tối đa C4G_READY_TRY lần. Lỗi loại khác → trả ngay
-- (không phí thời gian). Trả true nếu bật được; false + lỗi cuối nếu vẫn không có client.
local function airplaneOn()
    local ok, err
    for _ = 1, C4G_READY_TRY do
        ok, err = setAirplane(true)                   -- BẬT airplane (ngắt sóng)
        if ok then return true end
        local e = tostring(err)
        -- chỉ retry với lỗi thiếu client; lỗi khác (vd daemon từ chối) → trả ngay
        if not e:find("chưa sẵn sàng", 1, true) and not e:find("chưa có app", 1, true) then
            return false, err
        end
        wake()                                        -- kéo SpringBoard active → tweak nối lại daemon
        sleep(C4G_READY_WAIT)                         -- (có thể ném "đã dừng"; an toàn vì airplane CHƯA bật)
    end
    return false, err
end

-- holdAirplane: BẬT airplane → GIỮ `secs` giây → LUÔN bật lại sóng, KỂ CẢ khi người dùng ấn Dừng giữa
-- chừng. Nếu không bọc pcall, sleep() ném "đã dừng" sẽ thoát TRƯỚC khi setAirplane(false) → máy kẹt
-- chế độ máy bay không có mạng. Ở đây bảo đảm tắt airplane rồi mới ném lại lệnh Dừng cho vòng ngoài.
-- Trả true nếu xong; false + lỗi nếu ngay cả bật airplane cũng thất bại.
local function holdAirplane(secs)
    local ok, err = airplaneOn()                      -- BẬT airplane (có chờ SpringBoard sẵn sàng)
    if not ok then return false, err end
    local held, herr = pcall(function() sleep(secs) end)   -- sleep có thể ném "đã dừng"
    setAirplane(false)                                -- LUÔN bật lại sóng dù bị dừng giữa chừng
    if not held then error(herr, 0) end               -- ném lại NGUYÊN lỗi (giữ "đã dừng") cho vòng ngoài
    return true
end

-- cycle4g: nếu config bật use4g → tắt/bật sóng để xin IP 4G mới TRƯỚC mỗi lần reg, và XÁC MINH IP đã
-- đổi (so IP trước/sau); nếu chưa đổi thì thử lại tối đa C4G_IP_MAX_TRY lần. Cần daemon có setAirplane;
-- daemon cũ không có → báo rồi bỏ qua, vẫn reg bình thường. Ấn Dừng giữa chừng vẫn bật lại sóng an toàn.
local function cycle4g()
    if not readUse4g() then return end                 -- config tắt use4g → không đụng tới 4G
    if type(setAirplane) ~= "function" then
        notify("use4g BẬT nhưng daemon chưa hỗ trợ setAirplane — bỏ qua đổi 4G", 3)
        return
    end
    local oldIp = getIpWait(C4G_NET_WAIT)              -- IP trước khi đổi (nil nếu đang mất mạng)
    notify("Đổi 4G: IP hiện tại " .. tostring(oldIp or "?"), 2)
    for attempt = 1, C4G_IP_MAX_TRY do
        notify(string.format("Đổi 4G (lần %d/%d): ngắt sóng %ds rồi bật lại...",
            attempt, C4G_IP_MAX_TRY, C4G_OFF_SECONDS), 2)
        local ok, err = holdAirplane(C4G_OFF_SECONDS)  -- ngắt sóng C4G_OFF_SECONDS rồi bật lại (an toàn Dừng)
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
    notify("Đổi 4G: thử " .. C4G_IP_MAX_TRY .. " lần chưa đổi được IP — vẫn tiếp tục reg", 3)
end

-- Seed random 1 lần (nếu có os.time) để chuỗi delay khác nhau mỗi lần chạy.
if os and os.time then math.randomseed(os.time()) end

-- randSleep: nghỉ NGẪU NHIÊN [min,max] giây (giả lập thao tác người). Mặc định 1-3s. Trả số giây đã nghỉ.
local function randSleep(min, max)
    min = tonumber(min) or 1
    max = tonumber(max) or 3
    if max < min then max = min end
    local s = math.random(min, max)
    sleep(s)
    return s
end

-- ensureSafari: kéo Safari về foreground khi máy lỡ KHOÁ / về màn hình chính (web-action cần Safari
-- foreground). wake() bật màn + mở khoá (nếu KHÔNG có passcode) rồi launch Safari — giữ nguyên trang
-- đang mở (không điều hướng lại nên không mất dữ liệu form).
local function ensureSafari()
    wake()
    sleep(0.5)
    launch("com.apple.mobilesafari")
    sleep(1.5)
end

-- waitLoad: CHỜ trang load XONG (safari.load → document.readyState=='complete') tối đa `timeout`
-- giây (mặc định 60) — dùng SAU khi điều hướng (mở URL hoặc bấm submit). Gọi SAU 1 nhịp nghỉ ngắn để
-- Safari kịp BẮT ĐẦU điều hướng, tránh safari.load bắt nhầm readyState 'complete' của trang CŨ.
-- Daemon cũ (chưa có safari.load) → chờ cứng dự phòng để vẫn chạy được.
local function waitLoad(timeout)
    if safari and safari.load then
        local ok, diag = safari.load(timeout or 60)
        if ok then notify("Trang đã load xong", 2)
        else notify("safari.load chưa xong: " .. tostring(diag), 3) end
        return ok
    end
    sleep(3)                                       -- fallback: daemon cũ chưa có safari.load
    return true
end

-- openAndWait: mở URL rồi CHỜ trang load XONG (waitLoad). CÓ THỬ LẠI: đôi khi Safari mở lên MÀN
-- TRẮNG rồi treo (safari.load timeout "trạng thái cuối: ?") — do LAUNCH Safari bị kẹt lúc inject
-- tweak/hook vào tiến trình launch chậm (rõ nhất ngay SAU clearAppData: container vừa xoá → cold
-- launch nặng). Watchdog giết Safari → về home. Lần mở lại KHÔNG còn ngay sau wipe nên launch nhẹ,
-- thường qua. Thử tối đa `tries` lần trước khi bỏ. Nghỉ ngắn trước mỗi lần để Safari kịp điều hướng.
local function openAndWait(url, timeout, tries)
    tries = tonumber(tries) or 3
    for attempt = 1, tries do
        openUrl(url)
        sleep(2)                                   -- chờ Safari foreground + bắt đầu tải trang
        if waitLoad(timeout) then return true end
        if attempt < tries then
            notify("Trang chưa load (lần " .. attempt .. "/" .. tries .. ") — Safari có thể treo launch, mở lại", 3)
            ensureSafari()                         -- kéo Safari dậy (wake + foreground) rồi thử mở lại
            sleep(2)
        end
    end
    notify("Mở trang thất bại sau " .. tries .. " lần (Safari treo launch?)", 3)
    return false
end

-- waitFor: gọi lại `fn` (trả ok, diag) tối đa `timeout` giây, mỗi lần cách `gap` giây, tới khi
-- ok=true. safari.fill/click chỉ quét DOM 1 lần rồi trả ngay → dùng đây để CHỜ element xuất hiện
-- (trang tải chậm/điều hướng). Nếu diag báo "foreground" (Safari rớt do khoá/về home) → tự kéo Safari
-- lại rồi thử tiếp. Trả (ok, diag, số_lần_thử). Mặc định timeout 10s, gap 0.5s.
local function waitFor(fn, timeout, gap)
    timeout = tonumber(timeout) or 10
    gap = tonumber(gap) or 0.5
    local tries = math.max(1, math.floor(timeout / gap))
    local ok, diag
    for i = 1, tries do
        ok, diag = fn()
        if ok then return true, diag, i end
        if type(diag) == "string" and diag:find("foreground") then
            log("waitFor: Safari rớt foreground → kéo lại")
            ensureSafari()                       -- khoá/về home → mở khoá + foreground Safari rồi thử tiếp
        elseif i < tries then
            sleep(gap)
        end
    end
    return false, tostring(diag), tries
end

-- fillWait: safari.fill có chờ element (mặc định 10s, thử mỗi 0.5s). Tự nghỉ NGẪU NHIÊN 2-3s
-- TRƯỚC khi điền (giả lập người) — nghỉ 1 lần, không phải mỗi lần poll. Khỏi cần sleep lẻ tẻ.
local function fillWait(field, value, timeout, gap)
    return waitFor(function() return safari.fill(field, value) end, timeout, gap)
end

-- clickWait: safari.click có chờ element (mặc định 10s, thử mỗi 0.5s).
local function clickWait(field, timeout, gap)
    return waitFor(function() return safari.click(field) end, timeout, gap)
end

-- fillField: fillWait 1 ô/select rồi notify gọn (label để hiển thị). Trả ok. Dùng cho form dài.
-- safari.fill xử lý cả <select> (chọn option khớp value → text), nên year/month/day/gender đều dùng đây.
local function fillField(field, value, label)
    if value == nil or value == "" then
        notify("Bỏ qua " .. label .. " (không có dữ liệu)", 2)
        return false
    end
    local ok, diag = fillWait(field, value, 10)     -- fillWait đã tự nghỉ ngẫu nhiên 2-3s trước khi điền
    if ok then
        notify("Đã điền " .. label .. ": " .. tostring(value), 2)
    else
        notify("Điền " .. label .. " lỗi: " .. tostring(diag), 3)
    end                          -- nghỉ ngẫu nhiên 2-3s SAU khi điền (giả lập người)
    return ok
end

-- clickField: clickWait 1 element rồi notify gọn (label để hiển thị). Trả ok.
local function clickField(field, label)
    local ok, diag = clickWait(field, 10)
    if ok then
        notify("Đã bấm " .. label, 2)
    else
        notify("Bấm " .. label .. " lỗi: " .. tostring(diag), 3)
    end
    return ok
end

-- pad2: số → chuỗi 2 chữ số ("5" → "05") để khớp value option tháng/ngày ("01".."12"/"01".."31").
local function pad2(n)
    n = tonumber(n)
    return n and string.format("%02d", n) or nil
end

-- genderValue: map giới tính record → value <select gender> (1=男性, 2=女性). :lower() gộp
-- "Nam"/"nam"/"NAM" → "nam"; xử lý cả nữ/nu/male/female/Nhật.
local function genderValue(g)
    g = trim(tostring(g or "")):lower()
    if g == "nam" or g == "male" or g == "m" or g == "1" or g == "男性" then return "1" end   -- 男性
    if g == "nữ" or g == "nu" or g == "female" or g == "f" or g == "2" or g == "女性" then return "2" end  -- 女性
    return "1"                                    -- mặc định 男性
end

function main()
  -- Nếu bật use4g trong config: TẮT/BẬT 4G (10s) để xin IP di động mới TRƯỚC khi tạo tài khoản.
  cycle4g()

  -- Xoá TOÀN BỘ dữ liệu Safari trước khi reg (cookie/cache/session/lịch sử) → mỗi lần reg như máy
  -- mới, tránh dính phiên/tài khoản cũ. Cần iOSAuto ≥ 0.7.65 (có clearAppData).
  local okc, nc = clearAppData("com.apple.mobilesafari")
  notify("Xoá dữ liệu Safari: " .. (okc and (tostring(nc) .. " mục") or ("lỗi " .. tostring(nc))), 3)
  randSleep(1, 2)   -- nghỉ ngẫu nhiên 1-3s trước khi mở web (giả lập thao tác người)

  notify("Đang lấy thông tin đăng ký...", 3)

  -- Lấy thông tin đăng ký (email + toàn bộ info) 1 LẦN từ API records — dùng luôn email này cho
  -- form login (không gọi API lấy email riêng nữa).
  local rec = claimRecord()
  if not rec then
    notify("Không lấy được thông tin đăng ký", 3)
    return
  end
  local email = rec.email
  if not email or email == "" then
    return regFailed("Record không có trường email", "")
  end
  notify("Email: " .. email, 3)

  -- Ghép FULL thông tin (email + info đã claim) 1 lần — dùng cho upload dù THÀNH CÔNG hay THẤT BẠI.
  -- Thứ tự: email|nickname|name_tv|name_tn|year|month|day|gender|postal|address1|address2|phone|password
  local content = table.concat({
    email,
    tostring(rec.nickname or ""),
    tostring(rec.name_tv or ""),
    tostring(rec.name_tn or ""),
    tostring(rec.birth_year or ""),
    tostring(rec.birth_month or ""),
    tostring(rec.birth_day or ""),
    tostring(rec.gender or ""),
    tostring(rec.postal_code or ""),
    tostring(rec.address1 or ""),
    tostring(rec.address2 or ""),
    tostring(rec.phone or ""),
    tostring(rec.password or ""),
  }, "|")


  notify("Mở Link Đăng Ký", 3)
  if not openAndWait("https://www.pokemoncenter-online.com/login") then   -- chờ trang login load xong (≤60s, tự thử lại nếu Safari treo launch)
    return regFailed("Mở trang login thất bại (Safari treo launch)", content)
  end

  -- Điền email — chờ ô xuất hiện tối đa 10s (trang tự tải xong lúc nào điền lúc đó).
  local ok, diag = fillWait("login-form-regist-email", email, 10)
  if not ok then
    return regFailed("Load Web Failed", content)   -- không thấy ô email = web chưa/không load được
  end
  notify("Đã điền email: " .. email, 3)

  randSleep(1, 2) 

  -- Bấm nút "新規会員登録" (đăng ký hội viên mới) — <button id="form2Button" type="submit"> — chờ ≤10s.
  local ok2, diag2 = clickWait("form2Button", 10)
  if not ok2 then
    return regFailed("Load Web Failed", content)
  end
  notify("Đã bấm nút đăng ký", 3)

  randSleep(1, 2) 

  -- Bấm "仮登録メールを送信する" (gửi mail đăng ký tạm) — <a id="send-confirmation-email"> — chờ ≤10s
  -- (trang xác nhận điều hướng xong lúc nào bấm lúc đó).
  local ok3, diag3 = clickWait("send-confirmation-email", 10)
  if not ok3 then
    return regFailed("Load Web Failed", content)
  end
  notify("Đã bấm gửi mail xác nhận", 3)

  -- Chờ 5s cho mail gửi/tới → lấy link xác nhận (type=pokemon) tối đa 5 lần, cách 5s/lần.
  randSleep(1, 2) 

  notify("Đang lấy link từ email...", 3)         -- toast báo đang chờ/lấy link
  local link = getLinkPoke(email, 5, 5)
  if not link then
    return regFailed("Không có link gửi về email", content)
  end

  -- Mở link xác nhận → tới trang điền hồ sơ đăng ký. Chờ trang load xong (safari.load, ≤60s, tự thử lại).
  notify("Mở link: " .. link, 3)
  if not openAndWait(link) then
    return regFailed("Mở link xác nhận thất bại (Safari treo launch)", content)
  end

  -- MỐC CHẨN ĐOÁN: nếu lần chạy tới log DỪNG TRƯỚC dòng này → chết khi mở/tải trang new-customer
  -- (nhiều khả năng daemon bị kill do trang nặng). Nếu QUA được dòng này mà không điền → lỗi ở form.
  notify("Trang đăng ký đã mở — bắt đầu điền hồ sơ", 2)

  -- Điền hồ sơ đăng ký từ `rec` đã claim ở đầu. safari.fill tự cuộn tới từng ô/select rồi điền; chờ mỗi ô ≤10s.
  fillField("registration-form-nname", rec.nickname, "nickname (ニックネーム)")      -- <input id=registration-form-nname>
  sleep(0.5)
  fillField("registration-form-fname", rec.name_tv, "họ tên (お名前)")                -- name=dwfrm_profile_customer_lastname
  sleep(0.5)
  fillField("registration-form-kana", rec.name_tn, "furigana (フリガナ)")             -- name=dwfrm_profile_customer_namekana
  sleep(0.5)
  fillField("registration-form-birthdayyear", tostring(rec.birth_year or ""), "năm sinh (年)")
  sleep(0.5)
  fillField("registration-form-birthdaymonth", pad2(rec.birth_month), "tháng sinh (月)")
  sleep(0.5)
  fillField("registration-form-birthdayday", pad2(rec.birth_day), "ngày sinh (日)")
  sleep(0.5)
  fillField('select[aria-describedby="form-gender-error"]', genderValue(rec.gender), "giới tính (性別)")
  sleep(0.5)
  fillField("registration-form-postcode", tostring(rec.postal_code or ""), "mã bưu điện (郵便番号)")
  sleep(2)
  fillField("registration-form-address-line1", rec.address1, "địa chỉ 1 (番地)" )            -- <input id=…address-line1>
  sleep(0.5)
  fillField("registration-form-address-line2", rec.address2, "địa chỉ 2 (建物名)")          -- <input id=…address-line2>
  sleep(0.5)
  fillField('input[name="dwfrm_profile_customer_phone"]', rec.phone, "SĐT (電話番号)")
  sleep(0.5)
  fillField('input[name="dwfrm_profile_login_password"]', rec.password, "mật khẩu")
  sleep(0.5)
  fillField('input[name="dwfrm_profile_login_passwordconfirm"]', rec.password, "nhập lại mật khẩu")
  sleep(0.5)

  -- Tích 2 ô đồng ý (dùng "#id" cho chính xác — "terms" là chuỗi con của nhiều thuộc tính).
  -- QUY TẮC: BẤM KHÔNG THÀNH CÔNG = account THẤT BẠI luôn (không cố tiếp) → upload "failed" + kết thúc
  -- lần reg này (vòng ngoài sẽ sang account kế).
  if not clickField("#terms", "đồng ý điều khoản (利用規約)") then
    return regFailed("Bấm đồng ý điều khoản thất bại", content)
  end
  sleep(0.5)

  if not clickField("#privacyPolicy", "đồng ý chính sách bảo mật (プライバシーポリシー)") then
    return regFailed("Bấm đồng ý chính sách bảo mật thất bại", content)
  end

  sleep(0.5)

  if not clickField("#registration_button", "nút xác nhận thông tin (入力内容確認へ進む)") then
    return regFailed("Bấm nút xác nhận thông tin thất bại", content)
  end
  waitLoad(30)

  -- Trang xác nhận → chờ 5s → bấm "登録する" (đăng ký) — <button class="submitButton">.
  if not clickField("button.submitButton", "nút 登録する (đăng ký)") then
    return regFailed("Bấm nút đăng ký (登録する) thất bại", content)
  end

  -- Bấm 登録する → form submit → điều hướng sang trang kết quả. Nghỉ ngắn cho Safari kịp bắt đầu
  -- điều hướng rồi CHỜ trang load XONG (≤60s) trước khi kiểm hoàn tất.
  waitLoad(30)

  -- Hoàn tất khi có <h1 class="headLine01">会員登録完了</h1> (chờ ≤10s). Có h1 = đăng ký thành công.
  local done = clickWait("h1.headLine01", 10)
  if not done then
    return regFailed("Load Web Failed", content)   -- không thấy 会員登録完了 = reg không hoàn tất
  end
  notify("Đăng ký thành công (会員登録完了)!", 3)

  -- Upload tài khoản THÀNH CÔNG — FULL thông tin (email + info) ngăn bằng "|".
  if uploadAccount(content, "success") then
    notify("Đã upload tài khoản THÀNH CÔNG: " .. content, 4)
  else
    notify("Upload tài khoản lỗi (mạng/HTTP): " .. content, 4)
  end
end

-- ================= LICENSE (tool: pokemontool) =================
-- Kiểm bản quyền theo SERIAL máy — KHÔNG cần key. License phải được kích hoạt gắn serial máy
-- này từ trước (admin bind). Ở đây chỉ hỏi server "máy này (serial) còn quyền dùng pokemontool
-- không?" qua POST /api/verify/device { tool, machineId }.
--   machineId = getSN() (serial máy).
local LICENSE_BASE = "https://iosautos.com"
local LICENSE_SLUG = "pokemontool"

local function licPost(path, tbl)
    local resp, st = httpPost(LICENSE_BASE .. path, jsonEncode(tbl), "application/json")
    if not resp then log("license: lỗi mạng " .. tostring(st)); return nil end
    return jsonDecode(resp) or {}, st
end

-- ensureLicense: check theo (serial, tool). Trả true nếu máy này còn quyền dùng tool.
local function ensureLicense()
    local mid = trim(getSN())
    if mid == "" then notify("Không lấy được serial máy (getSN)", 5); return false end

    local d = licPost("/api/verify/device", { tool = LICENSE_SLUG, machineId = mid })
    if not d then notify("✗ Lỗi mạng khi kiểm license", 5); return false end
    log(string.format("license: serial=%s valid=%s reason=%s expiresAt=%s",
        mid, tostring(d.valid), tostring(d.reason), tostring(d.expiresAt)))
    if d.valid == true then notify("License OK ✓ (pokemontool)", 2); return true end

    local msg = ({
        not_found   = "Máy này chưa được cấp license pokemontool",
        expired     = "License đã hết hạn",
        revoked     = "License đã bị thu hồi",
        bad_request = "Thiếu serial/tool khi kiểm license",
    })[tostring(d.reason)] or ("License không hợp lệ: " .. tostring(d.reason))
    notify("✗ " .. msg, 5)
    return false
end

-- ================= VÒNG REG VÔ HẠN =================
-- Reg liên tục hết account này sang account khác. CHỈ dừng khi người dùng ấn "Dừng" (daemon đặt cờ huỷ
-- → sleep()/hook đếm lệnh ném lỗi chứa "đã dừng" → pcall bắt được → thoát vòng). Lỗi BẤT NGỜ ở 1
-- account (không phải lệnh Dừng) KHÔNG làm dừng vòng — log rồi sang account kế, đúng yêu cầu
-- "chỉ dừng khi người dùng ấn dừng".
local acc = 0
while true do
  acc = acc + 1
  -- MỖI lượt reg đều kiểm license trước (bắt kịp thu hồi/hết hạn giữa chừng). Không hợp lệ → dừng vòng.
  if not ensureLicense() then
    notify("Dừng: license pokemontool không hợp lệ", 4)
    break
  end
  notify("===== Bắt đầu tài khoản #" .. acc .. " =====", 2)
  local ok, err = pcall(main)
  if not ok then
    if type(err) == "string" and err:find("dừng", 1, true) then
      log("Đã dừng theo yêu cầu người dùng — kết thúc vòng reg (đã xong " .. acc .. " lượt).")
      break
    end
    log("Tài khoản #" .. acc .. " lỗi bất ngờ: " .. tostring(err) .. " → sang account kế")
  end
  sleep(3)   -- nghỉ giữa 2 account (cũng là điểm để lệnh Dừng kịp thoát)
end
