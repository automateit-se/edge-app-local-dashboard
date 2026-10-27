-- Local dashboard: serves the IoT Open Dashboard from the edge client on the local network.
--
-- The browser gets the dashboard (one HTML file) and talks to this app as if it were IoT Open: a read-only
-- subset of the REST API and MQTT over WebSocket. Behind it:
--   functions, devices     the edge client's own copies (always local)
--   latest values          the local broker, seeded from IoT Open's status API at start
--   layout, logo, images   installation files "dashboard-*", read via REST and cached on disk
--   installation (meta)    read via REST and cached on disk
--   history                IoT Open's v3beta log via REST; without it the history this app keeps
-- REST calls use the edge client's own credentials first and the optional API key when those are refused.
-- What changed is learnt from MQTT (evt/file/updated, evt/installation/updated), nothing is polled.

local cqueues = require("cqueues")
local condition = require("cqueues.condition")
local http_server = require("http.server")
local http_headers = require("http.headers")
local http_request = require("http.request")
local http_util = require("http.util")
local websocket = require("http.websocket")
local basexx = require("basexx")
local mqttm = require("ev.mqtt")
local ev = require("ev")

local VERSION = "0.1.1"
local DEFAULT_DASHBOARD = "https://github.com/automateit-se/iotopen-dashboard/releases/latest/download/iotopen-dashboard-local.html"

-- ---- settings ------------------------------------------------------------------------------------------------

local function str(v, d)
  if v == nil or v == json.null then return d end
  v = tostring(v):match("^%s*(.-)%s*$")
  if v == "" then return d end
  return v
end
local function num(v, d, lo, hi)
  local n = tonumber(v)
  if not n then return d end
  return math.max(lo, math.min(hi, math.floor(n)))
end
local function bool(v, d)
  if v == nil then return d end
  return v == true or v == "true" or v == 1 or v == "1"
