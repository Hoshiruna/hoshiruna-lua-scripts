-- VDP diagnostic script for debugging black screen issue
-- Runs for N frames, then dumps state, CRAM, VRAM nametable, framebuffer to file.

local frameTarget = 120  -- wait 2 seconds of emulation
local frameCount = 0
local outPath = "D:\\Mesen2-Expanded\\diag_output.txt"

local function log(msg)
    emu.log(msg)
end

function onEndFrame()
    frameCount = frameCount + 1
    if frameCount < frameTarget then return end

    local f = io.open(outPath, "w")
    local function flog(msg)
        log(msg)
        if f then f:write(msg .. "\n") end
    end

    flog("=== VDP DIAGNOSTIC (frame " .. frameCount .. ") ===")

    -- 1. Get emulator state (includes VDP registers)
    local state = emu.getState()
    flog("masterClock: " .. tostring(state["masterClock"]))
    flog("frameCount: " .. tostring(state["frameCount"]))

    -- Dump all state keys that contain "vdp" or "reg"
    flog("--- VDP-related state keys ---")
    local vdpKeys = {}
    for k, _ in pairs(state) do
        if string.find(string.lower(k), "vdp") or string.find(string.lower(k), "reg") then
            table.insert(vdpKeys, k)
        end
    end
    table.sort(vdpKeys)
    for _, k in ipairs(vdpKeys) do
        flog(string.format("  %s = %s", k, tostring(state[k])))
    end

    -- Also dump keys containing display-related terms
    flog("--- Display-related state keys ---")
    local dispKeys = {}
    for k, _ in pairs(state) do
        local lk = string.lower(k)
        if string.find(lk, "disp") or string.find(lk, "plane") or
           string.find(lk, "scroll") or string.find(lk, "sprite") or
           string.find(lk, "slot") or string.find(lk, "line") or
           string.find(lk, "fifo") or string.find(lk, "mclk") then
            dispKeys[k] = true
        end
    end
    local sortedDisp = {}
    for k in pairs(dispKeys) do table.insert(sortedDisp, k) end
    table.sort(sortedDisp)
    for _, k in ipairs(sortedDisp) do
        flog(string.format("  %s = %s", k, tostring(state[k])))
    end

    -- 2. CRAM (all 64 colors = 128 bytes)
    flog("--- CRAM (64 colors, 128 bytes) ---")
    local cramStr = ""
    for i = 0, 127 do
        local val = emu.read(i, emu.memType.genesisColorRam)
        cramStr = cramStr .. string.format("%02X", val)
        if i % 2 == 1 then cramStr = cramStr .. " " end
        if i % 32 == 31 then
            flog(cramStr)
            cramStr = ""
        end
    end
    if #cramStr > 0 then flog(cramStr) end

    -- 3. VRAM samples at common nametable locations
    local vramSamples = {0xC000, 0xE000, 0xA000, 0xB800, 0xD000, 0xF000, 0x0000}
    for _, base in ipairs(vramSamples) do
        flog(string.format("--- VRAM $%04X, first 64 bytes ---", base))
        local vramStr = ""
        for i = 0, 63 do
            local val = emu.read(base + i, emu.memType.genesisVideoRam)
            vramStr = vramStr .. string.format("%02X", val)
            if i % 2 == 1 then vramStr = vramStr .. " " end
            if i % 32 == 31 then
                flog(vramStr)
                vramStr = ""
            end
        end
        if #vramStr > 0 then flog(vramStr) end
    end

    -- 4. Framebuffer analysis
    flog("--- Framebuffer ---")
    local screenSize = emu.getScreenSize()
    flog(string.format("screenSize: %dx%d", screenSize.width, screenSize.height))

    local buf = emu.getScreenBuffer()
    if buf then
        flog("screenBuffer length: " .. #buf)
        -- Count non-black pixels
        local nonBlack = 0
        local firstNonBlack = -1
        local totalPixels = math.min(#buf, screenSize.width * screenSize.height)
        for i = 1, totalPixels do
            local px = buf[i]
            if px ~= 0 and px ~= -16777216 then
                nonBlack = nonBlack + 1
                if firstNonBlack < 0 then firstNonBlack = i - 1 end
            end
        end
        flog(string.format("nonBlack pixels: %d / %d (first at index %d)",
            nonBlack, totalPixels, firstNonBlack))

        -- Dump first 16 pixels of selected scanlines
        for _, line in ipairs({0, 1, 2, 3, 4, 50, 100, 112, 200}) do
            if line < screenSize.height then
                local lineStr = string.format("line %3d: ", line)
                local lineBase = line * screenSize.width
                for x = 0, 15 do
                    local idx = lineBase + x + 1
                    if idx <= #buf then
                        lineStr = lineStr .. string.format("%08X ", buf[idx] & 0xFFFFFFFF)
                    end
                end
                flog(lineStr)
            end
        end
    else
        flog("getScreenBuffer() returned nil!")
    end

    -- 5. VSRAM
    flog("--- VSRAM (first 40 bytes) ---")
    local vsramStr = ""
    for i = 0, 39 do
        local val = emu.read(i, emu.memType.genesisVScrollRam)
        vsramStr = vsramStr .. string.format("%02X", val)
        if i % 2 == 1 then vsramStr = vsramStr .. " " end
    end
    flog(vsramStr)

    flog("=== END DIAGNOSTIC ===")

    if f then f:close() end
    emu.stop(0)
end

emu.addEventCallback(onEndFrame, emu.eventType.endFrame)
emu.log("VDP diagnostic script loaded, waiting " .. frameTarget .. " frames...")
