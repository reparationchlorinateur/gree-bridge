# Integration test: the real gree_bus.be and gree_tools.be loaded together, as autoexec.be does.
# Frames flow from the (mocked) serial ports through gree_bus into a gree_tools capture; BusDetect
# pauses the real taps, measures the (mocked) pins and reopens the ports.   berry test_gree_integration.be
import sys
sys.path().push(".")
import string
import json
import os
import persist

NOW = 0
MOCK_T = 0
MQTT_UP = true
PUBS = []
LOGS = []
SERIALS = {}
GPIO_MODES = {}
WAVES = {}
WEB = []
WEB_ARGS = {}
WEB_ROUTES = {}
SO58 = "OFF"

class serial
  static var SERIAL_8E1 = 0x800001e
  static var SERIAL_8N1 = 0x800001c
  var rx, tx, baud, mode, inv, queue, ready, closed
  def init(rx, tx, baud, mode, inv)
    self.rx = rx  self.tx = tx  self.baud = baud  self.mode = mode  self.inv = inv
    self.queue = [] self.ready = bytes()
    SERIALS[rx] = self
  end
  def pump()
    var keep = []
    for q: self.queue if q[0] <= NOW self.ready = self.ready + q[1] else keep.push(q) end end
    self.queue = keep
  end
  def available() self.pump() return size(self.ready) end
  def read() self.pump() var r = self.ready self.ready = bytes() return r end
  def close() self.closed = true end
end
class MockTasmota
  var fast, drivers, cmds, rules, timers, resp, pubs
  def init() self.fast = [] self.drivers = [] self.cmds = {} self.rules = [] self.timers = [] self.pubs = [] end
  def millis() return NOW end
  static def micros() MOCK_T += 2 return MOCK_T end
  def wifi() return {"mac": "AA:BB:CC:01:02:03", "ip": "192.168.1.50"} end
  def add_fast_loop(f) self.fast.push(f) end
  def add_driver(d) self.drivers.push(d) end
  def add_cmd(n, f) self.cmds[n] = f end
  def add_rule(p, f) self.rules.push([p, f]) end
  def set_timer(ms, f) self.timers.push([NOW + ms, f]) end
  def publish_result(p, sub) self.pubs.push(p) end
  def resp_cmnd(s) self.resp = s end
  def resp_cmnd_str(s) self.resp = s end
  def rtc() return {"local": 1792310400} end
  def time_str(t) return "2026-10-18T08:00:00" end
  def web_send(s) WEB.push(s) end
  def cmd(c, mute)
    if c == "Topic" return {"Topic": "gree_test"} end
    if c == "DeviceName" return {"DeviceName": "Test heat pump"} end
    if c == "SetOption58" return {"SetOption58": SO58} end
    if c == "SetOption58 1" SO58 = "ON" end
    if c == "SetOption58 0" SO58 = "OFF" end
    return nil
  end
  def fire(p, v) for r: self.rules if r[0] == p r[1](v) end end end
end
tasmota = MockTasmota()
def log(msg, lvl) LOGS.push(msg) end

var fails = 0
def check(label, ok) print(ok ? "PASS" : "FAIL", label) if !ok fails += 1 end end

# 600 8E1 + 1 idle bit = 20 ms per byte, delivered in blocks of 10 like TasmotaSerial
def send(ser, start_ms, data)
  var bt = 12.0 * 1000 / 600
  var i = 0
  while i < size(data)
    var j = i + 10
    if j > size(data) j = size(data) end
    var t = start_ms + j * bt
    if j - i < 10 t += 2 * bt end
    ser.queue.push([int(t + 0.999), data[i .. j - 1]])
    i = j
  end
end
def run(until_ms)
  while NOW < until_ms
    for f: tasmota.fast f() end
    if NOW % 1000 == 0 for d: tasmota.drivers if d.every_second d.every_second() end end end
    for k: 0 .. size(tasmota.timers) - 1
      if k < size(tasmota.timers) && tasmota.timers[k][0] <= NOW var t = tasmota.timers[k] tasmota.timers.remove(k) t[1]() break end
    end
    NOW += 10
  end
end

