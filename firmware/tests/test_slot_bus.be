# Host test for slot_bus.be: a simulated mains-synchronous line (pulse = 1 per 60 Hz cycle, 8N1)
# is polled through mocked gpio / micros like the fast loop does.   berry -s test_slot_bus.be
import string
US = 0
LINE = []        # [start_us, end_us] of each LOW pulse on pin 6
class MockTasmota
  var fast, cmds, resp
  def init() self.fast = [] self.cmds = {} end
  def micros() US += 20 return US end
  def millis() return US / 1000 end
  def add_fast_loop(f) self.fast.push(f) end
  def remove_fast_loop(f) var i = self.fast.find(f) if i != nil self.fast.remove(i) end end
  def add_cmd(n, f) self.cmds[n] = f end
  def resp_cmnd(s) self.resp = s end
  def resp_cmnd_str(s) self.resp = s end
end
tasmota = MockTasmota()
LOGS = []
def log(m, l) LOGS.push(m) end
import sys
sys.path().push(".")      # gpio.be mock: level from SIGNAL(pin, MOCK_T)
GPIO_MODES = {}
MOCK_T = 0
def SIGNAL(p, t)
  if p != 6 return 1 end
  for q: LINE if US >= q[0] && US < q[1] return 0 end end
  return 1
end
class MockBus
  var paused, hooks, got
  def init() self.paused = false self.hooks = [] self.got = [] end
  def pause() self.paused = true end
  def resume() self.paused = false end
end
gree_bus = MockBus()
gree_bus.hooks.push(def (tap, f, now) gree_bus.got.push([tap, f.tohex()]) end)

# build the line: idle ones, frames (8N1 LSB first), idle ones; period 16670 us (a bit slow mains)
var P = 16670
var bitsq = []
def idle(n) for k: 1 .. n bitsq.push(1) end end
def char(v) bitsq.push(0) for k: 0 .. 7 bitsq.push((v >> k) & 1) end bitsq.push(1) end
def frame(h) var b = bytes(h) for i: 0 .. size(b) - 1 char(b[i]) end end
idle(12) frame("01F5CA200038") idle(10) frame("8514000000C4") idle(10) frame("095600008804") idle(12)
var t = 100000
for b: bitsq
  if b == 1 LINE.push([t, t + 6570]) end
  t += P
end
var T_END = t

var fails = 0
def check(label, cond) print(cond ? "PASS" : "FAIL", label) if !cond fails += 1 end end
slot_bus = nil  SlotBus = nil  SlotTap = nil
compile("../tasmota/slot_bus.be", "file")()
check("gree_bus taps paused", gree_bus.paused)
# fast loop every 3 to 5.5 ms (jitter)
var j = 0
while US < T_END
  for f: tasmota.fast f() end
  j = (j * 7 + 3) % 11
  US += 3000 + j * 400
end
print(gree_bus.got)
check("three frames decoded in order", size(gree_bus.got) == 3 && gree_bus.got[0] == ["RX", "01F5CA200038"] &&
      gree_bus.got[1] == ["RX", "8514000000C4"] && gree_bus.got[2] == ["RX", "095600008804"])
tasmota.cmds["SlotBus"]("SlotBus", 0, "", nil)
print(tasmota.resp)
check("status: cycle length tracked, counts", string.find(tasmota.resp, '"Frames":3') > 0 && slot_bus.measured > 16000 && slot_bus.measured < 17500)
tasmota.cmds["SlotBus"]("SlotBus", 0, "0", nil)
check("stop resumes gree_bus and removes the fast loop", !gree_bus.paused && size(tasmota.fast) == 0)
print(fails == 0 ? "SLOT ALL PASS" : string.format("SLOT %d FAILURES", fails))
