-- =============================================================================
-- Mesen2 Dynamic Reference Data Collector
-- Interactive version of the Genesis reference-data collector.
--
-- Hotkeys:
--   X : start continuous capture
--   Y : stop current capture
--   C : capture exactly 1 frame
--   V : capture RANGE_CAPTURE_FRAMES frames
--
-- Output:
--   
--
-- Notes:
--   - This script is intended for interactive gameplay, not headless runs.
--   - Each capture creates its own subfolder and keeps the same log formats
--     as the fixed collector: frame_meta.log, cpu_vdp_state.log, frame PNGs,
--     and VRAM/CRAM/VSRAM dumps.
-- =============================================================================

-- ======================== CONFIGURATION ========================
local OUTPUT_ROOT           = ""
local RANGE_CAPTURE_FRAMES  = 120
local WAIT_FOR_MANUAL_RESET = true
local AUTO_STOP_AFTER_COMPLETION = true
local STOP_DELAY_FRAMES = 15

local DUMP_FRAMES           = true
local DUMP_STATE            = true
local DUMP_VRAM             = true
local DUMP_VRAM_EVERY       = 10
local DUMP_WORKRAM          = false

local KEY_START_CAPTURE     = "Z"
local KEY_STOP_CAPTURE      = "X"
local KEY_SINGLE_FRAME      = "C"
local KEY_RANGE_CAPTURE     = "V"
-- ===============================================================

local emuFrame = 0
local nextCaptureIndex = 1
local activeCapture = nil
local pendingCapture = nil
local stateWarnedMissing = false
local lastMasterClock = nil
local sawPreResetRuntime = false
local pendingStopFrames = nil

local keyLatch = {
    [KEY_START_CAPTURE] = false,
    [KEY_STOP_CAPTURE] = false,
    [KEY_SINGLE_FRAME] = false,
    [KEY_RANGE_CAPTURE] = false
}

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

local function getMasterClock()
    local state = emu.getState()
    return state["masterClock"] or 0
end

local function logMessage(text)
    emu.log(text)
    emu.displayMessage("RefCapture", text)
end

local function dumpMemory(path, memType, size)
    local f = io.open(path, "wb")
    if not f then
        emu.log("ERROR: cannot open " .. path)
        return
    end

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

local function beginCaptureSession(mode, targetFrames)
    ensureDir(OUTPUT_ROOT)

    local sessionIndex = nextCaptureIndex
    nextCaptureIndex = nextCaptureIndex + 1

    local baseDir = OUTPUT_ROOT .. "\\capture_" .. padNum(sessionIndex, 4)
    ensureDir(baseDir)
    if DUMP_FRAMES then
        ensureDir(baseDir .. "\\frames")
    end
    if DUMP_VRAM then
        ensureDir(baseDir .. "\\vram")
        ensureDir(baseDir .. "\\cram")
        ensureDir(baseDir .. "\\vsram")
    end
    if DUMP_WORKRAM then
        ensureDir(baseDir .. "\\workram")
    end

    local capture = {
        index = sessionIndex,
        mode = mode,
        targetFrames = targetFrames,
        startGameFrame = emuFrame + 1,
        capturedFrames = 0,
        baseDir = baseDir,
        metaFile = nil,
        stateFile = nil
    }

    capture.metaFile = io.open(baseDir .. "\\frame_meta.log", "w")
    if capture.metaFile then
        capture.metaFile:write("# captureFrame emuFrame masterClock screenW screenH\n")
    end

    if DUMP_STATE then
        capture.stateFile = io.open(baseDir .. "\\cpu_vdp_state.log", "w")
        if capture.stateFile then
            capture.stateFile:write("# captureFrame emuFrame mclk pc sr sp usp stopped hc vc hv status displayEnabled")
            for i = 0, 7 do capture.stateFile:write(" d" .. i) end
            for i = 0, 7 do capture.stateFile:write(" a" .. i) end
            for i = 0, 23 do capture.stateFile:write(string.format(" r%02d", i)) end
            capture.stateFile:write("\n")
        end
    end

    activeCapture = capture

    if targetFrames > 0 then
        logMessage(string.format(
            "Capture %04d started: mode=%s frames=%d startEmuFrame=%d",
            sessionIndex, mode, targetFrames, capture.startGameFrame
        ))
    else
        logMessage(string.format(
            "Capture %04d started: mode=%s startEmuFrame=%d",
            sessionIndex, mode, capture.startGameFrame
        ))
    end
end

