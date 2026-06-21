emu.log("=== MINIMAL TEST STARTED ===")

local count = 0
function onFrame()
    count = count + 1
    emu.log("Frame " .. count)
    if count >= 3 then
        local f = io.open("D:\\tmp\\lua_test_output.txt", "w")
        if f then
            f:write("Lua works! Reached frame " .. count .. "\n")
            f:close()
            emu.log("File written")
        else
            emu.log("ERROR: io.open failed")
        end
        emu.stop(0)
    end
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
