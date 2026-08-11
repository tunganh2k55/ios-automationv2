-- test-chyusen-one.lua
-- Flow hoàn chỉnh 1 tài khoản: Login → Passcode → Ứng tuyển chyusen
-- Claim từ API → Login → Lấy code → Xác thực → Ứng tuyển LIST items → Upload kết quả

local BASE = "https://imapicloud.site"
local CONFIG_PATH = "/var/jb/usr/local/iosauto/scripts/config_reg_poke.txt"

-- ========== CẤU HÌNH ==========
local CHYUSEN_TYPE = "pokemon"
local LOGIN_URL    = "https://www.pokemoncenter-online.com/lottery/login.html"
local APPLY_URL    = "https://www.pokemoncenter-online.com/lottery/apply.html"
local LIST = {2, 4, 6}   -- danh sách item cần ứng tuyển (1-indexed)

-- Selectors
local SEL_EMAIL    = "email"
local SEL_PASSWORD = "password"
local SEL_LOGINBTN = "a.loginBtn"

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

-- ========== API FUNCTIONS ==========
local function claimChyusen(key, ctype)
    local url = BASE .. "/api/v1/chyusen/claim"
    if ctype and ctype ~= "" then url = url .. "?type=" .. ctype end
    local body, st = httpGet(url, { ["x-api-key"] = key })
    if not body then
        notify("claimChyusen: lỗi mạng " .. tostring(st), 3)
        return nil
    end
    if st == 200 then
        local d = jsonDecode(body) or {}
        if d.id then
            notify(string.format("Claim OK: id=%s (còn %s)", tostring(d.id), tostring(d.remaining)), 3)
            return d
        end
    elseif st == 409 then
        notify("Hết dòng chyusen chưa lấy", 3)
    else
        notify(string.format("claimChyusen HTTP %s: %s", tostring(st), tostring(body)), 3)
    end
    return nil
end

local function uploadResult(key, id, result, status)
    if not id or id == "" then return nil end
    status = (status == "failed") and "failed" or "success"
    local payload = jsonEncode({ id = id, result = result, status = status })
    local resp, st = httpPost(BASE .. "/api/v1/chyusen/result", payload,
        "application/json", { ["x-api-key"] = key })
    if not resp then notify("uploadResult: lỗi mạng", 3); return nil end
    local d = jsonDecode(resp) or {}
    if (st == 200 or st == 201) and d.ok then
        notify("Upload [" .. status .. "] OK cho id=" .. tostring(id), 3)
        return d.record or d
    end
    notify(string.format("uploadResult HTTP %s: %s", tostring(st), tostring(resp)), 3)
    return nil
end

local function getChyusenCode(key, id, tries, gap)
    if not id or id == "" then return nil, "thiếu id" end
    tries = math.max(1, tonumber(tries) or 20)
    gap = tonumber(gap) or 5
    local url = BASE .. "/api/v1/chyusen/code?id=" .. tostring(id)
    for attempt = 1, tries do
        local body, st = httpGet(url, { ["x-api-key"] = key })
        if st == 200 then
            local d = jsonDecode(body) or {}
            if d.found and d.code and d.code ~= "" then
                notify(string.format("Code OK (lần %d): %s", attempt, tostring(d.code)), 3)
                return d.code
            end
            notify(string.format("Poll %d/%d: mail chưa tới", attempt, tries), 2)
        elseif st == 400 or st == 404 then
            return nil, string.format("HTTP %s", tostring(st))
        else
            notify(string.format("Poll %d/%d: HTTP %s", attempt, tries, tostring(st)), 2)
        end
        if attempt < tries then sleep(gap) end
    end
    return nil, "hết " .. tries .. " lần chưa có code"
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
        if ok then notify("Trang load xong", 2) end
        return ok
    end
    sleep(3)
    return true
end

local function openAndWait(url, timeout)
    openUrl(url)
    sleep(2)
    return waitLoad(timeout)
end

