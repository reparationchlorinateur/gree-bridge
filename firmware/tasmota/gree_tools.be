#-
  gree_tools.be - helpers to fit the Gree bridge (rev B) to other units: IR brand detection,
                  bus speed detection and quick captures for decoding later (2026-10-18)

  Loaded by autoexec.be after gree_bus.be. Adds a "Gree tools" button to the main page (page /gt)
  and these console / MQTT commands:

    IrDetect           brand / protocol of the wall remote, decoded by Tasmota's IR library
                       (press any button on the remote); IrDetect 0 forgets it
    BusDetect          measures the speed, format and polarity of both bus taps (about 5 s; the bus
                       decoder is paused meanwhile). Result in the console and on the page.
    BusDetect apply    uses the detected settings (BusSerial + polarity); turns BusAuto off when they
                       are not the Gree 600 8E1 ones
    GreeCapture <s>                one capture of <s> seconds now (default 5)
    GreeCapture <s>,<every>,<n>    n captures of <s> seconds, one every <every> seconds
    GreeCapture startup            waits for the next IR command (wall remote or Home Assistant /
                                   Apple Home), keeps the 3 s before it, captures 5 s, then 5 s
                                   again 1, 2 and 3 minutes later
    GreeCapture stop               ends it;  GreeCapture  = status
    GreeMark <text>                writes a note into the running capture ("outdoor fan started")

  Captures go to /gree_capture.txt (the one before to /gree_capture_prev.txt) and are also printed
  live in the console. Download: Gree tools page, or Tools > Manage File system. One line per event:
    <ms since the capture started> <source> <data>
    RX / TX   raw bytes from that tap, hex, split on BusGap silence (as received)
    IR        Tasmota's IrReceived JSON (wall remote), with raw timings (SetOption58 is on meanwhile)
    IRHVAC    IR command sent by the board (Home Assistant, Apple Home, console)
    GREE      decoded values (gree_bus.be), at the start and end of each window
    MARK      a note from GreeMark
  Lines starting with # are comments (settings, window start and end).
-#

import string
import persist
import json
import global

