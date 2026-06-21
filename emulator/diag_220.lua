local frameTarget = 220
local frameCount = 0
local outPath = "D:\\Mesen2-Expanded\\diag_output_220.txt"
function onEndFrame()
  frameCount = frameCount + 1
  if frameCount < frameTarget then return end
  local f = io.open(outPath, "w")
  local function w(s) if f then f:write(s .. "\n") end end
  w("frame="..frameCount)
  local st = emu.getState()
  w("masterClock="..tostring(st.masterClock))
  local ss = emu.getScreenSize()
  w(string.format("screen=%dx%d", ss.width, ss.height))
  local buf = emu.getScreenBuffer()
  local nonBlack = 0
  for i=1, math.min(#buf, ss.width*ss.height) do
    local px = buf[i]
    if px ~= 0 and px ~= -16777216 then nonBlack = nonBlack + 1 end
  end
  w("nonBlack="..nonBlack)
  local line112 = "line112:"
  local base = 112*ss.width
  for x=0,15 do line112 = line112 .. string.format(" %08X", (buf[base+x+1] or 0) & 0xFFFFFFFF) end
  w(line112)
  w("CRAM:")
  local s=""
  for i=0,127 do
    s = s .. string.format("%02X", emu.read(i, emu.memType.genesisColorRam))
    if i%2==1 then s=s.." " end
    if i%32==31 then w(s); s="" end
  end
  if #s>0 then w(s) end
  if f then f:close() end
  emu.stop(0)
end
emu.addEventCallback(onEndFrame, emu.eventType.endFrame)