local function waitFor(fn, timeout, gap)
    timeout = tonumber(timeout) or 10
    gap = tonumber(gap) or 0.5
    local tries = math.max(1, math.floor(timeout / gap))
    for i = 1, tries do
        local ok, diag = fn()
        if ok then return true, diag end
        if type(diag) == "string" and diag:find("foreground") then
            ensureSafari()
        elseif i < tries then
            sleep(gap)
        end
    end
    return false
end

local function typeWait(field, value, timeout)
    if type(safari.type) ~= "function" then
        return false, "safari.type chưa có"
    end
    return waitFor(function() return safari.type(field, value) end, timeout, 0.5)
end

local function clickWait(field, timeout)
    return waitFor(function() return safari.click(field) end, timeout, 0.5)
end

-- ========== CHYUSEN APPLY ==========
local function applyItem(idx)
    notify("--- Ứng tuyển ITEM " .. idx .. " ---", 2)

    -- (1) Click "詳しく見る"
    local selDetail = string.format("ul.comOrderList > li:nth-child(%d) dl.subDl dt", idx)
    if not clickWait(selDetail, 10) then
        notify("FAIL: không mở được chi tiết item " .. idx, 2)
        return false
    end
    sleep(1)

    -- (2) Click radio chọn sản phẩm
    local selRadio = string.format('ul.comOrderList > li:nth-child(%d) input[type="radio"]', idx)
    if not clickWait(selRadio, 10) then
        notify("FAIL: không chọn được sản phẩm", 2)
        return false
    end
    sleep(0.5)

    -- (3) Check checkbox đồng ý
    local selCheckbox = string.format('ul.comOrderList > li:nth-child(%d) input[type="checkbox"].-check', idx)
    if not clickWait(selCheckbox, 10) then
        notify("FAIL: không check được checkbox", 2)
        return false
    end
    sleep(0.5)

    -- (4) Click "応募する" mở popup
    local selApply = string.format('ul.comOrderList > li:nth-child(%d) a.popup-modal', idx)
    if not clickWait(selApply, 10) then
        notify("FAIL: không bấm được 応募する", 2)
        return false
    end
    sleep(1)

    -- (5) Click "#applyBtn" xác nhận
    if not clickWait("#applyBtn", 10) then
        notify("FAIL: không bấm được #applyBtn", 2)
        return false
    end

    -- Chờ load
    waitLoad(30)
    sleep(1)

    notify("OK: Hoàn thành item " .. idx, 2)
    return true
end

-- ========== MAIN ==========
notify("========== CHYUSEN 1 TÀI KHOẢN ==========", 3)

-- Đọc config
local cfg = readConfig()
local key = cfg.apikey or cfg.api_key or cfg["x-api-key"]
if not key or key == "" then
    notify("Không đọc được apikey từ config — dừng", 5)
    return
end

-- (1) Claim 1 dòng
local rec = claimChyusen(key, CHYUSEN_TYPE)
if not rec then
    notify("Không lấy được dòng chyusen — dừng", 4)
    return
end

-- Tách email|password
local content = tostring(rec.content or "")
local parts = {}
for part in content:gmatch("[^|]+") do
    table.insert(parts, trim(part))
end
local email = parts[1]
local password = parts[2]
if not email or email == "" or not password or password == "" then
    notify("Content sai định dạng: " .. content, 4)
    uploadResult(key, rec.id, "failed: format sai", "failed")
    return
end
notify(string.format("Account: %s", email), 3)

-- (2) Clear Safari
notify("Clear Safari...", 2)
local okClear, infoClear, diagClear = safari.clear()
if okClear then
    notify(string.format("Safari clear OK - xóa %s mục", tostring(infoClear)), 2)
else
    notify("Safari clear lỗi: " .. tostring(infoClear), 2)
end
sleep(1)

-- (3) Mở trang login
notify("Mở trang login...", 3)
if not openAndWait(LOGIN_URL, 30) then
    uploadResult(key, rec.id, "failed: mở trang lỗi", "failed")
    return
