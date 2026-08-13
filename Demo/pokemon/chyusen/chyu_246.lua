-- ============================================================================
-- chyu_v44_B.lua — Vòng lặp VÔ HẠN login + ứng tuyển chyusen
-- v1.0.44-B (2026-08-13)
--
-- Thay đổi so với chyusen_v44.lua:
--   - Phương án B: Poll song song sau login — fail nhanh nếu lỗi, chờ lâu cho authCode
--   - Loop tối đa 30s (6 lần × 5s): check lỗi/reauth/authCode mỗi lần
--   - Sai pass/reauth → xử lý ngay; authCode → chờ page load xong mới thấy
--
-- Flow mỗi lượt:
--   (1) Check license pokemontool → (2) Đổi IP 4G (nếu use4g=1) → (3) Claim 1 dòng
--   → (4) Clear Safari → (5) Login (email+password) → (6) Poll 3 trạng thái (30s)
--   → (7) Poll code từ API → (8) Nhập passcode + xác thực → (9) Ứng tuyển LIST items
--   → (10) Upload kết quả
-- ============================================================================

local BASE = "https://imapicloud.site"
local CONFIG_PATH = "/var/jb/usr/local/iosauto/scripts/config_reg_poke.txt"

-- ========== CẤU HÌNH ==========
local CHYUSEN_TYPE = "pokemon"
local LOGIN_URL    = "https://www.pokemoncenter-online.com/lottery/login.html"
local APPLY_URL    = "https://www.pokemoncenter-online.com/lottery/apply.html"

local APPLY_ITEMS = { 2, 4, 6 }

-- Selectors
local SEL_EMAIL    = "email"
local SEL_PASSWORD = "password"
local SEL_LOGINBTN = "a.loginBtn"

local APPLY_MODAL_X = 187
local APPLY_MODAL_Y = 293

-- 4G settings
local C4G_OFF_SECONDS = 5
local C4G_NET_WAIT    = 40
local C4G_IP_MAX_TRY  = 3
local C4G_READY_TRY   = 4
local C4G_READY_WAIT  = 1.5

-- Retry settings
local MAX_EMPTY_RETRY = 100
local EMPTY_RETRY_GAP = 10
local MAX_ERROR_RETRY = 10

-- Poll code xác thực
local CODE_POLL_TRIES   = 36
local CODE_POLL_GAP     = 5
local CODE_POLL_MAX_SEC = 180

-- Login state poll settings (Phương án B)
local LOGIN_STATE_TIMEOUT = 30    -- tổng thời gian chờ (giây)
local LOGIN_STATE_GAP     = 5     -- nghỉ giữa mỗi lần check (giây)

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
    notify("Reset mạng: đã bật lại sóng, chờ 5s...", 2)
    sleep(5)
    notify("Reset mạng: OK", 2)
end

-- ========== API FUNCTIONS ==========
local function claimChyusen(key, ctype)
    if not key or key == "" then
        return nil, "MISSING_KEY", "thiếu apikey"
    end

    local url = BASE .. "/api/v1/chyusen/claim"
    if ctype and ctype ~= "" then url = url .. "?type=" .. ctype end

    local body, st = httpGet(url, { ["x-api-key"] = key })

    if not body then
        return nil, "NETWORK_ERROR", "lỗi mạng: " .. tostring(st)
    end

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

    if st == 409 then return nil, "EMPTY", "hết dòng chyusen chưa lấy" end
    if st == 400 then return nil, "BAD_REQUEST", "HTTP 400: " .. tostring(body):sub(1, 100) end
    if st == 401 or st == 403 then return nil, "UNAUTHORIZED", "HTTP " .. st .. ": apikey sai hoặc hết hạn" end
    if st == 404 then return nil, "NOT_FOUND", "HTTP 404: API endpoint không tồn tại" end
    if st == 429 then return nil, "RATE_LIMIT", "HTTP 429: quá nhiều request, thử lại sau" end
    if st >= 500 then return nil, "SERVER_ERROR", "HTTP " .. st .. ": server lỗi" end

    return nil, "HTTP_ERROR", string.format("HTTP %s: %s", tostring(st), tostring(body):sub(1, 100))
