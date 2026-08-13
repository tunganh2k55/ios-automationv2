-- ============================================================================
-- chyusen_honin.lua — Vòng lặp VÔ HẠN login + ứng tuyển chyusen (本人認証済み枠)
-- v1.0.0 (2026-08-13)
--
-- Flow mỗi lượt:
--   (1) Đổi IP 4G (nếu use4g=1) → (2) Claim 1 dòng → (3) Clear Safari →
--   (4) Login (email+password) → (5) Chờ passcode → (6) Poll code từ API →
--   (7) Nhập passcode + xác thực → (8) Mở trang apply → (9) Ứng tuyển LIST items
--   → (10) Upload kết quả
--
-- Logic dừng:
--   - Chạy VÔ HẠN, không giới hạn số account
--   - Khi hết acc (HTTP 409): chờ 5s rồi thử lại, đếm emptyRetryCount
--   - Nếu có acc mới: RESET emptyRetryCount về 0 (tiếp tục vô hạn)
--   - Nếu thử 100 lần liên tiếp mà vẫn hết acc: DỪNG HẲN
--
-- Error handling ĐẦY ĐỦ cho mọi case:
--   - Lỗi đọc config / thiếu apikey
--   - Lỗi mạng (httpGet/httpPost timeout/fail)
--   - HTTP 409 (hết dòng), 400/404/502 (lỗi API)
--   - Content sai định dạng (không tách được email|password)
--   - Lỗi Safari: clear fail, mở trang fail, gõ fail, click fail
--   - Lỗi passcode: không thấy #authCode, poll code timeout, mail không tới
--   - Lỗi apply item: mỗi bước (detail, radio, checkbox, popup, applyBtn)
--   - Lỗi bất ngờ (pcall catch all)
--   - User dừng script (ấn Dừng)
-- ============================================================================

local BASE = "https://imapicloud.site"
local CONFIG_PATH = "/var/jb/usr/local/iosauto/scripts/config_reg_poke.txt"

-- ========== CẤU HÌNH ==========
local CHYUSEN_TYPE = "pokemon"      -- loại chyusen (本人認証済み枠)
local LOGIN_URL    = "https://www.pokemoncenter-online.com/lottery/login.html"
-- APPLY_URL không cần vì web tự chuyển sau login

-- Selectors
local SEL_EMAIL    = "email"
local SEL_PASSWORD = "password"
local SEL_LOGINBTN = "a.loginBtn"

-- Popup xác nhận "応募してよろしいですか？": nút 応募する nằm GIỮA màn. Text nút này TRÙNG với nút
-- 応募する nền (khớp-text lấy nhầm nút nền) → dùng tap TOẠ ĐỘ. Giá trị cho màn 375x667 (iPhone 7),
-- nút ở tâm ngang (~187) và ~44% chiều cao (~293). Đổi nếu chạy máy khác kích thước.
local APPLY_MODAL_X = 187
local APPLY_MODAL_Y = 293

-- 4G settings
local C4G_OFF_SECONDS = 5
local C4G_NET_WAIT    = 40
local C4G_IP_MAX_TRY  = 3
local C4G_READY_TRY   = 4
local C4G_READY_WAIT  = 1.5

-- Retry settings
local MAX_EMPTY_RETRY = 100               -- khi hết acc, thử lại tối đa 100 lần rồi dừng
local EMPTY_RETRY_GAP = 10                 -- chờ 5s giữa mỗi lần retry khi hết acc
local MAX_ERROR_RETRY = 10                -- retry lỗi khác (network, server) tối đa 5 lần liên tiếp

-- Poll code xác thực (mail): chờ TỐI ĐA ~3 phút. Chia CODE_POLL_TRIES lần, mỗi lần nghỉ CODE_POLL_GAP
-- giây (36 × 5s ≈ 180s). Có CHỐT thời gian thực (os.time) → KHÔNG vượt quá 3 phút kể cả khi mạng chậm.
local CODE_POLL_TRIES   = 36               -- số lần poll tối đa (đủ phủ 3 phút với gap 5s)
local CODE_POLL_GAP     = 5                -- nghỉ giữa 2 lần poll (giây)
local CODE_POLL_MAX_SEC = 180              -- trần thời gian chờ tổng (giây) = 3 phút

-- ========== HELPERS ==========
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

pcall(function() math.randomseed(os.time()) end)

local function humanPause(lo, hi)
    lo = lo or 0.6; hi = hi or 1.6
    sleep(lo + math.random() * (hi - lo))
end

local function notify(msg, dur)
    log(msg)
    toast(msg, dur or 3)
end

local function readConfig()
    local cfg = {}
    local f = io.open(CONFIG_PATH, "r")
    if not f then
        notify("ERROR: Không mở được config: " .. CONFIG_PATH, 4)
        return cfg, "không mở được file config"
    end
    for line in f:lines() do
        local ln = trim(line)
        if ln ~= "" and ln:sub(1, 1) ~= "#" then
            local k, v = ln:match("^([%w%._%-]+)%s*[:=]%s*(.*)$")
            if k then cfg[k:lower()] = trim(v) end
        end
    end
    f:close()
    return cfg, nil
end

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

-- ========== 4G CYCLE ==========
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

local function airplaneOn()
    if type(setAirplane) ~= "function" then
        return false, "daemon chưa hỗ trợ setAirplane"
    end
    local ok, err
    for _ = 1, C4G_READY_TRY do
        ok, err = setAirplane(true)
        if ok then return true end
        local e = tostring(err)
        if not e:find("chưa sẵn sàng", 1, true) and not e:find("chưa có app", 1, true) then
            return false, err
        end
        wake()
        sleep(C4G_READY_WAIT)
    end
    return false, err
