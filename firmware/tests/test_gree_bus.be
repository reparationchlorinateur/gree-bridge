import sys
sys.path().push(".")   # mocks (persist.be, mqtt.be) live next to this test
import math
import string
# ---------------- mocks for the Tasmota environment ----------------
NOW = 0
MQTT_UP = true
DEVNAME = "Living room heat pump"
PUBS = []
LOGS = []
SERIALS = {}
class serial
  static var SERIAL_8E1 = 0x800001e
  static var SERIAL_8N1 = 0x800001c
  static var SERIAL_8O1 = 0x800001f
  var rx, tx, baud, mode, inv, queue, ready
  def init(rx, tx, baud, mode, inv)
    self.rx = rx  self.tx = tx  self.baud = baud  self.mode = mode  self.inv = inv
    self.queue = []      # [deliver_time_ms, bytes]
    self.ready = bytes()
    SERIALS[rx] = self
  end
  def pump()
    var keep = []
    for q: self.queue
      if q[0] <= NOW  self.ready = self.ready + q[1]  else  keep.push(q)  end
    end
    self.queue = keep
  end
  def available() self.pump() return size(self.ready) end
  def read() self.pump() var r = self.ready  self.ready = bytes()  return r end
  var closed
  def close() self.closed = true end
end
class MockTasmota
  var fast, drivers, cmds, resp, rules
  def init() self.fast = [] self.drivers = [] self.cmds = {} self.rules = {} end
  def add_rule(p, f) self.rules[p] = f end
  def wifi() return {"mac": "AA:BB:CC:01:02:03", "ip": "192.168.1.50"} end
  def millis() return NOW end
  def add_fast_loop(f) self.fast.push(f) end
  def add_driver(d) self.drivers.push(d) end
  def add_cmd(n, f) self.cmds[n] = f end
  def publish_result(p, sub) PUBS.push([sub, p]) end
  def web_send(s) print("  web:", s) end
  def resp_cmnd_str(s) self.resp = s end
  def resp_cmnd(s) self.resp = s end
  var appended
  def response_append(s) self.appended = s end
  def cmd(c, mute) if c == "Topic" return {"Topic": "tasmota_gree"} end if c == "DeviceName" return {"DeviceName": DEVNAME} end return nil end
end
tasmota = MockTasmota()
def log(msg, lvl) LOGS.push(msg) print("  log", lvl, msg) end

# UART model: 600 8E1 + 1 idle bit -> 20 ms per byte; blocks of 10 bytes, remainder after 2 symbol times
def send_frame(ser, start_ms, data)
  var bt = 12.0 * 1000 / 600
  var n = size(data)
  var i = 0
  while i < n
    var j = i + 10
    if j > n j = n end
    var t = start_ms + j * bt
    if j - i < 10 t += 2 * bt end
    ser.queue.push([int(t + 0.999), data[i .. j - 1]])
    i = j
  end
  return start_ms + n * bt
end
def frame(first, n) var b = bytes() for k: 0 .. n - 1 b.add((first + k) % 256) end return b end
def run(until_ms) while NOW < until_ms  for f: tasmota.fast  f()  end  NOW += 10 end end

# ---------------- load the real script ----------------
gree_bus = nil
GreeBus = nil
GreeIndoor = nil
GreeOutdoor = nil
gree_scan = nil
compile("../tasmota/gree_bus.be", "file")()
assert(gree_bus != nil)
var rxs = SERIALS[6]  var txs = SERIALS[7]
assert(rxs.tx == -1 && rxs.baud == 600 && rxs.mode == serial.SERIAL_8E1 && rxs.inv == true && txs.inv == false)
tasmota.cmds["BusAuto"]("BusAuto", 0, "0", nil)   # older tests keep fixed polarity

def expect(label, want)
  var got = []
  for l: LOGS got.push(l) end
  LOGS.clear()
  var ok = (got == want)
  print(ok ? "PASS" : "FAIL", label)
  if !ok print("  want", want) print("  got ", got) end
  return ok
end
var fails = 0
var h20a = GreeBus.hex(frame(0x31, 9))
var h20b = GreeBus.hex(frame(0x80, 9))
LOGS.clear()

