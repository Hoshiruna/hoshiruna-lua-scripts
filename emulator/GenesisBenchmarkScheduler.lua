------------------------------
-- Name: Genesis Bench Trace
-- Author: 
------------------------------
-- Watches the GenTest benchmark score in Genesis work RAM and records the
-- scheduler diagnostics exposed by emu.getGenesisVdpDebugState().backend.
--
-- Expected benchmark score address:
--   $FF001C -> work RAM offset $001C
--
-- Usage:
-- 1. Load a Genesis ROM and run this script.
-- 2. Let GenTest finish its startup benchmark.
-- 3. Read the final score + scheduler counters from the overlay or log.
------------------------------

local SCORE_ADDR = 0x001C
local OVERLAY_X = 6
local OVERLAY_Y = 6
local LOG_FILE_NAME = "genesis_benchmark_scheduler.csv"

local lastScore = 0
local resultLogged = false
local lastBackend = nil
local scriptEnabled = false
local logPath = nil
local logHeaderWritten = false

local function read_be16(addr, memType)
  local hi = emu.read(addr, memType)
  local lo = emu.read(addr + 1, memType)
  return ((hi << 8) | lo) & 0xFFFF
end

local function get_backend_state()
  local debugState = emu.getGenesisVdpDebugState()
  if not debugState then
    return nil
  end

  return debugState.backend
end

local function ensure_log_file()
  if logPath == nil then
    logPath = emu.getScriptDataFolder() .. "\\" .. LOG_FILE_NAME
  end

  if logHeaderWritten then
    return true
  end

  local file = io.open(logPath, "r")
  if file then
    local firstLine = file:read("*l")
    file:close()
    if firstLine ~= nil then
      logHeaderWritten = true
      return true
    end
  end

  file = io.open(logPath, "a")
  if not file then
    return false
  end

  file:write("score,line_slices_enabled,overrun_cycles,overrun_count,max_overrun,scheduler_frame\n")
  file:close()
  logHeaderWritten = true
  return true
end

local function append_log_row(score, backend)
  if not ensure_log_file() then
    emu.log("Failed to open benchmark log file: " .. tostring(logPath))
    return
  end

  local file = io.open(logPath, "a")
  if not file then
    emu.log("Failed to append benchmark log file: " .. tostring(logPath))
    return
  end

  file:write(string.format(
    "%d,%d,%d,%d,%d,%d\n",
    score,
    backend.lineSlicesEnabled and 1 or 0,
    backend.sliceOverrunCycles,
    backend.sliceOverrunCount,
    backend.maxSliceOverrun,
    backend.schedulerFrameCounter
  ))
  file:close()
end

local function log_result(score, backend)
  local message = string.format(
    "GenTest score=%d lineSlices=%s overrunCycles=%d overrunCount=%d maxOverrun=%d schedulerFrame=%d",
    score,
    backend.lineSlicesEnabled and "on" or "off",
    backend.sliceOverrunCycles,
    backend.sliceOverrunCount,
    backend.maxSliceOverrun,
    backend.schedulerFrameCounter
  )

  append_log_row(score, backend)
  emu.log(message)
  emu.displayMessage("Genesis Bench", message .. " | file=" .. logPath)
end

local function update_state()
  local backend = get_backend_state()
  if not backend then
    return
  end

  lastBackend = backend

  local score = read_be16(SCORE_ADDR, emu.memType.genesisWorkRam)
  if score ~= lastScore then
    lastScore = score
  end

  if not resultLogged and score ~= 0 then
    resultLogged = true
    log_result(score, backend)
  end
end

local function draw_overlay()
  if not scriptEnabled or not lastBackend then
    return
  end

  emu.drawRectangle(OVERLAY_X, OVERLAY_Y, 224, 52, 0xA0202020, true, 1)
  emu.drawRectangle(OVERLAY_X, OVERLAY_Y, 224, 52, 0xA0FFFFFF, false, 1)

  emu.drawString(
    OVERLAY_X + 4,
    OVERLAY_Y + 4,
    string.format("GenTest score: %5d", lastScore),
    0xFFFFFF,
    0xFF000000
  )

  emu.drawString(
    OVERLAY_X + 4,
    OVERLAY_Y + 14,
    string.format("Line slices: %s", lastBackend.lineSlicesEnabled and "on" or "off"),
    0xFFFFFF,
    0xFF000000
  )

  emu.drawString(
    OVERLAY_X + 4,
    OVERLAY_Y + 24,
    string.format("Overrun cycles: %d", lastBackend.sliceOverrunCycles),
    0xFFFFFF,
    0xFF000000
  )

  emu.drawString(
    OVERLAY_X + 4,
    OVERLAY_Y + 34,
    string.format("Overrun slices: %d  max: %d", lastBackend.sliceOverrunCount, lastBackend.maxSliceOverrun),
    0xFFFFFF,
    0xFF000000
  )

  emu.drawString(
    OVERLAY_X + 4,
    OVERLAY_Y + 44,
    string.format("Scheduler frame: %d", lastBackend.schedulerFrameCounter),
    0xFFFFFF,
    0xFF000000
  )
end

local function end_frame()
  update_state()
  draw_overlay()
end

local function initialize()
  local backend = get_backend_state()
  if not backend then
    emu.displayMessage("Genesis Bench", "This script requires the Genesis core.")
    return
  end

  scriptEnabled = true
  lastBackend = backend
  ensure_log_file()
  emu.log("Genesis bench trace script loaded. File log: " .. tostring(logPath))
  emu.displayMessage("Genesis Bench", "Tracing GenTest benchmark.")
end

initialize()
emu.addEventCallback(end_frame, emu.eventType.endFrame)
