# Host tests for gree_tools.be: bus speed detection on synthetic UART lines, the sampling loop with a
# mocked pin and clock, IR brand detection, captures (single, sequence, start-up with pre-trigger),
# BusDetect apply, and the web page.   Run from this folder:  berry test_gree_tools.be
import sys
sys.path().push(".")   # mocks (persist, gpio, path, webserver) live next to this test
import string
import json
import os
import persist

# ---------------- mocks ----------------
NOW = 0                # millis
MOCK_T = 0             # micros (sampling loop)
GPIO_MODES = {}
WAVES = {}             # pin -> synthetic sample used by SIGNAL()
LOGS = []
WEB = []
WEB_ARGS = {}
WEB_ROUTES = {}
SO58 = "OFF"

class MockTasmota
  var rules, cmds, drivers, timers, resp, pubs, cmd_log, sent
  def init() self.rules = [] self.cmds = {} self.drivers = [] self.timers = [] self.pubs = [] self.cmd_log = [] self.sent = [] end
  def millis() return NOW end
  static def micros() MOCK_T += 2 return MOCK_T end
  def add_rule(p, f) self.rules.push([p, f]) end
  def add_cmd(n, f) self.cmds[n] = f end
  def add_driver(d) self.drivers.push(d) end
  def set_timer(ms, f) self.timers.push([NOW + ms, f]) end
  def publish_result(p, sub) self.pubs.push(p) end
  def resp_cmnd(s) self.resp = s end
  def resp_cmnd_str(s) self.resp = s end
  def rtc() return {"local": 1792310400} end
  def time_str(t) return "2026-10-18T08:00:00" end
  def web_send(s) self.sent.push(s) end
  def cmd(c, mute)
    self.cmd_log.push(c)
    if c == "SetOption58" return {"SetOption58": SO58} end
    if c == "SetOption58 1" SO58 = "ON" return {"SetOption58": "ON"} end
    if c == "SetOption58 0" SO58 = "OFF" return {"SetOption58": "OFF"} end
    return nil
  end
  def fire(pattern, value)       # run the rules registered for this trigger
    for r: self.rules if r[0] == pattern r[1](value) end end
  end
  def run_timers()
    var again = true
    while again
      again = false
      for k: 0 .. size(self.timers) - 1
        var t = self.timers[k]
        if t[0] <= NOW self.timers.remove(k) t[1]() again = true break end
      end
    end
  end
  def second() for d: self.drivers if d.every_second d.every_second() end end end
end
tasmota = MockTasmota()
def log(msg, lvl) LOGS.push(msg) end

class MockTap
  var name, gpio, inverted
  def init(n, g, i) self.name = n self.gpio = g self.inverted = i end
end
class MockBus
  static var BAUD = 600
  static var VERSION = "test"
  var taps, baud, fmt, gap, auto, hooks, paused_n, resumed_n, serial_set
  def init()
    self.taps = [MockTap("RX", 6, true), MockTap("TX", 7, false)]
    self.baud = 600 self.fmt = "8E1" self.gap = 300 self.auto = true self.hooks = [] self.paused_n = 0 self.resumed_n = 0
  end
  def add_hook(h) self.hooks.push(h) end
  def remove_hook(h) var i = self.hooks.find(h) if i != nil self.hooks.remove(i) end end
  def pause() self.paused_n += 1 end
  def resume() self.resumed_n += 1 end
  def gree_json(now) return '{"Room":21.0,"Power":"ON","Mode":"heat"}' end
  def set_serial(b, f, inv)
    self.serial_set = [b, f, inv] self.baud = b self.fmt = f
    for t: self.taps if inv.contains(t.name) t.inverted = inv[t.name] end end
    return true
  end
  def frame(tap, b) for h: self.hooks h(tap, b, NOW) end end
end
gree_bus = MockBus()

var fails = 0
def check(label, ok)
  print(ok ? "PASS" : "FAIL", label)
  if !ok fails += 1 end
end