# 1) indoor frame on TX + echo/reply on RX, reply 400 ms after -> split by silence
var t_end = send_frame(txs, 1000, frame(0x31, 9))
send_frame(rxs, 1000, frame(0x31, 9))
send_frame(rxs, t_end + 400, frame(0x80, 9))
run(2500)
if !expect("silence split (reply 400 ms later)", ["BUS: RX 9 bytes: " + h20a, "BUS: TX 9 bytes: " + h20a, "BUS: RX 9 bytes: " + h20b]) fails += 1 end

# 2) reply only 5 ms later -> merges (expected), then BusLen 20 splits it
t_end = send_frame(rxs, 3000, frame(0x31, 9))
send_frame(rxs, t_end + 30, frame(0x80, 9))
run(4500)
if !expect("merged without BusLen (reply 30 ms later)", ["BUS: RX 18 bytes: " + GreeBus.hex(frame(0x31, 9) + frame(0x80, 9))]) fails += 1 end
tasmota.cmds["BusLen"]("BusLen", 0, "9", nil)
assert(tasmota.resp == "9")
t_end = send_frame(rxs, 5000, frame(0x31, 9))
send_frame(rxs, t_end + 30, frame(0x80, 9))
run(6500)
if !expect("BusLen 9 splits", ["BUS: RX 9 bytes: " + h20a, "BUS: RX 9 bytes: " + h20b]) fails += 1 end

# 3) publishing: off by default, on after BusPublish 1, only on change
assert(size(PUBS) == 0)
tasmota.cmds["BusPublish"]("BusPublish", 0, "1", nil)
assert(tasmota.resp == "ON")
send_frame(txs, 7000, frame(0x31, 9))
send_frame(txs, 8000, frame(0x31, 9))       # identical -> logged but not republished
send_frame(txs, 9000, frame(0x32, 9))
run(10500)
LOGS.clear()
print("  pubs:", PUBS)
var ok = size(PUBS) == 2 && PUBS[0][0] == "tele/tasmota_gree/BUS_TX" && PUBS[1][0] == "tele/tasmota_gree/BUS_TX"
import json
var j = json.load(PUBS[0][1])
ok = ok && j["Bus"]["Tap"] == "TX" && j["Bus"]["Len"] == 9 && j["Bus"]["Data"] == h20a
print(ok ? "PASS" : "FAIL", "publish on change, valid JSON") if !ok fails += 1 end

# 4) commands validate input, web page renders
tasmota.cmds["BusGap"]("BusGap", 0, "5", nil)     assert(tasmota.resp == "300")
tasmota.cmds["BusGap"]("BusGap", 0, "150", nil)   assert(tasmota.resp == "150")
tasmota.cmds["BusLen"]("BusLen", 0, "", nil)      assert(tasmota.resp == "9")
tasmota.cmds["BusPublish"]("BusPublish", 0, "off", nil) assert(tasmota.resp == "OFF")
gree_bus.web_sensor()
print(fails == 0 ? "ALL PASS" : string.format("%d FAILURES", fails))

# ---------------- decoder tests with real frames from the captures ----------------
print("--- decoder")
PUBS.clear()
tasmota.cmds["BusLen"]("BusLen", 0, "0", nil)
tasmota.cmds["BusGap"]("BusGap", 0, "300", nil)
def gree_pubs()
  var r = []
  for p: PUBS if p[0] == "tele/tasmota_gree/GREE" r.push(json.load(p[1])["Gree"]) end end
  return r
end
def tx(hexstr) send_frame(txs, NOW + 10, bytes(hexstr)) run(NOW + 600) end
def tick() gree_bus.every_second() end
var dfail = 0
def check(label, cond) print(cond ? "PASS" : "FAIL", label) if !cond dfail += 1 end end

