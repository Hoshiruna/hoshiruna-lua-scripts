-- =============================================================================
-- Mesen2 Reference Data Collection Script
-- Collects per-frame data for comparison against BlastEm reference output.
--
-- Available data through Lua API in this build:
--   P0: Frame buffer (emu.takeScreenshot / emu.getScreenBuffer)
--   P1: 68K CPU registers via emu.getState() (D0-D7, A0-A7, PC, SR, SP, USP)
--   P2: VDP register file via emu.getState() (R0-R23, status, H/V, HV counter)
--   P3: VRAM/CRAM/VSRAM (emu.read with memory types)
--   Metadata: frameCount, masterClock, screen size
--
-- Usage (Headless Mode):
--   Mesen.exe --testRunner collect_reference_data.lua xxx.bin
-- =============================================================================

-- ======================== CONFIGURATION ========================
local TOTAL_FRAMES    = 50
local OUTPUT_DIR      = "D:\\Mesen2-Expanded\\Core\\Genesis\\mesen_reference"
local WAIT_FOR_MANUAL_RESET = false
-- do not reset from Lua; begin capture only after a manual ROM reset is detected
local AUTO_STOP_AFTER_CAPTURE = true
local STOP_DELAY_FRAMES = 15
-- What to dump
local DUMP_FRAMES     = true   -- P0: frame buffer PNGs
local DUMP_STATE      = true   -- P1/P2: CPU + VDP state via emu.getState()
local DUMP_VRAM       = true   -- P3: VRAM/CRAM/VSRAM binary dumps
local DUMP_VRAM_EVERY = 10     -- dump VRAM/CRAM/VSRAM every N frames (1=every)
local DUMP_WORKRAM    = false  -- dump 68K work RAM (64KB) — expensive
local DUMP_VDP_TRACES = true   -- Genesis VDP trace buffers via emu.getGenesisVdpTrace()
-- ===============================================================
local VDP_TRACE_FRAME_END = math.max(TOTAL_FRAMES + STOP_DELAY_FRAMES + 4, 260)

local frameCount = 0
local metaFile = nil
local stateFile = nil
local spriteTraceFile = nil
local composeTraceFile = nil
local scrollTraceFile = nil
local dmaTraceFile = nil
local hscrollDmaTraceFile = nil
local stateWarnedMissing = false
local traceWarnedMissing = false
local captureStarted = not WAIT_FOR_MANUAL_RESET
local resetDetected = not WAIT_FOR_MANUAL_RESET
local lastMasterClock = nil
local sawPreResetRuntime = false
local captureFinished = false
local pendingStopFrames = nil
local traceDataSeen = false

local function fatalStop(text)
    emu.log("FATAL: " .. text)
    emu.displayMessage("RefCapture", "FATAL: " .. text)
    error(text, 0)
end

local function getMasterClock()
    local state = emu.getState()
    return state["masterClock"] or 0
end

local function getGenesisVdpFrameCount()
    if not emu.getGenesisVdpDebugState then
        return 0
    end

    local vdpState = emu.getGenesisVdpDebugState()
    if not vdpState then
        return 0
    end

    return vdpState["frameCount"] or 0
end

local function showStatus(text)
    emu.log(text)
    emu.displayMessage("RefCapture", text)
end

local function ensureDir(path)
    os.execute('mkdir "' .. path .. '" 2>NUL')
end

local function padNum(n, width)
    return string.format("%0" .. width .. "d", n)
end

local function stateValue(state, key, default)
    local value = state[key]
    if value == nil then
        return default
    end
    return value
end