# ---------------- load the real script ----------------
GreeDetect = nil
GreeTools = nil
gree_tools = nil
compile("../tasmota/gree_tools.be", "file")()
assert(gree_tools != nil)

# ---------------- synthetic UART lines ----------------
var seed = 12345
def rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return (seed / 65536) % n end

# frames: [[start_us, bytes], ...]; idle_bits: idle bits after each character (Gree: 1)
# q: polling resolution (us): edges are seen a random 0..q us late
def wave(frames, baud, fmt, idle, idle_bits, t_end, q)
  var T = 1000000.0 / baud
  var nd = int(fmt[0])  var par = fmt[1]  var ns = int(fmt[2])
  var edges = []
  var lvl = idle
  for fr: frames
    var t = fr[0] * 1.0
    for vi: 0 .. size(fr[1]) - 1
      var v = fr[1][vi]
      var bits = [0]
      var ones = 0
      for j: 0 .. nd - 1 var b = (v >> j) & 1 bits.push(b) ones += b end
      if par == "E" bits.push(ones % 2) end
      if par == "O" bits.push(1 - ones % 2) end
      for j: 0 .. ns - 1 bits.push(1) end
      for b: bits
        var l = (b == 1) ? idle : 1 - idle
        if l != lvl
          var te = int(t) + ((q > 0) ? rnd(q) : 0)
          if size(edges) == 0 || te > edges[-1] edges.push(te) end
          lvl = l
        end
        t += T
      end
      t += idle_bits * T
    end
  end
  return {"lvl0": idle, "edges": edges, "t_end": t_end}
end

var IND = bytes("07159A0C0003BC3C0D")
var OUT = bytes("082C01004C78612B04570F")
def gree_wave(idle, q)       # one indoor frame at 30 ms, the outdoor reply 50 ms after it ends
  var t_in = 9 * 12 * 1000000.0 / 600
  return wave([[30000, IND], [int(30000 + t_in + 50000), OUT]], 600, "8E1", idle, 1, 800000, q)
end

def det(s) return GreeDetect.analyze(s) end
def show(r) print("    ", json.dump(r)) end

var r = det(gree_wave(0, 4))
show(r)
check("Gree, idle low: 600 baud 8E1, inverted, both frames found",
      r["baud"] == 600 && r["fmt"] == "8E1" && r["inverted"] == true && r["errors"] == 0 && r["bytes"] == 20 &&
      r["gree"] == 2 && r["bursts"] == [9, 11] && string.find(r["sample"], "07 15 9A 0C") == 0)
r = det(gree_wave(1, 4))
check("Gree, idle high: normal polarity", r["baud"] == 600 && r["fmt"] == "8E1" && r["inverted"] == false && r["gree"] == 2)
check("measured baud close to 600", r["measured"] >= 590 && r["measured"] <= 610)
check("gap between the indoor frame and the reply: about 50 ms", size(r["gaps_ms"]) == 1 && r["gaps_ms"][0] >= 48 && r["gaps_ms"][0] <= 55)

# a newer Gree-like line: 1200 baud 8E1, other frame layout, no idle bit
var f31 = bytes("3104141C2A0000000000E1")
r = det(wave([[20000, f31], [140000, bytes("3203001E0B0A08000077")]], 1200, "8E1", 1, 0, 600000, 4))
show(r)
check("1200 baud 8E1 (no checksum knowledge needed)", r["baud"] == 1200 && r["fmt"] == "8E1" && r["errors"] == 0 && r["gree"] == 0)