end
local function list(v)
  local out = {}
  for part in tostring(v or ""):gmatch("[^,]+") do
    part = part:match("^%s*(.-)%s*$")
    if part ~= "" then out[#out + 1] = part end
  end
  return out
end

local C = cfg or {}
local CONF = {
  port = num(C.port, 8090, 1, 65535),
  networks = list(C.networks),
  access = ({ open = true, pin = true, password = true })[str(C.access, "open")] and str(C.access, "open") or "open",
  secret = str(C.secret, ""),
  control = bool(C.control, true),
  pages = list(C.pages),
  exclude = list(str(C.exclude, "tracker")),
  start = str(C.start_page, ""),
  kiosk = bool(C.kiosk, false),
  hours = num(C.history_hours, 48, 1, 168),
  key = str(C.api_key, ""),
  url = str(C.dashboard_url, DEFAULT_DASHBOARD),
  title = str(C.title, "Dashboard"),
}
if C.exclude == "" then CONF.exclude = {} end
-- a PIN or password mode without a secret would lock everyone out: fall back to viewing only
if CONF.access ~= "open" and CONF.secret == "" then
  log.e("access %s without a PIN/password: the dashboard is shown without control", CONF.access)
  CONF.access, CONF.control = "open", false
end

local iot = json:readfile("/etc/iot-open/iotopen.json") or {}
local IID = tonumber(iot.installation_id) or 0
local CID = tostring(iot.client_id or "0")
local DIR = "/var/lib/iot-open/edge/local-dashboard/" .. tostring(app and app.id or "0")
io.stdout:flush() -- a fork would print what is buffered twice
os.execute("mkdir -p '" .. DIR .. "/files'")

-- ---- small helpers ---------------------------------------------------------------------------------------------

local function now() return os.time() end

local function readfile(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end

local function writefile(p, data)
  local tmp = p .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return os.rename(tmp, p)
end

local function decode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, v = pcall(json.decode, json, s)
  if ok then return v end
  return nil
end

local function save(name, t) writefile(DIR .. "/" .. name, json:encode(t)) end
local function load(name) return decode(readfile(DIR .. "/" .. name)) end

local function randomHex(n)
  local f = io.open("/dev/urandom", "rb")
  local b = f:read(n)
  f:close()
  return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local cq = cqueues.new()
local function spawn(fn, ...)
  local args = table.pack(...)
  cq:wrap(function()
    local ok, err = pcall(fn, table.unpack(args, 1, args.n))
    if not ok then log.e("%s", tostring(err)) end
  end)
end

-- ---- IoT Open over REST -------------------------------------------------------------------------------------

local cloud = { ok = nil, at = 0, auth = {}, refused = {}, bridge = nil } -- auth[kind] = "gw" | "key"

--- Whether IoT Open can be reached: the MQTT bridge's own state when known (a REST call that timed out while the
--- bridge is up does not count), else the last REST call.
local function cloudReachable()
  if cloud.bridge ~= nil then return cloud.bridge end
  return cloud.ok
end

local function fetch(url, headers, timeout)
  local req = http_request.new_from_uri(url)
  req.headers:upsert(":method", "GET")
  for k, v in pairs(headers or {}) do req.headers:upsert(k, v) end
  local h, s = req:go(timeout or 15)
  if not h then return nil, 0 end
  local body = s:get_body_as_string(timeout or 30)
  return body, tonumber(h:get(":status")) or 0, h
end

--- GET a path of IoT Open's API: the edge client's credentials, then the API key when those are refused.
local function api(kind, path)
  if not iot.api then return nil, 0 end
  local tries = cloud.auth[kind] == "key" and { "key" } or { "gw", "key" }
  local status = 0
  for _, how in ipairs(tries) do
    if how == "key" and CONF.key == "" then break end
    local hdr = how == "key" and { ["x-api-key"] = CONF.key }
      or { authorization = "Basic " .. basexx.to_base64(CID .. ":" .. tostring(iot.mqtt_password)) }
    local body, st = fetch(iot.api .. path, hdr)
    status = st
    if st == 0 then
      cloud.ok = false
      return nil, 0
    end
    cloud.ok, cloud.at = true, now()
    if st >= 200 and st < 300 then
      cloud.auth[kind], cloud.refused[kind] = how, nil
      return body, st
    end
    if st ~= 401 and st ~= 403 then return nil, st end
  end
  cloud.refused[kind] = true
  return nil, status
end

-- ---- what is cached ---------------------------------------------------------------------------------------------

local inst = load("installation.json") or { id = IID, name = "Installation " .. IID, client_id = tonumber(CID), meta = {} }
local files = load("files.json") or {}
local latest = {} -- topic -> { topic, value, msg, timestamp }
local hist = {} -- topic -> { {ts, value}, … }
for _, e in ipairs(load("status.json") or {}) do latest[e.topic] = e end
for t, pts in pairs(load("history.json") or {}) do hist[t] = pts end

local tracked = {} -- topics of functions (topic_read*), the ones kept in the local history
local function rebuildTracked()
  tracked = {}
  for _, f in ipairs(functions or {}) do
    for k, v in pairs(f.meta or {}) do
      if k:match("^topic_read") and type(v) == "string" and v ~= "" then tracked[(v:gsub("^%d+/", ""))] = true end
    end
  end
end
rebuildTracked()

local publishToClients -- set further down

local function syncInstallation()
  local body = api("installation", "/api/v2/installation/" .. IID)
  local d = decode(body)
  if type(d) == "table" and d.id then
    d.client_id = d.client_id or tonumber(CID)
    inst = d
    save("installation.json", d)
    publishToClients("evt/installation/updated", "{}")
  end
end

local function safeHash(h) return type(h) == "string" and h:match("^[%w]+$") and h or nil end

local function syncFiles()
  local body = api("files", "/api/v2/file/installation/" .. IID)
  local list_ = decode(body)
  if type(list_) ~= "table" then return end
  local keep, have = {}, {}
  for _, f in ipairs(list_) do
    local h = safeHash(f.hash)
    if h and tostring(f.name):match("^dashboard%-") then
      local p = DIR .. "/files/" .. h
      if not readfile(p) then
        local data, st = api("files", "/api/v2/file/download/" .. h)
        if data then writefile(p, data) else log.e("file %s: %s", tostring(f.name), tostring(st)) end
      end
      if readfile(p) then
        keep[#keep + 1] = f
        have[h] = true
      end
    end
  end
  for _, f in ipairs(files) do
    local h = safeHash(f.hash)
    if h and not have[h] then os.remove(DIR .. "/files/" .. h) end
  end
  files = keep
  save("files.json", files)
  publishToClients("evt/file/updated", "{}")
end

local function syncStatus()
  local d = decode((api("status", "/api/v2/status/" .. IID)))
  if type(d) ~= "table" then return end
  for _, e in ipairs(d) do
    local t = tostring(e.topic or ""):gsub("^%d+/", "")
    local old = latest[t]
    if t ~= "" and (not old or (tonumber(old.timestamp) or 0) <= (tonumber(e.timestamp) or 0)) then
      latest[t] = { topic = t, value = e.value, msg = e.msg or "", timestamp = e.timestamp }
    end
  end
end

--- The dashboard itself: downloaded at start, the copy on disk is used when that fails.
local function syncDashboard()
  local body, st = fetch(CONF.url, nil, 60)
  if st == 200 and body and #body > 1000 and body:find("<html", 1, true) then
    writefile(DIR .. "/dashboard.html", body)
    log.i("dashboard downloaded (%d kB)", #body // 1024)
  else
    log.e("could not download the dashboard (%s), %s", tostring(st), readfile(DIR .. "/dashboard.html") and "using the saved copy" or "none saved yet")
  end
end

-- ---- local history ------------------------------------------------------------------------------------------------
-- At most MAX_POINTS per topic over CONF.hours: one point per GAP seconds, a newer value in the same gap replaces it.

local MAX_POINTS = 4000
local GAP = math.max(10, CONF.hours * 3600 // MAX_POINTS)

local function remember(topic, value, ts)
  if not tracked[topic] or type(value) ~= "number" then return end
  local pts = hist[topic]
  if not pts then
    pts = {}
    hist[topic] = pts
  end
  local last = pts[#pts]
  if last and ts - last[1] < GAP and ts >= last[1] then
    last[2] = value
  elseif not last or ts > last[1] then
    pts[#pts + 1] = { ts, value }
  end
end

local function trimHistory()
  local cut = now() - CONF.hours * 3600
  for t, pts in pairs(hist) do
    local keep = {}
    for _, p in ipairs(pts) do if p[1] >= cut then keep[#keep + 1] = p end end
    if #keep > MAX_POINTS then keep = table.move(keep, #keep - MAX_POINTS + 1, #keep, 1, {}) end
    hist[t] = (#keep > 0 and tracked[t]) and keep or nil
  end
end

local function persist()
  trimHistory()
  save("history.json", hist)
  local arr = {}
  for _, e in pairs(latest) do arr[#arr + 1] = e end
  save("status.json", arr)
end

local AGGR = {
  avg = function(v) local s = 0 for _, x in ipairs(v) do s = s + x end return s / #v end,
  sum = function(v) local s = 0 for _, x in ipairs(v) do s = s + x end return s end,
  min = function(v) return math.min(table.unpack(v)) end,
  max = function(v) return math.max(table.unpack(v)) end,
  last = function(v) return v[#v] end,
  first = function(v) return v[1] end,
  count = function(v) return #v end,
  median = function(v) table.sort(v) return v[#v // 2 + 1] end,
}
AGGR.mean = AGGR.avg

local UNITS = { s = 1, m = 60, h = 3600, d = 86400 }

--- The v3beta log answered from the local history (same shape as IoT Open's).
local function localLog(q)
  local from, to = tonumber(q.from) or (now() - 86400), tonumber(q.to) or now()
  local topics = {}
  for _, t in ipairs(q.topics) do topics[#topics + 1] = (t:gsub("^%d+/", "")) end
  if #topics == 0 then for t in pairs(hist) do topics[#topics + 1] = t end end
  local n, u = tostring(q.aggr_interval or ""):match("^(%d+)([smhd])$")
  local step = n and tonumber(n) * UNITS[u]
  local fn = AGGR[q.aggr_method or ""]
  local data = {}
  for _, t in ipairs(topics) do
    local buckets, order = {}, {}
    for _, p in ipairs(hist[t] or {}) do
      if p[1] >= from and p[1] <= to then
        if step and fn then
          local b = p[1] // step * step
          if not buckets[b] then buckets[b] = {} order[#order + 1] = b end
          table.insert(buckets[b], p[2])
        else
          data[#data + 1] = { timestamp = p[1], topic = CID .. "/" .. t, value = p[2], msg = "" }
        end
      end
    end
    for _, b in ipairs(order) do data[#data + 1] = { timestamp = b, topic = CID .. "/" .. t, value = fn(buckets[b]), msg = "" } end
  end
  local asc = q.order == "asc"
  table.sort(data, function(a, b) if asc then return a.timestamp < b.timestamp end return a.timestamp > b.timestamp end)
  local off, lim = tonumber(q.offset) or 0, tonumber(q.limit) or 500
  local page = {}
  for i = off + 1, math.min(#data, off + lim) do page[#page + 1] = data[i] end
  return { total = #data, count = #page, last_time = page[#page] and page[#page].timestamp or 0, data = page, ["local"] = true }
end

-- ---- access -------------------------------------------------------------------------------------------------------

local sessions = {} -- token -> expires
local failures = {} -- ip -> { n, since }

local function ipv4(s)
  local a, b, c, d = tostring(s):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
end

local function allowedNet(ip)
  if #CONF.networks == 0 then return true end
  ip = tostring(ip):gsub("^::ffff:", "")
  if ip == "127.0.0.1" or ip == "::1" then return true end
  local x = ipv4(ip)
  for _, n in ipairs(CONF.networks) do
    local base, bits = n:match("^([%d%.]+)/?(%d*)$")
    local b = ipv4(base)
    bits = tonumber(bits) or 32
    if x and b then
      local size = 2 ^ (32 - bits)
      if x // size == b // size then return true end
    elseif n == ip then
      return true
    end
  end
  return false
end

local function validSession(token)
  local exp = token and sessions[token]
  if exp and exp > now() then return true end
  if exp then sessions[token] = nil end
  return false
end

local function canView(token) return CONF.access ~= "password" or validSession(token) end
local function canControl(token) return CONF.control and (CONF.access == "open" or validSession(token)) end

-- ---- MQTT over WebSocket ------------------------------------------------------------------------------------------
-- Enough of MQTT 3.1.1 for the dashboard's client: CONNECT, SUBSCRIBE, UNSUBSCRIBE, PUBLISH (QoS 0), PING.
-- Topics carry the client id like on IoT Open's broker ("<client id>/obj/…"); locally they do not.

local clients = {}

local function varlen(n)
  local out = {}
  repeat
    local d = n % 128
    n = n // 128
    if n > 0 then d = d | 128 end
    out[#out + 1] = string.char(d)
  until n == 0
  return table.concat(out)
end

local function packet(kind, body) return string.char(kind) .. varlen(#body) .. body end
local function mstr(s) return string.pack(">s2", s) end

local function enqueue(c, data)
  if #c.queue > 1000 then return end -- a client that does not keep up loses messages, not memory
  c.queue[#c.queue + 1] = data
  c.cond:signal()
end

publishToClients = function(topic, payload)
  local full = CID .. "/" .. topic
  local data
  for c in pairs(clients) do
    for f in pairs(c.filters) do
      if mqttm.match(f, full) then
        data = data or packet(0x30, mstr(full) .. payload)
        enqueue(c, data)
        break
      end
    end
  end
end

local function onPacket(c, kind, flags, body)
  if kind == 1 then -- CONNECT: the password is the session from /local/login (or anything when open)
    local pos = 1
    local _, p = string.unpack(">s2", body, pos)
    local cflags = body:byte(p + 1)
    pos = p + 4
    local _
    _, pos = string.unpack(">s2", body, pos) -- client id
    if cflags & 0x04 ~= 0 then _, pos = string.unpack(">s2", body, pos) _, pos = string.unpack(">s2", body, pos) end
    if cflags & 0x80 ~= 0 then _, pos = string.unpack(">s2", body, pos) end
    local token = cflags & 0x40 ~= 0 and (string.unpack(">s2", body, pos)) or nil
    if not canView(token) then
      enqueue(c, packet(0x20, "\0\5"))
      c.closing = true
      return
    end
    c.token = token
    enqueue(c, packet(0x20, "\0\0"))
  elseif kind == 8 or kind == 10 then -- SUBSCRIBE / UNSUBSCRIBE
    local id = body:sub(1, 2)
    local pos, granted = 3, {}
    while pos <= #body do
      local f
      f, pos = string.unpack(">s2", body, pos)
      if kind == 8 then
        pos = pos + 1
        c.filters[f] = true
        granted[#granted + 1] = "\0"
      else
        c.filters[f] = nil
      end
    end
    enqueue(c, packet(kind == 8 and 0x90 or 0xB0, id .. table.concat(granted)))
  elseif kind == 3 then -- PUBLISH from the browser: control, only when allowed
    local topic, pos = string.unpack(">s2", body)
    if (flags >> 1) & 3 > 0 then pos = pos + 2 end
    local prefix = CID .. "/"
    if topic:sub(1, #prefix) ~= prefix then return end
    topic = topic:sub(#prefix + 1)
    if not canControl(c.token) then
      log.i("refused control of %s from %s", topic, c.ip)
      return
    end
    if not (topic:match("^set/") or topic:match("^obj/") or topic:match("^cmd/")) then return end
    mq:pub(topic, body:sub(pos), false, 0)
  elseif kind == 12 then
    enqueue(c, "\208\0") -- PINGRESP
  elseif kind == 14 then
    c.closing = true
  end
end

local function serveMqtt(stream, req, ip)
  local ws = websocket.new_from_stream(stream, req)
  if not ws or not ws:accept({ protocols = { "mqtt" } }) then return end
  local c = { ws = ws, filters = {}, queue = {}, cond = condition.new(), ip = ip }
  clients[c] = true
  cq:wrap(function()
    while clients[c] do
      local d = table.remove(c.queue, 1)
      if d then
        if not ws:send(d, "binary") then break end
      else
        c.cond:wait(30)
      end
    end
  end)
  local buf = ""
  while not c.closing do
    local data = ws:receive(120)
    if not data then break end
    buf = buf .. data
    while #buf >= 2 do
      local len, mul, i = 0, 1, 2
      local byte
      repeat
        byte = buf:byte(i)
        if not byte then break end
        len = len + (byte & 127) * mul
        mul, i = mul * 128, i + 1
      until byte & 128 == 0
      if not byte or #buf < i - 1 + len then break end
      local ok, err = pcall(onPacket, c, buf:byte(1) >> 4, buf:byte(1) & 15, buf:sub(i, i - 1 + len))
      if not ok then log.e("mqtt from %s: %s", ip, tostring(err)) c.closing = true end
      buf = buf:sub(i + len)
    end
  end
  cqueues.sleep(0.2) -- let a refusal (CONNACK 5) reach the browser
  clients[c] = nil
  c.cond:signal()
  ws:close()
end

-- ---- HTTP ---------------------------------------------------------------------------------------------------------

local function reply(stream, status, body, ctype, extra)
  local h = http_headers.new()
  h:append(":status", tostring(status))
  h:append("content-type", ctype or "application/json")
  h:append("cache-control", "no-store")
  h:append("x-content-type-options", "nosniff")
  for k, v in pairs(extra or {}) do h:append(k, v) end
  stream:write_headers(h, false)
  stream:write_chunk(body or "", true)
end

local function replyJson(stream, status, t) reply(stream, status, json:encode(t)) end

local function localConfig()
  return {
    appTitle = CONF.title,
    liveUpdates = true,
    customServers = false,
    mapTiles = "",
    ["local"] = {
      installation = IID,
      access = CONF.access,
      control = CONF.control,
      pages = CONF.pages,
      exclude = CONF.exclude,
      start = CONF.start,
      kiosk = CONF.kiosk,
      version = VERSION,
    },
  }
end

local WAIT = [[<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="30"><title>Dashboard</title>
<body style="font:16px system-ui;margin:40px">Dashboarden har inte hämtats än. Edge clienten behöver internet första gången appen startar.
Sidan laddas om automatiskt.</body>]]

local function query(path)
  local q = { topics = {} }
  local qs = path:match("%?(.*)$")
  if qs then
    for k, v in http_util.query_args(qs) do
      if k == "topics" or k == "topic" then q.topics[#q.topics + 1] = v else q[k] = v end
    end
  end
  return q
end

local function logRequest(stream, path)
  local q = query(path)
  if CONF.key ~= "" or not cloud.refused.log then
    local body = api("log", "/api/v3beta/log/" .. IID .. (path:match("(%?.*)$") or ""))
    if body then return reply(stream, 200, body) end
  end
  replyJson(stream, 200, localLog(q))
end

local function login(stream, ip)
  local f = failures[ip]
  if f and f.n >= 5 and now() - f.since < 300 then return replyJson(stream, 429, { message = "För många försök, vänta 5 minuter" }) end
  local body = decode(stream:get_body_as_string(5)) or {}
  if CONF.secret == "" or tostring(body.secret or "") ~= CONF.secret then
    if not f or now() - f.since >= 300 then f = { n = 0, since = now() } failures[ip] = f end
    f.n = f.n + 1
    return replyJson(stream, 401, { message = CONF.access == "pin" and "Fel PIN-kod" or "Fel lösenord" })
  end
  failures[ip] = nil
  local token = randomHex(24)
  sessions[token] = now() + (CONF.access == "password" and 30 * 86400 or 12 * 3600)
  replyJson(stream, 200, { token = token })
end

local function route(stream, req, ip)
  local method = req:get(":method")
  local path = req:get(":path") or "/"
  local p = path:gsub("%?.*$", "")
  if p == "/mqtt" then return serveMqtt(stream, req, ip) end
  if p == "/" or p == "/index.html" then
    return reply(stream, 200, readfile(DIR .. "/dashboard.html") or WAIT, "text/html; charset=utf-8", { ["x-frame-options"] = "SAMEORIGIN" })
  end
  if p == "/config.json" then return replyJson(stream, 200, localConfig()) end
  if p == "/local/login" and method == "POST" then return login(stream, ip) end
  if p == "/local/status" then
    return replyJson(stream, 200, {
      cloud = cloudReachable(), bridge = cloud.bridge, cloud_at = cloud.at, files = cloud.refused.files and "refused" or "ok",
      key = CONF.key ~= "", session = validSession(req:get("x-api-key")), version = VERSION,
    })
  end
  if not p:match("^/api/") then return replyJson(stream, 404, { message = "Not found" }) end
  if method ~= "GET" then return replyJson(stream, 403, { message = "Den lokala dashboarden kan bara läsa. Ändra dashboarden i molnet." }) end
  if not canView(req:get("x-api-key")) then return replyJson(stream, 401, { message = "Unauthorized" }) end
  local i = "/" .. IID
  if p == "/api/v2/user/me" then return replyJson(stream, 200, { id = 0, email = "", firstname = "Lokal", ["local"] = true }) end
  if p == "/api/v2/installationinfo" then return replyJson(stream, 200, { { id = IID, name = inst.name, client_id = inst.client_id } }) end
  if p == "/api/v2/installation" .. i then return replyJson(stream, 200, inst) end
  if p == "/api/v2/functionx" .. i then return replyJson(stream, 200, functions or {}) end
  if p == "/api/v2/devicex" .. i then return replyJson(stream, 200, devices or {}) end
  if p == "/api/v2/status" .. i then
    local arr = {}
    for _, e in pairs(latest) do arr[#arr + 1] = e end
    return replyJson(stream, 200, arr)
  end
  if p == "/api/v3beta/log" .. i then return logRequest(stream, path) end
  if p == "/api/v2/file/installation" .. i then return replyJson(stream, 200, files) end
  local h = safeHash(p:match("^/api/v2/file/download/(.+)$"))
  if h then
    for _, f in ipairs(files) do
      if f.hash == h then
        local data = readfile(DIR .. "/files/" .. h)
        if data then return reply(stream, 200, data, f.mime or "application/octet-stream") end
      end
    end
  end
  replyJson(stream, 404, { message = "Not found" })
end

local server = http_server.listen({
  host = "0.0.0.0",
  port = CONF.port,
  cq = cq,
  onstream = function(_, stream)
    local req = stream:get_headers(30)
    if not req then return end
    local _, ip = stream.connection:peername()
    if not allowedNet(ip) then return replyJson(stream, 403, { message = "Forbidden" }) end
    local ok, err = pcall(route, stream, req, tostring(ip))
    if not ok then
      log.e("%s %s: %s", tostring(req:get(":method")), tostring(req:get(":path")), tostring(err))
      pcall(replyJson, stream, 500, { message = "Internal error" })
    end
  end,
  onerror = function(_, _, op, err) log.d("http %s: %s", tostring(op), tostring(err)) end,
})

-- ---- MQTT from the edge client ------------------------------------------------------------------------------

--- Repeats fn every secs seconds. (edge.timer's interval shares one global callback between all intervals.)
local function every(secs, fn)
  local function tick()
    timer:after(secs, tick)
    fn()
  end
  timer:after(secs, tick)
end

local pending = {}
local function later(name, secs, fn)
  if pending[name] then pending[name]:cancel() end
  pending[name] = timer:after(secs, function()
    pending[name] = nil
    spawn(fn)
  end)
end

--- The edge client's MQTT bridge reports its own connection to IoT Open on <client id>/box/event/status
--- (mosquitto's notification topic, retained, also on the local broker): 1 = connected, 0 = not. When it comes
--- back, what may have changed meanwhile is read again, once. No polling.
local function onBridge(_, payload)
  local up = tostring(payload):match("^%s*1") ~= nil
  local was = cloud.bridge
  cloud.bridge = up
  if up and was == false then
    log.i("connected to IoT Open again, reading what may have changed")
    spawn(function()
      syncStatus()
      syncInstallation()
      syncFiles()
    end)
  elseif not up and was ~= false then
    log.i("the edge client is not connected to IoT Open, showing saved data")
  end
end

local function onLocal(topic, payload)
  -- the dashboard re-reads these: tell it only once the local copy is up to date
  if topic == "evt/file/updated" then return later("files", 2, syncFiles) end
  if topic == "evt/installation/updated" then return later("installation", 2, syncInstallation) end
  if topic == "evt/functionx/updated" or topic == "evt/devicex/updated" or topic == "evt/edge_app/updated" then return end
  local d = decode(payload)
  local value, msg, ts
  if type(d) == "table" and d.value ~= nil then
    value, msg, ts = d.value, d.msg, tonumber(d.timestamp)
  else
    value = tonumber(payload) or payload
  end
  ts = ts or now()
  if ts > 1e12 then ts = ts // 1000 end
  if not topic:match("^evt/") then
    latest[topic] = { topic = topic, value = value, msg = type(msg) == "string" and msg or "", timestamp = ts }
    remember(topic, value, ts)
  end
  publishToClients(topic, payload)
end

function onFunctionsUpdated()
  rebuildTracked()
  publishToClients("evt/functionx/updated", "{}")
end

function onDevicesUpdated() publishToClients("evt/devicex/updated", "{}") end

function onExit() persist() end

function onStart()
  assert(server:listen())
  log.i("local dashboard %s on port %d (installation %d, access %s)", VERSION, CONF.port, IID, CONF.access)
  ev:add(cq:pollfd(), function() cq:step(0) end)
  every(0.1, function() cq:step(0) end)
  mq:sub("obj/#", 0)
  mq:sub("evt/#", 0)
  mq:bind("obj/#", onLocal)
  mq:bind("evt/#", onLocal)
  mq:sub(CID .. "/box/event/status", 0)
  mq:bind(CID .. "/box/event/status", onBridge)
  spawn(function()
    syncDashboard()
    syncStatus()
    syncInstallation()
    syncFiles()
    if cloud.refused.files then log.e("installation files are not readable: add an API key with read access") end
  end)
  every(600, persist)
end