# ---------------------------------------------------------------------------------------------------
# Bus speed detection. sample() records the tap pin's edges with tasmota.micros(); analyze() is pure
# (host-tested): idle level -> polarity, run lengths -> baud, then each frame format is tried as a
# software UART and the one with the fewest framing / parity errors wins.
# ---------------------------------------------------------------------------------------------------
class GreeDetect
  static var BAUDS = [300, 600, 1200, 2400, 4800, 9600, 19200]
  # tried in this order of preference when two formats decode without errors: parity first (it is
  # extra evidence), then 8 data bits, then 1 stop bit (a 2nd stop bit can just be an idle bit)
  static var FORMATS = ["8E1", "8O1", "7E1", "7O1", "8N1", "7N1", "8E2", "8O2", "7E2", "7O2", "8N2", "7N2"]

  # Record edges on <pin>: wait up to wait_ms for a quiet line (no edge for quiet_ms), then for the
  # first edge, then record for cap_ms. Blocks the CPU meanwhile (a few seconds at most).
  static def sample(pin, quiet_ms, wait_ms, cap_ms)
    import gpio
    var rd = gpio.digital_read
    var us = tasmota.micros
    gpio.pin_mode(pin, gpio.INPUT)
    var t0 = us()
    var last = rd(pin)
    var quiet_us = quiet_ms * 1000
    var limit = wait_ms * 1000
    var last_edge = 0
    var now = 0
    var i = 0
    var quiet = false
    while !quiet                                   # phase 1: find a quiet gap
      var v = rd(pin)
      if v != last last = v last_edge = us() - t0 end
      i += 1
      if (i & 31) == 0
        now = us() - t0
        if now - last_edge >= quiet_us quiet = true end
        if now >= limit break end
      end
    end
    var edges = []
    var lvl0 = rd(pin)
    last = lvl0
    var t1 = us()
    limit = (quiet ? wait_ms * 1000 : 0) + cap_ms * 1000
    var first = nil
    var loops = 0
    now = 0
    while true                                     # phase 2: record
      var v = rd(pin)
      if v != last
        now = us() - t1
        edges.push(now)
        last = v
        if first == nil first = now limit = now + cap_ms * 1000 end
      end
      loops += 1
      if (loops & 31) == 0
        now = us() - t1
        if now >= limit break end
      end
    end
    return {"lvl0": lvl0, "edges": edges, "t_end": now, "loops": loops, "quiet": quiet}
  end

  # [[level, duration_us], ...]; the first and last runs are cut by the window
  static def runs(s)
    var r = []
    var lvl = s["lvl0"]
    var prev = 0
    for t: s["edges"]
      r.push([lvl, t - prev])
      prev = t
      lvl = 1 - lvl
    end
    r.push([lvl, s["t_end"] - prev])
    return r
  end

  static def level_at(s, t)
    var e = s["edges"]
    var lo = 0
    var hi = size(e)
    while lo < hi
      var mid = (lo + hi) / 2
      if e[mid] <= t lo = mid + 1 else hi = mid end
    end
    return (lo % 2 == 0) ? s["lvl0"] : 1 - s["lvl0"]
  end

  # Lowest standard baud whose bit time fits every pulse: [baud, measured baud] or nil
  static def find_baud(runs)
    if size(runs) < 10 return nil end
    for b: GreeDetect.BAUDS
      var T = 1000000.0 / b
      var n = 0
      var short = 0
      var err = 0.0
      var sum_d = 0.0
      var sum_k = 0
      for i: 1 .. size(runs) - 2
        var d = runs[i][1]
        if d < 14 * T
          var k = d / T
          var r = int(k + 0.5)
          n += 1
          if r < 1
            short += 1
          else
            err += (k > r) ? k - r : r - k
            sum_d += d
            sum_k += r
          end
        end
      end
      if n >= 8 && short * 20 <= n && sum_k > 0 && err / (n - short) <= 0.12
        return [b, int(1000000.0 * sum_k / sum_d + 0.5)]
      end
    end
    return nil
  end

  # Rough baud for non-standard speeds: from the shortest pulses (about one bit)
  static def estimate(runs)
    var d = []
    for i: 1 .. size(runs) - 2 d.push(runs[i][1]) end
    if size(d) < 4 return nil end
    for i: 1 .. size(d) - 1                      # insertion sort (Berry lists have no sort)
      var v = d[i]
      var j = i - 1
      while j >= 0 && d[j] > v d[j + 1] = d[j] j -= 1 end
      d[j + 1] = v
    end
    var p = d[size(d) / 10]
    return (p > 0) ? int(1000000.0 / p + 0.5) : nil
  end

  # Software UART over the recorded edges. Returns {"bytes", "times", "errors"}
  static def decode(s, idle, T, nd, par, ns)
    var e = s["edges"]
    var t_end = s["t_end"]
    var lvl0 = s["lvl0"]
    var nbits = 1 + nd + ((par == "N") ? 0 : 1) + ns
    var out = bytes()
    var times = []
    var errs = 0
    var t_min = 0
    var i = 0
    while i < size(e)
      var after = (i % 2 == 0) ? 1 - lvl0 : lvl0  # level right after edge i
      var ts = e[i]
      i += 1
      if after == idle || ts < t_min continue end  # only idle -> active edges start a character
      if ts + nbits * T > t_end break end
      if GreeDetect.level_at(s, ts + 0.5 * T) == idle continue end   # glitch, not a start bit
      var v = 0
      var ones = 0
      for j: 0 .. nd - 1
        var b = (GreeDetect.level_at(s, ts + (1.5 + j) * T) == idle) ? 1 : 0
        v = v | (b << j)
        ones += b
      end
      var bad = false
      var pos = 1 + nd
      if par != "N"
        if GreeDetect.level_at(s, ts + (pos + 0.5) * T) == idle ones += 1 end
        if (par == "E" && ones % 2 != 0) || (par == "O" && ones % 2 != 1) bad = true end
        pos += 1
      end
      for j: 0 .. ns - 1
        if GreeDetect.level_at(s, ts + (pos + j + 0.5) * T) != idle bad = true end
      end
      if bad errs += 1 end
      out.add(v)
      times.push(ts)
      t_min = ts + (nbits - 0.5) * T
    end
    return {"bytes": out, "times": times, "errors": errs}
  end

  static def hex(b, n)
    var p = []
    var m = size(b)
    if n != nil && n < m m = n end
    for i: 0 .. m - 1 p.push(string.format("%02X", b[i])) end
    return p.concat(" ")
  end

  # Count valid Gree frames (indoor 07 .. 0D, 9 bytes; outdoor 08 .. 0F, 11 bytes; XOR checksum)
  static def gree_frames(b)
    var n = 0
    for f: [[0x07, 9, 0x0D], [0x08, 11, 0x0F]]
      var i = 0
      while i + f[1] <= size(b)
        if b[i] == f[0] && b[i + f[1] - 1] == f[2]
          var x = 0
          for k: 1 .. f[1] - 3 x = x ^ b[i + k] end
          if x == b[i + f[1] - 2] n += 1 i += f[1] continue end
        end
        i += 1
      end
    end
    return n
  end

  static def analyze(s)
    var res = {"edges": size(s["edges"])}
    if size(s["edges"]) < 20
      res["activity"] = false
      return res
    end
    res["activity"] = true
    var runs = GreeDetect.runs(s)
    var longest = runs[0]
    for r: runs if r[1] > longest[1] longest = r end end
    var idle = longest[0]
    res["idle"] = idle ? "high" : "low"
    res["inverted"] = (idle == 0)
    var fb = GreeDetect.find_baud(runs)
    if fb == nil
      res["estimate"] = GreeDetect.estimate(runs)
      return res
    end
    res["baud"] = fb[0]
    res["measured"] = fb[1]
    var T = 1000000.0 / fb[1]
    var best = nil
    var best_score = 100000
    for k: 0 .. size(GreeDetect.FORMATS) - 1
      var f = GreeDetect.FORMATS[k]
      var d = GreeDetect.decode(s, idle, T, int(f[0]), f[1], int(f[2]))
      var n = size(d["bytes"])
      if n < 4 continue end
      var score = int(d["errors"] * 50.0 / n + 0.5) * 100 + k     # error rate in 2 % steps, then order
      if score < best_score best_score = score best = [f, d] end
    end
    if best == nil return res end
    var d = best[1]
    res["fmt"] = best[0]
    res["bytes"] = size(d["bytes"])
    res["errors"] = d["errors"]
    res["sample"] = GreeDetect.hex(d["bytes"], 24)
    res["gree"] = GreeDetect.gree_frames(d["bytes"])
    # bursts: characters closer together than 3 character times belong to the same burst
    var f = best[0]
    var ct = (1 + int(f[0]) + ((f[1] == "N") ? 0 : 1) + int(f[2])) * T
    var bursts = []
    var gaps = []                                  # idle time between the end of a burst and the next one (ms)
    var n = 0
    var prev = nil
    for t: d["times"]
      if prev != nil && t - prev > 3 * ct
        bursts.push(n)
        if size(gaps) < 6 gaps.push(int((t - prev - ct) / 1000 + 0.5)) end
        n = 0
      end
      n += 1
      prev = t
    end
    if n > 0 bursts.push(n) end
    res["bursts"] = bursts
    res["gaps_ms"] = gaps
    return res
  end

  static def summary(name, r)
    if r == nil return name + ": not measured" end
    if !r["activity"] return string.format("%s: no activity (%d edges): is the unit on?", name, r["edges"]) end
    if !r.contains("baud")
      return string.format("%s: idle %s, speed not standard (about %s baud)", name, r["idle"], str(r.find("estimate")))
    end
    if !r.contains("fmt") return string.format("%s: %d baud, idle %s, format not found", name, r["baud"], r["idle"]) end
    return string.format("%s: %d baud (%d measured) %s, %s, %d bytes, %d errors%s", name, r["baud"], r["measured"],
                         r["fmt"], r["inverted"] ? "inverted" : "normal", r["bytes"], r["errors"],
                         r["gree"] > 0 ? string.format(", %d Gree frames", r["gree"]) : "")
  end