end

local function holdAirplane(secs)
    local ok, err = airplaneOn()
    if not ok then return false, err end
    local held, herr = pcall(function() sleep(secs) end)
    setAirplane(false)
    if not held then error(herr, 0) end
    return true
end

-- resetNetwork: TẮT/BẬT airplane để reset mạng — chờ 10s cho mạng ổn định
-- Dùng sau khi lấy được acc mới để đổi IP
local function resetNetwork()
    if not readUse4g() then return end
    if type(setAirplane) ~= "function" then
        notify("use4g BẬT nhưng daemon chưa hỗ trợ setAirplane — bỏ qua", 3)
        return
    end
    notify("Reset mạng: ngắt sóng " .. C4G_OFF_SECONDS .. "s...", 2)
    local ok, err = holdAirplane(C4G_OFF_SECONDS)
    if not ok then
        notify("Reset mạng lỗi: " .. tostring(err) .. " — bỏ qua", 3)
        return
    end
    notify("Reset mạng: đã bật lại sóng, chờ 10s...", 2)
    sleep(10)  -- chờ mạng ổn định trước khi mở link
    notify("Reset mạng: OK", 2)
end

-- ========== API FUNCTIONS ==========
local function claimChyusen(key, ctype)
    -- Kiểm tra key
    if not key or key == "" then
        return nil, "MISSING_KEY", "thiếu apikey"
    end

    local url = BASE .. "/api/v1/chyusen/claim"
    if ctype and ctype ~= "" then url = url .. "?type=" .. ctype end

    local body, st = httpGet(url, { ["x-api-key"] = key })

    -- Case 1: Lỗi mạng (body = nil)
    if not body then
        return nil, "NETWORK_ERROR", "lỗi mạng: " .. tostring(st)
    end

    -- Case 2: HTTP 200 OK
    if st == 200 then
        local d = jsonDecode(body)
        if not d then
            return nil, "INVALID_JSON", "không parse được JSON: " .. tostring(body):sub(1, 100)
        end
        if d.id then
            notify(string.format("Claim OK: id=%s (còn %s)", tostring(d.id), tostring(d.remaining)), 3)
            return d, "OK", nil
        end
        return nil, "INVALID_RESPONSE", "HTTP 200 nhưng thiếu id: " .. tostring(body):sub(1, 100)
    end

    -- Case 3: HTTP 409 = hết dòng
    if st == 409 then
        return nil, "EMPTY", "hết dòng chyusen chưa lấy"
    end

    -- Case 4: HTTP 400 = request sai
    if st == 400 then
        return nil, "BAD_REQUEST", "HTTP 400: " .. tostring(body):sub(1, 100)
    end

    -- Case 5: HTTP 401/403 = key sai hoặc hết hạn
    if st == 401 or st == 403 then
        return nil, "UNAUTHORIZED", "HTTP " .. st .. ": apikey sai hoặc hết hạn"
    end

    -- Case 6: HTTP 404 = endpoint không tồn tại
    if st == 404 then
        return nil, "NOT_FOUND", "HTTP 404: API endpoint không tồn tại"
    end

    -- Case 7: HTTP 429 = rate limit
    if st == 429 then
        return nil, "RATE_LIMIT", "HTTP 429: quá nhiều request, thử lại sau"
    end

    -- Case 8: HTTP 500/502/503/504 = server lỗi
    if st >= 500 then
        return nil, "SERVER_ERROR", "HTTP " .. st .. ": server lỗi"
    end

    -- Case 9: HTTP khác
    return nil, "HTTP_ERROR", string.format("HTTP %s: %s", tostring(st), tostring(body):sub(1, 100))
end

local function uploadResult(key, id, result, status)
    -- Case 1: Thiếu id
    if not id or id == "" then
        notify("uploadResult: thiếu id — bỏ qua", 2)
        return nil, "MISSING_ID"
    end

    -- Case 2: Thiếu result
    if not result then result = "unknown" end

    status = (status == "failed") and "failed" or "success"

    local payload = jsonEncode({ id = id, result = result, status = status })

    -- Case 3: jsonEncode fail
    if not payload then
        notify("uploadResult: jsonEncode lỗi", 2)
        return nil, "JSON_ENCODE_ERROR"
    end

    local resp, st = httpPost(BASE .. "/api/v1/chyusen/result", payload,
        "application/json", { ["x-api-key"] = key })

    -- Case 4: Lỗi mạng
    if not resp then
        notify("uploadResult: lỗi mạng " .. tostring(st), 3)
        return nil, "NETWORK_ERROR"
    end

    -- Case 5: Parse response
    local d = jsonDecode(resp)
    if not d then
        notify("uploadResult: không parse được response: " .. tostring(resp):sub(1, 100), 3)
        return nil, "INVALID_JSON"
    end

    -- Case 6: Success
    if (st == 200 or st == 201) and d.ok then
        notify("Upload [" .. status .. "] OK cho id=" .. tostring(id), 3)
        return d.record or d, "OK"
    end

    -- Case 7: HTTP error
    notify(string.format("uploadResult HTTP %s: %s", tostring(st), tostring(resp):sub(1, 100)), 3)
    return nil, "HTTP_" .. tostring(st)
end