tick()
check("nothing published before the first valid frame", size(gree_pubs()) == 0)
tx("0713720400838B6D0D")
tick()
var g = gree_pubs()
check("standby frame published", size(g) == 1)
if size(g) == 1
  var x = g[0]
  print("  ", x)
  check("standby values", x["Room"] == 19.5 && x["CoilRaw"] == 114 && x["Coil"] == 20.1 && x["Power"] == "OFF" &&
        x["Mode"] == "heat" && x["Setpoint"] == 27 && x["Fan"] == 0 && x["Link"] == "OK")
end
tx("0713A50C00039B220D")                       # heat on, coil 165, fan 1 -> immediate
tick()
g = gree_pubs()
check("state change published immediately", size(g) == 2 && g[1]["Fan"] == 1 && g[1]["Power"] == "ON" && g[1]["Coil"] == 39.0 && g[1]["Room"] == 19.0)
tx("0713A40C00039B230D")                       # coil only 165 -> 164, within interval
tick()
check("temperature-only change held back inside GreeInterval", size(gree_pubs()) == 2)
NOW += 10000
tx("0713A40C00039B230D")
tick()
g = gree_pubs()
check("temperature change published after GreeInterval", size(g) == 3 && g[2]["CoilRaw"] == 164)
tx("0713A40C00039B240D")                       # bad checksum -> ignored
tick()
check("bad checksum ignored", gree_bus.indoor.coil_raw == 164 && size(gree_pubs()) == 3)
# RX tap: indoor echo merged with an unknown outdoor reply in one block
send_frame(rxs, NOW + 10, bytes("55AA01") + bytes("071471090003B0DF0D") + bytes("31100014"))
run(NOW + 900)
tick()
g = gree_pubs()
check("indoor frame found inside a merged RX block", gree_bus.indoor.mode == "cool" && gree_bus.indoor.fan == 3 && g[-1]["Mode"] == "cool")
# frame split across two deliveries (short BusGap) is still decoded
tasmota.cmds["BusGap"]("BusGap", 0, "50", nil)
var before = gree_bus.indoor.frames
send_frame(txs, NOW + 10, bytes("1122334455") + bytes("071472090083B05C0D"))
run(NOW + 600)
check("frame split over two blocks still decoded", gree_bus.indoor.frames == before + 1 && gree_bus.indoor.coil_raw == 0x72)
tasmota.cmds["BusGap"]("BusGap", 0, "300", nil)
# link loss
NOW += 11000
tick()
g = gree_pubs()
check("link LOST published after 10 s without frames", g[-1]["Link"] == "LOST")
# teleperiod + command
import introspect
check("no SENSOR (TelePeriod) block any more", introspect.members(GreeBus).find("json_append") == nil && introspect.members(GreeBus).find("every_second") != nil)
tasmota.cmds["Gree"]("Gree", 0, "", nil)
var gl = json.load(tasmota.resp)["Gree"]
check("LOST: measurements null, not the old readings", gl["Link"] == "LOST" && gl["CoilRaw"] == nil && gl["Room"] == nil && gl["Fan"] == nil && gl["Setpoint"] != nil)
tasmota.cmds["GreeInterval"]("GreeInterval", 0, "30", nil)
check("GreeInterval 30", tasmota.resp == "30" && gree_bus.interval == 30)
# coil conversion vs Python model
var ref = {78: 7.5, 79: 7.9, 81: 8.6, 113: 19.8, 114: 20.1, 128: 25.0, 165: 39.0}
var ok = true
for k: ref.keys()
  var v = real(string.format("%.1f", GreeIndoor.coil_c(k)))
  if v != ref[k] print("  coil", k, v, ref[k]) ok = false end
end
check("coil conversion matches the Python model", ok)