end

local function uploadResult(key, id, result, status)
    if not id or id == "" then
        notify("uploadResult: thiếu id — bỏ qua", 2)
        return nil, "MISSING_ID"
    end

    if not result then result = "unknown" end
    status = (status == "failed") and "failed" or "success"

    local payload = jsonEncode({ id = id, result = result, status = status })
    if not payload then
        notify("uploadResult: jsonEncode lỗi", 2)
        return nil, "JSON_ENCODE_ERROR"
    end

    local resp, st = httpPost(BASE .. "/api/v1/chyusen/result", payload,
        "application/json", { ["x-api-key"] = key })

    if not resp then
        notify("uploadResult: lỗi mạng " .. tostring(st), 3)
        return nil, "NETWORK_ERROR"
    end

    local d = jsonDecode(resp)
    if not d then
        notify("uploadResult: không parse được response: " .. tostring(resp):sub(1, 100), 3)
        return nil, "INVALID_JSON"
    end

    if (st == 200 or st == 201) and d.ok then
        notify("Upload [" .. status .. "] OK cho id=" .. tostring(id), 3)
        return d.record or d, "OK"
    end

    notify(string.format("uploadResult HTTP %s: %s", tostring(st), tostring(resp):sub(1, 100)), 3)
    return nil, "HTTP_" .. tostring(st)
end

local function getChyusenCode(key, id, tries, gap, maxSec)
    if not id or id == "" then
        return nil, "MISSING_ID", "thiếu id"
    end

    tries = math.max(1, tonumber(tries) or 20)
    gap = tonumber(gap) or 5
    maxSec = tonumber(maxSec) or (tries * gap)
    local startT = (os and os.time) and os.time() or nil
    local url = BASE .. "/api/v1/chyusen/code?id=" .. tostring(id)
    local lastErr = "unknown"
    local lastCode = "UNKNOWN"

    for attempt = 1, tries do
        if startT and (os.time() - startT) >= maxSec then
            notify(string.format("getCode: đã chờ ~%ds (trần %ds) → dừng poll", os.time() - startT, maxSec), 2)
            break
        end
        local body, st = httpGet(url, { ["x-api-key"] = key })

        if not body then
            lastErr = "lỗi mạng: " .. tostring(st)
            lastCode = "NETWORK_ERROR"
            notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
            if attempt < tries then sleep(gap) end
            goto continue
        end

        if st == 200 then
            local d = jsonDecode(body)
            if not d then
                lastErr = "không parse được JSON"
                lastCode = "INVALID_JSON"
                notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
                if attempt < tries then sleep(gap) end
                goto continue
            end

            if d.found and d.code and d.code ~= "" then
                notify(string.format("Code OK (lần %d): %s", attempt, tostring(d.code)), 3)
                return d.code, "OK", nil
            end

            lastErr = "mail chưa tới (found=" .. tostring(d.found) .. ")"
            lastCode = "MAIL_NOT_ARRIVED"
            notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
            if attempt < tries then sleep(gap) end
            goto continue
        end

        if st == 400 then return nil, "BAD_CONFIG", "HTTP 400: thiếu email_forward/app_password trong dòng chyusen" end
        if st == 404 then return nil, "NOT_FOUND", "HTTP 404: không tìm thấy dòng chyusen id=" .. tostring(id) end
        if st == 401 or st == 403 then return nil, "UNAUTHORIZED", "HTTP " .. st .. ": apikey sai" end

        if st == 502 then
            lastErr = "HTTP 502: lỗi kết nối mail server (sai app password?)"
            lastCode = "MAIL_SERVER_ERROR"
            notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
            if attempt < tries then sleep(gap) end
            goto continue
        end

        if st == 503 or st == 504 then
            lastErr = "HTTP " .. st .. ": server tạm không khả dụng"
            lastCode = "SERVER_UNAVAILABLE"
            notify(string.format("getCode %d/%d: %s", attempt, tries, lastErr), 2)
            if attempt < tries then sleep(gap) end
            goto continue
        end

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

        if not okCall then
            lastDiag = "exception: " .. tostring(ok)
            if i < tries then sleep(gap) end
            goto continue
        end

        if ok then return true, diag, i end

        lastDiag = tostring(diag or "unknown")

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
    if not safari then
        return false, "safari object không tồn tại"
    end
    if type(safari.type) ~= "function" then
        return false, "safari.type chưa có (cần daemon mới có WEBTYPE)"
    end

    if not field or field == "" then
        return false, "field rỗng"
    end
    if not value then
        return false, "value nil"
    end

    return waitFor(function() return safari.type(field, value) end, timeout, 0.5)