local function getChyusenCode(key, id, tries, gap, maxSec)
    -- Case 1: Thiếu id
    if not id or id == "" then
        return nil, "MISSING_ID", "thiếu id"
    end

    tries = math.max(1, tonumber(tries) or 20)
    gap = tonumber(gap) or 5
    -- Trần thời gian chờ TỔNG (giây). Poll dừng khi ĐỦ maxSec dù chưa hết `tries` — đảm bảo "tối đa
    -- 3 phút" kể cả khi từng lần httpGet chậm. Mặc định = tries*gap (giữ hành vi cũ nếu không truyền).
    maxSec = tonumber(maxSec) or (tries * gap)
    local startT = (os and os.time) and os.time() or nil    -- os.time có thể bị sandbox → bỏ chốt, chỉ theo tries
    local url = BASE .. "/api/v1/chyusen/code?id=" .. tostring(id)
    local lastErr = "unknown"
    local lastCode = "UNKNOWN"

    for attempt = 1, tries do
        -- Chốt thời gian thực: đã chờ đủ maxSec → dừng sớm (không đợi cho hết `tries`).
        if startT and (os.time() - startT) >= maxSec then
            notify(string.format("getCode: đã chờ ~%ds (trần %ds) → dừng poll", os.time() - startT, maxSec), 2)
            break
        end
        local body, st = httpGet(url, { ["x-api-key"] = key })

        -- Case 2: Lỗi mạng
        if not body then
            lastErr = "lỗi mạng: " .. tostring(st)
            lastCode = "NETWORK_ERROR"
            notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
            if attempt < tries then sleep(gap) end
            goto continue
        end

        -- Case 3: HTTP 200
        if st == 200 then
            local d = jsonDecode(body)
            if not d then
                lastErr = "không parse được JSON"
                lastCode = "INVALID_JSON"
                notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
                if attempt < tries then sleep(gap) end
                goto continue
            end

            -- Case 3a: Có code
            if d.found and d.code and d.code ~= "" then
                notify(string.format("Code OK (lần %d): %s", attempt, tostring(d.code)), 3)
                return d.code, "OK", nil
            end

            -- Case 3b: Mail chưa tới
            lastErr = "mail chưa tới (found=" .. tostring(d.found) .. ")"
            lastCode = "MAIL_NOT_ARRIVED"
            notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
            if attempt < tries then sleep(gap) end
            goto continue
        end

        -- Case 4: HTTP 400 = thiếu email_forward/app_password
        if st == 400 then
            return nil, "BAD_CONFIG", "HTTP 400: thiếu email_forward/app_password trong dòng chyusen"
        end

        -- Case 5: HTTP 404 = không tìm thấy dòng
        if st == 404 then
            return nil, "NOT_FOUND", "HTTP 404: không tìm thấy dòng chyusen id=" .. tostring(id)
        end

        -- Case 6: HTTP 401/403 = key sai
        if st == 401 or st == 403 then
            return nil, "UNAUTHORIZED", "HTTP " .. st .. ": apikey sai"
        end

        -- Case 7: HTTP 502 = lỗi kết nối mail server
        if st == 502 then
            lastErr = "HTTP 502: lỗi kết nối mail server (sai app password?)"
            lastCode = "MAIL_SERVER_ERROR"
            notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
            if attempt < tries then sleep(gap) end
            goto continue
        end

        -- Case 8: HTTP 503/504 = server tạm không khả dụng
        if st == 503 or st == 504 then
            lastErr = "HTTP " .. st .. ": server tạm không khả dụng"
            lastCode = "SERVER_UNAVAILABLE"
            notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
            if attempt < tries then sleep(gap) end
            goto continue
        end

        -- Case 9: HTTP khác
        lastErr = "HTTP " .. tostring(st) .. ": " .. tostring(body):sub(1, 100)
        lastCode = "HTTP_" .. tostring(st)
        notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
        if attempt < tries then sleep(gap) end

        ::continue::
    end

    local waited = startT and (os.time() - startT) or (tries * gap)
    return nil, lastCode, string.format("hết thời gian chờ code (~%ds, trần %ds): %s", waited, maxSec, lastErr)
end

-- ========== SAFARI HELPERS ==========
local function ensureSafari()
    wake()
    sleep(0.5)
    launch("com.apple.mobilesafari")
    sleep(1.5)
end

local function waitLoad(timeout)
    if safari and safari.load then
        local ok, diag = safari.load(timeout or 60)
        if ok then
            notify("Trang load xong", 2)
            return true, "OK"
        end
        return false, tostring(diag or "timeout")
    end
    sleep(3)
    return true, "no safari.load (daemon cũ)"
end

local function openAndWait(url, timeout, retries)
    retries = tonumber(retries) or 3
    local lastDiag = "unknown"

    for attempt = 1, retries do
        -- Case 1: openUrl fail
        local okOpen = pcall(function() openUrl(url) end)
        if not okOpen then
            lastDiag = "openUrl exception"
            notify(string.format("Mở URL lỗi (lần %d/%d): %s", attempt, retries, lastDiag), 2)
            if attempt < retries then
                ensureSafari()
                sleep(2)
            end
            goto continue
        end

        sleep(2)

        -- Case 2: waitLoad
        local ok, diag = waitLoad(timeout)
        if ok then return true, "OK" end

        lastDiag = tostring(diag)
        if attempt < retries then
            notify(string.format("Mở trang lỗi (lần %d/%d): %s — thử lại", attempt, retries, lastDiag), 2)
            ensureSafari()
            sleep(2)
        end

        ::continue::
    end

    return false, "mở trang thất bại sau " .. retries .. " lần: " .. lastDiag
end