# ---------------- outdoor reply (capture 3, heating at 28 C) ----------------
print("--- outdoor")
tasmota.cmds["Gree"]("Gree", 0, "", nil)
check("no Out field before the first outdoor frame", json.load(tasmota.resp)["Gree"].find("Out") == nil)
NOW += 1000
send_frame(txs, NOW + 10, bytes("07159A0C0003BC3C0D"))
var e = send_frame(rxs, NOW + 10, bytes("07159A0C0003BC3C0D"))
send_frame(rxs, e + 50, bytes("082C01004C78612B04570F"))
run(NOW + 1200)
tick()
g = gree_pubs()
var want_out = [44, 1, 0, 76, 120, 97, 43, 4]
check("outdoor reply decoded from the RX echo+reply block", gree_bus.outdoor.frames == 1 && gree_bus.outdoor.raw == want_out)
check("indoor echo on RX still decoded", gree_bus.indoor.mode == "heat" && gree_bus.indoor.setpoint == 28 && gree_bus.indoor.room == 21.0)
check("published with Out + OutLink OK (key change)", size(g) > 0 && g[-1].find("Out") == want_out && g[-1]["OutLink"] == "OK" && g[-1]["Link"] == "OK")
print("  ", g[-1])
# o7 changes 0x2B -> 0x23 (new checksum 0x5F): value-only change, held back inside GreeInterval
var np = size(g)
send_frame(txs, NOW + 10, bytes("07159A0C0003BC3C0D"))
e = send_frame(rxs, NOW + 10, bytes("07159A0C0003BC3C0D"))
send_frame(rxs, e + 50, bytes("082C01004C786123045F0F"))
run(NOW + 1200)
tick()
check("o7 change decoded", gree_bus.outdoor.raw[6] == 0x23 && gree_bus.outdoor.frames == 2)
check("value-only outdoor change held back", size(gree_pubs()) == np)
# bad outdoor checksum ignored
send_frame(rxs, NOW + 10, bytes("082C01004C786128045F0F"))
run(NOW + 600)
check("bad outdoor checksum ignored", gree_bus.outdoor.frames == 2 && gree_bus.outdoor.raw[6] == 0x23)
# reply split across two serial blocks (10-byte delivery) with short BusGap
tasmota.cmds["BusGap"]("BusGap", 0, "50", nil)
send_frame(rxs, NOW + 10, bytes("082C01004C78612804540F"))
run(NOW + 800)
check("outdoor reply split over two blocks decoded", gree_bus.outdoor.frames == 3 && gree_bus.outdoor.raw[6] == 0x28)
tasmota.cmds["BusGap"]("BusGap", 0, "300", nil)
# outdoor goes silent while indoor keeps talking -> OutLink LOST published immediately
for k: 0 .. 11
  send_frame(txs, NOW + 10, bytes("07159A0C0003BC3C0D"))
  run(NOW + 1000)
  tick()
end
g = gree_pubs()
check("OutLink LOST while indoor Link stays OK", g[-1]["OutLink"] == "LOST" && g[-1]["Link"] == "OK")
tasmota.cmds["Gree"]("Gree", 0, "", nil)
var gq = json.load(tasmota.resp)["Gree"]
check("OutLink LOST: outdoor values null (no phantom power), indoor still live",
      gq["Out"] == nil && gq["PowerW"] == nil && gq["CompHz"] == nil && gq["OutAir"] == nil && gq["Room"] != nil && gq["Link"] == "OK")
# outdoor-only (indoor never seen) JSON is still valid
var o2 = GreeOutdoor()
o2.feed(bytes("082C01004C78612B04570F"), 0, "RX")
var bus2 = gree_bus
check("outdoor json_part shape", o2.json_part(0) == ',"CompHz":44,"CompA":2.15,"PowerW":536,"OutCoil":6.8,"OutAir":14.3,"DischC":49.5,"OutMode":"heat","DischRaw":120,"LoadRaw":43,"Out":[44,1,0,76,120,97,43,4],"OutLink":"OK"')
print("  ", o2.json_part(0))
# compressor stop (o1 -> 0, mode off) is published immediately; restart ramp values wait for GreeInterval
tasmota.cmds["GreeInterval"]("GreeInterval", 0, "10", nil)
def outframe(o)
  var b = bytes("08")
  var x = 0
  for v: o b.add(v) x = x ^ v end
  b.add(x) b.add(0x0F)
  return b
end
def both(o)
  send_frame(txs, NOW + 10, bytes("07159A0C0003BC3C0D"))
  var e = send_frame(rxs, NOW + 10, bytes("07159A0C0003BC3C0D"))
  send_frame(rxs, e + 50, outframe(o))
  run(NOW + 1000)
  tick()
