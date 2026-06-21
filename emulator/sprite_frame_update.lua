-- Sprite frame-window patch helper (Mesen Lua)
-- Applies VRAM byte writes only during a specific frame range.
-- Optional: press X to enable patching, Y to disable patching.

local cfg = {
	startFrame = 0,     -- relative to script start
	endFrame = 50,       -- inclusive
	enableHotkeys = true, -- X=start, Y=stop
	announceEveryApply = false
}

-- Fill this table with the bytes you want to patch.
-- Example:
-- { addr = 0xD000, value = 0x12 },
-- { addr = 0xD001, value = 0x34 },
local vramWrites = {
	-- TODO: add sprite tile bytes here
}

local frame = 0
local patchEnabled = true
local xPrev = false
local yPrev = false
local appliedFrames = {}

local memEnum = (emu and emu.memType) or _G.memType
local vramMem = memEnum and (memEnum.genesisVideoRam or memEnum.GenesisVideoRam) or nil
if not vramMem then
	emu.displayMessage("Lua", "genesisVideoRam memory type not found.")
	return
end

local logFile = nil
local function openLog()
	if not io or not io.open then
		return
	end
	local folder = emu.getScriptDataFolder and emu.getScriptDataFolder() or ""
	if folder and folder ~= "" then
		local path = folder .. "/sprite_frame_update.log"
		logFile = io.open(path, "w")
		if logFile then
			logFile:write("# sprite_frame_update.lua\n")
			logFile:flush()
		end
	end
end

local function log(msg)
	if logFile then
		logFile:write(msg .. "\n")
		logFile:flush()
	end
	emu.displayMessage("LuaSprite", msg)
end

local function applyVramWrites()
	for _, w in ipairs(vramWrites) do
		emu.write(w.addr, w.value, vramMem)
	end
end

local function onStartFrame(cpuType)
	frame = frame + 1

	if cfg.enableHotkeys then
		local xNow = emu.isKeyPressed("X")
		local yNow = emu.isKeyPressed("Y")

		if xNow and not xPrev then
			patchEnabled = true
			log(string.format("PATCH ENABLED at frame=%d", frame))
		end
		if yNow and not yPrev then
			patchEnabled = false
			log(string.format("PATCH DISABLED at frame=%d", frame))
		end

		xPrev = xNow
		yPrev = yNow
	end

	if not patchEnabled then
		return
	end

	if frame < cfg.startFrame or frame > cfg.endFrame then
		return
	end

	if appliedFrames[frame] then
		return
	end

	applyVramWrites()
	appliedFrames[frame] = true

	if cfg.announceEveryApply then
		log(string.format("APPLY frame=%d writes=%d", frame, #vramWrites))
	end
end

openLog()
log(string.format("READY range=%d-%d writes=%d", cfg.startFrame, cfg.endFrame, #vramWrites))
emu.addEventCallback(onStartFrame, emu.eventType.startFrame)
