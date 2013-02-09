local mosync = rawget(_G or _ENV, "mosync")
if not mosync then return end

-- this is a socket class that implements maConnect interface
local function socketMobileLua() 
  local self = {}
  self.select = function(readfrom) -- writeto and timeout parameters are ignored
    local canread = {}
    for _,s in ipairs(readfrom) do
      if s:receive(0) then canread[s] = true end
    end
    return canread
  end
  self.connect = coroutine.wrap(function(host, port)
    while true do
      local connection = mosync.maConnect("socket://" .. host .. ":" .. port)
  
      if connection > 0 then
        local event = mosync.SysEventCreate()
        while true do
          mosync.maWait(0)
          mosync.maGetEvent(event)
          local eventType = mosync.SysEventGetType(event)
          if (mosync.EVENT_TYPE_CONN == eventType and
            mosync.SysEventGetConnHandle(event) == connection and
            mosync.SysEventGetConnOpType(event) == mosync.CONNOP_CONNECT) then
              -- result > 0 ? success : error
              if not (mosync.SysEventGetConnResult(event) > 0) then connection = nil end
              break
          elseif mosync.EventMonitor and mosync.EventMonitor.HandleEvent then
            mosync.EventMonitor:HandleEvent(event)
          end
        end
        mosync.SysFree(event)
      end
  
      host, port = coroutine.yield(connection and (function ()
        local self = {}
        local outBuffer = mosync.SysAlloc(1000)
        local inBuffer = mosync.SysAlloc(1000)
        local event = mosync.SysEventCreate()
        local recvBuffer = ""
        function stringToBuffer(s, buffer)
          local i = 0
          for c in s:gmatch(".") do
            i = i + 1
            local b = s:byte(i)
            mosync.SysBufferSetByte(buffer, i - 1, b)
          end
          return i
        end
        function bufferToString(buffer, len)
          local s = ""
          for i = 0, len - 1 do
            local c = mosync.SysBufferGetByte(buffer, i)
            s = s .. string.char(c)
          end
          return s
        end
        self.send = coroutine.wrap(function(self, msg)
          while true do
            local numberOfBytes = stringToBuffer(msg, outBuffer)
            mosync.maConnWrite(connection, outBuffer, numberOfBytes)
            while true do
              mosync.maWait(0)
              mosync.maGetEvent(event)
              local eventType = mosync.SysEventGetType(event)
              if (mosync.EVENT_TYPE_CONN == eventType and
                  mosync.SysEventGetConnHandle(event) == connection and
                  mosync.SysEventGetConnOpType(event) == mosync.CONNOP_WRITE) then
                break
              elseif mosync.EventMonitor and mosync.EventMonitor.HandleEvent then
                mosync.EventMonitor:HandleEvent(event)
              end
            end
            self, msg = coroutine.yield()
          end
        end)
        self.receive = coroutine.wrap(function(self, len)
          while true do
            local line = recvBuffer
            while (len and string.len(line) < len)     -- either we need len bytes
               or (not len and not line:find("\n")) -- or one line (if no len specified)
               or (len == 0) do -- only check for new data (select-like)
              mosync.maConnRead(connection, inBuffer, 1000)
              while true do
                if len ~= 0 then mosync.maWait(0) end
                mosync.maGetEvent(event)
                local eventType = mosync.SysEventGetType(event)
                if (mosync.EVENT_TYPE_CONN == eventType and
                    mosync.SysEventGetConnHandle(event) == connection and
                    mosync.SysEventGetConnOpType(event) == mosync.CONNOP_READ) then
                  local result = mosync.SysEventGetConnResult(event)
                  if result > 0 then line = line .. bufferToString(inBuffer, result) end
                  if len == 0 then self, len = coroutine.yield("") end
                  break -- got the event we wanted; now check if we have all we need
                elseif len == 0 then
                  self, len = coroutine.yield(nil)
                elseif mosync.EventMonitor and mosync.EventMonitor.HandleEvent then
                  mosync.EventMonitor:HandleEvent(event)
                end
              end  
            end
    
            if not len then
              len = string.find(line, "\n") or string.len(line)
            end
    
            recvBuffer = string.sub(line, len+1)
            line = string.sub(line, 1, len)
    
            self, len = coroutine.yield(line)
          end
        end)
        self.close = coroutine.wrap(function(self) 
          while true do
            mosync.SysFree(inBuffer)
            mosync.SysFree(outBuffer)
            mosync.SysFree(event)
            mosync.maConnClose(connection)
            coroutine.yield(self)
          end
        end)
        return self
      end)())
    end
  end)

  return self
end

-- overwrite RunEventLoop in MobileLua as it conflicts with the event
-- loop that needs to run to process debugger events (socket read/write).
-- event loop functionality is implemented by calling HandleEvent
-- while waiting for debugger events.
if mosync and mosync.EventMonitor then
  mosync.EventMonitor.RunEventLoop = function(self) end
end

package.loaded.socket = socketMobileLua() 
return package.loaded.socket