end

# ---------------------------------------------------------------------------------------------------
class GreeTools
  static var VERSION = "2026-10-18b"
  static var CAP_FILE = "/gree_capture.txt"
  static var PREV_FILE = "/gree_capture_prev.txt"
  static var MAX_BYTES = 200000
  static var PRE_MS = 3000            # startup capture keeps this much before the trigger
  static var ARM_MS = 600000          # startup capture gives up waiting for an IR command after 10 min

  var ir_seen, ir_last, ir_det        # protocol -> count; last IrReceived summary; detected HVAC brand
  var ir_models                       # model -> count for the detected brand (the decoder's model guess varies)
  var det, det_state                  # last detection {"RX": res, "TX": res}; nil / "running"
  var cap                             # running capture (map) or nil
  var cap_done                        # summary of the last finished capture
  var cap_file, prev_file

  def init()
    self.cap_file = self.CAP_FILE
    self.prev_file = self.PREV_FILE
    self.ir_seen = {}
    self.ir_models = {}
    self.ir_det = persist.find("gree_ir", nil)
    tasmota.add_rule("IrReceived", /v -> self.on_ir(v))
    tasmota.add_rule("IRHVAC", /v -> self.on_irhvac(v))
    tasmota.add_cmd("IrDetect", /cmd, idx, payload -> self.cmd_irdetect(payload))
    tasmota.add_cmd("BusDetect", /cmd, idx, payload -> self.cmd_busdetect(payload))
    tasmota.add_cmd("GreeCapture", /cmd, idx, payload -> self.cmd_capture(payload))
    tasmota.add_cmd("GreeMark", /cmd, idx, payload -> self.cmd_mark(payload))
    tasmota.add_driver(self)
  end

  static def bus() return global.gree_bus end

  # ---------------- IR brand ----------------
  # Short UNKNOWN codes are noise on the IR line (seen on GRJ819-A3 with the unit off): counted apart,
  # kept in captures, but never taken as a remote press or as the start of a start-up capture.
  static def ir_noise(p, bits) return p == "UNKNOWN" && bits < 16 end

  def on_ir(v)
    if type(v) != 'instance' && type(v) != 'map' return end
    var p = str(v.find("Protocol", "?"))
    var bits = v.find("Bits", 0)
    var noise = GreeTools.ir_noise(p, bits)
    var k = noise ? "noise" : p
    self.ir_seen[k] = self.ir_seen.find(k, 0) + 1
    var h = v.find("IRHVAC")
    var vendor = (h != nil) ? h.find("Vendor") : nil
    var model = (h != nil) ? h.find("Model") : nil
    if !noise
      self.ir_last = {"protocol": p, "bits": bits, "vendor": vendor, "model": model, "t": tasmota.millis()}
    end
    if vendor != nil
      var m = (model != nil) ? str(model) : ""
      if self.ir_det == nil || self.ir_det.find("vendor") != str(vendor)
        self.ir_models = {}
      end
      self.ir_models[m] = self.ir_models.find(m, 0) + 1
      var best = (self.ir_det != nil && self.ir_det.find("vendor") == str(vendor) &&
                  self.ir_models.contains(self.ir_det.find("model"))) ? self.ir_det["model"] : m   # ties keep the shown one
      for km: self.ir_models.keys() if self.ir_models[km] > self.ir_models[best] best = km end end
      var d = {"vendor": str(vendor), "model": best, "protocol": p, "bits": bits}
      # flash is written only when the brand changes, or the most frequent model does
      if self.ir_det == nil || self.ir_det.find("vendor") != d["vendor"] || self.ir_det.find("model") != d["model"]
        self.ir_det = d
        persist.gree_ir = d
        persist.save()
        log(string.format("IR: remote detected: %s %s (protocol %s, %d bits)", d["vendor"], d["model"], p, bits), 2)
      end
    end
    self.cap_event("IR", json.dump(v), true, vendor != nil)     # only a decoded AC command starts a capture
  end

  def on_irhvac(v)
    self.cap_event("IRHVAC", json.dump(v), true, true)
  end

  def ir_text()
    var d = self.ir_det
    var n = 0
    for k: self.ir_seen.keys() if k != "noise" n += self.ir_seen[k] end end
    if d != nil
      var m = (d["model"] != "" && d["model"] != "-1") ? ", model " + d["model"] : ""
      return string.format("%s%s (%d presses since restart)", d["vendor"], m, n)
    end
    if self.ir_last != nil
      return string.format("not recognised as an AC remote (%s, %d bits): make a capture", self.ir_last["protocol"],
                           self.ir_last["bits"])
    end
    return "press a button on the wall remote"
  end

  def reset_ir()
    self.ir_det = nil
    self.ir_seen = {}
    self.ir_models = {}
    self.ir_last = nil
    persist.gree_ir = nil
    persist.save()
  end

  def cmd_irdetect(payload)
    if str(payload) == "0" self.reset_ir() end
    var r = {"Detected": self.ir_det, "Seen": self.ir_seen}
    if self.ir_last != nil r["Last"] = {"Protocol": self.ir_last["protocol"], "Bits": self.ir_last["bits"]} end
    tasmota.resp_cmnd(json.dump({"IrDetect": r}))
  end

  # ---------------- bus speed detection ----------------
  def start_detect()
    var b = GreeTools.bus()
    if b == nil || self.det_state == "running" return false end
    self.det_state = "running"
    self.det = {}
    log("BUS: speed detection, bus decoder paused", 2)
    b.pause()
    tasmota.set_timer(200, /-> self.detect_tap(0))
    return true
  end

  def detect_tap(k)
    var b = GreeTools.bus()
    var t = b.taps[k]
    var r = nil
    try
      r = GreeDetect.analyze(GreeDetect.sample(t.gpio, 150, 1500, 800))
    except .. as e, m
      r = {"activity": false, "edges": 0, "error": str(e) + " " + str(m)}
    end
    self.det[t.name] = r
    log("BUS: " + GreeDetect.summary(t.name, r), 2)
    if k + 1 < size(b.taps)
      tasmota.set_timer(300, /-> self.detect_tap(k + 1))     # let Tasmota breathe between the taps
    else
      b.resume()
      self.det_state = nil
      tasmota.publish_result(json.dump({"BusDetect": self.det}), "RESULT")
    end
  end

  # Detected settings both taps agree on, or nil
  def detected_serial()
    if self.det == nil return nil end
    var baud = nil
    var fmt = nil
    var inv = {}
    for k: self.det.keys()
      var r = self.det[k]
      if r.contains("fmt")
        if baud != nil && (baud != r["baud"] || fmt != r["fmt"]) return nil end
        baud = r["baud"]
        fmt = r["fmt"]
        inv[k] = r["inverted"]
      end
    end
    return (baud == nil) ? nil : [baud, fmt, inv]
  end

  def apply_detect()
    var d = self.detected_serial()
    var b = GreeTools.bus()
    if d == nil || b == nil return false end
    b.set_serial(d[0], d[1], d[2])
    if d[0] != b.BAUD || d[1] != "8E1"
      b.auto = false                    # BusAuto looks for Gree frames: it would keep flipping
      persist.bus_auto = false
      persist.save()
    end
    return true
  end

  def cmd_busdetect(payload)
    var p = string.tolower(str(payload == nil ? "" : payload))
    if p == "apply"
      tasmota.resp_cmnd(string.format('{"BusDetect":"%s"}', self.apply_detect() ? "applied" : "nothing to apply"))
      return
    end
    if self.start_detect()
      tasmota.resp_cmnd('{"BusDetect":"running, about 5 s"}')
    else
      tasmota.resp_cmnd(json.dump({"BusDetect": self.det_state == "running" ? "already running" : "no bus"}))
    end
  end

  # ---------------- captures ----------------
  # c: {"win", "every", "count", "k", "t0", "w_start", "w_end", "lines", "bytes", "buf", "mode", "pre", "so58"}
  def start_capture(win_s, every_s, count, mode)
    var b = GreeTools.bus()
    if self.cap != nil self.stop_capture("replaced") end
    import path
    if path.exists(self.cap_file)
      if path.exists(self.prev_file) path.remove(self.prev_file) end
      path.rename(self.cap_file, self.prev_file)
    end
    var so = tasmota.cmd("SetOption58", true)
    var c = {"win": win_s * 1000, "every": every_s * 1000, "count": count, "k": 0, "lines": 0, "bytes": 0,
             "buf": [], "mode": mode, "pre": [], "so58": (so != nil) ? so.find("SetOption58") : nil,
             "armed_at": tasmota.millis()}
    self.cap = c
    tasmota.cmd("SetOption58 1", true)         # IR raw timings in IrReceived while capturing
    var hook = /tap, f, now -> self.on_frame(tap, f, now)
    c["hook"] = hook
    if b != nil b.add_hook(hook) end
    self.write_header()
    if mode == "now"
      self.open_window(tasmota.millis())
    else
      self.cap_line(nil, "#", "armed: waiting for an IR command (wall remote, Home Assistant or Apple Home)", true)
    end
    return true
  end

  def write_header()
    var c = self.cap
    var b = GreeTools.bus()
    var hdr = ["# Gree bridge capture " + tasmota.time_str(tasmota.rtc()["local"]),
               "# gree_tools.be " + self.VERSION + ((b != nil) ? ", gree_bus.be " + b.VERSION : "")]
    if b != nil
      hdr.push(string.format("# bus: %d %s, RX %s, TX %s, BusGap %d ms, BusAuto %s", b.baud, b.fmt,
               b.taps[0].inverted ? "inverted" : "normal", b.taps[1].inverted ? "inverted" : "normal", b.gap,
               b.auto ? "on" : "off"))
    end
    if self.det != nil
      for k: self.det.keys() hdr.push("# detected " + GreeDetect.summary(k, self.det[k])) end
    end
    hdr.push("# ir: " + self.ir_text())
    if c["mode"] == "startup"
      hdr.push(string.format("# plan: on the next IR command, %d s before and %d s after, then %d s every %d s, %d windows",
               self.PRE_MS / 1000, c["win"] / 1000, c["win"] / 1000, c["every"] / 1000, c["count"]))
    else
      hdr.push(string.format("# plan: %d window(s) of %d s, one every %d s", c["count"], c["win"] / 1000, c["every"] / 1000))
    end
    hdr.push("# format: <ms since the capture started> <RX|TX|IR|IRHVAC|GREE|MARK> <data>")
    for h: hdr c["buf"].push(h) end
    c["bytes"] += size(hdr.concat("\n")) + 1
  end

  def gree_snapshot(now)
    var b = GreeTools.bus()
    if b == nil return end
    var j = b.gree_json(now)
    if j != nil self.cap_line(now, "GREE", j, false) end
  end

  def open_window(now)
    var c = self.cap
    if c["k"] == 0 c["t0"] = (c["mode"] == "startup") ? now - self.PRE_MS : now end
    c["w_start"] = now
    c["w_end"] = now + c["win"]
    c["k"] += 1
    self.cap_line(nil, "#", string.format("window %d/%d starts at +%d s", c["k"], c["count"], (now - c["t0"]) / 1000), true)
    if c["k"] == 1 && c["mode"] == "startup"   # what happened just before the trigger
      for l: c["pre"] if l[0] >= c["t0"] self.cap_line(l[0], l[1], l[2], true) end end
      c["pre"] = []
    end
    self.gree_snapshot(now)
  end

  def close_window(now)
    var c = self.cap
    self.gree_snapshot(now)
    self.cap_line(nil, "#", string.format("window %d/%d ends at +%d s", c["k"], c["count"], (now - c["t0"]) / 1000), true)
    c.remove("w_end")
    if c["k"] >= c["count"] self.stop_capture("done") end
  end

  def in_window(now)
    var c = self.cap
    return c != nil && c.contains("w_end") && now <= c["w_end"]
  end

  def on_frame(tap, f, now)
    var c = self.cap
    if c == nil return end
    var h = GreeDetect.hex(f, nil)
    if self.in_window(now)
      self.cap_line(now, tap, h, true)
    elif c["mode"] == "startup" && c["k"] == 0      # armed: keep the last PRE_MS
      c["pre"].push([now, tap, h])
      while size(c["pre"]) > 0 && now - c["pre"][0][0] > self.PRE_MS c["pre"].remove(0) end
    end
  end

  # IR events: in a window they are written; while armed (startup) they start the capture
  def cap_event(src, data, echo, trigger)
    var c = self.cap
    if c == nil return end
    var now = tasmota.millis()
    if c["mode"] == "startup" && c["k"] == 0
      if !trigger                               # armed: noise or a non-AC code is kept with the pre-trigger frames
        c["pre"].push([now, src, data])
        return
      end
      self.open_window(now)
    end
    if self.in_window(now) self.cap_line(now, src, data, echo) end
  end

  # one line; t = millis (nil for comments). echo: also print it in the console
  def cap_line(t, src, data, echo)
    var c = self.cap
    if c == nil return end
    var l = (t == nil) ? src + " " + data : string.format("%d %s %s", t - (c.contains("t0") ? c["t0"] : t), src, data)
    c["buf"].push(l)
    c["lines"] += 1
    c["bytes"] += size(l) + 1
    if echo log("CAP: " + l, 2) end
    if c["bytes"] > self.MAX_BYTES self.stop_capture("file full") end
  end

  def flush()
    var c = self.cap
    if c == nil || size(c["buf"]) == 0 return end
    try
      var f = open(self.cap_file, "a")
      f.write(c["buf"].concat("\n") + "\n")
      f.close()
    except .. as e, m
      log("CAP: cannot write " + self.cap_file + ": " + str(m), 1)
    end
    c["buf"] = []
  end

  def stop_capture(why)
    var c = self.cap
    if c == nil return end
    var b = GreeTools.bus()
    c["buf"].push("# end: " + why)
    self.flush()
    self.cap = nil                              # before anything that could log
    if b != nil b.remove_hook(c["hook"]) end
    if c["so58"] != nil && c["so58"] != "ON" tasmota.cmd("SetOption58 0", true) end
    self.cap_done = {"why": why, "lines": c["lines"], "bytes": c["bytes"], "windows": c["k"]}
    log(string.format("CAP: capture %s, %d lines, %d bytes in %s", why, c["lines"], c["bytes"], self.cap_file), 2)
  end

  def every_second()
    var c = self.cap
    if c == nil return end
    var now = tasmota.millis()
    if c.contains("w_end")
      if now > c["w_end"] self.close_window(now) end
    elif c["k"] == 0 && c["mode"] == "startup"
      if now - c["armed_at"] > self.ARM_MS self.stop_capture("no IR command within 10 min") end
    elif c["k"] > 0 && now >= c["w_start"] + c["every"]
      self.open_window(now)
    end
    self.flush()
  end

  def cap_status()
    var c = self.cap
    if c == nil
      return (self.cap_done == nil) ? "no capture yet" : string.format("last capture: %s, %d windows, %d lines, %d bytes",
             self.cap_done["why"], self.cap_done["windows"], self.cap_done["lines"], self.cap_done["bytes"])
    end
    var now = tasmota.millis()
    if c["k"] == 0 return "armed: waiting for an IR command (press the wall remote)" end
    if c.contains("w_end")
      return string.format("capturing window %d/%d, %d s left, %d lines", c["k"], c["count"], (c["w_end"] - now) / 1000 + 1, c["lines"])
    end
    return string.format("window %d/%d done, next in %d s, %d lines", c["k"], c["count"],
                         (c["w_start"] + c["every"] - now) / 1000 + 1, c["lines"])
  end

  def cmd_capture(payload)
    var p = string.tolower(string.replace(str(payload == nil ? "" : payload), " ", ""))
    if p == "stop"
      self.stop_capture("stopped")
    elif p == "startup"
      self.start_capture(5, 60, 4, "startup")
    elif size(p) > 0
      var a = string.split(p, ",")
      var w = int(a[0])
      var every = (size(a) > 1) ? int(a[1]) : w
      var n = (size(a) > 2) ? int(a[2]) : 1
      if w < 1 || w > 600 || n < 1 || n > 20 || every < w
        tasmota.resp_cmnd_str("usage: GreeCapture 5 | GreeCapture 5,60,4 | GreeCapture startup | GreeCapture stop")
        return
      end
      self.start_capture(w, every, n, "now")
    end
    tasmota.resp_cmnd(json.dump({"GreeCapture": self.cap_status(), "File": self.cap_file}))
  end

  def mark(t)
    var c = self.cap
    if c == nil return false end
    self.cap_line(c.contains("t0") ? tasmota.millis() : nil, (c.contains("t0") ? "MARK" : "# mark:"), t, true)
    return true
  end

  def cmd_mark(payload)
    var t = str(payload == nil ? "" : payload)
    if !self.mark(t)
      tasmota.resp_cmnd_str("no capture running")
      return
    end
    tasmota.resp_cmnd(json.dump({"GreeMark": t}))
  end

  # ---------------- web ----------------
  def web_sensor()
    tasmota.web_send("{s}IR remote{m}" + self.ir_text() + "{e}")
    if self.cap != nil tasmota.web_send("{s}Capture{m}" + self.cap_status() + "{e}") end
  end

  def web_add_main_button()
    import webserver
    webserver.content_send("<p></p><form action='gt' method='get'><button>Gree tools</button></form>")
  end

  def web_add_handler()
    import webserver
    webserver.on("/gt", / -> self.page(), webserver.HTTP_GET)
    webserver.on("/gt", / -> self.page_post(), webserver.HTTP_POST)
  end

  static def btn(act, label, cls)
    return string.format("<button name='act' value='%s' class='button %s'>%s</button><p></p>", act, cls, label)
  end

  def page()
    import webserver
    if !webserver.check_privileged_access() return nil end
    var e = webserver.html_escape
    var b = GreeTools.bus()
    webserver.content_start("Gree tools")
    webserver.content_send_style()
    if self.det_state == "running" || self.cap != nil
      webserver.content_send("<script>setTimeout(function(){location.href='/gt'},2000)</script>")
    end
    webserver.content_send("<form action='/gt' method='post'>")
    # IR
    webserver.content_send("<fieldset><legend><b>&nbsp;IR remote&nbsp;</b></legend>")
    webserver.content_send("<p>" + e(self.ir_text()) + "</p>")
    var d = self.ir_det
    if d != nil
      if d["vendor"] == "GREE"
        webserver.content_send("<p>Matches this board's settings (protocol GREE).</p>")
      else
        webserver.content_send("<p>For this brand: Home Assistant package <code>protocol: \"" + e(d["vendor"]) +
                               "\"</code>, Matter endpoint <code>vendor " + e(d["vendor"]) + "</code>.</p>")
      end
    end
    if size(self.ir_seen) > 0
      webserver.content_send("<p><small>Seen since restart: " + e(json.dump(self.ir_seen)) + "</small></p>")
    end
    webserver.content_send(GreeTools.btn("irreset", "Forget the detected remote", "bgrn"))
    webserver.content_send("</fieldset><p></p>")
    # bus
    webserver.content_send("<fieldset><legend><b>&nbsp;Bus speed&nbsp;</b></legend>")
    if b != nil
      webserver.content_send(string.format("<p>Now: %d %s, RX %s, TX %s, BusAuto %s</p>", b.baud, b.fmt,
                             b.taps[0].inverted ? "inverted" : "normal", b.taps[1].inverted ? "inverted" : "normal",
                             b.auto ? "on" : "off"))
    end
    if self.det_state == "running"
      webserver.content_send("<p><b>Detecting... (about 5 s)</b></p>")
    elif self.det != nil
      for k: self.det.keys()
        var r = self.det[k]
        webserver.content_send("<p>" + e(GreeDetect.summary(k, r)) + "</p>")
        if r.contains("sample")
          webserver.content_send("<p><small><code>" + e(r["sample"]) + "</code><br>bytes per burst: " +
                                 e(json.dump(r.find("bursts"))) + ", gaps between bursts (ms): " +
                                 e(json.dump(r.find("gaps_ms"))) + "</small></p>")
        end
      end
      var ds = self.detected_serial()
      if ds != nil && b != nil && (ds[0] != b.baud || ds[1] != b.fmt ||
         ds[2].find("RX", b.taps[0].inverted) != b.taps[0].inverted || ds[2].find("TX", b.taps[1].inverted) != b.taps[1].inverted)
        webserver.content_send(GreeTools.btn("apply", "Use the detected settings", "bred"))
      end
    end
    webserver.content_send("<p><small>Switch the unit on first. The decoder is paused for about 5 s.</small></p>")
    webserver.content_send(GreeTools.btn("detect", "Detect speed and format", "bgrn"))
    webserver.content_send("</fieldset><p></p>")
    # capture
    webserver.content_send("<fieldset><legend><b>&nbsp;Capture&nbsp;</b></legend>")
    webserver.content_send("<p>" + e(self.cap_status()) + "</p>")
    if self.cap == nil
      webserver.content_send(GreeTools.btn("cap5", "Capture 5 s now", "bgrn"))
      webserver.content_send(GreeTools.btn("startup", "Start-up sequence (next IR command, then +1, +2, +3 min)", "bgrn"))
    else
      webserver.content_send("<p><input name='note' placeholder='note, e.g. outdoor fan started'></p>")
      webserver.content_send(GreeTools.btn("mark", "Add the note", "bgrn"))
      webserver.content_send(GreeTools.btn("stop", "Stop", "bred"))
    end
    import path
    if path.exists(self.cap_file)
      webserver.content_send("<p><a href='/ufsd?download=" + self.cap_file + "'>Download " + self.cap_file + "</a>")
      if path.exists(self.prev_file)
        webserver.content_send(" &nbsp; <a href='/ufsd?download=" + self.prev_file + "'>previous</a>")
      end
      webserver.content_send("</p>")
    end
    webserver.content_send("<p><small>Also printed live in the Console. Commands: GreeCapture, GreeMark, BusDetect, IrDetect.</small></p>")
    webserver.content_send("</fieldset></form><p></p>")
    webserver.content_button(webserver.BUTTON_MAIN)
    webserver.content_stop()
  end

  def page_post()
    import webserver
    if !webserver.check_privileged_access() return nil end
    var a = webserver.has_arg("act") ? webserver.arg("act") : ""
    if a == "detect" self.start_detect()
    elif a == "apply" self.apply_detect()
    elif a == "irreset" self.reset_ir()
    elif a == "cap5" self.start_capture(5, 5, 1, "now")
    elif a == "startup" self.start_capture(5, 60, 4, "startup")
    elif a == "stop" self.stop_capture("stopped")
    elif a == "mark" && webserver.has_arg("note") self.mark(webserver.arg("note"))
    end
    webserver.redirect("/gt")
  end
end

gree_tools = GreeTools()