local function waitFor(fn, timeout, gap)
    timeout = tonumber(timeout) or 10
    gap = tonumber(gap) or 0.5
    local tries = math.max(1, math.floor(timeout / gap))
    local lastDiag = "unknown"

    for i = 1, tries do
        local okCall, ok, diag = pcall(fn)

        -- Case 1: fn exception
        if not okCall then
            lastDiag = "exception: " .. tostring(ok)
            if i < tries then sleep(gap) end
            goto continue
        end

        -- Case 2: Success
        if ok then return true, diag, i end

        lastDiag = tostring(diag or "unknown")

        -- Case 3: Safari không foreground
        if lastDiag:find("foreground") then
            ensureSafari()
        elseif i < tries then
            sleep(gap)
        end

        ::continue::
    end

    return false, lastDiag, tries
end

local function typeWait(field, value, timeout)
    -- Case 1: safari.type không tồn tại
    if not safari then
        return false, "safari object không tồn tại"
    end
    if type(safari.type) ~= "function" then
        return false, "safari.type chưa có (cần daemon mới có WEBTYPE)"
    end

    -- Case 2: field/value rỗng
    if not field or field == "" then
        return false, "field rỗng"
    end
    if not value then
        return false, "value nil"
    end

    return waitFor(function() return safari.type(field, value) end, timeout, 0.5)
end

local function clickWait(field, timeout)
    -- Case 1: safari.click không tồn tại
    if not safari then
        return false, "safari object không tồn tại"
    end
    if type(safari.click) ~= "function" then
        return false, "safari.click chưa có"
    end

    -- Case 2: field rỗng
    if not field or field == "" then
        return false, "selector rỗng"
    end

    return waitFor(function() return safari.click(field) end, timeout, 0.5)
end

-- checkboxWait: tick checkbox/radio bằng safari.checkbox — tìm ĐÚNG <input>, tap vào label nếu input
-- bị ẩn/quá nhỏ (style đè lên), VERIFY .checked + .click() JS bù nếu HID tap trượt. Chuẩn hơn nhiều so
-- với safari.click (chỉ tap toạ độ → dễ trượt/không toggle với ô ẩn). Daemon cũ chưa có safari.checkbox
-- → fallback về safari.click để vẫn chạy được.
local function checkboxWait(field, timeout)
    if not safari then
        return false, "safari object không tồn tại"
    end
    if not field or field == "" then
        return false, "selector rỗng"
    end
    if type(safari.checkbox) == "function" then
        return waitFor(function() return safari.checkbox(field) end, timeout, 0.5)
    end
    -- Fallback daemon cũ (chưa có safari.checkbox)
    if type(safari.click) == "function" then
        return waitFor(function() return safari.click(field) end, timeout, 0.5)
    end
    return false, "safari.checkbox/click chưa có"
end

local function clearSafari()
    -- Case 1: Thử safari.clear() trước (daemon mới)
    if safari and type(safari.clear) == "function" then
        local okCall, ok, count, diag = pcall(safari.clear)
        if okCall and ok then
            notify(string.format("Safari clear OK - xóa %s mục", tostring(count)), 2)
            return true, "OK"
        end
        notify("safari.clear lỗi: " .. tostring(count or diag) .. " — thử clearAppData", 2)
    end

    -- Case 2: Fallback clearAppData
    if type(clearAppData) == "function" then
        local okCall, ok, count = pcall(clearAppData, "com.apple.mobilesafari")
        if okCall and ok then
            notify("clearAppData Safari OK - " .. tostring(count) .. " mục", 2)
            return true, "OK"
        end
        return false, "clearAppData lỗi: " .. tostring(ok or count)
    end

    -- Case 3: Không có hàm clear
    return false, "không có hàm clear Safari (daemon quá cũ)"
end

-- ========== APPLY (dùng safari.eval — daemon >= 1.0.43) ==========
-- Item cần ứng tuyển trong ul.comOrderList (1-based). Đổi số này để nhắm item khác (vd 5).
local APPLY_ITEM_INDEX = 1

-- evalStr: chạy JS qua safari.eval → (chuỗi | nil, diag). JS phải `return` giá trị.
local function evalStr(js)
    if not (safari and type(safari.eval) == "function") then
        return nil, "safari.eval chưa có (cần daemon >= 1.0.43)"
    end
    local ok, a, b = pcall(safari.eval, js)
    if not ok then return nil, "eval exception: " .. tostring(a) end
    if a == nil then return nil, tostring(b or "eval lỗi") end
    return a, nil
end

-- tapByEval: JS trả "x,y" (tâm element cần bấm) → HID tap đúng toạ độ đó. Lặp tới khi có toạ độ hợp
-- lệ (khác 0,0) hoặc hết timeout. Dùng cho nút CHỈ nhận touch thật (popup xác nhận bỏ qua JS click).
local function tapByEval(js, label, timeout)
    timeout = tonumber(timeout) or 8
    local last = "?"
    for _ = 1, math.max(1, math.floor(timeout)) do
        local res, diag = evalStr(js)
        if res then
            local x, y = tostring(res):match("(%-?%d+)%s*,%s*(%-?%d+)")
            if x and y and not (tonumber(x) == 0 and tonumber(y) == 0) then
                if type(tap) ~= "function" then return false, "tap() không có" end
                tap(tonumber(x), tonumber(y))
                return true, string.format("%s tap(%d,%d)", label or "", tonumber(x), tonumber(y))
            end
            last = "eval='" .. tostring(res) .. "'"
        else
            last = tostring(diag)
        end
        sleep(1)
    end
    return false, (label or "") .. " không lấy được toạ độ: " .. last
end