-- Dump raw memory region to a binary file
local function dumpMemory(path, memType, size)
    local f = io.open(path, "wb")
    if not f then
        emu.log("ERROR: cannot open " .. path)
        return
    end
    -- Build string in chunks for performance
    local chunks = {}
    local chunk = {}
    for i = 0, size - 1 do
        chunk[#chunk + 1] = string.char(emu.read(i, memType))
        if #chunk >= 4096 then
            chunks[#chunks + 1] = table.concat(chunk)
            chunk = {}
        end
    end
    if #chunk > 0 then
        chunks[#chunks + 1] = table.concat(chunk)
    end
    f:write(table.concat(chunks))
    f:close()
end

-- Setup output directories
local function setup()
    ensureDir(OUTPUT_DIR)
    if DUMP_FRAMES then
        ensureDir(OUTPUT_DIR .. "\\frames")
    end
    if DUMP_VRAM then
        ensureDir(OUTPUT_DIR .. "\\vram")
        ensureDir(OUTPUT_DIR .. "\\cram")
        ensureDir(OUTPUT_DIR .. "\\vsram")
    end

    -- Metadata log: one line per frame with what we CAN read
    metaFile = io.open(OUTPUT_DIR .. "\\frame_meta.log", "w")
    if metaFile then
        metaFile:write("# frame masterClock screenW screenH\n")
    end

    if DUMP_STATE then
        stateFile = io.open(OUTPUT_DIR .. "\\cpu_vdp_state.log", "w")
        if stateFile then
            stateFile:write("# frame mclk pc sr sp usp stopped hc vc hv status displayEnabled")
            for i = 0, 7 do stateFile:write(" d" .. i) end
            for i = 0, 7 do stateFile:write(" a" .. i) end
            for i = 0, 23 do stateFile:write(string.format(" r%02d", i)) end
            stateFile:write("\n")
        end
    end

    if DUMP_VDP_TRACES then
        spriteTraceFile = io.open(OUTPUT_DIR .. "\\sprite_trace.log", "w")
        composeTraceFile = io.open(OUTPUT_DIR .. "\\compose_trace.log", "w")
        scrollTraceFile = io.open(OUTPUT_DIR .. "\\scroll_trace.log", "w")
        dmaTraceFile = io.open(OUTPUT_DIR .. "\\dma_trace.log", "w")
        hscrollDmaTraceFile = io.open(OUTPUT_DIR .. "\\hscroll_dma_trace.log", "w")
    end
end

-- P0: Save frame as PNG
local function dumpFrameBuffer(frame)
    local pngData = emu.takeScreenshot()
    if pngData and #pngData > 0 then
        local path = OUTPUT_DIR .. "\\frames\\frame_" .. padNum(frame, 6) .. ".png"
        local f = io.open(path, "wb")
        if f then
            f:write(pngData)
            f:close()
        end
        return true
    end

    -- Fallback: raw RGBA from getScreenBuffer
    local screenSize = emu.getScreenSize()
    local buf = emu.getScreenBuffer()
    if buf then
        local path = OUTPUT_DIR .. "\\frames\\frame_" .. padNum(frame, 6) .. ".bin"
        local f = io.open(path, "wb")
        if f then
            local chunks = {}
            local chunk = {}
            for i = 1, screenSize.width * screenSize.height do
                local px = buf[i]
                local r = (px >> 16) & 0xFF
                local g = (px >> 8) & 0xFF
                local b = px & 0xFF
                chunk[#chunk + 1] = string.char(r, g, b, 0xFF)
                if #chunk >= 1024 then
                    chunks[#chunks + 1] = table.concat(chunk)
                    chunk = {}
                end
            end
            if #chunk > 0 then
                chunks[#chunks + 1] = table.concat(chunk)
            end
            f:write(table.concat(chunks))
            f:close()
        end
        return true
    end
    return false
end

-- P3: VRAM/CRAM/VSRAM dumps
local function dumpVramSet(frame)
    local tag = padNum(frame, 6)

    local vramSize  = emu.getMemorySize(emu.memType.genesisVideoRam)
    local cramSize  = emu.getMemorySize(emu.memType.genesisColorRam)
    local vsramSize = emu.getMemorySize(emu.memType.genesisVScrollRam)

    dumpMemory(OUTPUT_DIR .. "\\vram\\vram_"   .. tag .. ".bin", emu.memType.genesisVideoRam, vramSize)
    dumpMemory(OUTPUT_DIR .. "\\cram\\cram_"   .. tag .. ".bin", emu.memType.genesisColorRam, cramSize)
    dumpMemory(OUTPUT_DIR .. "\\vsram\\vsram_" .. tag .. ".bin", emu.memType.genesisVScrollRam, vsramSize)

    if DUMP_WORKRAM then
        local wramSize = emu.getMemorySize(emu.memType.genesisWorkRam)
        ensureDir(OUTPUT_DIR .. "\\workram")
        dumpMemory(OUTPUT_DIR .. "\\workram\\wram_" .. tag .. ".bin", emu.memType.genesisWorkRam, wramSize)
    end
end

-- Per-frame metadata
local function logFrameMeta(frame)
    if not metaFile then return end
    local state = emu.getState()
    local screenSize = emu.getScreenSize()
    metaFile:write(string.format("%s %010d %d %d\n",
        padNum(frame, 6),
        state["masterClock"] or 0,
        screenSize.width,
        screenSize.height))
    metaFile:flush()
end

local function logGenesisState(frame)
    if not stateFile then return end

    local state = emu.getState()
    if state["cpu.pc"] == nil or state["vdp.status"] == nil then
        if not stateWarnedMissing then
            emu.log("Genesis CPU/VDP Lua state keys are not available in this build.")
            stateWarnedMissing = true
        end
        return
    end

    local parts = {
        padNum(frame, 6),
        string.format("mclk=%010d", stateValue(state, "masterClock", 0)),
        string.format("pc=%06X", stateValue(state, "cpu.pc", 0)),
        string.format("sr=%04X", stateValue(state, "cpu.sr", 0)),
        string.format("sp=%08X", stateValue(state, "cpu.sp", 0)),
        string.format("usp=%08X", stateValue(state, "cpu.usp", 0)),
        string.format("stopped=%d", stateValue(state, "cpu.stopped", false) and 1 or 0),
        string.format("hc=%03d", stateValue(state, "vdp.hClock", 0)),
        string.format("vc=%03d", stateValue(state, "vdp.vClock", 0)),
        string.format("hv=%04X", stateValue(state, "vdp.hvCounter", 0)),
        string.format("status=%04X", stateValue(state, "vdp.status", 0)),
        string.format("displayEnabled=%d", stateValue(state, "vdp.displayEnabled", false) and 1 or 0)
    }

    for i = 0, 7 do
        parts[#parts + 1] = string.format("d%d=%08X", i, stateValue(state, "cpu.d" .. i, 0))
    end

    for i = 0, 7 do
        parts[#parts + 1] = string.format("a%d=%08X", i, stateValue(state, "cpu.a" .. i, 0))
    end

    for i = 0, 23 do
        parts[#parts + 1] = string.format("r%02d=%02X", i, stateValue(state, "vdp.reg" .. i, 0))
    end

    stateFile:write(table.concat(parts, " ") .. "\n")
    stateFile:flush()
end

local function writeTraceLines(fileHandle, lines)
    if not fileHandle or not lines then
        return
    end

    for i = 1, #lines do
        fileHandle:write(lines[i], "\n")
    end
    fileHandle:flush()
end

local function configureGenesisVdpTraces(baseFrame)
    if not DUMP_VDP_TRACES then
        return
    end

    if not emu.setGenesisVdpTraceConfig then
        fatalStop("Genesis VDP trace config Lua API is not available in this build.")
    end
    if not emu.getGenesisVdpTrace then
        fatalStop("Genesis VDP trace Lua API is not available in this build.")
    end
    if not emu.getGenesisVdpDebugState then
        fatalStop("Genesis VDP debug-state Lua API is not available in this build.")
    end

    baseFrame = baseFrame or getGenesisVdpFrameCount()
    local frameEnd = baseFrame + VDP_TRACE_FRAME_END
    emu.log(string.format("Genesis VDP trace window: frames %u-%u", baseFrame, frameEnd))

    local ok = emu.setGenesisVdpTraceConfig("sprite", {
        frameStart = baseFrame,
        frameEnd = frameEnd,
        lineStart = 0,
        lineEnd = 239,
        maxLines = 200000
    })
    if not ok then
        fatalStop("Failed to configure Genesis sprite trace window.")
    end

    ok = emu.setGenesisVdpTraceConfig("compose", {
        frameStart = baseFrame,
        frameEnd = frameEnd,
        lineStart = 0,
        lineEnd = 239,
        xStart = 0,
        xEnd = 319,
        maxLines = 250000
    })
    if not ok then
        fatalStop("Failed to configure Genesis compose trace window.")
    end

    ok = emu.setGenesisVdpTraceConfig("scroll", {
        frameStart = baseFrame,
        frameEnd = frameEnd,
        lineStart = 0,
        lineEnd = 239,
        columnStart = 0,
        columnEnd = 63,
        maxLines = 1000000
    })
    if not ok then
        fatalStop("Failed to configure Genesis scroll trace window.")
    end

    ok = emu.setGenesisVdpTraceConfig("hscrollDma", {
        frameStart = baseFrame,
        frameEnd = frameEnd,
        dstStart = 0xFC00,
        dstEnd = 0xFDFF,
        maxLines = 300000
    })
    if not ok then
        fatalStop("Failed to configure Genesis hscroll DMA trace window.")
    end
end

local function logGenesisTraceBuffers()
    if not DUMP_VDP_TRACES then
        return
    end

    if not emu.getGenesisVdpTrace then
        fatalStop("Genesis VDP trace Lua API is not available in this build.")
    end

    local spriteLines = emu.getGenesisVdpTrace("sprite")
    if spriteLines == nil then
        fatalStop("Genesis VDP trace buffers are not available in this build.")
    end

    local composeLines = emu.getGenesisVdpTrace("compose")
    local scrollLines = emu.getGenesisVdpTrace("scroll")
    local dmaLines = emu.getGenesisVdpTrace("dma")
    local hscrollDmaLines = emu.getGenesisVdpTrace("hscrollDma")
    local totalTraceLines = #spriteLines + #composeLines + #scrollLines + #dmaLines + #hscrollDmaLines

    if totalTraceLines > 0 then
        traceDataSeen = true
    elseif frameCount >= 3 and not traceDataSeen then
        local vdpFrame = getGenesisVdpFrameCount()
        fatalStop(string.format(
            "Genesis VDP trace buffers are still empty after %d captured frames (current VDP frame=%u). The running executable likely does not include the Genesis trace-producing changes.",
            frameCount,
            vdpFrame
        ))
    end

    writeTraceLines(spriteTraceFile, spriteLines)
    writeTraceLines(composeTraceFile, composeLines)
    writeTraceLines(scrollTraceFile, scrollLines)
    writeTraceLines(dmaTraceFile, dmaLines)
    writeTraceLines(hscrollDmaTraceFile, hscrollDmaLines)
end

-- Write run info at end
local function writeRunInfo()
    local state = emu.getState()
    local info = emu.getRomInfo()

    local f = io.open(OUTPUT_DIR .. "\\run_info.txt", "w")
    if f then
        f:write("emulator=Mesen2-Expanded (Native backend)\n")
        f:write("rom_file=" .. (info.name or "unknown") .. "\n")
        f:write("region=" .. tostring(state["region"] or "unknown") .. "\n")
        f:write("master_clock_rate=" .. tostring(state["clockRate"] or 0) .. "\n")
        f:write("frames_captured=" .. TOTAL_FRAMES .. "\n")
        f:write("dump_frames=" .. tostring(DUMP_FRAMES) .. "\n")
        f:write("dump_state=" .. tostring(DUMP_STATE) .. "\n")
        f:write("dump_vram=" .. tostring(DUMP_VRAM) .. " (every " .. DUMP_VRAM_EVERY .. ")\n")
        f:write("dump_workram=" .. tostring(DUMP_WORKRAM) .. "\n")
        f:write("dump_vdp_traces=" .. tostring(DUMP_VDP_TRACES) .. "\n")
        f:write("wait_for_manual_reset=" .. tostring(WAIT_FOR_MANUAL_RESET) .. "\n")
        f:write("auto_stop_after_capture=" .. tostring(AUTO_STOP_AFTER_CAPTURE) .. "\n")
        f:write("stop_delay_frames=" .. tostring(STOP_DELAY_FRAMES) .. "\n")
        f:close()
    end
end

-- Main frame callback
local function onEndFrame()
    if captureFinished then
        if pendingStopFrames ~= nil then
            pendingStopFrames = pendingStopFrames - 1
            if pendingStopFrames <= 0 then
                pendingStopFrames = nil
                emu.stop(0)
            end
        end
        return
    end

    local masterClock = getMasterClock()

    if WAIT_FOR_MANUAL_RESET and not resetDetected then
        if lastMasterClock ~= nil then
            if masterClock > lastMasterClock then
                sawPreResetRuntime = true
            elseif sawPreResetRuntime and masterClock < lastMasterClock then
                resetDetected = true
                captureStarted = true
                frameCount = 0
                configureGenesisVdpTraces(0)
                emu.log("Manual ROM reset detected; capture starts from the first frame after reset")
            end
        end
        lastMasterClock = masterClock

        if not captureStarted then
            return
        end
    end

    if not captureStarted then
        captureStarted = true
        frameCount = 0
        emu.log("Capture starts immediately")
    end

    frameCount = frameCount + 1
    lastMasterClock = masterClock

    if frameCount == 1 then
        emu.log("Collecting: frame 1/" .. TOTAL_FRAMES)
    elseif frameCount % 100 == 0 then
        emu.log("Progress: frame " .. frameCount .. "/" .. TOTAL_FRAMES)
    end

    -- Per-frame metadata
    logFrameMeta(frameCount)

    -- P1/P2: CPU + VDP state
    if DUMP_STATE then
        logGenesisState(frameCount)
    end

    if DUMP_VDP_TRACES then
        logGenesisTraceBuffers()
    end

    -- P0: frame buffer
    if DUMP_FRAMES then
        dumpFrameBuffer(frameCount)
    end

    -- P3: VRAM/CRAM/VSRAM
    if DUMP_VRAM and (frameCount % DUMP_VRAM_EVERY == 0 or frameCount == 1) then
        dumpVramSet(frameCount)
    end

    -- Done?
    if frameCount >= TOTAL_FRAMES then
        if metaFile then
            metaFile:close()
            metaFile = nil
        end
        if stateFile then
            stateFile:close()
            stateFile = nil
        end
        if spriteTraceFile then
            spriteTraceFile:close()
            spriteTraceFile = nil
        end
        if composeTraceFile then
            composeTraceFile:close()
            composeTraceFile = nil
        end
        if scrollTraceFile then
            scrollTraceFile:close()
            scrollTraceFile = nil
        end
        if dmaTraceFile then
            dmaTraceFile:close()
            dmaTraceFile = nil
        end
        if hscrollDmaTraceFile then
            hscrollDmaTraceFile:close()
            hscrollDmaTraceFile = nil
        end
        writeRunInfo()
        captureFinished = true
        showStatus("Done: " .. TOTAL_FRAMES .. " frames -> " .. OUTPUT_DIR)
        if AUTO_STOP_AFTER_CAPTURE then
            pendingStopFrames = math.max(1, STOP_DELAY_FRAMES)
        end
    end
end

-- Clean old data and set up fresh output directories
os.execute('rmdir /S /Q "' .. OUTPUT_DIR .. '" 2>NUL')
setup()
configureGenesisVdpTraces()

emu.addEventCallback(onEndFrame, emu.eventType.endFrame)
if WAIT_FOR_MANUAL_RESET then
    showStatus("Reference data collector loaded: waiting for manual ROM reset, then " .. TOTAL_FRAMES .. " frames -> " .. OUTPUT_DIR)
else
    showStatus("Reference data collector loaded: " .. TOTAL_FRAMES .. " frames -> " .. OUTPUT_DIR)
end
