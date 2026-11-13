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
WEB = []
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
  def web_send(s) WEB.push(s) print("  web:", s) end
  def resp_cmnd_str(s) self.resp = s end
  def resp_cmnd(s) self.resp = s end
  var appended
  def response_append(s) self.appended = s end
  def cmd(c, mute) if c == "Topic" return {"Topic": "tasmota_gree"} end if c == "DeviceName" return {"DeviceName": DEVNAME} end return nil end
end
tasmota = MockTasmota()
def log(msg, lvl) LOGS.push(msg) print("  log", lvl, msg) end

# UART model: 600 8E1 + 1 idle bit -> 20 ms per byte; blocks of 10 bytes, remainder after 2 symbol times

# Protocol B test: the real start-up capture of a second Gree unit (1200 baud 8E1, 20-byte frames,
# sum checksum) replayed through the mocked serial ports into the real gree_bus.be.
#   berry test_gree_protocol_b.be
# UART model: 1200 8E1 + 1 idle bit -> 10 ms per byte; blocks of 10 bytes, remainder after 2 byte times
def send_frame(ser, start_ms, data)
  var bt = 12.0 * 1000 / 1200
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
def run(until_ms) while NOW < until_ms  for f: tasmota.fast  f()  end  NOW += 10 end end

import persist
import json
persist.bus_baud = 1200            # as left by "BusDetect apply" on that unit
persist.bus_fmt = "8E1"
persist.bus_inv_rx = true
persist.bus_inv_tx = false
persist.bus_auto = false
gree_bus = nil  GreeBus = nil  GreeIndoor = nil  GreeOutdoor = nil  GreeBusTap = nil  gree_scan = nil  gree_scan_sum = nil
compile("../tasmota/gree_bus.be", "file")()
var rxs = SERIALS[6]  var txs = SERIALS[7]
assert(rxs.baud == 1200 && rxs.mode == serial.SERIAL_8E1)

var fails = 0
def check(label, cond) print(cond ? "PASS" : "FAIL", label) if !cond fails += 1 end end
def tick() gree_bus.every_second() end
def gree() return json.load('{' + gree_bus.gree_json(NOW)[1 ..]) end   # current JSON as a map
def b(h) return bytes(string.replace(h, " ", "")) end
def sumck(h) var x = b(h) var s = 0 for k: 0 .. size(x) - 1 s += x[k] end return s & 0xFF end

# ---------------- checksum rule on the captured frames ----------------
var off_in = "31 20 00 00 80 08 41 3B 00 3C 01 00 00 00 00 00 00 00 00"
check("sum checksum of a captured indoor frame", sumck(off_in) == 0x92)
check("sum checksum of a captured outdoor frame", sumck("31 10 00 14 21 00 00 0A 00 00 4F 00 34 32 4E 00 00 02 00") == 0x85)

# ---------------- replay the capture ----------------
var f = open("../../docs/captures/protocol_b_startup_heat.txt", "r")
var lines = string.split(f.read(), "\n")
f.close()
var events = []
for l: lines
  if size(l) == 0 || l[0] == "#" continue end
  var p = string.split(l, " ", 2)
  if p[1] == "RX" || p[1] == "TX" events.push([int(p[0]), p[1], b(p[2])]) end
end
check("capture read", size(events) > 60)
var ev = 0
def replay_to(t)
  while ev < size(events) && events[ev][0] <= t
    var e = events[ev]
    send_frame(e[1] == "RX" ? SERIALS[6] : SERIALS[7], e[0], e[2])
    ev += 1
  end
  while NOW < t
    for fl: tasmota.fast fl() end
    if NOW % 1000 == 0 tick() end
    NOW += 10
  end
end

replay_to(5000)       # unit off for 85 s
var g = gree()
check("off: Power OFF, setpoint 25, room 19, coil 20, fan 0, link OK",
      g["Power"] == "OFF" && g["Setpoint"] == 25 && g["Room"] == 19.0 && g["Coil"] == 20.0 && g["Fan"] == 0 && g["Link"] == "OK")
check("off: outdoor off, 0 Hz, 0 W; air 16, coil 23, discharge 36",
      g["OutMode"] == "off" && g["CompHz"] == 0 && g["PowerW"] == 0 && g["OutAir"] == 16.0 && g["OutCoil"] == 23.0 &&
      g["DischC"] == 36.0 && g["OutLink"] == "OK")
