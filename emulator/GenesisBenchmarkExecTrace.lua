------------------------------
-- Genesis Bench Exec Trace
------------------------------
-- Produces a benchmark-specific execution trace/profile for GenTest on the Genesis.
--
-- Trace method:
-- - Attempts to register an Exec callback on the main 68K bus-address range
--   used by the startup benchmark loop.
-- - Also polls the benchmark score each frame and dumps ROM exec counters as a
--   reliable fallback when the benchmark completes.
-- - Writes CSV output to the script data folder.
--
-- Intended use:
-- - Run this script in Mesen while booting GenTest.
-- - Capture the resulting CSV.
-- - Ask the BlastEm side to emit the same columns for the same address range.
------------------------------

local TRACE_START = 0x16A8
local TRACE_END = 0x1712
local SCORE_ADDR = 0x001C
local LOG_FILE_NAME = "genesis_benchmark_exec_trace.csv"
local FLUSH_INTERVAL = 1024
local MAX_ROWS = 600000

local traceFile = nil
local tracePath = nil
local traceRows = 0
local traceStopped = false
local profileDumped = false
local registeredExecRef = nil
local registeredScoreRef = nil

local function read_be16(addr, memType)
  local hi = emu.read(addr, memType)
  local lo = emu.read(addr + 1, memType)
  return ((hi << 8) | lo) & 0xFFFF
end

local function ensure_trace_file()
  if traceFile ~= nil then
    return true
  end

  tracePath = emu.getScriptDataFolder() .. "\\" .. LOG_FILE_NAME
  traceFile = io.open(tracePath, "w")
  if not traceFile then
    emu.log("Failed to open trace file: " .. tostring(tracePath))
    return false
  end

  traceFile:write("kind,frame,master_clock,cpu_cycle,pc,address,value,score,d1,d2,d6,d7,sr,exec_count,last_exec_clock,notes\n")
  traceFile:flush()
  return true
end

local function flush_trace_file()
  if traceFile then
    traceFile:flush()
  end
end

local function close_trace_file()
  if traceFile then
    traceFile:flush()
    traceFile:close()
    traceFile = nil
  end
end

local function stop_trace(reason)
  if traceStopped then
    return
  end

  traceStopped = true
  flush_trace_file()
  emu.log("Genesis benchmark exec trace stopped: " .. reason .. " | file=" .. tostring(tracePath))
  emu.displayMessage("Genesis Trace", reason)
end

local function write_row(kind, address, value)
  if traceStopped or traceRows >= MAX_ROWS then
    if traceRows >= MAX_ROWS then
      stop_trace("Trace row limit reached")
    end
    return
  end

  if not ensure_trace_file() then
    traceStopped = true
    return
  end

  local state = emu.getState()
  local score = read_be16(SCORE_ADDR, emu.memType.genesisWorkRam)

  traceFile:write(string.format(
    "%s,%d,%d,%d,%06X,%06X,%02X,%d,%08X,%08X,%08X,%08X,%04X,,,\n",
    kind,
    state["frameCount"],
    state["masterClock"],
    state["cpu.cycleCount"],
    state["cpu.pc"] & 0xFFFFFF,
    address & 0xFFFFFF,
    value & 0xFF,
    score,
    state["cpu.d1"] & 0xFFFFFFFF,
    state["cpu.d2"] & 0xFFFFFFFF,
    state["cpu.d6"] & 0xFFFFFFFF,
    state["cpu.d7"] & 0xFFFFFFFF,
    state["cpu.sr"] & 0xFFFF
  ))

  traceRows = traceRows + 1
  if (traceRows % FLUSH_INTERVAL) == 0 then
    flush_trace_file()
  end
end

local function dump_exec_profile(reason)
  if profileDumped or traceStopped then
    return
  end

  if not ensure_trace_file() then
    traceStopped = true
    return
  end

  local state = emu.getState()
  local score = read_be16(SCORE_ADDR, emu.memType.genesisWorkRam)
  local romSize = emu.getMemorySize(emu.memType.genesisPrgRom)
  local execCounts = emu.getAccessCounters(emu.memType.genesisPrgRom, emu.counterType.execCount)
  local lastExecClocks = emu.getAccessCounters(emu.memType.genesisPrgRom, emu.counterType.lastExecClock)

  traceFile:write(string.format(
    "summary,%d,%d,%d,%06X,,,%d,%08X,%08X,%08X,%08X,%04X,,,%s\n",
    state["frameCount"],
    state["masterClock"],
    state["cpu.cycleCount"],
    state["cpu.pc"] & 0xFFFFFF,
    score,
    state["cpu.d1"] & 0xFFFFFFFF,
    state["cpu.d2"] & 0xFFFFFFFF,
    state["cpu.d6"] & 0xFFFFFFFF,
    state["cpu.d7"] & 0xFFFFFFFF,
    state["cpu.sr"] & 0xFFFF,
    reason
  ))

  for address = 0, romSize - 1 do
    local count = execCounts[address]
    if count ~= nil and count ~= 0 then
      local lastClock = lastExecClocks[address] or 0
      traceFile:write(string.format(
        "exec_profile,,,,,%06X,,%d,,,,,,%d,%d,\n",
        address & 0xFFFFFF,
        score,
        count,
        lastClock
      ))
    end
  end

  profileDumped = true
  flush_trace_file()
end

local function on_exec(address, value)
  if traceStopped then
    return
  end

  write_row("exec", address, value)
end

local function on_score_write(address, value)
  if traceStopped then
    return
  end

  write_row("score_write", address, value)

  local score = read_be16(SCORE_ADDR, emu.memType.genesisWorkRam)
  if score ~= 0 then
    dump_exec_profile("score_write")
    stop_trace(string.format("Benchmark complete, score=%d", score))
  end
end

local function on_end_frame()
  if traceStopped then
    return
  end

  local score = read_be16(SCORE_ADDR, emu.memType.genesisWorkRam)
  if score ~= 0 then
    dump_exec_profile("end_frame_poll")
    stop_trace(string.format("Benchmark complete, score=%d", score))
  end
end

local function on_script_end()
  if not profileDumped then
    dump_exec_profile("script_end")
  end
  stop_trace("Script ended")
  close_trace_file()
end

local function initialize()
  local debugState = emu.getGenesisVdpDebugState()
  if not debugState then
    emu.displayMessage("Genesis Trace", "This script requires the Genesis core.")
    return
  end

  if not ensure_trace_file() then
    return
  end

  emu.resetAccessCounters()

  registeredExecRef = emu.addMemoryCallback(
    on_exec,
    emu.callbackType.exec,
    TRACE_START,
    TRACE_END,
    emu.cpuType.genesisMain,
    emu.memType.genesisMemory
  )

  registeredScoreRef = emu.addMemoryCallback(
    on_score_write,
    emu.callbackType.write,
    SCORE_ADDR,
    SCORE_ADDR + 1,
    emu.cpuType.genesisMain,
    emu.memType.genesisWorkRam
  )

  emu.addEventCallback(on_script_end, emu.eventType.scriptEnded)
  emu.addEventCallback(on_end_frame, emu.eventType.endFrame)
  emu.log("Genesis benchmark exec trace started. File: " .. tracePath)
  emu.displayMessage("Genesis Trace", "Tracing GenTest benchmark execs/profile.")
end

initialize()