-- JS lấy TOẠ ĐỘ tâm nút 応募する của FORM (đang HIỂN THỊ, KHÔNG thuộc popup). Dùng HID tap (touch
-- thật chạy trên MỌI nút, không phụ thuộc nút có nhận JS click hay không, và né được vụ #applyBtn
-- global luôn = item 1). Trả "x,y" | "0,0" (chưa thấy).
local JS_FORM_APPLY_COORD = [[
var as=document.querySelectorAll('a,button');
for(var i=0;i<as.length;i++){var a=as[i];
if((a.textContent||'').indexOf('応募する')<0)continue;
if(a.closest&&(a.closest('.mfp-content')||a.closest('#pop01')))continue;
var r=a.getBoundingClientRect();if(r.width<=0||r.height<=0)continue;
return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);}
return '0,0';
]]

-- JS lấy TOẠ ĐỘ tâm nút 応募する TRONG POPUP xác nhận (Magnific #pop01 / .mfp-content). Nút này BỎ QUA
-- JS click (isTrusted) nên phải HID tap toạ độ này. Trả "x,y" | "0,0" (chưa thấy → tapByEval sẽ lặp).
local JS_POPUP_APPLY_COORD = [[
var as=document.querySelectorAll('.mfp-content a,.mfp-content button,#pop01 a,#pop01 button');
for(var i=0;i<as.length;i++){var a=as[i];
if((a.textContent||'').indexOf('応募する')<0)continue;
var r=a.getBoundingClientRect();if(r.width<=0||r.height<=0)continue;
return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);}
return '0,0';
]]

-- Flow ứng tuyển item N (本人認証済み枠) — VERIFY trên web 2026-08-13:
--   (1) 詳しく見る : mở accordion item N            → ul.comOrderList > li:nth-child(N) dt
--   (2) radio SP   : safari.checkbox drill vào <input radio> đầu tiên trong li
--   (3) 同意する   : tick checkbox "応募要項に同意する" (scope trong li, fallback theo label)
--   (4) 応募する   : HID tap nút form (eval tìm nút HIỂN THỊ ngoài popup + lấy toạ độ) → mở popup
--   (5) 応募する   : HID tap nút TRONG popup (eval lấy toạ độ; nút popup bỏ qua JS click)
-- LƯU Ý: web yêu cầu ĐÃ LOGIN; nếu chưa login, bước (5) nhảy về trang login (không ghi nhận).
local function applyItem(n)
    local ITEM = string.format("ul.comOrderList > li:nth-child(%d)", n)
    notify(string.format("--- Ứng tuyển item %d ---", n), 2)
    local errors = {}

    -- Step 1: mở chi tiết 詳しく見る (toggle là thẻ <dt> trong li)
    local ok1, diag1 = clickWait(ITEM .. " dt", 10)
    if not ok1 then
        table.insert(errors, "step1_detail: " .. tostring(diag1))
        notify("FAIL: không mở được chi tiết - " .. tostring(diag1), 2)
        return false, errors, "DETAIL_CLICK_FAIL"
    end
    sleep(1)

    -- Step 2: chọn RADIO sản phẩm (safari.checkbox tự tìm <input radio> ĐẦU TIÊN trong li)
    local ok2, diag2 = checkboxWait(ITEM, 10)
    if not ok2 then
        table.insert(errors, "step2_radio: " .. tostring(diag2))
        notify("FAIL: không chọn được radio - " .. tostring(diag2), 2)
        return false, errors, "RADIO_CLICK_FAIL"
    end
    sleep(0.5)

    -- Step 3: tick checkbox đồng ý (scope trong li; fallback theo label nếu không match)
    local ok3, diag3 = checkboxWait(ITEM .. ' input[type="checkbox"]', 10)
    if not ok3 then ok3, diag3 = checkboxWait("応募要項に同意する", 6) end
    if not ok3 then
        table.insert(errors, "step3_checkbox: " .. tostring(diag3))
        notify("FAIL: không tick được đồng ý - " .. tostring(diag3), 2)
        return false, errors, "CHECKBOX_CLICK_FAIL"
    end
    sleep(0.5)

    -- Step 4: HID tap nút 応募する của FORM (eval lấy toạ độ) → mở popup xác nhận
    if not (safari and type(safari.eval) == "function") then
        table.insert(errors, "step4_apply: safari.eval chưa có → cần cập nhật daemon 1.0.43")
        notify("FAIL: cần daemon >= 1.0.43 (safari.eval)", 3)
        return false, errors, "NO_EVAL"
    end
    local ok4, diag4 = tapByEval(JS_FORM_APPLY_COORD, "form 応募する", 8)
    if not ok4 then
        table.insert(errors, "step4_apply: " .. tostring(diag4))
        notify("FAIL: không bấm được 応募する (form) - " .. tostring(diag4), 2)
        return false, errors, "APPLYBTN_CLICK_FAIL"
    end
    notify("Đã bấm 応募する (form): " .. tostring(diag4), 2)
    sleep(1.5)   -- chờ popup xác nhận hiện

    -- Step 5: HID tap nút 応募する TRONG popup (eval lấy toạ độ; nút popup bỏ qua JS click)
    local ok5, diag5 = tapByEval(JS_POPUP_APPLY_COORD, "popup 応募する", 8)
    if not ok5 then
        -- fallback: Magnific căn popup GIỮA màn → tap tâm cố định
        if type(tap) == "function" then
            tap(APPLY_MODAL_X, APPLY_MODAL_Y)
            notify(string.format("popup: fallback tap(%d,%d) [%s]", APPLY_MODAL_X, APPLY_MODAL_Y, tostring(diag5)), 2)
        else
            table.insert(errors, "step5_popup: " .. tostring(diag5))
            notify("FAIL: không xác nhận được popup - " .. tostring(diag5), 2)
            return false, errors, "POPUP_TAP_FAIL"
        end
    else
        notify("Đã xác nhận popup: " .. tostring(diag5), 2)
    end

    -- Step 6: chờ load trang kết quả
    local okLoad, diagLoad = waitLoad(30)
    if not okLoad then
        table.insert(errors, "step6_load: " .. tostring(diagLoad))
        notify("WARN: trang load chậm - " .. tostring(diagLoad), 2)
    end
    sleep(1)

    notify(string.format("OK: hoàn thành ứng tuyển item %d", n), 2)
    return true, {}, "OK"