check("protocol B recognised on both", gree_bus.indoor.proto == "B" && gree_bus.outdoor.proto == "B")
var fr_in = gree_bus.indoor.frames
check("32 xx frames are not decoded as indoor frames (one 31 20 per TX group and one per RX group)",
      fr_in >= 6 && fr_in <= 12)
check("both taps marked valid", gree_bus.taps[0].last_valid != nil && gree_bus.taps[1].last_valid != nil)

replay_to(7000)       # heat 22 sent at 5.2 s
g = gree()
check("heat 22 decoded 1 s later: Power ON, heat, 22", g["Power"] == "ON" && g["Mode"] == "heat" && g["Setpoint"] == 22)
replay_to(8500)
g = gree()
check("outdoor switched to heat, compressor not started yet", g["OutMode"] == "heat" && g["CompHz"] == 0)

replay_to(66000)
g = gree()
check("+1 min: compressor 33 Hz, 1.0 A, 274 W", g["CompHz"] == 33 && g["CompA"] == 1.0 && g["PowerW"] == 274)
check("+1 min: outdoor air 12, coil 10, discharge 38", g["OutAir"] == 12.0 && g["OutCoil"] == 10.0 && g["DischC"] == 38.0)
check("+1 min: indoor coil 21, fan still stopped (warm-up)", g["Coil"] == 21.0 && g["Fan"] == 0 && g["Room"] == 19.0)
check("raw outdoor bytes b3..b18", size(g["Out"]) == 16 && g["Out"][0] == 0x14 && g["Out"][1] == 33 && g["Out"][4] == 0x0A)

replay_to(190000)
g = gree()
check("+3 min: indoor fan low, coil 27", g["Fan"] == 1 && g["Coil"] == 27.0)
check("+3 min: outdoor air 9, coil 5, discharge 44, 1.2 A",
      g["OutAir"] == 9.0 && g["OutCoil"] == 5.0 && g["DischC"] == 44.0 && g["CompA"] == 1.2 && g["DischRaw"] == 0x54 && g["LoadRaw"] == 12)

# same JSON fields as protocol A (the HA package and gree_matter.be read these)
var want = ["Room", "Coil", "CoilRaw", "Power", "Mode", "Setpoint", "Fan", "Link", "CompHz", "CompA", "PowerW", "OutCoil",
            "OutAir", "DischC", "OutMode", "Defrost", "DischRaw", "LoadRaw", "Out", "OutLink"]
var keys_ok = size(g) == size(want)
for k: want keys_ok = keys_ok && g.contains(k) end
check("same JSON fields as protocol A", keys_ok)
var pubs = 0
for p: PUBS if p[0] == "tele/tasmota_gree/GREE" pubs += 1 end end
check("published on MQTT", pubs >= 4)

# ---------------- synthetic frames ----------------
def frame_b(h) var x = b(h) x.add(sumck(h)) return x end
var fr = gree_bus.indoor.frames
send_frame(txs, NOW + 20, frame_b(off_in))
run(NOW + 800)
check("switched off: Power OFF, mode heat and setpoint 22 kept (off frames carry no mode and always 25)",
      gree_bus.indoor.power == false && gree_bus.indoor.mode == "heat" && gree_bus.indoor.setpoint == 22 &&
      gree_bus.indoor.frames == fr + 1)
var bad = frame_b("31 20 00 11 02 08 3C 3B 00 30 01 00 00 00 00 00 00 00 00")
bad[19] = (bad[19] + 1) & 0xFF
send_frame(txs, NOW + 20, bad)
run(NOW + 800)
check("bad sum checksum ignored", gree_bus.indoor.power == false && gree_bus.indoor.frames == fr + 1)
send_frame(txs, NOW + 20, frame_b("31 20 00 11 02 08 3C 3B 00 30 01 00 00 00 00 00 00 00 00"))
run(NOW + 800)
check("cool 20, fan medium, coil 8", gree_bus.indoor.power && gree_bus.indoor.mode == "cool" && gree_bus.indoor.setpoint == 20 &&
      gree_bus.indoor.fan == 2 && gree_bus.indoor.coil == 8.0)
