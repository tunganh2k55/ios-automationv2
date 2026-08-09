local function contains_ci(h, n)
    return h and n and n ~= "" and string.find(h:lower(), n:lower(), 1, true) ~= nil
end

function FindTextRegion(text, region, tries, lang)
    assert(type(text) == "string" and text ~= "", "FindTextRegion: 'text' phải là chuỗi khác rỗng")
    region = region or {}
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

return FindTextRegion