end

-- Wrapper: ứng tuyển item cấu hình (APPLY_ITEM_INDEX). processOne gọi hàm này.
local function applyHonin()
    return applyItem(APPLY_ITEM_INDEX)
end

-- ========== MAIN FLOW 1 ACCOUNT ==========
local function processOne(key, accountNum)
    local rec, code, errCode, errMsg
    local failReason = nil

    -- Step 1: Clear Safari TRƯỚC (để không dính session cũ)
    notify("[#" .. accountNum .. "] Clear Safari...", 2)
    local okClear, clearDiag = clearSafari()
    if not okClear then
        notify("[#" .. accountNum .. "] Clear Safari lỗi: " .. tostring(clearDiag) .. " — vẫn tiếp tục", 2)
    end

    -- Step 2: Claim 1 dòng
    notify(string.format("[#%d] Đang lấy dòng chyusen (type=%s)...", accountNum, CHYUSEN_TYPE), 3)
    rec, code, errMsg = claimChyusen(key, CHYUSEN_TYPE)

    if not rec then
        -- Phân loại lỗi claim chi tiết
        if code == "EMPTY" then
            notify("[#" .. accountNum .. "] Hết dòng chyusen — dừng vòng lặp", 4)
            return "STOP_EMPTY", nil
        elseif code == "NETWORK_ERROR" then
            notify("[#" .. accountNum .. "] Lỗi mạng claim: " .. tostring(errMsg), 3)
            return "RETRY_NETWORK", nil
        elseif code == "UNAUTHORIZED" then
            notify("[#" .. accountNum .. "] API key sai hoặc hết hạn — dừng", 4)
            return "STOP_AUTH", nil
        elseif code == "SERVER_ERROR" then
            notify("[#" .. accountNum .. "] Server lỗi: " .. tostring(errMsg), 3)
            return "RETRY_SERVER", nil
        elseif code == "RATE_LIMIT" then
            notify("[#" .. accountNum .. "] Rate limit — chờ 30s rồi thử lại", 3)
            sleep(30)
            return "RETRY_RATE", nil
        elseif code == "MISSING_KEY" then
            notify("[#" .. accountNum .. "] Thiếu apikey — dừng", 4)
            return "STOP_CONFIG", nil
        elseif code == "INVALID_JSON" then
            notify("[#" .. accountNum .. "] API trả về JSON không hợp lệ: " .. tostring(errMsg), 3)
            return "RETRY_JSON", nil
        elseif code == "NOT_FOUND" then
            notify("[#" .. accountNum .. "] API endpoint không tồn tại — dừng", 4)
            return "STOP_API", nil
        else
            notify("[#" .. accountNum .. "] Claim lỗi [" .. tostring(code) .. "]: " .. tostring(errMsg), 3)
            return "RETRY_UNKNOWN", nil
        end
    end

    local id = rec.id
    notify(string.format("[#%d] Claim OK: id=%s", accountNum, tostring(id)), 3)

    -- Step 3: Reset mạng (có acc mới → đổi IP nhanh, không check, không chờ)
    resetNetwork()

    -- Step 4: Parse content (format: email|password|email_forward|app_password)
    local content = tostring(rec.content or "")

    -- Case 3a: Content rỗng
    if content == "" then
        failReason = "content rỗng"
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

    -- Case 3b: Tách 4 trường: email|password|email_forward|app_password
    local parts = {}
    for part in content:gmatch("[^|]+") do
        table.insert(parts, trim(part))
    end

    local email = parts[1]
    local password = parts[2]
    -- parts[3] = email_forward (API dùng để đọc mail)
    -- parts[4] = app_password (API dùng để đọc mail)

    if not email or email == "" then
        failReason = "content sai định dạng (thiếu email): " .. content:sub(1, 50)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

    if not password or password == "" then
        failReason = "content sai định dạng (thiếu password): " .. content:sub(1, 50)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

    -- Case 3c: Email không hợp lệ (không có @)
    if not email:find("@") then
        failReason = "email không hợp lệ (thiếu @): " .. email:sub(1, 30)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

    notify(string.format("[#%d] Account: %s", accountNum, email), 3)

    -- Step 5: Mở trang login
    notify("[#" .. accountNum .. "] Mở trang login...", 3)
    local okOpen, openDiag = openAndWait(LOGIN_URL, 30, 3)
    if not okOpen then
        failReason = "mở trang login lỗi: " .. tostring(openDiag)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

    -- Step 6: Gõ email
    humanPause(0.9, 2.0)
    local okEmail, emailDiag = typeWait(SEL_EMAIL, email, 10)
    if not okEmail then
        failReason = "gõ email lỗi: " .. tostring(emailDiag)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end
    notify("[#" .. accountNum .. "] Đã gõ email", 2)

    -- Step 7: Gõ password
    humanPause(0.5, 1.2)
    local okPass, passDiag = typeWait(SEL_PASSWORD, password, 10)
    if not okPass then
        failReason = "gõ password lỗi: " .. tostring(passDiag)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end
    notify("[#" .. accountNum .. "] Đã gõ password", 2)

    -- Step 8: Bấm login
    humanPause(0.6, 1.4)
    local okLogin, loginDiag = clickWait(SEL_LOGINBTN, 10)
    if not okLogin then
        failReason = "bấm login lỗi: " .. tostring(loginDiag)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end
    notify("[#" .. accountNum .. "] Đã bấm ログイン — chờ load...", 3)

    sleep(5)
    waitLoad(30)

    -- Step 9: Chờ trang passcode
    local okAuthCode, authDiag = clickWait("#authCode", 15)
    if not okAuthCode then
        -- Có thể: sai password, tài khoản bị khóa, hoặc đã login sẵn
        failReason = "không thấy trang passcode (#authCode): " .. tostring(authDiag) .. " (có thể sai password hoặc tài khoản bị khóa)"
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end
    notify("[#" .. accountNum .. "] Trang パスコード → chờ mail...", 3)

    -- Step 10: Poll lấy code
    local passcode, codeStatus, codeDiag = getChyusenCode(key, id, CODE_POLL_TRIES, CODE_POLL_GAP, CODE_POLL_MAX_SEC)
    if not passcode then
        if codeStatus == "BAD_CONFIG" then
            failReason = "thiếu email_forward/app_password trong dòng chyusen"
        elseif codeStatus == "NOT_FOUND" then
            failReason = "không tìm thấy dòng chyusen (id không tồn tại?)"
        elseif codeStatus == "MAIL_NOT_ARRIVED" then
            failReason = "mail không tới sau 100s poll"
        elseif codeStatus == "MAIL_SERVER_ERROR" then
            failReason = "lỗi kết nối mail server (sai app password?)"
        elseif codeStatus == "NETWORK_ERROR" then
            failReason = "lỗi mạng khi poll code"
        elseif codeStatus == "UNAUTHORIZED" then
            failReason = "apikey sai khi poll code"
        else
            failReason = "lấy code lỗi [" .. tostring(codeStatus) .. "]: " .. tostring(codeDiag)
        end
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

    -- Step 11: Gõ passcode
    humanPause(0.6, 1.4)
    local okCode, codeDiag2 = typeWait("#authCode", passcode, 10)
    if not okCode then
        failReason = "gõ passcode lỗi: " .. tostring(codeDiag2)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end
    notify("[#" .. accountNum .. "] Đã gõ passcode: " .. passcode, 2)

    -- Step 12: Bấm 認証する
    humanPause(0.6, 1.4)
    local okCertify, certifyDiag = clickWait("#certify", 10)
    if not okCertify then
        failReason = "bấm 認証する lỗi: " .. tostring(certifyDiag)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end
    notify("[#" .. accountNum .. "] Đã bấm 認証する — chờ load...", 3)

    sleep(5)
    waitLoad(30)

    notify("[#" .. accountNum .. "] ===== LOGIN THÀNH CÔNG =====", 3)

    -- Step 13: Web tự chuyển đến trang apply sau login
    -- Chờ trang load xong
    sleep(2)
    waitLoad(30)

    -- Step 14: Ứng tuyển 本人認証済み枠
    notify("[#" .. accountNum .. "] Bắt đầu ứng tuyển 本人認証済み枠...", 3)
    local okApply, errs, errCode = applyHonin()

    -- Step 15: Upload kết quả
    if okApply then
        uploadResult(key, id, "honin apply OK", "success")
        notify("[#" .. accountNum .. "] THÀNH CÔNG: 本人認証済み枠", 3)
    else
        local errMsg = table.concat(errs, "; ") .. " [" .. tostring(errCode) .. "]"
        uploadResult(key, id, "failed: " .. errMsg, "failed")
        notify("[#" .. accountNum .. "] THẤT BẠI: " .. errMsg, 3)
    end

    return "CONTINUE", rec
