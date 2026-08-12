-- test-click.lua: Debug safari.click với checkbox
-- Mở trang đăng ký Pokemon có 2 checkbox (#terms, #privacyPolicy) rồi chạy script này

local function notify(msg, dur)
    log(msg)
    toast(msg, dur or 3)
end

notify("===== TEST CLICK DEBUG =====", 3)
sleep(1)

-- Test 1: Kiểm tra VNC tap hoạt động không (tap giữa màn hình)
notify("Test 1: VNC tap(188, 300) - khoảng giữa màn hình", 3)
tap(188, 300)
sleep(2)

-- Test 2: Click #terms bằng safari.click
notify("Test 2: safari.click #terms", 3)
local ok1, diag1 = safari.click("#terms")
notify("  Result: ok=" .. tostring(ok1) .. " diag=" .. tostring(diag1), 3)
sleep(2)

-- Test 3: Click #privacyPolicy bằng safari.click
notify("Test 3: safari.click #privacyPolicy", 3)
local ok2, diag2 = safari.click("#privacyPolicy")
notify("  Result: ok=" .. tostring(ok2) .. " diag=" .. tostring(diag2), 3)
sleep(2)

-- Test 4: Click #registration_button
-- notify("Test 4: safari.click #registration_button", 3)
-- local ok3, diag3 = safari.click("#registration_button")
-- notify("  Result: ok=" .. tostring(ok3) .. " diag=" .. tostring(diag3), 3)
-- sleep(2)

notify("===== TEST XONG =====", 4)
notify("Kiểm tra: 2 checkbox đã tick chưa? Form đã submit chưa?", 5)