var txt = bytes()
for k: 0 .. 39 txt.add((k * 37 + 11) % 256) end
r = det(wave([[10000, txt]], 4800, "8N1", 1, 0, 200000, 3))
show(r)
check("4800 baud 8N1, continuous bytes", r["baud"] == 4800 && r["fmt"] == "8N1" && r["errors"] == 0 && r["bytes"] == 40)
r = det(wave([[10000, txt]], 9600, "8N1", 1, 0, 100000, 4))
check("9600 baud 8N1 with 4 us polling jitter", r["baud"] == 9600 && r["fmt"] == "8N1" && r["errors"] == 0)
var a7 = bytes()
for k: 0 .. 29 a7.add(0x20 + (k * 7) % 90) end
r = det(wave([[10000, a7]], 2400, "7E1", 1, 0, 300000, 4))
show(r)
check("2400 baud 7E1", r["baud"] == 2400 && r["fmt"] == "7E1" && r["errors"] == 0)
r = det(wave([[10000, txt]], 600, "8O1", 0, 1, 900000, 4))
check("600 baud 8O1 inverted", r["baud"] == 600 && r["fmt"] == "8O1" && r["inverted"] == true && r["errors"] == 0)
r = det(wave([[10000, txt]], 1200, "8N2", 1, 0, 500000, 4))
check("1200 baud 8N2 reads as 8N1 (the 2nd stop bit is just idle)", r["baud"] == 1200 && r["fmt"] == "8N1" && r["errors"] == 0)
r = det(wave([[10000, txt]], 1000, "8N1", 1, 0, 600000, 4))
show(r)
check("1000 baud (not standard): estimate only", !r.contains("baud") && r["estimate"] >= 900 && r["estimate"] <= 1100)
r = det({"lvl0": 1, "edges": [100, 200], "t_end": 800000})
check("silent line: no activity", r["activity"] == false)
check("summary texts", string.find(GreeDetect.summary("RX", det(gree_wave(0, 4))), "RX: 600 baud") == 0 &&
      string.find(GreeDetect.summary("TX", r), "no activity") > 0)

# ---------------- the sampling loop, with a mocked pin and clock ----------------
# frames every second; the clock starts in the middle of a frame, so phase 1 must wait for quiet
def periodic(idle)
  var frs = []
  var t_in = 9 * 12 * 1000000.0 / 600
  for k: 0 .. 3
    var t0 = 200000 + k * 1000000
    frs.push([t0, IND])
    frs.push([int(t0 + t_in + 50000), OUT])
  end
  return wave(frs, 600, "8E1", idle, 1, 4000000, 0)
end
WAVES[6] = periodic(0)     # RX pin idles low (inverted after the 74LVC14)
WAVES[7] = periodic(1)     # TX pin idles high
SIGNAL = def (p, t) return GreeDetect.level_at(WAVES[p], t) end
MOCK_T = 250000
var s = GreeDetect.sample(6, 150, 1500, 800)
print("    sample: quiet", s["quiet"], "edges", size(s["edges"]), "loops", s["loops"], "t_end", s["t_end"])
r = det(s)
show(r)
check("sample() + analyze(): starts after a quiet gap, 600 8E1 inverted, 2 Gree frames",
      s["quiet"] == true && GPIO_MODES[6] == 1 && r["baud"] == 600 && r["fmt"] == "8E1" && r["inverted"] && r["gree"] == 2)

# ---------------- BusDetect through the driver ----------------
MOCK_T = 1250000
tasmota.cmds["BusDetect"]("BusDetect", 0, "", nil)
check("BusDetect starts and pauses the bus decoder", string.find(tasmota.resp, "running") > 0 && gree_bus.paused_n == 1)
NOW += 1000 tasmota.run_timers() NOW += 1000 tasmota.run_timers()
check("both taps measured, decoder resumed, result published",
      gree_tools.det["RX"]["fmt"] == "8E1" && gree_tools.det["RX"]["inverted"] == true &&
      gree_tools.det["TX"]["fmt"] == "8E1" && gree_tools.det["TX"]["inverted"] == false &&
      gree_bus.resumed_n == 1 && size(tasmota.pubs) == 1 && string.find(tasmota.pubs[0], "BusDetect") > 0)
tasmota.cmds["BusDetect"]("BusDetect", 0, "apply", nil)
check("apply with the Gree settings keeps BusAuto on", gree_bus.serial_set[0] == 600 && gree_bus.serial_set[1] == "8E1" &&
      gree_bus.serial_set[2]["RX"] == true && gree_bus.serial_set[2]["TX"] == false && gree_bus.auto == true)