# a frame split over two deliveries, with junk before it
var whole = b("00 FF 31") + frame_b("31 20 00 12 01 08 3D 3C 00 32 01 00 00 00 00 00 00 00 00")
var t1 = NOW + 20
SERIALS[7].queue.push([t1 + 50, whole[0 .. 9]])
SERIALS[7].queue.push([t1 + 120, whole[10 ..]])
run(NOW + 900)
check("split frame with junk before it: dry 21, room 20", gree_bus.indoor.mode == "dry" && gree_bus.indoor.setpoint == 21 &&
      gree_bus.indoor.room == 20.0 && gree_bus.indoor.fan == 1)
send_frame(rxs, NOW + 20, frame_b("31 10 00 11 3C 00 00 18 00 00 55 00 3A 4B 6B 00 00 05 00"))
run(NOW + 800)
g = gree()
check("outdoor cool 60 Hz: 2.4 A, coil 35, discharge 67", g["CompHz"] == 60 && g["OutMode"] == "cool" && g["CompA"] == 2.4 &&
      g["OutCoil"] == 35.0 && g["DischC"] == 67.0 && g["OutAir"] == 18.0)

WEB.clear() gree_bus.web_sensor()
var page = WEB.concat(" ")
check("main page: protocol B, compressor and temperatures",
      string.find(page, "protocol B") >= 0 && string.find(page, "60 Hz, cool, 2.40 A") >= 0 && string.find(page, "18.0 / 35.0 / 67.0") >= 0)

# defrost, real frames from a Willis unit heating at -2 C outside (2026-11-13, docs/captures/protocol_b_defrost.txt)
def heat_pair(o, i)
  send_frame(rxs, NOW + 20, frame_b(o))
  send_frame(txs, NOW + 20, frame_b(i))
  run(NOW + 800)
end
heat_pair("31 10 00 14 58 00 00 24 00 00 5C 00 26 20 86 00 00 09 00", "31 20 00 14 04 08 42 3E 00 4B 07 00 0A 00 00 00 00 00 00")
g = gree()
check("heat: Defrost false", g["Defrost"] == false && gree_bus.outdoor.defrost == false)
var pubs0 = size(PUBS)
heat_pair("31 10 00 14 55 00 00 11 00 00 5C 00 2A 29 81 02 00 03 00", "31 20 00 14 00 20 42 3E 00 23 07 00 00 00 00 00 00 00 00")
g = gree()
check("defrost: Defrost true, compressor 85 Hz, outdoor coil 1, indoor coil -5, fan 0",
      g["Defrost"] == true && g["CompHz"] == 85 && g["OutCoil"] == 1.0 && g["Coil"] == -5.0 && g["Fan"] == 0)
tick()
check("defrost start published at once", size(PUBS) > pubs0)
WEB.clear() gree_bus.web_sensor()
check("main page shows defrost", string.find(WEB.concat(" "), "85 Hz, heat (defrost)") >= 0)
heat_pair("31 10 00 04 00 00 00 00 00 00 59 00 38 38 74 02 00 00 00", "31 20 00 14 00 00 42 3D 00 15 07 00 00 00 00 00 00 00 00")
check("compressor paused at the end of defrost: still Defrost", gree()["Defrost"] == true && gree()["CompHz"] == 0)
heat_pair("31 10 00 14 21 00 00 0A 00 00 50 00 35 2C 67 00 00 01 00", "31 20 00 14 00 00 42 3C 00 23 07 00 08 00 00 00 00 00 00")
check("back to heat: Defrost false", gree()["Defrost"] == false && gree()["CompHz"] == 33)
var disc = nil
for d: gree_bus.HA if d[1] == "defrost" disc = d end end
check("HA discovery has a Defrost binary sensor", disc != nil && disc[0] == "binary_sensor")

# link: the bus goes quiet while off -> STANDBY, the outdoor part 0 W
send_frame(txs, NOW + 20, frame_b(off_in))
send_frame(rxs, NOW + 20, frame_b("31 10 00 00 00 00 00 00 00 00 4F 00 38 3F 4C 00 00 00 00"))
run(NOW + 800)
NOW += 11000
g = gree()
check("quiet bus after off: STANDBY, nulls, 0 W, Defrost false", g["Link"] == "STANDBY" && g["Room"] == nil && g["OutLink"] == "STANDBY" &&
      g["PowerW"] == 0 && g["OutAir"] == nil && g["Defrost"] == false)

print(fails == 0 ? "PROTOCOL B ALL PASS" : string.format("PROTOCOL B %d FAILURES", fails))