end

local function clickWait(field, timeout)
    if not safari then
        return false, "safari object không tồn tại"
    end
    if type(safari.click) ~= "function" then
        return false, "safari.click chưa có"
    end

    if not field or field == "" then
        return false, "selector rỗng"
    end

    return waitFor(function() return safari.click(field) end, timeout, 0.5)
end

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
    if type(safari.click) == "function" then
        return waitFor(function() return safari.click(field) end, timeout, 0.5)
    end
    return false, "safari.checkbox/click chưa có"
end

local function clearSafari()
    if safari and type(safari.clear) == "function" then
        local okCall, ok, count, diag = pcall(safari.clear)
        if okCall and ok then
            notify(string.format("Safari clear OK - xóa %s mục", tostring(count)), 2)
            return true, "OK"
        end
        notify("safari.clear lỗi: " .. tostring(count or diag) .. " — thử clearAppData", 2)
    end

    if type(clearAppData) == "function" then
        local okCall, ok, count = pcall(clearAppData, "com.apple.mobilesafari")
        if okCall and ok then
            notify("clearAppData Safari OK - " .. tostring(count) .. " mục", 2)
            return true, "OK"
        end
        return false, "clearAppData lỗi: " .. tostring(ok or count)
    end

    return false, "không có hàm clear Safari (daemon quá cũ)"
end

-- ========== APPLY (dùng safari.eval — daemon >= 1.0.43) ==========
local function evalStr(js)
    if not (safari and type(safari.eval) == "function") then
        return nil, "safari.eval chưa có (cần daemon >= 1.0.43)"
    end
    local ok, a, b = pcall(safari.eval, js)
    if not ok then return nil, "eval exception: " .. tostring(a) end
    if a == nil then return nil, tostring(b or "eval lỗi") end
    return a, nil
end

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

local JS_FORM_APPLY_COORD = [[
var as=document.querySelectorAll('a,button');
for(var i=0;i<as.length;i++){var a=as[i];
if((a.textContent||'').indexOf('応募する')<0)continue;
if(a.closest&&(a.closest('.mfp-content')||a.closest('#pop01')))continue;
var r=a.getBoundingClientRect();if(r.width<=0||r.height<=0)continue;
return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);}
return '0,0';
]]

local JS_POPUP_APPLY_COORD = [[
var as=document.querySelectorAll('.mfp-content a,.mfp-content button,#pop01 a,#pop01 button');
for(var i=0;i<as.length;i++){var a=as[i];
if((a.textContent||'').indexOf('応募する')<0)continue;
var r=a.getBoundingClientRect();if(r.width<=0||r.height<=0)continue;
return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);}
return '0,0';
]]

