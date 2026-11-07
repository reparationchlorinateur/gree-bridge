#-
  slot_bus.be - reader for indoor/outdoor buses that send ONE BIT PER MAINS CYCLE
                (older Toshiba / Carrier units, found on a RAS-15LKV-UL, 2026-11-07)

  On these units the communication line is synchronised to the 60 Hz (or 50 Hz) mains: in each
  mains cycle the line carries a pulse (about 6.6 ms, the bridge's tap pin goes LOW) or nothing.
    pulse = bit 1, no pulse = bit 0, characters are UART-like 8N1, LSB first (start 0, stop 1),
    the line idles on 1s (a pulse every cycle), frames are a few bytes back to back.
  A UART cannot read that (the "1" is a short pulse, not a level), so this script polls the tap pin
  from Tasmota's fast loop, counts mains cycles between pulse starts and rebuilds the bits.

  While it runs, gree_bus.be's serial taps are closed (both pins are polled directly here). Frames go
  to the same hooks as gree_bus.be's frames, so gree_tools.be captures (GreeCapture) record them as
  RX / TX lines, and to the console with SlotLog 1.

  Console commands
    SlotBus            status: pins, pulses, cycle length, frames, last frame of each pin
    SlotBus 0|1        stop / start (default: started when loaded)
    SlotLog 0|1        every frame to the console (default 0)
  Load it by hand while decoding a unit:  br load("slot_bus.be")    (not in autoexec.be)

  EXPERIMENTAL, NOT RELIABLE YET: on the first board Tasmota ran the fast loop only 70 to 130 times
  a second (even with Sleep 0), so the pins stay unread for up to about 10 ms between calls and some
  6.6 ms pulses are missed. Until that is solved (phase-locked sampling, or another input method),
  decode such a bus from blocking samples: GreeDetect.sample() in gree_tools.be records every edge
  for a few seconds, and the bits are rebuilt the same way (see docs/adapting.md).
-#

import string
import gpio
import global

class SlotTap
  var name, pin, last_lvl, t_fall, bits, state, cur, nbit, frame, idle_ones, frames, last_frame, pulses

  def init(name, pin)
    self.name = name
    self.pin = pin
    self.frames = 0
    self.pulses = 0
    self.last_frame = nil
    self.reset()
  end

  def reset()
    self.last_lvl = nil
    self.t_fall = nil
    self.state = 0           # 0 idle (waiting for a start bit), 1 data bits, 2 stop bit
    self.cur = 0
    self.nbit = 0
    self.frame = bytes()
    self.idle_ones = 0
  end

  # one bit, in time order; returns a finished frame (bytes) or nil
  def bit(b)
    if self.state == 0
      if b == 0
        self.state = 1  self.cur = 0  self.nbit = 0
        self.idle_ones = 0
      else
        self.idle_ones += 1
        if self.idle_ones >= 3 && size(self.frame) > 0     # idle after a frame: it is finished
          var f = self.frame
          self.frame = bytes()
          return f
        end
      end
    elif self.state == 1
      if b != 0 self.cur = self.cur | (1 << self.nbit) end
      self.nbit += 1
      if self.nbit == 8 self.state = 2 end
    else
      self.state = 0
      if b == 1
        self.frame.add(self.cur, 1)
      else                                                 # framing error: drop the frame
        self.frame = bytes()
      end
    end
    return nil
  end
end

class SlotBus
  static var PERIOD_US = 16667     # one mains cycle (60 Hz); 20000 for 50 Hz. Fixed: mains is stable, and
                                   # a cycle count is rounded, so jitter of a few ms in the polling is harmless
  static var MAX_GAP = 40          # cycles without a pulse that end everything (bus stopped)
  static var POLL_US = 3500        # time each fast-loop call keeps reading the pins
  var taps, on, log_on, period, measured, loops, loops_t0, rate, fl

  def init()
    self.period = self.PERIOD_US
    self.measured = self.PERIOD_US
    self.taps = [SlotTap("RX", 6), SlotTap("TX", 7)]
    self.log_on = false
    self.loops = 0
    self.rate = 0
    self.loops_t0 = tasmota.millis()
    self.fl = /-> self.loop()
    tasmota.add_cmd("SlotBus", /cmd, idx, payload -> self.cmd_bus(payload))
    tasmota.add_cmd("SlotLog", /cmd, idx, payload -> self.cmd_log(payload))
    self.start()
  end

  def start()
    var g = global.gree_bus
    if g != nil && !g.paused g.pause() end
    for t: self.taps
      gpio.pin_mode(t.pin, gpio.INPUT)
      t.reset()
    end
    if !self.on
      tasmota.add_fast_loop(self.fl)
    end
    self.on = true
  end

  def stop()
    if self.on
      tasmota.remove_fast_loop(self.fl)
    end
    self.on = false
    var g = global.gree_bus
    if g != nil && g.paused g.resume() end
  end

  def emit(t, f, now)
    t.frames += 1
    t.last_frame = f
    if self.log_on log("SLOT: " + t.name + " " + f.tohex(), 2) end
    var g = global.gree_bus
    if g != nil
      for hk: g.hooks
        try hk(t.name, f, now) except .. as e, m log("SLOT: hook error " + str(e) + " " + str(m), 2) end
      end
    end
  end

  # one edge check of one tap at time us
  def sample(t, v, us, now)
    if t.last_lvl == 1 && v == 0                         # pulse start
      t.pulses += 1
      if t.t_fall != nil
        var n = int((us - t.t_fall + self.period / 2) / self.period)   # mains cycles since the last pulse
        if n >= 1 && n <= self.MAX_GAP
          if n == 1 self.measured = (self.measured * 15 + (us - t.t_fall)) / 16 end   # for the status only
          for k: 1 .. n - 1
            var f = t.bit(0)
            if f != nil self.emit(t, f, now) end
          end
          var f = t.bit(1)
          if f != nil self.emit(t, f, now) end
        elif n > self.MAX_GAP                            # bus was silent: start over
          t.reset()
          t.last_lvl = v
        end
      end
      t.t_fall = us
    end
    t.last_lvl = v
  end

  # Tasmota calls the fast loop only every 5 to 10 ms, which can miss a 6.6 ms pulse: each call
  # therefore keeps reading both pins for POLL_US, so the pins are never left unread for long
  def loop()
    if !self.on return end
    var now = tasmota.millis()
    self.loops += 1
    if now - self.loops_t0 >= 1000
      self.rate = self.loops
      self.loops = 0
      self.loops_t0 = now
    end
    var rd = gpio.digital_read
    var r = self.taps[0]
    var x = self.taps[1]
    var us = tasmota.micros()
    var stop_us = us + self.POLL_US
    while true
      self.sample(r, rd(r.pin), us, now)
      self.sample(x, rd(x.pin), us, now)
      us = tasmota.micros()
      if us >= stop_us break end
    end
  end

  def cmd_bus(payload)
    var p = string.toupper(str(payload))
    if p == "1" || p == "ON" self.start() elif p == "0" || p == "OFF" self.stop() end
    var parts = []
    for t: self.taps
      parts.push(string.format('"%s":{"Pin":%d,"Pulses":%d,"Frames":%d,"Last":"%s"}', t.name, t.pin, t.pulses, t.frames,
                               t.last_frame != nil ? t.last_frame.tohex() : ""))
    end
    tasmota.resp_cmnd(string.format('{"SlotBus":"%s","CycleUs":%d,"MeasuredUs":%d,"LoopsPerS":%d,%s}', self.on ? "ON" : "OFF",
                                    self.period, self.measured, self.rate, parts.concat(",")))
  end

  def cmd_log(payload)
    var p = string.toupper(str(payload))
    if p == "1" || p == "ON" self.log_on = true elif p == "0" || p == "OFF" self.log_on = false end
    tasmota.resp_cmnd_str(self.log_on ? "ON" : "OFF")
  end
end

if global.slot_bus != nil global.slot_bus.stop() end
slot_bus = SlotBus()
