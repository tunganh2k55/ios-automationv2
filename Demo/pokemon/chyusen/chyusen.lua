-- ============================================================================
-- chyusen.lua — Vòng lặp VÔ HẠN login + ứng tuyển chyusen
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
local CHYUSEN_TYPE = "pokemon"            -- loại chyusen
local LOGIN_URL    = "https://www.pokemoncenter-online.com/lottery/login.html"
local APPLY_URL    = "https://www.pokemoncenter-online.com/lottery/apply.html"
local LIST         = {2, 4, 6}            -- danh sách item cần ứng tuyển (1-indexed)

-- Selectors
local SEL_EMAIL    = "email"
local SEL_PASSWORD = "password"
local SEL_LOGINBTN = "a.loginBtn"

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

local function cycle4g()
    if not readUse4g() then return end
    if type(setAirplane) ~= "function" then
        notify("use4g BẬT nhưng daemon chưa hỗ trợ setAirplane — bỏ qua", 3)
        return
    end
    local oldIp = getIpWait(C4G_NET_WAIT)
    notify("Đổi 4G: IP hiện tại " .. tostring(oldIp or "?"), 2)
    for attempt = 1, C4G_IP_MAX_TRY do
        notify(string.format("Đổi 4G (lần %d/%d): ngắt sóng %ds...", attempt, C4G_IP_MAX_TRY, C4G_OFF_SECONDS), 2)
        local ok, err = holdAirplane(C4G_OFF_SECONDS)
        if not ok then
            notify("Đổi 4G lỗi: " .. tostring(err) .. " — bỏ qua", 3)
            return
        end
        notify("Đổi 4G: đã bật lại sóng, chờ mạng...", 2)
        local newIp = getIpWait(C4G_NET_WAIT)
        if not newIp then
            notify("Đổi 4G: mạng chưa lên lại sau " .. C4G_NET_WAIT .. "s", 3)
        elseif not oldIp or newIp ~= oldIp then
            notify("Đổi 4G OK - IP mới: " .. newIp, 3)
            return
        else
            notify(string.format("Đổi 4G: IP chưa đổi (%s)%s", newIp, attempt < C4G_IP_MAX_TRY and " — thử lại" or ""), 3)
            oldIp = newIp
        end
    end
    notify("Đổi 4G: thử " .. C4G_IP_MAX_TRY .. " lần chưa đổi được IP — vẫn tiếp tục", 3)
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

local function getChyusenCode(key, id, tries, gap)
    -- Case 1: Thiếu id
    if not id or id == "" then
        return nil, "MISSING_ID", "thiếu id"
    end

    tries = math.max(1, tonumber(tries) or 20)
    gap = tonumber(gap) or 5
    local url = BASE .. "/api/v1/chyusen/code?id=" .. tostring(id)
    local lastErr = "unknown"
    local lastCode = "UNKNOWN"

    for attempt = 1, tries do
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

    return nil, lastCode, "hết " .. tries .. " lần: " .. lastErr
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

