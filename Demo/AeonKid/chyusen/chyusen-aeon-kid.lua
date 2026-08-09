-- ============================================================================
-- chyusen-aeon-kid.lua — QUÉT TOÀN BỘ crane container của app AEON Kids Republic
-- (jp.aeonretail.aeon-kidsrepublic) rồi với TỪNG container: switch sang nó →
-- mở app → chạy hàm main(ctx). Mỗi container = 1 account cô lập (Crane isolate
-- cả data + keychain), nên đây là cách duyệt lần lượt mọi account đã tạo.
--
-- LUỒNG:
--   (1) đọc config-aeon-kids-iosauto.txt  (bundle, apikey, use4g, last_check, continue_after_last_check)
--   (2) crane.list(bundle) → danh sách {name,id} TẤT CẢ container; BỎ QUA "Default",
--       đánh số các container còn lại từ 1 (vd: Default, cbv, xyz → cbv=#1, xyz=#2)
--   (3) với mỗi container (từ #1, hoặc TIẾP TỤC sau last_check nếu bật):
--                           (a) đổi IP 4G nếu use4g=1
--                           (b) crane.switch(bundle, id)  (tự kill + relaunch app)
--                           (c) main(ctx)  ← nơi bạn viết thao tác cho 1 account
--                           (d) GHI last_check=<tên container> vào config (để lần sau resume)
--   Lỗi 1 container KHÔNG làm dừng vòng (log rồi sang container kế); chỉ lệnh
--   "Dừng" của người dùng mới thoát.
--
-- RESUME: continue_after_last_check=1 + last_check=cbv → chạy lại sẽ bắt đầu từ container
--   NGAY SAU cbv (tức xyz #2). =0 → luôn check lại từ #1. last_check là container CUỐI → hết việc.
--
-- YÊU CẦU: máy phải CÀI Crane (opa334) — không có thì crane.list trả nil,"chưa
-- cài Crane" và script dừng. Cần daemon iOSAuto có bảng Lua `crane` (xem crane.m).
-- ============================================================================

-- Path TUYỆT ĐỐI tới config trong scripts iOSAuto — cwd của engine Lua KHÔNG phải
-- thư mục này nên tên file trần io.open sẽ fail; phải dùng full path.
local CONFIG_PATH = "/var/jb/usr/local/iosauto/scripts/config-aeon-kids-iosauto.txt"

local BASE = "https://imapicloud.site"   -- host API (nếu main cần gọi)

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- notify: vừa log vừa toast cùng 1 thông điệp (dur giây, mặc định 3).
local function notify(msg, dur)
    log(msg)
    toast(msg, dur or 3)
end

-- readConfig: đọc key=value (bỏ dòng trống / bắt đầu bằng #). Trả bảng {key=value},
-- key hạ thường. Không mở được -> bảng rỗng.
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

local function isOn(v)
    v = trim(v):lower()
    return v == "1" or v == "true" or v == "on" or v == "yes"
end

-- setConfigKey: GHI ĐÈ 1 khoá trong config (giữ nguyên comment + các khoá khác). Nếu khoá đã có
-- (dòng không phải comment) → thay giá trị; chưa có → thêm vào cuối. Dùng để lưu last_check sau mỗi
-- container. Trả true nếu ghi được; false + lý do nếu mở/ghi file lỗi.
local function setConfigKey(keyName, value)
    value = tostring(value or "")
    local lines, found = {}, false
    local f = io.open(CONFIG_PATH, "r")
    if f then
        for line in f:lines() do
            local ln = (line:gsub("\r$", ""))                    -- bỏ CR nếu file CRLF
            local k = ln:match("^%s*([%w%._%-]+)%s*[:=]")        -- dòng comment (#...) → k=nil, giữ nguyên
            if k and k:lower() == keyName:lower() then
                lines[#lines + 1] = keyName .. " = " .. value
                found = true
            else
                lines[#lines + 1] = ln
            end
        end
        f:close()
    end
    if not found then lines[#lines + 1] = keyName .. " = " .. value end
    local w = io.open(CONFIG_PATH, "w")
    if not w then return false, "không mở được config để ghi" end
    w:write(table.concat(lines, "\n") .. "\n")
    w:close()
    return true
end

-- ===== Đổi IP 4G (tắt/bật sóng qua Airplane Mode) — port từ chyusen pokemon =====
local C4G_OFF_SECONDS = 5
local C4G_NET_WAIT    = 40
local C4G_IP_MAX_TRY  = 3
local C4G_READY_TRY   = 4
local C4G_READY_WAIT  = 1.5

local function getIpWait(timeout)
    if type(getPublicIp) ~= "function" then return nil end
    timeout = tonumber(timeout) or 30
    for _ = 1, math.max(1, math.floor(timeout / 2)) do
        local ip = getPublicIp()
        if ip and ip ~= "" then return ip end
        sleep(2)
    end
    return nil
end

local function airplaneOn()
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

-- holdAirplane: BẬT airplane → GIỮ secs giây → LUÔN bật lại sóng, kể cả khi bị Dừng.
local function holdAirplane(secs)
    local ok, err = airplaneOn()
    if not ok then return false, err end
    local held, herr = pcall(function() sleep(secs) end)
    setAirplane(false)
    if not held then error(herr, 0) end
    return true
end

-- cycle4g: nếu use4g bật → tắt/bật sóng xin IP mới, xác minh IP đã đổi (≤ C4G_IP_MAX_TRY lần).
local function cycle4g(use4g)
    if not use4g then return end
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

-- ===== Quét crane =====

-- scanContainers: crane.list(bundle) → mảng {name,id} của TẤT CẢ container. Trả
-- (mảng, nil) hoặc (nil, lỗi). Chưa cài Crane / daemon thiếu bảng crane → lỗi rõ.
local function scanContainers(bundle)
    if type(crane) ~= "table" or type(crane.list) ~= "function" then
        return nil, "daemon chưa có bảng Lua `crane` (cần build có crane.m)"
    end
    local list, err = crane.list(bundle)
    if not list then return nil, tostring(err or "crane.list trả nil") end
    return list
end

-- ===== HÀM MAIN: thao tác cho 1 container/account =====
-- ctx = { bundle=..., id=<uuid container>, name=<tên container>, index=i, total=n,
--         key=<apikey> }.  App ĐÃ được crane.switch launch sẵn ở foreground.
-- TODO: viết các bước thao tác thật cho 1 account vào đây (điều hướng app, đọc/ghi
-- API imapicloud, chụp OCR, v.v.). Trả "ok" khi xong, "skip" nếu bỏ qua.
local function main(ctx)
    notify(string.format("▶ Container %d/%d: %s (%s)",
        ctx.index, ctx.total, ctx.name, ctx.id), 3)

    -- App vừa được crane.switch mở lại — chờ nó vào foreground ổn định.
    sleep(3)

    -- ------------------------------------------------------------------
    -- === CHÈN THAO TÁC CHO 1 ACCOUNT Ở ĐÂY ===
    -- Ví dụ khung sẵn có thể dùng:
    --   launch(ctx.bundle)                 -- chắc chắn app ở foreground
    --   tapDump("...")                     -- tap theo nhãn accessibility
    --   tap(x, y) / swipe(...)             -- thao tác toạ độ
    --   local body, st = httpGet(BASE.."/api/v1/...", { ["x-api-key"]=ctx.key })
    -- ------------------------------------------------------------------

    notify(string.format("✔ Xong container %d/%d: %s", ctx.index, ctx.total, ctx.name), 2)
    return "ok"
end

-- ============================================================================
-- CHẠY: đọc config → quét toàn bộ container → lặp switch + main cho từng cái.
-- ============================================================================
local cfg = readConfig()
local bundle = cfg.bundle or cfg.app or "jp.aeonretail.aeon-kidsrepublic"
local key = cfg.apikey or cfg.api_key or cfg["x-api-key"]
local use4g = isOn(cfg.use4g)
local lastCheck = trim(cfg.last_check)
local resume = isOn(cfg.continue_after_last_check)

notify("Quét crane app: " .. bundle, 3)
local raw, err = scanContainers(bundle)
if not raw then
    notify("Không quét được crane: " .. tostring(err) .. " — dừng", 5)
    return
end

-- BỎ QUA container "Default" (name rỗng "" → cranectl hiển thị "Default"); đánh số các container
-- còn lại từ 1 theo đúng thứ tự crane.list trả về.
local containers = {}
for _, ct in ipairs(raw) do
    local nm = ct.name
    if nm ~= nil and nm ~= "" and nm ~= "Default" then
        containers[#containers + 1] = ct
    end
end

local total = #containers
if total == 0 then
    notify("App " .. bundle .. " KHÔNG có container Crane nào (ngoài Default) — dừng", 5)
    return
end

-- RESUME: nếu bật continue_after_last_check và last_check khớp 1 container → bắt đầu từ cái NGAY SAU.
-- Không khớp / để trống → bắt đầu từ #1. last_check là cái cuối → đã check hết.
local startIdx = 1
if resume and lastCheck ~= "" then
    local pos = nil
    for i, ct in ipairs(containers) do
        if ct.name == lastCheck then pos = i; break end
    end
    if pos then
        startIdx = pos + 1
        if startIdx > total then
            notify(string.format("last_check='%s' là container CUỐI (#%d/%d) — đã check hết, không còn gì để tiếp.",
                lastCheck, pos, total), 5)
            return
        end
        notify(string.format("Tiếp tục sau last_check='%s' → bắt đầu từ #%d/%d", lastCheck, startIdx, total), 4)
    else
        notify(string.format("last_check='%s' không khớp container nào — check lại từ #1", lastCheck), 4)
    end
else
    notify(string.format("Check từ đầu (#1). Tìm thấy %d container (ngoài Default) cho %s", total, bundle), 4)
end

local done = 0
for i = startIdx, total do
    local ct = containers[i]
    local name = ct.name
    local target = (ct.id and ct.id ~= "") and ct.id or ct.name   -- switch dùng id cho chắc

    local ok, res = pcall(function()
        -- (a) đổi IP 4G trước mỗi account nếu bật.
        cycle4g(use4g)

        -- (b) switch sang container này (crane.switch tự kill + relaunch app).
        notify(string.format("Switch → container %d/%d: %s (%s)", i, total, name, tostring(target)), 3)
        local sok, serr = crane.switch(bundle, target)
        if not sok then
            error("crane.switch lỗi: " .. tostring(serr or "false"), 0)
        end

        -- (c) chạy thao tác cho account này.
        return main({ bundle = bundle, id = ct.id, name = name,
                      index = i, total = total, key = key })
    end)

    if not ok and type(res) == "string" and res:find("dừng", 1, true) then
        -- Người dùng ấn Dừng GIỮA container này → KHÔNG ghi last_check (chưa check xong).
        notify("Đã dừng theo yêu cầu người dùng (đã xong " .. done .. " container lần này).", 4)
        return
    end

    -- (d) Container đã check xong (dù ok hay lỗi thao tác) → GHI last_check để lần sau resume tiếp.
    local wok, werr = setConfigKey("last_check", name)
    if not wok then notify("Ghi last_check lỗi: " .. tostring(werr), 3) end

    if ok then
        done = done + 1
        notify(string.format("✔ last_check='%s' (đã lưu, #%d/%d)", name, i, total), 2)
    else
        notify(string.format("Container %d/%d (%s) lỗi: %s → đã lưu last_check, sang container kế",
            i, total, name, tostring(res)), 4)
    end

    sleep(2)   -- nghỉ giữa 2 container (cũng là điểm để lệnh Dừng kịp thoát)
end

notify(string.format("HOÀN TẤT: đã xử lý %d container Crane của %s (last_check='%s')",
    done, bundle, containers[total].name), 5)