var f1200 = []
for k: 0 .. 3 f1200.push([200000 + k * 1000000, f31]) end
WAVES[6] = wave(f1200, 1200, "8E1", 1, 0, 4000000, 0)
WAVES[7] = wave(f1200, 1200, "8E1", 1, 0, 4000000, 0)
MOCK_T = 0
tasmota.cmds["BusDetect"]("BusDetect", 0, "", nil)
NOW += 1000 tasmota.run_timers() NOW += 1000 tasmota.run_timers()
tasmota.cmds["BusDetect"]("BusDetect", 0, "apply", nil)
check("apply 1200 8E1 turns BusAuto off", gree_bus.serial_set[0] == 1200 && gree_bus.auto == false &&
      persist.find("bus_auto", nil) == false)
gree_bus.auto = true  gree_bus.baud = 600  gree_bus.fmt = "8E1"  gree_bus.taps[0].inverted = true  gree_bus.taps[1].inverted = false

# ---------------- IR brand ----------------
gree_tools.web_sensor()
check("main page asks for a remote press", string.find(tasmota.sent[-1], "press a button") > 0)
tasmota.fire("IrReceived", {"Protocol": "NEC", "Bits": 32, "Data": "0x20DF10EF"})
check("non-AC remote: not taken as the brand", gree_tools.ir_det == nil && string.find(gree_tools.ir_text(), "not recognised") == 0)
tasmota.fire("IrReceived", {"Protocol": "GREE", "Bits": 64, "Data": "0x0950200050000020",
                            "IRHVAC": {"Vendor": "GREE", "Model": "YAW1F", "Power": "On", "Mode": "Cool", "Temp": 22}})
check("GREE remote detected and saved", gree_tools.ir_det["vendor"] == "GREE" && gree_tools.ir_det["model"] == "YAW1F" &&
      persist.find("gree_ir", nil)["vendor"] == "GREE")
check("text shows brand, model and presses", gree_tools.ir_text() == "GREE, model YAW1F (2 presses since restart)")
tasmota.cmds["IrDetect"]("IrDetect", 0, "", nil)
var jd = json.load(tasmota.resp)
check("IrDetect shows detected + seen", jd["IrDetect"]["Detected"]["vendor"] == "GREE" && jd["IrDetect"]["Seen"]["NEC"] == 1)
tasmota.cmds["IrDetect"]("IrDetect", 0, "0", nil)
check("IrDetect 0 forgets", gree_tools.ir_det == nil && persist.find("gree_ir", 1) == nil)
tasmota.fire("IrReceived", {"Protocol": "DAIKIN", "Bits": 280, "IRHVAC": {"Vendor": "DAIKIN", "Model": -1}})
check("another brand is detected too", gree_tools.ir_det["vendor"] == "DAIKIN" && gree_tools.ir_text() == "DAIKIN (1 presses since restart)")
var saves0 = persist.saves
for m: ["YBOFB", "YAW1F", "YBOFB", "YAW1F", "YBOFB"]
  tasmota.fire("IrReceived", {"Protocol": "GREE", "Bits": 64, "IRHVAC": {"Vendor": "GREE", "Model": m}})
end
print("    saves for 5 GREE presses with a flipping model:", persist.saves - saves0)
check("model guess flipping: most frequent model shown, flash written only on change", gree_tools.ir_det["model"] == "YBOFB" &&
      persist.saves - saves0 <= 2)
tasmota.fire("IrReceived", {"Protocol": "UNKNOWN", "Bits": 3})
check("noise is not counted as a press", gree_tools.ir_seen["noise"] == 1 && gree_tools.ir_last["protocol"] == "GREE")
gree_tools.reset_ir()
tasmota.fire("IrReceived", {"Protocol": "DAIKIN", "Bits": 280, "IRHVAC": {"Vendor": "DAIKIN", "Model": -1}})