gree_bus = nil
gree_tools = nil
GreeBus = nil  GreeIndoor = nil  GreeOutdoor = nil  GreeBusTap = nil  gree_scan = nil
GreeDetect = nil  GreeTools = nil
compile("../tasmota/gree_bus.be", "file")()
compile("../tasmota/gree_tools.be", "file")()
check("both scripts loaded", gree_bus != nil && gree_tools != nil)
gree_tools.cap_file = "./tmp_int_capture.txt"
gree_tools.prev_file = "./tmp_int_capture_prev.txt"
for f: [gree_tools.cap_file, gree_tools.prev_file] if os.path.exists(f) os.remove(f) end end

var IND = bytes("07159A0C0003BC3C0D")
var OUT = bytes("082C01004C78612B04570F")
def cycle(t)               # one bus cycle: indoor frame on TX + echo and outdoor reply on RX
  send(SERIALS[7], t, IND)
  send(SERIALS[6], t, IND)
  send(SERIALS[6], t + 230, OUT)
end

# capture with the real bus decoder feeding it
NOW = 10000
tasmota.cmds["GreeCapture"]("GreeCapture", 0, "3", nil)
for k: 0 .. 3 cycle(10100 + k * 1000) end
run(15000)
var h = open(gree_tools.cap_file, "r") var c = h.read() h.close()
print(c)
check("capture has TX and RX frames from the real decoder", string.find(c, " TX 07 15 9A 0C 00 03 BC 3C 0D") > 0 &&
      string.find(c, " RX 07 15 9A 0C 00 03 BC 3C 0D 08 2C") > 0)
check("capture has the decoded values (GREE line)", string.find(c, " GREE {\"Room\":21") > 0 || string.find(c, " GREE {\"Room\":21.0") > 0)
check("hook removed at the end", size(gree_bus.hooks) == 0)

# BusDetect: pauses the real taps, samples the pins, reopens the ports
def wave(frames, idle)
  var T = 1000000.0 / 600
  var edges = []
  var lvl = idle
  for fr: frames
    var t = fr[0] * 1.0
    for vi: 0 .. size(fr[1]) - 1
      var v = fr[1][vi]
      var bits = [0]
      var ones = 0
      for j: 0 .. 7 var b = (v >> j) & 1 bits.push(b) ones += b end
      bits.push(ones % 2) bits.push(1) bits.push(1)       # parity, stop, 1 idle bit
      for b: bits
        var l = (b == 1) ? idle : 1 - idle
        if l != lvl edges.push(int(t)) lvl = l end
        t += T
      end
    end
  end
  return {"lvl0": idle, "edges": edges, "t_end": 9000000}
end
var frs = []
for k: 0 .. 6 frs.push([200000 + k * 1000000, IND]) frs.push([200000 + k * 1000000 + 230000, OUT]) end
WAVES[6] = wave(frs, 0)
WAVES[7] = wave(frs, 1)
SIGNAL = def (p, t) return GreeDetect.level_at(WAVES[p], t) end
var rx_before = SERIALS[6]
tasmota.cmds["BusDetect"]("BusDetect", 0, "", nil)
check("BusDetect pauses the real bus decoder", gree_bus.paused && rx_before.closed)
run(NOW + 2000)
check("detection done, ports reopened", !gree_bus.paused && SERIALS[6] != rx_before && SERIALS[6].baud == 600)
check("RX 600 8E1 inverted, TX 600 8E1 normal", gree_tools.det["RX"]["fmt"] == "8E1" && gree_tools.det["RX"]["inverted"] &&
      gree_tools.det["TX"]["fmt"] == "8E1" && !gree_tools.det["TX"]["inverted"] && gree_tools.det["RX"]["gree"] == 2)
tasmota.cmds["BusDetect"]("BusDetect", 0, "apply", nil)
check("apply keeps 600 8E1 and BusAuto on", gree_bus.baud == 600 && gree_bus.fmt == "8E1" && gree_bus.auto)
cycle(NOW + 100)
run(NOW + 1500)
check("decoder still decodes after detection", gree_bus.indoor.last_ok != nil && gree_bus.indoor.room == 21.0)

# main page rows from both scripts
WEB.clear()
for d: tasmota.drivers if d.web_sensor d.web_sensor() end end
var page = WEB.concat("\n")
check("main page: Gree rows and the IR remote row", string.find(page, "Gree room") > 0 && string.find(page, "IR remote") > 0)

for f: [gree_tools.cap_file, gree_tools.prev_file] if os.path.exists(f) os.remove(f) end end
print(fails == 0 ? "ALL PASS" : string.format("%d FAILURES", fails))