-- ========== APPLY ITEM ==========
local function applyItem(idx)
    notify("--- Ứng tuyển ITEM " .. idx .. " ---", 2)
    local errors = {}

    -- Step 1: Click "詳しく見る" để mở chi tiết
    local selDetail = string.format("ul.comOrderList > li:nth-child(%d) dl.subDl dt", idx)
    local ok1, diag1 = clickWait(selDetail, 10)
    if not ok1 then
        table.insert(errors, "step1_detail: " .. tostring(diag1))
        notify("FAIL item " .. idx .. ": không mở được chi tiết - " .. tostring(diag1), 2)
        return false, errors, "DETAIL_CLICK_FAIL"
    end
    sleep(1)

    -- Step 2: Click radio chọn sản phẩm
    local selRadio = string.format('ul.comOrderList > li:nth-child(%d) input[type="radio"]', idx)
    local ok2, diag2 = clickWait(selRadio, 10)
    if not ok2 then
        table.insert(errors, "step2_radio: " .. tostring(diag2))
        notify("FAIL item " .. idx .. ": không chọn được radio - " .. tostring(diag2), 2)
        return false, errors, "RADIO_CLICK_FAIL"
    end
    sleep(0.5)

    -- Step 3: Check checkbox đồng ý
    local selCheckbox = string.format('ul.comOrderList > li:nth-child(%d) input[type="checkbox"].-check', idx)
    local ok3, diag3 = clickWait(selCheckbox, 10)
    if not ok3 then
        table.insert(errors, "step3_checkbox: " .. tostring(diag3))
        notify("FAIL item " .. idx .. ": không check được checkbox - " .. tostring(diag3), 2)
        return false, errors, "CHECKBOX_CLICK_FAIL"
    end
    sleep(0.5)

    -- Step 4: Click "応募する" mở popup
    local selApply = string.format('ul.comOrderList > li:nth-child(%d) a.popup-modal', idx)
    local ok4, diag4 = clickWait(selApply, 10)
    if not ok4 then
        table.insert(errors, "step4_popup: " .. tostring(diag4))
        notify("FAIL item " .. idx .. ": không bấm được 応募する - " .. tostring(diag4), 2)
        return false, errors, "POPUP_CLICK_FAIL"
    end
    sleep(1)

    -- Step 5: Click "#applyBtn" xác nhận
    local ok5, diag5 = clickWait("#applyBtn", 10)
    if not ok5 then
        table.insert(errors, "step5_applyBtn: " .. tostring(diag5))
        notify("FAIL item " .. idx .. ": không bấm được #applyBtn - " .. tostring(diag5), 2)
        return false, errors, "APPLYBTN_CLICK_FAIL"
    end

    -- Step 6: Chờ load
    local okLoad, diagLoad = waitLoad(30)
    if not okLoad then
        table.insert(errors, "step6_load: " .. tostring(diagLoad))
        notify("WARN item " .. idx .. ": trang load chậm - " .. tostring(diagLoad), 2)
        -- Không return false, coi như đã submit thành công
    end
    sleep(1)

    notify("OK: Hoàn thành item " .. idx, 2)
    return true, {}, "OK"
end

