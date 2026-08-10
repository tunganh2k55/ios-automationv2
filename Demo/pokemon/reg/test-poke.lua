-- Test: Mở link Pokemon Center và click vào ô email
-- safari.click sẽ tự swipe + sleep 0.5s + click

-- 1. Mở Safari với link login
openUrl("https://www.pokemoncenter-online.com/login")
sleep(3)

-- 2. Chờ trang load xong
local ok, diag = safari.load(30)
if not ok then
    log("Trang không load được: " .. tostring(diag))
    return
end
log("Trang đã load xong")

-- 3. Click vào ô email (dùng id selector)
sleep(1)
local clicked, msg = safari.click("#login-form-email")
if clicked then
    log("Đã click vào ô email: " .. tostring(msg))
else
    log("Không click được ô email: " .. tostring(msg))
    -- Thử bằng placeholder text
    clicked, msg = safari.click("メールアドレス")
    if clicked then
        log("Click bằng placeholder thành công: " .. tostring(msg))
    else
        log("Click bằng placeholder thất bại: " .. tostring(msg))
    end
end