end

-- ========== MAIN LOOP ==========
notify("========== CHYUSEN HONIN 本人認証済み枠 (vô hạn, dừng khi hết acc 100 lần liên tiếp) ==========", 3)

-- Đọc config
local cfg, cfgErr = readConfig()
if cfgErr then
    notify("Lỗi đọc config: " .. cfgErr .. " — dừng", 5)
    return
end

local key = cfg.apikey or cfg.api_key or cfg["x-api-key"]
if not key or key == "" then
    notify("Không tìm thấy apikey trong config — dừng", 5)
    notify("Config path: " .. CONFIG_PATH, 3)
    notify("Cần có dòng: apikey=<your-key>", 3)
    return
end

local successTotal = 0
local failedTotal = 0
local errorRetryCount = 0      -- đếm retry lỗi mạng/server liên tiếp
local emptyRetryCount = 0      -- đếm retry khi hết acc liên tiếp

local n = 0
while true do
    n = n + 1

    if emptyRetryCount > 0 then
        notify(string.format("===== Lượt #%d (chờ acc mới: %d/%d) =====", n, emptyRetryCount, MAX_EMPTY_RETRY), 2)
    else
        notify(string.format("===== Lượt #%d =====", n), 2)
    end

    local ok, result = pcall(processOne, key, n)

    if not ok then
        -- pcall catch lỗi bất ngờ
        local errStr = tostring(result)

        -- Case: User dừng script
        if errStr:find("dừng", 1, true) or errStr:find("stop", 1, true) or errStr:find("abort", 1, true) then
            notify("Đã dừng theo yêu cầu người dùng (xong " .. successTotal .. " acc)", 3)
            break
        end

        -- Case: Lỗi bất ngờ khác
        notify("Lượt #" .. n .. " lỗi bất ngờ: " .. errStr, 4)
        failedTotal = failedTotal + 1
        errorRetryCount = errorRetryCount + 1

        if errorRetryCount >= MAX_ERROR_RETRY then
            notify("Quá nhiều lỗi liên tiếp (" .. MAX_ERROR_RETRY .. ") — dừng", 4)
            break
        end
    else
        -- Xử lý result code
        if result == "STOP_EMPTY" then
            -- Hết acc → tăng emptyRetryCount, chờ rồi thử lại
            emptyRetryCount = emptyRetryCount + 1
            n = n - 1  -- không tính lượt này

            if emptyRetryCount >= MAX_EMPTY_RETRY then
                notify(string.format("Đã thử %d lần mà vẫn hết acc — DỪNG HẲN", MAX_EMPTY_RETRY), 4)
                break
            end

            notify(string.format("Hết acc, chờ %ds rồi thử lại (%d/%d)...",
                EMPTY_RETRY_GAP, emptyRetryCount, MAX_EMPTY_RETRY), 2)
            sleep(EMPTY_RETRY_GAP)

        elseif result == "STOP_AUTH" then
            notify("API key sai — kết thúc vòng lặp", 4)
            break
        elseif result == "STOP_CONFIG" then
            notify("Lỗi config — kết thúc vòng lặp", 4)
            break
        elseif result == "STOP_API" then
            notify("API endpoint không tồn tại — kết thúc vòng lặp", 4)
            break
        elseif result:find("^RETRY") then
            -- Các case retry lỗi mạng/server
            n = n - 1  -- không tính lượt này
            errorRetryCount = errorRetryCount + 1
            if errorRetryCount >= MAX_ERROR_RETRY then
                notify("Quá nhiều retry lỗi liên tiếp (" .. MAX_ERROR_RETRY .. ") — dừng", 4)
                break
            end
            notify("Retry sau 5s...", 2)
            sleep(5)
        elseif result == "CONTINUE" then
            -- Đã xử lý xong 1 account (dù thành công hay thất bại)
            -- QUAN TRỌNG: Có acc mới → RESET emptyRetryCount về 0
            if emptyRetryCount > 0 then
                notify(string.format("Có acc mới! Reset empty retry counter (was %d)", emptyRetryCount), 3)
            end
            emptyRetryCount = 0
            errorRetryCount = 0  -- reset error retry counter
            successTotal = successTotal + 1
        else
            -- Case không xác định
            notify("Result không xác định: " .. tostring(result) .. " — tiếp tục", 2)
            errorRetryCount = 0
        end
    end

    sleep(2)