-- ========== MAIN FLOW 1 ACCOUNT ==========
local function processOne(key, accountNum)
    local rec, code, errCode, errMsg
    local failReason = nil

    -- Step 1: Đổi IP 4G
    cycle4g()

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

    -- Step 3: Parse content
    local content = tostring(rec.content or "")

    -- Case 3a: Content rỗng
    if content == "" then
        failReason = "content rỗng"
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

    -- Case 3b: Tách email|password
    local email, password = content:match("^%s*(.-)%s*|%s*(.-)%s*$")

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

    -- Step 4: Clear Safari
    local okClear, clearDiag = clearSafari()
    if not okClear then
        notify("[#" .. accountNum .. "] Clear Safari lỗi: " .. tostring(clearDiag) .. " — vẫn thử tiếp", 2)
        -- Không fail, vẫn thử login (có thể Safari đã sạch)
    end
    sleep(1)

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
    local passcode, codeStatus, codeDiag = getChyusenCode(key, id, 20, 5)
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

    -- Step 13: Mở trang apply
    notify("[#" .. accountNum .. "] Mở trang chyusen apply...", 3)
    local okApplyPage, applyPageDiag = openAndWait(APPLY_URL, 30, 3)
    if not okApplyPage then
        failReason = "mở trang apply lỗi: " .. tostring(applyPageDiag)
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

    -- Step 14: Ứng tuyển các items trong LIST
    notify(string.format("[#%d] Ứng tuyển %d items: %s", accountNum, #LIST, table.concat(LIST, ", ")), 3)
    local successCount = 0
    local failedItems = {}
    local itemErrors = {}

    for i, idx in ipairs(LIST) do
        notify(string.format("[#%d] >>> [%d/%d] ITEM %d <<<", accountNum, i, #LIST, idx), 2)
        local okItem, errs, errCode = applyItem(idx)
        if okItem then
            successCount = successCount + 1
        else
            table.insert(failedItems, idx)
            itemErrors[idx] = table.concat(errs, "; ") .. " [" .. tostring(errCode) .. "]"
            notify("[#" .. accountNum .. "] WARN: Item " .. idx .. " thất bại", 2)
        end
        sleep(1)
    end

    -- Step 15: Upload kết quả
    local resultMsg = string.format("items:%s success:%d/%d", table.concat(LIST, ","), successCount, #LIST)
    if #failedItems > 0 then
        resultMsg = resultMsg .. " failed:" .. table.concat(failedItems, ",")
    end

    if successCount > 0 then
        uploadResult(key, id, resultMsg, "success")
        notify(string.format("[#%d] THÀNH CÔNG: %d/%d items", accountNum, successCount, #LIST), 3)
    elseif successCount == 0 and #LIST > 0 then
        uploadResult(key, id, "failed: " .. resultMsg, "failed")
        notify(string.format("[#%d] THẤT BẠI: 0/%d items", accountNum, #LIST), 3)
    else
        -- LIST rỗng
        uploadResult(key, id, "login OK, no items to apply", "success")
        notify(string.format("[#%d] Login OK nhưng LIST rỗng", accountNum), 3)
    end

    return "CONTINUE", rec
end

-- ========== MAIN LOOP ==========
notify("========== CHYUSEN LOOP (vô hạn, dừng khi hết acc 100 lần liên tiếp) ==========", 3)

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
  HƯỚNG DẪN CẤU HÌNH:

  1. LIST = {2, 4, 6}  → items cần ứng tuyển
  2. MAX_EMPTY_RETRY = 100  → khi hết acc, thử lại tối đa 100 lần rồi dừng hẳn
  3. EMPTY_RETRY_GAP = 5    → chờ 5s giữa mỗi lần retry khi hết acc

  LOGIC VÒNG LẶP:
    - Chạy VÔ HẠN, không giới hạn số lượng account
    - Khi hết acc (HTTP 409): chờ EMPTY_RETRY_GAP giây rồi thử lại
    - Nếu có acc mới: RESET emptyRetryCount về 0 (tiếp tục vô hạn)
    - Nếu thử MAX_EMPTY_RETRY lần liên tiếp mà vẫn hết: DỪNG HẲN

  DANH SÁCH ITEMS:
    1 = 本人認証済み枠 - MEGA 拡張パック 30th CELEBRATION BOX
    2 = 本人未認証枠 - MEGA 拡張パック 30th CELEBRATION BOX
    3 = 本人認証済み枠 - プレミアムデッキセット エーフィ・ブラッキー
    4 = 本人未認証枠 - プレミアムデッキセット エーフィ・ブラッキー
    5 = 本人認証済み枠 - FUTURISTIC BOX
    6 = 本人未認証枠 - FUTURISTIC BOX

  STOP CODES (dừng vòng lặp ngay):
    STOP_AUTH    = apikey sai (HTTP 401/403)
    STOP_CONFIG  = thiếu apikey trong config
    STOP_API     = API endpoint không tồn tại (HTTP 404)

  STOP_EMPTY = hết acc → KHÔNG dừng ngay, mà retry tới MAX_EMPTY_RETRY lần

  RETRY CODES (thử lại, tối đa MAX_ERROR_RETRY lần liên tiếp):
    RETRY_NETWORK  = lỗi mạng tạm thời
    RETRY_SERVER   = server lỗi (5xx)
    RETRY_RATE     = rate limit (429)
    RETRY_JSON     = API trả về JSON không hợp lệ
    RETRY_UNKNOWN  = lỗi không xác định

  CONTINUE = đã xử lý xong 1 account → RESET emptyRetryCount về 0

  FAIL REASONS (upload vào result với status=failed):
    - content rỗng / sai định dạng / thiếu email / thiếu password
    - email không hợp lệ (thiếu @)
    - mở trang login/apply lỗi
    - gõ email/password/passcode lỗi
    - bấm login/認証する lỗi
    - không thấy trang passcode (sai password / tài khoản khóa)
    - mail không tới / lỗi lấy code / thiếu email_forward/app_password
    - apply item lỗi (detail/radio/checkbox/popup/applyBtn)
]]