local function applyItem(n)
    local ITEM = string.format("ul.comOrderList > li:nth-child(%d)", n)
    notify(string.format("--- Ứng tuyển item %d ---", n), 2)
    local errors = {}

    local ok1, diag1 = clickWait(ITEM .. " dt", 10)
    if not ok1 then
        table.insert(errors, "step1_detail: " .. tostring(diag1))
        notify("FAIL: không mở được chi tiết - " .. tostring(diag1), 2)
        return false, errors, "DETAIL_CLICK_FAIL"
    end
    sleep(1)

    local ok2, diag2 = checkboxWait(ITEM, 10)
    if not ok2 then
        table.insert(errors, "step2_radio: " .. tostring(diag2))
        notify("FAIL: không chọn được radio - " .. tostring(diag2), 2)
        return false, errors, "RADIO_CLICK_FAIL"
    end
    sleep(0.5)

    local ok3, diag3 = checkboxWait(ITEM .. ' input[type="checkbox"]', 10)
    if not ok3 then ok3, diag3 = checkboxWait("応募要項に同意する", 6) end
    if not ok3 then
        table.insert(errors, "step3_checkbox: " .. tostring(diag3))
        notify("FAIL: không tick được đồng ý - " .. tostring(diag3), 2)
        return false, errors, "CHECKBOX_CLICK_FAIL"
    end
    sleep(0.5)

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
    sleep(1.5)

    local ok5, diag5 = tapByEval(JS_POPUP_APPLY_COORD, "popup 応募する", 8)
    if not ok5 then
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

    sleep(5)

    local okLoad, diagLoad = waitLoad(30)
    if not okLoad then
        table.insert(errors, "step6_load: " .. tostring(diagLoad))
        notify("WARN: trang load chậm - " .. tostring(diagLoad), 2)
    end
    sleep(1)

    notify(string.format("OK: hoàn thành ứng tuyển item %d", n), 2)
    return true, {}, "OK"
end

local function dismissPopup()
    if not (safari and type(safari.eval) == "function") then return end
    pcall(safari.eval, [[
var as=document.querySelectorAll('.mfp-content a,.mfp-content button,#pop01 a,#pop01 button,.mfp-close');
for(var i=0;i<as.length;i++){var a=as[i];var t=(a.textContent||'')+' '+(a.className||'');
if(t.indexOf('閉じる')>=0||t.indexOf('close')>=0||t.indexOf('mfp-close')>=0){
var r=a.getBoundingClientRect();if(r.width>0&&r.height>0){a.click();return 'closed';}}}
return 'none';
]])
end

local function applyAll()
    local total = #APPLY_ITEMS
    if total == 0 then return false, { "APPLY_ITEMS rỗng — chưa cấu hình item" }, "NO_ITEMS" end
    local okList, failList, allErrors = {}, {}, {}
    for idx, n in ipairs(APPLY_ITEMS) do
        notify(string.format("=== Item %d/%d (nth-child %d) ===", idx, total, n), 2)
        local ok, errs = applyItem(n)
        if ok then
            table.insert(okList, n)
        else
            table.insert(failList, n)
            for _, e in ipairs(errs or {}) do table.insert(allErrors, string.format("li%d:%s", n, tostring(e))) end
        end
        if idx < total then
            dismissPopup()
            sleep(1.5)
        end
    end
    local summary
    if #okList > 0 then
        summary = "ok:" .. table.concat(okList, ",")
        if #failList > 0 then summary = summary .. "-fail" .. table.concat(failList, ",") end
    else
        summary = "fail:" .. table.concat(failList, ",")
    end
    if #okList == 0 then return false, allErrors, summary end
    return true, allErrors, summary
end