end

notify("========================================", 3)
notify(string.format("TỔNG KẾT: %d acc xử lý, %d lỗi bất ngờ, chờ acc %d lần",
    successTotal, failedTotal, emptyRetryCount), 4)
notify("========== KẾT THÚC ==========", 3)

--[[
  HƯỚNG DẪN CẤU HÌNH (本人認証済み枠 version):

  1. MAX_EMPTY_RETRY = 100  → khi hết acc, thử lại tối đa 100 lần rồi dừng hẳn
  2. EMPTY_RETRY_GAP = 10   → chờ 10s giữa mỗi lần retry khi hết acc

  FLOW ỨNG TUYỂN (item = APPLY_ITEM_INDEX trong ul.comOrderList, cần daemon >= 1.0.43 có safari.eval):
    Login → trang apply → 詳しく見る (dt) → chọn radio SP → tick 応募要項に同意する
          → HID tap 応募する (nút form; safari.eval tìm nút hiển thị ngoài popup + lấy toạ độ)
          → HID tap 応募する trong POPUP (safari.eval lấy toạ độ thật; fallback tap APPLY_MODAL_X/Y)
  ĐỔI ITEM: sửa APPLY_ITEM_INDEX ở đầu file (vd = 5 để nhắm item 5).

  LOGIC VÒNG LẶP:
    - Chạy VÔ HẠN, không giới hạn số lượng account
    - Khi hết acc (HTTP 409): chờ EMPTY_RETRY_GAP giây rồi thử lại
    - Nếu có acc mới: RESET emptyRetryCount về 0 (tiếp tục vô hạn)
    - Nếu thử MAX_EMPTY_RETRY lần liên tiếp mà vẫn hết: DỪNG HẲN

  STOP CODES (dừng vòng lặp ngay):
    STOP_AUTH    = apikey sai (HTTP 401/403)
    STOP_CONFIG  = thiếu apikey trong config
    STOP_API     = API endpoint không tồn tại (HTTP 404)

  RETRY CODES (thử lại, tối đa MAX_ERROR_RETRY lần liên tiếp):
    RETRY_NETWORK  = lỗi mạng tạm thời
    RETRY_SERVER   = server lỗi (5xx)
    RETRY_RATE     = rate limit (429)
    RETRY_JSON     = API trả về JSON không hợp lệ
    RETRY_UNKNOWN  = lỗi không xác định

  FAIL REASONS (upload vào result với status=failed):
    - content rỗng / sai định dạng / thiếu email / thiếu password
    - email không hợp lệ (thiếu @)
    - mở trang login lỗi
    - gõ email/password/passcode lỗi
    - bấm login/認証する lỗi
    - không thấy trang passcode (sai password / tài khoản khóa)
    - mail không tới / lỗi lấy code / thiếu email_forward/app_password
    - apply lỗi (detail/radio/checkbox/applyBtn/popup-modal)
]]