end

-- (4) Gõ email
humanPause(0.9, 2.0)
if not typeWait(SEL_EMAIL, email, 10) then
    uploadResult(key, rec.id, "failed: gõ email lỗi", "failed")
    return
end
notify("Đã gõ email", 2)

-- (5) Gõ password
humanPause(0.5, 1.2)
if not typeWait(SEL_PASSWORD, password, 10) then
    uploadResult(key, rec.id, "failed: gõ password lỗi", "failed")
    return
end
notify("Đã gõ password", 2)

-- (6) Bấm login
humanPause(0.6, 1.4)
if not clickWait(SEL_LOGINBTN, 10) then
    uploadResult(key, rec.id, "failed: bấm login lỗi", "failed")
    return
end
notify("Đã bấm ログイン — chờ load...", 3)
sleep(5)
waitLoad(30)

-- (7) Chờ trang passcode
if not clickWait("#authCode", 12) then
    uploadResult(key, rec.id, "failed: không thấy trang passcode", "failed")
    return
end
notify("Trang パスコード → chờ mail...", 3)

-- (8) Poll lấy code
local code, cerr = getChyusenCode(key, rec.id, 20, 5)
if not code then
    notify("Không lấy được code: " .. tostring(cerr), 4)
    uploadResult(key, rec.id, "failed: " .. tostring(cerr), "failed")
    return
end

-- (9) Gõ passcode
humanPause(0.6, 1.4)
if not typeWait("#authCode", code, 10) then
    uploadResult(key, rec.id, "failed: gõ passcode lỗi", "failed")
    return
end
notify("Đã gõ passcode: " .. code, 2)

-- (10) Bấm 認証する
humanPause(0.6, 1.4)
if not clickWait("#certify", 10) then
    uploadResult(key, rec.id, "failed: bấm 認証する lỗi", "failed")
    return
end
notify("Đã bấm 認証する — chờ load...", 3)
sleep(5)
waitLoad(30)

notify("===== LOGIN THÀNH CÔNG =====", 3)

-- (11) Mở trang ứng tuyển
notify("Mở trang chyusen apply...", 3)
if not openAndWait(APPLY_URL, 30) then
    uploadResult(key, rec.id, "failed: mở trang apply lỗi", "failed")
    return
end

-- (12) Ứng tuyển các items trong LIST
notify(string.format("Ứng tuyển %d items: %s", #LIST, table.concat(LIST, ", ")), 3)
local successCount = 0
for i, idx in ipairs(LIST) do
    notify(string.format(">>> [%d/%d] ITEM %d <<<", i, #LIST, idx), 2)
    local ok = applyItem(idx)
    if ok then
        successCount = successCount + 1
    else
        notify("WARN: Item " .. idx .. " thất bại", 2)
    end
    sleep(1)
end

-- (13) Upload kết quả
local resultMsg = string.format("items:%s success:%d/%d", table.concat(LIST, ","), successCount, #LIST)
if successCount > 0 then
    uploadResult(key, rec.id, resultMsg, "success")
else
    uploadResult(key, rec.id, "failed: " .. resultMsg, "failed")
end

notify("========== HOÀN THÀNH ==========", 4)
notify(string.format("Kết quả: %d/%d items thành công", successCount, #LIST), 4)

--[[
  HƯỚNG DẪN:

  1. Cấu hình LIST = {2, 4, 6} để chọn items cần ứng tuyển

  DANH SÁCH ITEMS:
    1 = 本人認証済み枠 - MEGA 拡張パック 30th CELEBRATION BOX
    2 = 本人未認証枠 - MEGA 拡張パック 30th CELEBRATION BOX
    3 = 本人認証済み枠 - プレミアムデッキセット エーフィ・ブラッキー
    4 = 本人未認証枠 - プレミアムデッキセット エーフィ・ブラッキー
    5 = 本人認証済み枠 - FUTURISTIC BOX
    6 = 本人未認証枠 - FUTURISTIC BOX
]]