end
both([44, 1, 0, 76, 120, 97, 40, 4])
NOW += 11000
both([44, 1, 0, 76, 120, 97, 40, 4])
var np2 = size(gree_pubs())
both([0, 0, 0, 77, 118, 97, 0, 0])
g = gree_pubs()
check("compressor stop published immediately", size(g) == np2 + 1 && g[-1]["CompHz"] == 0 && g[-1]["OutMode"] == "off" && g[-1]["PowerW"] == 0 && g[-1]["CompA"] == 0)
both([0, 0, 0, 78, 117, 97, 0, 4])
g = gree_pubs()
check("outdoor mode change published immediately", size(g) == np2 + 2 && g[-1]["OutMode"] == "heat")
both([23, 1, 0, 78, 117, 97, 0, 4])
g = gree_pubs()
check("compressor start published immediately", size(g) == np2 + 3 && g[-1]["CompHz"] == 23 && g[-1]["OutCoil"] == 7.5)
both([24, 1, 0, 78, 117, 97, 0, 4])
check("ramp step held back inside GreeInterval", size(gree_pubs()) == np2 + 3)
gree_bus.web_sensor()
# clamp-meter points: o7 55 -> ~3.05 A total, o7 27 -> ~1.6 A total (240 V)
var o3 = GreeOutdoor()
o3.feed(outframe([46, 1, 0, 119, 151, 101, 55, 1]), 0, "RX")
check("o7 55 -> 2.75 A compressor, 3.0 A total ~ clamp 3.05 A", math.abs(o3.comp_amps() - 2.75) < 1e-6 && o3.power_w() == int(240 * 0.95 * 2.95 + 0.5))
o3.feed(outframe([46, 1, 0, 107, 81, 101, 27, 1]), 0, "RX")
check("o7 27 -> 1.35 A compressor, 1.55 A total ~ clamp 1.6 A", math.abs(o3.comp_amps() - 1.35) < 1e-6 && o3.power_w() == 353)
print("  ", o3.json_part(0))
# ---------------- standby: unit OFF, then the bus goes silent ----------------
print("--- standby")
both([0, 0, 0, 96, 41, 96, 0, 0])
send_frame(txs, NOW + 10, bytes("07131F0400838B000D"))     # indoor frame with power OFF (b3 = 0x04)
run(NOW + 1000)
tick()
check("cold reference: DischC 13.6 at o5 = 41", gree_pubs()[-1].find("DischC") == 13.6 || json.load('{' + gree_bus.outdoor.json_part(NOW)[1 ..] + '}')["DischC"] == 13.6)
NOW += 12000
tick()
g = gree_pubs()
check("silence after OFF -> Link STANDBY, OutLink STANDBY (published)", g[-1]["Link"] == "STANDBY" && g[-1]["OutLink"] == "STANDBY")
check("STANDBY: power 0, fan 0, mode off, temperatures null", g[-1]["PowerW"] == 0 && g[-1]["CompHz"] == 0 && g[-1]["Fan"] == 0 &&
      g[-1]["OutMode"] == "off" && g[-1]["OutAir"] == nil && g[-1]["Room"] == nil && g[-1]["Out"] == nil && g[-1]["Power"] == "OFF")
var nsb = size(gree_pubs())
NOW += 61000
tick()
g = gree_pubs()
check("heartbeat in standby repeats no old readings", size(g) == nsb + 1 && g[-1]["Room"] == nil && g[-1]["PowerW"] == 0)
both([46, 1, 0, 107, 81, 101, 27, 1])
send_frame(txs, NOW + 10, bytes("07159A0C0003BC3C0D"))
run(NOW + 1000)
NOW += 12000
tick()
g = gree_pubs()
check("silence while ON -> LOST", g[-1]["Link"] == "LOST" && g[-1]["OutLink"] == "LOST")
check("LOST: PowerW / CompHz / Fan null", g[-1]["PowerW"] == nil && g[-1]["CompHz"] == nil && g[-1]["Fan"] == nil)
# ---------------- automatic polarity ----------------
import persist
print("--- polarity")
tasmota.cmds["BusAuto"]("BusAuto", 0, "1", nil)
check("BusAuto on", json.load(tasmota.resp)["BusAuto"] == "ON")
var tx_old = SERIALS[7]
var rx_old = SERIALS[6]
for k: 0 .. 24  run(NOW + 1000)  tick()  end
check("silent bus (standby): no polarity switch", SERIALS[7] == tx_old && SERIALS[6] == rx_old && !tx_old.closed)
for k: 0 .. 21
  send_frame(tx_old, NOW + 10, bytes("F0E1D2C3B4A5968778"))      # what a wrong polarity looks like: bytes, no frame
  send_frame(rx_old, NOW + 10, bytes("F0E1D2C3B4A5968778"))
  run(NOW + 1000)  tick()