# ---------------- captures ----------------
gree_tools.cap_file = "./tmp_capture.txt"
gree_tools.prev_file = "./tmp_capture_prev.txt"
for f: [gree_tools.cap_file, gree_tools.prev_file] if os.path.exists(f) os.remove(f) end end
def read_cap(f) var h = open(f, "r") var c = h.read() h.close() return c end

NOW = 100000
tasmota.cmds["GreeCapture"]("GreeCapture", 0, "5", nil)
check("GreeCapture 5 starts, SetOption58 on, hook added", string.find(tasmota.resp, "capturing window 1/1") > 0 &&
      SO58 == "ON" && size(gree_bus.hooks) == 1)
for k: 0 .. 5
  NOW = 100000 + k * 1000 + 30
  gree_bus.frame("TX", IND)
  gree_bus.frame("RX", IND + OUT)
  if k == 2 tasmota.fire("IrReceived", {"Protocol": "GREE", "Bits": 64, "RawData": "+9000-4500A", "IRHVAC": {"Vendor": "GREE"}}) end
  if k == 3 tasmota.cmds["GreeMark"]("GreeMark", 0, "fan started", nil) end
  NOW += 500 tasmota.second()
end
check("capture ends by itself, SetOption58 restored, hook removed", gree_tools.cap == nil && SO58 == "OFF" &&
      size(gree_bus.hooks) == 0 && gree_tools.cap_done["why"] == "done")
var c = read_cap(gree_tools.cap_file)
print(c)
check("file: header, frames, IR with raw data, mark, decoded values, end",
      string.find(c, "# Gree bridge capture 2026-10-18T08:00:00") == 0 && string.find(c, "# bus: 600 8E1, RX inverted") > 0 &&
      string.find(c, "\n30 TX 07 15 9A 0C 00 03 BC 3C 0D\n") > 0 && string.find(c, "RX 07 15 9A 0C 00 03 BC 3C 0D 08 2C") > 0 &&
      string.find(c, " IR {") > 0 && string.find(c, "RawData") > 0 && string.find(c, " MARK fan started") > 0 &&
      string.find(c, "0 GREE {\"Room\":21.0") > 0 && string.find(c, "# end: done") > 0)
check("frames after the window are not written", string.find(c, "5030 TX") < 0)
var echoed = 0
for l: LOGS if string.find(l, "CAP: ") == 0 echoed += 1 end end
check("lines echoed to the console", echoed > 10)

# sequence: 2 s windows, one every 10 s, 3 windows; file moved to prev
NOW = 200000
tasmota.cmds["GreeCapture"]("GreeCapture", 0, "2,10,3", nil)
check("previous capture kept", os.path.exists(gree_tools.prev_file))
for k: 0 .. 35
  NOW = 200000 + k * 1000 + 20
  gree_bus.frame("TX", IND)
  NOW += 500 tasmota.second()
end
c = read_cap(gree_tools.cap_file)
check("3 windows at +0, +10, +20 s, then done", string.find(c, "# window 1/3 starts at +0 s") > 0 &&
      string.find(c, "# window 2/3 starts at +10 s") > 0 && string.find(c, "# window 3/3 starts at +20 s") > 0 &&
      string.find(c, "# end: done") > 0 && gree_tools.cap == nil)
var ntx = 0
for l: string.split(c, "\n") if string.find(l, " TX ") > 0 && l[0] != "#" ntx += 1 end end

check("only frames inside the windows (2 per 2 s window)", ntx == 6)

# start-up sequence: armed, 3 s before the IR command are kept, then +60 / +120 / +180 s
NOW = 400000
tasmota.cmds["GreeCapture"]("GreeCapture", 0, "startup", nil)
check("startup: armed", string.find(tasmota.resp, "armed") > 0)
for k: 0 .. 9
  NOW = 400000 + k * 1000 + 10
  gree_bus.frame("TX", IND)
  NOW += 500 tasmota.second()