local function openCaptureSession(mode, targetFrames)
    if activeCapture or pendingCapture then
        logMessage("Capture already active or armed. Stop it first with " .. KEY_STOP_CAPTURE .. ".")
        return
    end

    if WAIT_FOR_MANUAL_RESET then
        pendingCapture = {
            mode = mode,
            targetFrames = targetFrames
        }
        sawPreResetRuntime = false
        lastMasterClock = getMasterClock()
        if targetFrames > 0 then
            logMessage(string.format(
                "Capture armed: mode=%s frames=%d. Manually reset the ROM to begin.",
                mode, targetFrames
            ))
        else
            logMessage(string.format(
                "Capture armed: mode=%s. Manually reset the ROM to begin.",
                mode
            ))
        end
        return
    end

    beginCaptureSession(mode, targetFrames)
end

local function closeCaptureSession(reason)
    local capture = activeCapture
    if not capture then
        return
    end

    local state = emu.getState()
    local info = emu.getRomInfo()

    if capture.metaFile then capture.metaFile:close() end
    if capture.stateFile then capture.stateFile:close() end
    capture.metaFile = nil
    capture.stateFile = nil

    local f = io.open(capture.baseDir .. "\\run_info.txt", "w")
    if f then
        f:write("emulator=Mesen2-Expanded (Native backend)\n")
        f:write("rom_file=" .. (info.name or "unknown") .. "\n")
        f:write("region=" .. tostring(state["region"] or "unknown") .. "\n")
        f:write("master_clock_rate=" .. tostring(state["clockRate"] or 0) .. "\n")
        f:write("capture_index=" .. capture.index .. "\n")
        f:write("capture_mode=" .. capture.mode .. "\n")
        f:write("start_emu_frame=" .. capture.startGameFrame .. "\n")
        f:write("end_emu_frame=" .. emuFrame .. "\n")
        f:write("frames_captured=" .. capture.capturedFrames .. "\n")
        f:write("target_frames=" .. capture.targetFrames .. "\n")
        f:write("dump_frames=" .. tostring(DUMP_FRAMES) .. "\n")
        f:write("dump_state=" .. tostring(DUMP_STATE) .. "\n")
        f:write("dump_vram=" .. tostring(DUMP_VRAM) .. " (every " .. DUMP_VRAM_EVERY .. ")\n")
        f:write("dump_workram=" .. tostring(DUMP_WORKRAM) .. "\n")
        f:write("wait_for_manual_reset=" .. tostring(WAIT_FOR_MANUAL_RESET) .. "\n")
        f:write("auto_stop_after_completion=" .. tostring(AUTO_STOP_AFTER_COMPLETION) .. "\n")
        f:write("stop_delay_frames=" .. tostring(STOP_DELAY_FRAMES) .. "\n")
        f:write("stop_reason=" .. reason .. "\n")
        f:close()
    end

    logMessage(string.format(
        "Capture %04d stopped: frames=%d reason=%s",
        capture.index, capture.capturedFrames, reason
    ))

    activeCapture = nil
    if reason == "target_reached" and AUTO_STOP_AFTER_COMPLETION then
        pendingStopFrames = math.max(1, STOP_DELAY_FRAMES)
    end
end

local function cancelPendingCapture(reason)
    if not pendingCapture then
        return
    end
    logMessage(string.format(
        "Armed capture canceled: mode=%s reason=%s",
        pendingCapture.mode, reason
    ))
    pendingCapture = nil
    sawPreResetRuntime = false
end

local function dumpFrameBuffer(captureFrame)
    local capture = activeCapture
    local pngData = emu.takeScreenshot()
    if pngData and #pngData > 0 then
        local path = capture.baseDir .. "\\frames\\frame_" .. padNum(captureFrame, 6) .. ".png"
        local f = io.open(path, "wb")
        if f then
            f:write(pngData)
            f:close()
        end
        return true
    end

    local screenSize = emu.getScreenSize()
    local buf = emu.getScreenBuffer()
    if buf then
        local path = capture.baseDir .. "\\frames\\frame_" .. padNum(captureFrame, 6) .. ".bin"
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

local function dumpVramSet(captureFrame)
    local capture = activeCapture
    local tag = padNum(captureFrame, 6)

    local vramSize  = emu.getMemorySize(emu.memType.genesisVideoRam)
    local cramSize  = emu.getMemorySize(emu.memType.genesisColorRam)
    local vsramSize = emu.getMemorySize(emu.memType.genesisVScrollRam)

    dumpMemory(capture.baseDir .. "\\vram\\vram_"   .. tag .. ".bin", emu.memType.genesisVideoRam, vramSize)
    dumpMemory(capture.baseDir .. "\\cram\\cram_"   .. tag .. ".bin", emu.memType.genesisColorRam, cramSize)
    dumpMemory(capture.baseDir .. "\\vsram\\vsram_" .. tag .. ".bin", emu.memType.genesisVScrollRam, vsramSize)

    if DUMP_WORKRAM then
        local wramSize = emu.getMemorySize(emu.memType.genesisWorkRam)
        dumpMemory(capture.baseDir .. "\\workram\\wram_" .. tag .. ".bin", emu.memType.genesisWorkRam, wramSize)
    end