-- ========== MAIN FLOW 1 ACCOUNT ==========
local function processOne(key, accountNum)
    local rec, code, errCode, errMsg
    local failReason = nil

    -- Step 1: Clear Safari
    notify("[#" .. accountNum .. "] Clear Safari...", 2)
    local okClear, clearDiag = clearSafari()
    if not okClear then
        notify("[#" .. accountNum .. "] Clear Safari lỗi: " .. tostring(clearDiag) .. " — vẫn tiếp tục", 2)
    end

    -- Step 2: Claim 1 dòng
    notify(string.format("[#%d] Đang lấy dòng chyusen (type=%s)...", accountNum, CHYUSEN_TYPE), 3)
    rec, code, errMsg = claimChyusen(key, CHYUSEN_TYPE)

    if not rec then
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

    -- Step 3: Reset mạng
    resetNetwork()

    -- Step 4: Parse content
    local content = tostring(rec.content or "")

    if content == "" then
        failReason = "content rỗng"
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

    local parts = {}
    for part in content:gmatch("[^|]+") do
        table.insert(parts, trim(part))
    end

    local email = parts[1]
    local password = parts[2]

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

    -- Step 8: Bấm login (có retry nếu bắt xác thực lại)
    local MAX_LOGIN_RETRY = 2
    local loginAttempt = 0
    local passcodePassed = false

    -- JS kiểm tra trạng thái sau login
    local JS_CHECK_LOGIN_STATE = [[
var authCode = document.querySelector('#authCode');
if (authCode) return 'authcode';
var body = document.body ? document.body.innerText : '';
if (body.indexOf('認証し直す') >= 0 || body.indexOf('再度ログイン') >= 0 || body.indexOf('もう一度ログイン') >= 0)
    return 'reauth';
var errBox = document.querySelector('.err, .error, .errMsg, .errorMessage, [class*="error"]');
if (errBox && errBox.innerText && errBox.innerText.trim().length > 0)
    return 'error:' + errBox.innerText.trim().substring(0, 100);
if (body.indexOf('メールアドレスまたはパスワードが正しくありません') >= 0)
    return 'error:メールアドレスまたはパスワードが正しくありません';
if (body.indexOf('ログインできませんでした') >= 0)
    return 'error:ログインできませんでした';
return 'unknown';
]]

    -- Vòng lặp login (retry nếu reauth)
    while loginAttempt <= MAX_LOGIN_RETRY do
        loginAttempt = loginAttempt + 1
        notify(string.format("[#%d] Bấm ログイン (lần %d/%d)...", accountNum, loginAttempt, MAX_LOGIN_RETRY + 1), 2)

        humanPause(0.6, 1.4)
        local okLogin, loginDiag = clickWait(SEL_LOGINBTN, 10)
        if not okLogin then
            failReason = "bấm login lỗi: " .. tostring(loginDiag)
            notify("[#" .. accountNum .. "] " .. failReason, 3)
            uploadResult(key, id, "failed: " .. failReason, "failed")
            return "CONTINUE", rec
        end
        notify("[#" .. accountNum .. "] Đã bấm ログイン — bắt đầu poll trạng thái...", 3)

        -- ========== PHƯƠNG ÁN B: Poll song song 30s ==========
        -- Loop tối đa 30s (6 lần × 5s):
        --   - Check lỗi (sai pass) → fail ngay
        --   - Check reauth → retry login ngay
        --   - Check authCode → tiếp tục flow
        --   - Chưa thấy gì → sleep 5s, tiếp tục poll
        local maxPolls = math.floor(LOGIN_STATE_TIMEOUT / LOGIN_STATE_GAP)
        local loginState = "unknown"
        local pollCount = 0
        local shouldRetryLogin = false

        for poll = 1, maxPolls do
            pollCount = poll
            notify(string.format("[#%d] Poll trạng thái %d/%d...", accountNum, poll, maxPolls), 2)

            local stateRes, stateDiag = evalStr(JS_CHECK_LOGIN_STATE)
            if stateRes then
                loginState = tostring(stateRes)
            else
                loginState = "eval_error:" .. tostring(stateDiag)
            end

            notify(string.format("[#%d] State: %s", accountNum, loginState), 2)

            -- Case A: Trang nhập code → OK, tiếp tục flow
            if loginState == "authcode" then
                notify("[#" .. accountNum .. "] Thấy #authCode → tiếp tục flow", 3)
                local okAuthCode, authDiag = clickWait("#authCode", 5)
                if okAuthCode then
                    notify("[#" .. accountNum .. "] Trang パスコード → chờ mail...", 3)
                    passcodePassed = true
                    break
                end
            end

            -- Case B: Sai email/password → fail ngay (không chờ tiếp)
            if loginState:sub(1, 6) == "error:" then
                local errMsg = loginState:sub(7)
                failReason = "sai email/password: " .. errMsg
                notify("[#" .. accountNum .. "] " .. failReason, 3)
                uploadResult(key, id, "failed: " .. failReason, "failed")
                return "CONTINUE", rec
            end

            -- Case C: Bắt xác thực lại → đánh dấu retry, thoát poll loop
            if loginState == "reauth" then
                notify(string.format("[#%d] Bắt xác thực lại — chờ 5s rồi thử lại...", accountNum), 3)
                sleep(5)
                shouldRetryLogin = true
                break
            end

            -- Chưa thấy gì → sleep 5s rồi poll tiếp
            if poll < maxPolls then
                notify(string.format("[#%d] Chưa thấy gì, chờ %ds...", accountNum, LOGIN_STATE_GAP), 2)
                sleep(LOGIN_STATE_GAP)
            end
        end

        -- Nếu đã vào trang passcode → thoát vòng login
        if passcodePassed then
            break
        end

        -- Nếu cần retry login → tiếp tục vòng while
        if shouldRetryLogin then
            -- continue to next iteration
        else
            -- Hết 30s mà vẫn không thấy gì → fail
            failReason = string.format("không xác định được trạng thái sau login sau %ds (state=%s, %d lần poll)",
                LOGIN_STATE_TIMEOUT, loginState, pollCount)
            notify("[#" .. accountNum .. "] " .. failReason, 3)
            uploadResult(key, id, "failed: " .. failReason, "failed")
            return "CONTINUE", rec
        end
    end

    -- Nếu retry hết lần mà vẫn reauth
    if not passcodePassed then
        failReason = "bắt xác thực lại quá " .. MAX_LOGIN_RETRY .. " lần"
        notify("[#" .. accountNum .. "] " .. failReason, 3)
        uploadResult(key, id, "failed: " .. failReason, "failed")
        return "CONTINUE", rec
    end

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

    -- Step 13: Chờ trang apply load
    sleep(2)
    waitLoad(30)

    -- Step 14: Ứng tuyển
    notify("[#" .. accountNum .. "] Bắt đầu ứng tuyển...", 3)
    local okApply, errs, errCode = applyAll()

    -- Step 15: Upload kết quả
    local detail = tostring(errCode)
    if errs and #errs > 0 then detail = detail .. " | " .. table.concat(errs, "; ") end
    if okApply then
        uploadResult(key, id, detail, "success")
    else
        uploadResult(key, id, "failed: " .. detail, "failed")
    end
    notify("[#" .. accountNum .. "] " .. tostring(errCode), 3)

    return "CONTINUE", rec