end
var tx_new = SERIALS[7]
check("TX reopened inverted after 20 s of bytes without a valid frame", tx_new != tx_old && tx_old.closed == true && tx_new.inv == true)
check("RX tried the other polarity too", SERIALS[6].inv == false)
var before_f = gree_bus.indoor.frames
var saves0 = persist.saves
for k: 0 .. 24
  send_frame(tx_new, NOW + 10, bytes("07159A0C0003BC3C0D"))
  run(NOW + 1000)
  tick()
end
check("frames decoded on the reopened TX port", gree_bus.indoor.frames >= before_f + 24)
check("working TX polarity saved", persist.find("bus_inv_tx", nil) == true)
check("flash written once, not on every frame", persist.saves - saves0 == 1)
check("no further switch while frames arrive", SERIALS[7] == tx_new)
tasmota.cmds["BusAuto"]("BusAuto", 0, "", nil)
check("BusAuto status shows TX inverted", json.load(tasmota.resp)["TX"] == "inverted")
gree_bus.web_sensor()

# ---------------- Home Assistant discovery ----------------
print("--- discovery")
def disc_pubs() var r = [] for p: PUBS if string.find(p[0], "homeassistant/") == 0 r.push(p) end end return r end
var d = disc_pubs()
check("discovery published once (first second with MQTT up)", size(d) == 20)
var ids = {}
var okd = true
var maxlen = 0
var names = []
for p: d
  okd = okd && p[2] == true
  var c = json.load(p[1])
  okd = okd && c["dev"]["name"] == "Living room heat pump" && c["stat_t"] == "~/GREE" && c["~"] == "tele/tasmota_gree"
  okd = okd && c.find("has_entity_name") == nil && c["avty_t"] == "~/LWT" && c["exp_aft"] == 180
  okd = okd && c["dev"]["ids"][0] == "gree_aabbcc010203" && c["dev"]["cns"][0][1] == "aa:bb:cc:01:02:03" && c["dev"]["cu"] == "http://192.168.1.50/"
  if string.find(p[0], "/binary_sensor/") > 0 okd = okd && c["pl_on"] == "ON" && c["pl_off"] == "OFF" end
  ids[c["uniq_id"]] = true
  names.push(c["name"])
  var l = size(p[0]) + size(p[1])
  if l > maxlen maxlen = l end
end
check("retained, valid JSON, device = DeviceName + MAC, availability = LWT", okd)
check("20 unique ids", size(ids) == 20)
check("each message well under Tasmota's 1200-byte MQTT limit", maxlen < 1000)
print("  longest discovery message:", maxlen, "bytes")
print("  entities:", names)
check("topic format", d[0][0] == "homeassistant/sensor/gree_aabbcc010203/room_temperature/config")
check("enum options kept", json.load(d[3][1])["options"] == ["auto", "cool", "dry", "fan_only", "heat"])
var n0 = size(disc_pubs())
for k: 0 .. 5 NOW += 1000 tick() end
check("no repeat while nothing changes", size(disc_pubs()) == n0)
DEVNAME = "Bedroom heat pump"
for k: 0 .. 61 NOW += 1000 tick() end
d = disc_pubs()
check("DeviceName change republished within a minute", size(d) == n0 + 20 && json.load(d[-1][1])["dev"]["name"] == "Bedroom heat pump")
tasmota.rules["Mqtt#Connected"]()
NOW += 1000 tick()
check("republished after an MQTT reconnect", size(disc_pubs()) == n0 + 40)
tasmota.cmds["GreeDiscovery"]("GreeDiscovery", 0, "0", nil)
d = disc_pubs()
var removed = true
for k: n0 + 40 .. size(d) - 1 removed = removed && d[k][1] == "" && d[k][2] == true end
check("GreeDiscovery 0 removes all 20 entities", size(d) == n0 + 60 && removed && json.load(tasmota.resp)["GreeDiscovery"] == "OFF")
for k: 0 .. 70 NOW += 1000 tick() end
check("nothing published while off", size(disc_pubs()) == n0 + 60)
tasmota.cmds["GreeDiscovery"]("GreeDiscovery", 0, "1", nil)
check("GreeDiscovery 1 publishes again (saved)", size(disc_pubs()) == n0 + 80 && persist.find("gree_disc", nil) == true &&
      json.load(tasmota.resp)["Id"] == "gree_aabbcc010203")