end

local function logFrameMeta(captureFrame)
    local capture = activeCapture
    if not capture or not capture.metaFile then return end

    local state = emu.getState()
    local screenSize = emu.getScreenSize()
    capture.metaFile:write(string.format("%s %s %010d %d %d\n",
        padNum(captureFrame, 6),
        padNum(emuFrame, 6),
        state["masterClock"] or 0,
        screenSize.width,
        screenSize.height))
    capture.metaFile:flush()
end

local function logGenesisState(captureFrame)
    local capture = activeCapture
    if not capture or not capture.stateFile then return end

    local state = emu.getState()
    if state["cpu.pc"] == nil or state["vdp.status"] == nil then
        if not stateWarnedMissing then
            logMessage("Genesis CPU/VDP Lua state keys are not available in this build.")
            stateWarnedMissing = true
        end
        return
    end

    local parts = {
        padNum(captureFrame, 6),
        padNum(emuFrame, 6),
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

    capture.stateFile:write(table.concat(parts, " ") .. "\n")
    capture.stateFile:flush()
end

local function processCaptureFrame()
    if not activeCapture then
        return
    end

    activeCapture.capturedFrames = activeCapture.capturedFrames + 1
    local captureFrame = activeCapture.capturedFrames

    logFrameMeta(captureFrame)

    if DUMP_STATE then
        logGenesisState(captureFrame)
    end

    if DUMP_FRAMES then
        dumpFrameBuffer(captureFrame)
    end

    if DUMP_VRAM and (captureFrame % DUMP_VRAM_EVERY == 0 or captureFrame == 1) then
        dumpVramSet(captureFrame)
    end

    if activeCapture.targetFrames > 0 and captureFrame >= activeCapture.targetFrames then
        closeCaptureSession("target_reached")
    end
end

local function onInputPolled()
    local function pressedOnce(key)
        local now = emu.isKeyPressed(key)
        local once = now and not keyLatch[key]
        keyLatch[key] = now
        return once
    end

    if pressedOnce(KEY_START_CAPTURE) then
        openCaptureSession("continuous", 0)
    end

    if pressedOnce(KEY_STOP_CAPTURE) then
        if activeCapture then
            closeCaptureSession("manual_stop")
        elseif pendingCapture then
            cancelPendingCapture("manual_stop")
        else
            logMessage("No active or armed capture to stop.")
        end
    end

    if pressedOnce(KEY_SINGLE_FRAME) then
        openCaptureSession("single_frame", 1)
    end

    if pressedOnce(KEY_RANGE_CAPTURE) then
        openCaptureSession("range", RANGE_CAPTURE_FRAMES)
    end
end

local function onEndFrame()
    if pendingStopFrames ~= nil and not activeCapture then
        pendingStopFrames = pendingStopFrames - 1
        if pendingStopFrames <= 0 then
            pendingStopFrames = nil
            emu.stop(0)
            return
        end
    end

    emuFrame = emuFrame + 1
    local masterClock = getMasterClock()

    if pendingCapture then
        if lastMasterClock ~= nil then
            if masterClock > lastMasterClock then
                sawPreResetRuntime = true
            elseif sawPreResetRuntime and masterClock < lastMasterClock then
                local request = pendingCapture
                pendingCapture = nil
                beginCaptureSession(request.mode, request.targetFrames)
                logMessage("Manual ROM reset detected; armed capture is starting now.")
            end
        end
    end

    lastMasterClock = masterClock
    processCaptureFrame()
end

ensureDir(OUTPUT_ROOT)

emu.addEventCallback(onInputPolled, emu.eventType.inputPolled)
emu.addEventCallback(onEndFrame, emu.eventType.endFrame)

local intro = string.format(
    WAIT_FOR_MANUAL_RESET
        and "Dynamic collector ready. Hotkeys arm capture; manually reset ROM to start. %s=start %s=stop %s=1 frame %s=%d frames"
        or "Dynamic collector ready. %s=start %s=stop %s=1 frame %s=%d frames",
    KEY_START_CAPTURE,
    KEY_STOP_CAPTURE,
    KEY_SINGLE_FRAME,
    KEY_RANGE_CAPTURE,
    RANGE_CAPTURE_FRAMES
)
emu.displayMessage("RefCapture", intro)
emu.log(intro)
