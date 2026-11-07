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

# Protocol C test: the real capture of an older Gree unit (600 baud 8E1, 20- and 29-byte frames,
# XOR checksum) replayed through the mocked serial ports into the real gree_bus.be.
#   berry -s test_gree_protocol_c.be
def run(until_ms) while NOW < until_ms  for f: tasmota.fast  f()  end  NOW += 10 end end

import persist
import json
persist.bus_auto = false
gree_bus = nil  GreeBus = nil  GreeIndoor = nil  GreeOutdoor = nil  GreeBusTap = nil  gree_scan = nil  gree_scan_sum = nil
compile("../tasmota/gree_bus.be", "file")()
var rxs = SERIALS[6]  var txs = SERIALS[7]
assert(rxs.baud == 600 && rxs.mode == serial.SERIAL_8E1)

var fails = 0
def check(label, cond) print(cond ? "PASS" : "FAIL", label) if !cond fails += 1 end end
def tick() gree_bus.every_second() end
def gree() return json.load('{' + gree_bus.gree_json(NOW)[1 ..]) end
def b(h) return bytes(string.replace(h, " ", "")) end

# ---------------- replay the capture ----------------
var f = open("../../docs/captures/protocol_c_sequence.txt", "r")
var lines = string.split(f.read(), "\n")
f.close()
var events = []
for l: lines
  if size(l) == 0 || l[0] == "#" continue end
  var p = string.split(l, " ", 2)
  if p[1] == "RX" || p[1] == "TX" events.push([int(p[0]), p[1], b(p[2])]) end
end
check("capture read", size(events) > 800)
var ev = 0
def replay_to(t)
  while NOW < t
    while ev < size(events) && events[ev][0] <= NOW
      var e = events[ev]
      (e[1] == "RX" ? SERIALS[6] : SERIALS[7]).queue.push([e[0], e[2]])    # whole chunk at its time
      ev += 1
    end
    for fl: tasmota.fast fl() end
    if NOW % 1000 == 0 tick() end
    NOW += 10
  end
end

replay_to(6000)       # unit off
var g = gree()
check("off: Power OFF, setpoint 25, room 22.5, coil 21.9, fan 0, link OK",
      g["Power"] == "OFF" && g["Setpoint"] == 25 && g["Room"] == 22.5 && g["Coil"] == 21.9 && g["Fan"] == 0 &&
      g["Link"] == "OK" && g["CoilRaw"] == 0x77)
check("off: outdoor off, 0 Hz, 0 W; air 9.0, coil 9.3, discharge 9.1",
      g["OutMode"] == "off" && g["CompHz"] == 0 && g["PowerW"] == 0 && g["OutAir"] == 9.0 && g["OutCoil"] == 9.3 &&
      g["DischC"] == 9.1 && g["OutLink"] == "OK")
check("protocol C recognised on both", gree_bus.indoor.proto == "C" && gree_bus.outdoor.proto == "C")
check("both taps marked valid", gree_bus.taps[0].last_valid != nil && gree_bus.taps[1].last_valid != nil)
check("no protocol A or B frame seen in it", gree_bus.indoor.frames > 3)

replay_to(30000)      # heat 22 sent at 7.9 s
g = gree()
check("heat 22: Power ON, heat, 22, fan 1", g["Power"] == "ON" && g["Mode"] == "heat" && g["Setpoint"] == 22 && g["Fan"] == 1)
check("outdoor: compressor started in heat", g["OutMode"] == "heat" && g["CompHz"] > 0)

replay_to(151000)
g = gree()
check("2.5 min: 55 Hz, 1.90 A, 479 W, coil 25.4, outdoor coil 1.8, discharge 29.4",
      g["CompHz"] == 55 && g["CompA"] == 1.9 && g["PowerW"] == 479 && g["Coil"] == 25.4 && g["OutCoil"] == 1.8 &&
      g["DischC"] == 29.4 && g["DischRaw"] == 0x48 && g["LoadRaw"] == 38)
check("raw outdoor bytes b5..b19", size(g["Out"]) == 15 && g["Out"][0] == 55 && g["Out"][1] == 0x14)

replay_to(206000)  check("setpoint 23, fan medium", gree()["Setpoint"] == 23 && gree()["Fan"] == 2)
replay_to(236000)  check("setpoint 24", gree()["Setpoint"] == 24)
replay_to(266000)  check("setpoint 22, room 24.0", gree()["Setpoint"] == 22 && gree()["Room"] == 24.0)
replay_to(296000)  check("fan low", gree()["Fan"] == 1)
replay_to(326000)  check("fan high", gree()["Fan"] == 3)
replay_to(356000)  check("fan medium", gree()["Fan"] == 2)
replay_to(390000)
g = gree()
check("cool 18: cool, 18, compressor stopped, outdoor cool", g["Mode"] == "cool" && g["Setpoint"] == 18 && g["CompHz"] == 0 &&
      g["OutMode"] == "cool" && g["PowerW"] == 0)
replay_to(450000)  g = gree()  check("dry 22: dry, 22, fan low, outdoor dry", g["Mode"] == "dry" && g["Setpoint"] == 22 && g["Fan"] == 1 && g["OutMode"] == "dry")
replay_to(490000)  g = gree()  check("fan only: fan_only, fan medium, outdoor fan_only", g["Mode"] == "fan_only" && g["Fan"] == 2 && g["OutMode"] == "fan_only")
replay_to(530000)  g = gree()  check("auto: the unit shows the mode it chose (fan) and 25", g["Power"] == "ON" && g["Mode"] == "fan_only" && g["Setpoint"] == 25)
replay_to(580000)
g = gree()
check("off: Power OFF, last mode and setpoint kept, fan 0, outdoor off", g["Power"] == "OFF" && g["Mode"] == "fan_only" &&
      g["Setpoint"] == 25 && g["Fan"] == 0 && g["OutMode"] == "off" && g["CompHz"] == 0)

var want = ["Room", "Coil", "CoilRaw", "Power", "Mode", "Setpoint", "Fan", "Link", "CompHz", "CompA", "PowerW", "OutCoil",
            "OutAir", "DischC", "OutMode", "DischRaw", "LoadRaw", "Out", "OutLink"]
var keys_ok = size(g) == size(want)
for k: want keys_ok = keys_ok && g.contains(k) end
check("same JSON fields as protocols A and B", keys_ok)

# a bad checksum is ignored
var fr = gree_bus.indoor.frames
var bad = b("06 02 00 0F AA 5D 00 77 00 00 5C 0C 09 00 3C 00 00 00 E8 0E")
bad[18] = bad[18] ^ 1
txs.queue.push([NOW + 20, bad])
run(NOW + 800)
check("bad XOR checksum ignored", gree_bus.indoor.frames == fr && gree_bus.indoor.power == false)
txs.queue.push([NOW + 20, b("06 02 00 0F AA 5D 00 77 00 00 5C 0C 09 00 3C 00 00 00 E8 0E")])
run(NOW + 800)
check("good frame accepted", gree_bus.indoor.frames == fr + 1 && gree_bus.indoor.power == true && gree_bus.indoor.mode == "heat")

WEB.clear() gree_bus.web_sensor()
var page = WEB.concat(" ")
check("main page: protocol C", string.find(page, "protocol C") >= 0)

print(fails == 0 ? "PROTOCOL C ALL PASS" : string.format("PROTOCOL C %d FAILURES", fails))