end

-- ================= LICENSE (tool: pokemontool) =================
local LICENSE_BASE = "https://iosautos.com"
local LICENSE_SLUG = "pokemontool"

local function licPost(path, tbl)
    local resp, st = httpPost(LICENSE_BASE .. path, jsonEncode(tbl), "application/json")
    if not resp then log("license: lỗi mạng " .. tostring(st)); return nil end
    return jsonDecode(resp) or {}, st
end

local function ensureLicense()
    local mid = trim(getSN())
    if mid == "" then notify("Không lấy được serial máy (getSN)", 5); return false end

    local d = licPost("/api/verify/device", { tool = LICENSE_SLUG, machineId = mid })
    if not d then notify("Lỗi mạng khi kiểm license", 5); return false end
    log(string.format("license: serial=%s valid=%s reason=%s expiresAt=%s",
        mid, tostring(d.valid), tostring(d.reason), tostring(d.expiresAt)))
    if d.valid == true then notify("License OK (pokemontool)", 2); return true end

    local msg = ({
        not_found   = "Máy này chưa được cấp license pokemontool",
        expired     = "License đã hết hạn",
        revoked     = "License đã bị thu hồi",
        bad_request = "Thiếu serial/tool khi kiểm license",
    })[tostring(d.reason)] or ("License không hợp lệ: " .. tostring(d.reason))
    notify("X " .. msg, 5)
    return false
