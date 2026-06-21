-- Minimal test: verify Lua scripts work in test runner mode
emu.log("MINIMAL SCRIPT LOADED")

local f = io.open("D:\\Mesen2-Expanded\\diag_output.txt", "w")
if f then
    f:write("Lua script is working!\n")
    f:close()
    emu.log("File written successfully")
else
    emu.log("ERROR: io.open failed")
end

local count = 0
function onFrame()
    count = count + 1
    if count >= 5 then
        local f2 = io.open("D:\\Mesen2-Expanded\\diag_output.txt", "a")
        if f2 then
            f2:write("Frame " .. count .. " reached\n")
            f2:close()
        end
        emu.stop(0)
    end
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