MQTT_UP = false
tasmota.rules["Mqtt#Connected"]()
for k: 0 .. 3 NOW += 1000 tick() end
check("nothing sent while MQTT is down", size(disc_pubs()) == n0 + 80)
MQTT_UP = true
NOW += 1000 tick()
check("announced when MQTT is back", size(disc_pubs()) == n0 + 100)
check("GREE values still published normally", size(gree_pubs()) > 0)

# ---------------- hooks for gree_tools.be: frames, pause / resume, serial settings ----------------
var got = []
var hk = /tap, f, now -> got.push([tap, size(f)])
gree_bus.add_hook(hk)
gree_bus.add_hook(hk)
check("a hook is added once", size(gree_bus.hooks) == 1)
def bad_hook(tap, f, now) raise "test_error", "boom" end
gree_bus.add_hook(bad_hook)
var rx = SERIALS[6]
send_frame(rx, NOW + 10, frame(0x40, 9))
run(NOW + 1000)
check("hooks get every raw frame, a failing hook does not stop the decoder", size(got) == 1 && got[0] == ["RX", 9])
gree_bus.hooks.remove(1)
gree_bus.remove_hook(hk)
check("remove_hook", size(gree_bus.hooks) == 0)
gree_bus.pause()
check("pause closes both taps", gree_bus.paused && gree_bus.taps[0].ser == nil && gree_bus.taps[1].ser == nil && rx.closed)
gree_bus.loop()
gree_bus.resume()
check("resume reopens them with the same settings", !gree_bus.paused && SERIALS[6] != rx && SERIALS[6].baud == 600 &&
      SERIALS[6].mode == serial.SERIAL_8E1)
tasmota.cmds["BusSerial"]("BusSerial", 0, "", nil)
check("BusSerial shows 600,8E1", tasmota.resp == '{"BusSerial":"600,8E1"}')
tasmota.cmds["BusSerial"]("BusSerial", 0, "1200,8n1", nil)
check("BusSerial 1200,8n1 reopens both taps and saves", SERIALS[6].baud == 1200 && SERIALS[7].mode == serial.SERIAL_8N1 &&
      persist.find("bus_baud", nil) == 1200 && persist.find("bus_fmt", nil) == "8N1" && tasmota.resp == '{"BusSerial":"1200,8N1"}')
tasmota.cmds["BusSerial"]("BusSerial", 0, "1200,9X9", nil)
check("unknown format refused", string.find(tasmota.resp, "usage") == 0 && gree_bus.fmt == "8N1")
var tx_inv = gree_bus.taps[1].inverted
check("set_serial with polarity (RX only given, TX kept)", gree_bus.set_serial(600, "8E1", {"RX": false}) && SERIALS[6].inv == false &&
      SERIALS[7].inv == tx_inv && persist.find("bus_inv_rx", nil) == false && gree_bus.fmt == "8E1" && SERIALS[6].baud == 600)
gree_bus.set_serial(600, "8E1", {"RX": true})
print(dfail == 0 ? "DECODER ALL PASS" : string.format("DECODER %d FAILURES", dfail))