end

-- ========== MAIN LOOP ==========
notify("========== CHYUSEN v44-B (poll song song, sleep 5s) ==========", 3)

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
local errorRetryCount = 0
local emptyRetryCount = 0

local n = 0
while true do
    n = n + 1

    if not ensureLicense() then
        notify("Dừng: license pokemontool không hợp lệ", 4)
        break
    end

    if emptyRetryCount > 0 then
        notify(string.format("===== Lượt #%d (chờ acc mới: %d/%d) =====", n, emptyRetryCount, MAX_EMPTY_RETRY), 2)
    else
        notify(string.format("===== Lượt #%d =====", n), 2)
    end

    local ok, result = pcall(processOne, key, n)

    if not ok then
        local errStr = tostring(result)

        if errStr:find("dừng", 1, true) or errStr:find("stop", 1, true) or errStr:find("abort", 1, true) then
            notify("Đã dừng theo yêu cầu người dùng (xong " .. successTotal .. " acc)", 3)
            break
        end

        notify("Lượt #" .. n .. " lỗi bất ngờ: " .. errStr, 4)
        failedTotal = failedTotal + 1
        errorRetryCount = errorRetryCount + 1

        if errorRetryCount >= MAX_ERROR_RETRY then
            notify("Quá nhiều lỗi liên tiếp (" .. MAX_ERROR_RETRY .. ") — dừng", 4)
            break
        end
    else
        if result == "STOP_EMPTY" then
            emptyRetryCount = emptyRetryCount + 1
            n = n - 1

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
            n = n - 1
            errorRetryCount = errorRetryCount + 1
            if errorRetryCount >= MAX_ERROR_RETRY then
                notify("Quá nhiều retry lỗi liên tiếp (" .. MAX_ERROR_RETRY .. ") — dừng", 4)
                break
            end
            notify("Retry sau 5s...", 2)
            sleep(5)
        elseif result == "CONTINUE" then
            if emptyRetryCount > 0 then
                notify(string.format("Có acc mới! Reset empty retry counter (was %d)", emptyRetryCount), 3)
            end
            emptyRetryCount = 0
            errorRetryCount = 0
            successTotal = successTotal + 1
        else
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
  HƯỚNG DẪN CẤU HÌNH (v44-B — Phương án B: poll song song):

  PHƯƠNG ÁN B - Poll song song sau login:
    - Sau khi bấm login, KHÔNG chờ safari.load
    - Loop tối đa 30s (6 lần × 5s):
      + Check lỗi (sai pass) → FAIL NGAY (không chờ tiếp)
      + Check reauth → RETRY LOGIN NGAY
      + Check #authCode → TIẾP TỤC FLOW
      + Chưa thấy gì → sleep 5s, tiếp tục poll
    - Hết 30s mà không thấy gì → fail

  ƯU ĐIỂM:
    - Sai pass → fail ngay sau ~5s (không chờ 30s vô ích)
    - Reauth → retry ngay
    - AuthCode → chờ đủ lâu cho page load (tối đa 30s)
    - Không phụ thuộc safari.load (có thể timeout dù page OK)

  CẤU HÌNH:
    LOGIN_STATE_TIMEOUT = 30    -- tổng thời gian poll (giây)
    LOGIN_STATE_GAP     = 5     -- nghỉ giữa mỗi lần poll (giây)
]]
