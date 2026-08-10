-- Test: kiểm tra tweak đã cài đúng chưa

local function notify(msg, dur)
    log(msg)
    toast(msg, dur or 3)
end

-- Kiểm tra file tweak tồn tại
local paths = {
    "/var/jb/Library/MobileSubstrate/DynamicLibraries/iOSAutoTouch.dylib",
    "/var/jb/Library/MobileSubstrate/DynamicLibraries/iOSAutoTouch.plist",
}

for _, p in ipairs(paths) do
    local f = io.open(p, "r")
    if f then
        f:close()
        notify("OK: " .. p, 2)
    else
        notify("MISSING: " .. p, 3)
    end
end

notify("Nếu file OK mà vẫn không hoạt động -> cần RESPRING để load lại tweak", 5)