end
NOW = 409500
tasmota.fire("IrReceived", {"Protocol": "UNKNOWN", "Bits": 3, "RawData": "+125-790+85-3150+225"})   # line noise
check("startup: IR line noise does not start the capture", gree_tools.cap["k"] == 0)
NOW = 410200
tasmota.fire("IRHVAC", {"Vendor": "GREE", "Power": "On", "Mode": "Cool", "Temp": 19})   # sent from Home Assistant
check("an IR command starts window 1", gree_tools.cap["k"] == 1)
for k: 0 .. 200
  NOW = 410300 + k * 1000
  gree_bus.frame("TX", IND)
  NOW += 500 tasmota.second()
end
c = read_cap(gree_tools.cap_file)
var lines = string.split(c, "\n")
var pre = 0
for l: lines
  var sp = string.split(l, " ")
  if size(sp) > 2 && sp[1] == "TX" && int(sp[0]) < 3000 pre += 1 end
end
var neg = false
for l: lines var sp = string.split(l, " ") if size(sp) > 2 && sp[0] != "#" && int(sp[0]) < 0 neg = true end end
print("    pre-trigger frames:", pre)
check("startup: the frames of the 3 s before the command are in the file, no negative times", pre == 2 && !neg)
check("startup: command written, 4 windows (+0, +60, +120, +180 s after the command), done",
      string.find(c, " IRHVAC {") > 0 && string.find(c, "# window 2/4 starts at +63 s") > 0 &&
      string.find(c, "# window 4/4 starts at +183 s") > 0 && string.find(c, "# end: done") > 0)
NOW = 700000
tasmota.cmds["GreeCapture"]("GreeCapture", 0, "startup", nil)
NOW += 601000 tasmota.second()
check("startup gives up after 10 min without a command", gree_tools.cap == nil && string.find(gree_tools.cap_done["why"], "no IR") == 0)
tasmota.cmds["GreeCapture"]("GreeCapture", 0, "0", nil)
check("bad arguments: usage", string.find(tasmota.resp, "usage") == 0)
tasmota.cmds["GreeMark"]("GreeMark", 0, "x", nil)
check("GreeMark without a capture", tasmota.resp == "no capture running")

# ---------------- web page ----------------
WEB.clear()
gree_tools.web_add_handler()
check("routes registered", WEB_ROUTES.contains("/gt1") && WEB_ROUTES.contains("/gt2"))
WEB_ROUTES["/gt1"]()
var page = WEB.concat("\n")
check("page renders: IR, bus result, apply button, capture buttons, download links",
      string.find(page, "<start Gree tools>") == 0 && string.find(page, "<p>GREE (") > 0 &&
      string.find(page, "Matches this board") > 0 && string.find(page, "RX: 1200 baud") > 0 &&
      string.find(page, "Use the detected settings") > 0 && string.find(page, "Capture 5 s now") > 0 &&
      string.find(page, "download=./tmp_capture.txt") > 0 && string.find(page, "<stop>") > 0)
WEB.clear()
WEB_ARGS = {"act": "cap5"}
WEB_ROUTES["/gt2"]()
check("page button starts a 5 s capture and redirects", gree_tools.cap != nil && WEB[-1] == "<redirect /gt>")
WEB.clear()
WEB_ROUTES["/gt1"]()
page = WEB.concat("\n")
check("while capturing: auto refresh, note field, stop button", string.find(page, "setTimeout") > 0 &&
      string.find(page, "name='note'") > 0 && string.find(page, "value='stop'") > 0)
WEB_ARGS = {"act": "mark", "note": "compressor on"}
WEB_ROUTES["/gt2"]()
WEB_ARGS = {"act": "stop"}
WEB_ROUTES["/gt2"]()
check("note and stop from the page", gree_tools.cap == nil && string.find(read_cap(gree_tools.cap_file), "MARK compressor on") > 0)
WEB.clear()
gree_tools.web_add_main_button()
check("main page button", string.find(WEB[0], "action='gt'") > 0)

for f: [gree_tools.cap_file, gree_tools.prev_file] if os.path.exists(f) os.remove(f) end end
print(fails == 0 ? "ALL PASS" : string.format("%d FAILURES", fails))
