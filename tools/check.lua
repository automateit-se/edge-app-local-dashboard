-- Checks that an IoT Open edge client can run the edge app "Lokal dashboard", without installing it.
-- Run on the edge client (e.g. a Raspberry Pi 4 with the edge client installed directly in Linux):
--
--   sudo iotopen-rt check.lua [port]
--
-- Optional: an API key to check what it may read (start the line with a space to keep it out of the history):
--
--    sudo API_KEY=<key> iotopen-rt check.lua
--
-- Prints OK / FEL / INFO per check, never credentials, values or file contents. Changes nothing: the test
-- file in the data directory and the test server are removed again.

local PORT = tonumber(arg and arg[1]) or 8090
local DASHBOARD = "https://github.com/automateit-se/iotopen-dashboard/releases/latest/download/iotopen-dashboard-local.html"
local DATA = "/var/lib/iot-open/edge/local-dashboard"

local results = { ok = 0, fail = 0 }
local function line(ok, name, info)
  local mark = ok == nil and "INFO" or ok and "OK  " or "FEL "
  if ok == true then results.ok = results.ok + 1 elseif ok == false then results.fail = results.fail + 1 end
  -- padded by characters, not bytes (å, ä, ö)
  print(mark .. " " .. name .. string.rep(" ", math.max(1, 39 - (utf8.len(name) or #name))) .. (info or ""))
end

print("Lokal dashboard: kontroll av edge clienten")
print(string.rep("-", 78))

-- 1. the Lua runtime and the modules the app uses ------------------------------------------------------------
line(_VERSION == "Lua 5.3" or _VERSION == "Lua 5.4", "Lua", _VERSION)
local mods = { "json", "basexx", "cqueues", "cqueues.condition", "cqueues.socket", "http.server", "http.request",
  "http.headers", "http.util", "http.websocket", "openssl", "ev", "ev.mqtt" }
local missing = {}
for _, m in ipairs(mods) do
  if not pcall(require, m) then missing[#missing + 1] = m end
end
line(#missing == 0, "moduler (" .. #mods .. " st)", #missing == 0 and "alla finns" or "saknas: " .. table.concat(missing, ", "))
if #missing > 0 then
  print("\nAppen kan inte köras utan modulerna. Uppdatera edge clienten och kör kontrollen igen.")
  os.exit(1)
end

local json = require("json")
local basexx = require("basexx")
local cqueues = require("cqueues")
local socket = require("cqueues.socket")
local http_server = require("http.server")
local http_headers = require("http.headers")
local http_request = require("http.request")

-- 2. the edge client's own configuration ---------------------------------------------------------------------
local iot = json:readfile("/etc/iot-open/iotopen.json")
if type(iot) ~= "table" then
  line(false, "/etc/iot-open/iotopen.json", "saknas eller går inte att läsa (kör med sudo?)")
  iot = {}
else
  local host = tostring(iot.api or ""):gsub("^https?://", ""):gsub("/.*$", "")
  local ok = iot.installation_id ~= nil and iot.client_id ~= nil and iot.api ~= nil
  line(ok, "/etc/iot-open/iotopen.json", ok and ("installation " .. tostring(iot.installation_id) .. ", " .. host) or "saknar installation_id, client_id eller api")
end
local IID = tostring(iot.installation_id or "")
local CID = tostring(iot.client_id or "")

-- 3. the data directory -----------------------------------------------------------------------------------
do
  io.stdout:flush()
  os.execute("mkdir -p '" .. DATA .. "' 2>/dev/null")
  local p = DATA .. "/.check-" .. tostring(os.time())
  local f = io.open(p, "wb")
  local ok = f and f:write(string.rep("x", 4096)) and f:close()
  if ok then os.remove(p) end
  local free
  local df = io.popen("df -Pm '" .. DATA .. "' 2>/dev/null | tail -1")
  if df then
    free = tonumber((df:read("a") or ""):match("^%S+%s+%d+%s+%d+%s+(%d+)"))
    df:close()
  end
  line(ok and true or false, "datakatalog", (ok and "skrivbar" or "går inte att skriva i") .. ": " .. DATA .. (free and string.format(" (%d MB ledigt)", free) or ""))
  if free and free < 100 then line(false, "diskutrymme", "under 100 MB ledigt") end
end

-- network checks run in cqueues ------------------------------------------------------------------------------
local cq = cqueues.new()

local function get(url, headers, timeout)
  local req = http_request.new_from_uri(url)
  req.headers:upsert(":method", "GET")
  for k, v in pairs(headers or {}) do req.headers:upsert(k, v) end
  local h, s = req:go(timeout or 15)
  if not h then return nil, 0, tostring(s) end
  local body = s:get_body_as_string(timeout or 60)
  return body, tonumber(h:get(":status")) or 0
end

cq:wrap(function()
  -- 4. the port: a test server on all interfaces, answered from this machine
  local srv = http_server.listen({
    host = "0.0.0.0", port = PORT, cq = cq,
    onstream = function(_, stream)
      stream:get_headers()
      local h = http_headers.new()
      h:append(":status", "200")
      stream:write_headers(h, false)
      stream:write_chunk("ok", true)
    end,
  })
  local ok, err = pcall(function() assert(srv:listen()) end)
  if not ok then
    line(false, "port " .. PORT, "upptagen eller ej tillåten: " .. tostring(err):gsub("^.-: ", ""):sub(1, 60) .. ". Välj en annan port i appen")
  else
    local body = get("http://127.0.0.1:" .. PORT .. "/", nil, 5)
    line(body == "ok", "port " .. PORT, body == "ok" and "ledig, en testserver svarade" or "testservern svarade inte")
    srv:close()
  end

  -- 5. the local broker (the app subscribes to obj/# and evt/#)
  local s = socket.connect({ host = "127.0.0.1", port = 1883 })
  local connack
  if s then
    s:settimeout(5)
    local vh = string.pack(">s2", "MQTT") .. "\4\2" .. string.pack(">I2", 30)
    local pl = string.pack(">s2", "ld-check-" .. tostring(os.time()))
    local ok2 = pcall(function()
      s:write("\16" .. string.char(#vh + #pl) .. vh .. pl)
      s:flush()
      connack = s:read(4)
      s:write("\224\0")
      s:flush()
    end)
    if not ok2 then connack = nil end
    s:close()
  end
  line(connack ~= nil and connack:sub(1, 1) == "\32" and connack:byte(4) == 0, "lokal MQTT-broker (127.0.0.1:1883)", connack and "svarar" or "svarar inte: körs edge clienten?")

  -- 6. what the edge client's own credentials may read
  if iot.api and CID ~= "" then
    local basic = { authorization = "Basic " .. basexx.to_base64(CID .. ":" .. tostring(iot.mqtt_password)) }
    local now = os.time()
    local checks = {
      { "funktioner", "/api/v2/functionx/" .. IID },
      { "enheter", "/api/v2/devicex/" .. IID },
      { "senaste värden", "/api/v2/status/" .. IID },
      { "installationens metadata", "/api/v2/installation/" .. IID },
      { "installationens filer", "/api/v2/file/installation/" .. IID },
      { "historik (v3beta)", "/api/v3beta/log/" .. IID .. "?from=" .. (now - 3600) .. "&to=" .. now .. "&limit=1" },
    }
    local reached = false
    local function try(label, hdr, needed)
      for _, c in ipairs(checks) do
        local body, st = get(iot.api .. c[2], hdr)
        if st ~= 0 then reached = true end
        local d = st >= 200 and st < 300 and body and json:decode(body)
        local info = st == 0 and "nås inte" or (st >= 200 and st < 300) and ("läsbar" .. (type(d) == "table" and #d > 0 and string.format(" (%d st)", #d) or "")) or ("nekad (" .. st .. ")")
        local fine = st >= 200 and st < 300
        line(fine or (not needed[c[1]] and nil), label .. ": " .. c[1], info)
      end
    end
    -- functions, devices and latest values are needed with the edge client's own credentials
    try("egen inloggning", basic, { ["funktioner"] = true, ["enheter"] = true, ["senaste värden"] = true })
    if not reached then line(false, "IoT Open", "nås inte från edge clienten") end
    local key = os.getenv("API_KEY")
    if key and key ~= "" then
      try("API-nyckel", { ["x-api-key"] = key }, { ["installationens metadata"] = true, ["installationens filer"] = true, ["historik (v3beta)"] = true })
    else
      line(nil, "API-nyckel", "ingen angiven (API_KEY): det som nekas ovan behöver en nyckel i appen")
    end
  end

  -- 7. the dashboard file on GitHub
  local body, st = get(DASHBOARD, nil, 60)
  local okd = st == 200 and body and body:find("<html", 1, true)
  line(okd and true or false, "dashboarden från GitHub", okd and string.format("hämtad, %d kB", #body // 1024) or (st == 0 and "nås inte (internet, DNS eller certifikat?)" or "HTTP " .. st))
end)

local ok, err = cq:loop(180)
if not ok then line(false, "kontrollen", tostring(err)) end

-- 8. how the screens reach it -----------------------------------------------------------------------------
local ips = io.popen("hostname -I 2>/dev/null")
local addr = ips and (ips:read("a") or ""):match("(%d+%.%d+%.%d+%.%d+)")
if ips then ips:close() end
if addr then line(nil, "adress för skärmarna", "http://" .. addr .. ":" .. PORT) end
local ufw = io.popen("command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1")
local fw = ufw and (ufw:read("a") or ""):gsub("%s+$", "")
if ufw then ufw:close() end
if fw and fw:find("active", 1, true) and not fw:find("inactive", 1, true) then
  line(nil, "brandvägg (ufw)", "aktiv: öppna porten, t.ex. sudo ufw allow from 192.168.1.0/24 to any port " .. PORT)
end

print(string.rep("-", 78))
print(string.format("%d OK, %d FEL", results.ok, results.fail))
os.exit(results.fail == 0 and 0 or 1)
