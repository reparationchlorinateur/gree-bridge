#-
  gree_bus.be - indoor/outdoor bus sniffer, indoor-frame decoder and outdoor-reply reader
                for the Gree bridge (rev B), with Home Assistant MQTT discovery

  GPIO6 <- COMM_RX tap: U6 RX opto output (pin 4, 0.10 V / 1.07 V) through the BC847 stage Q2
           (the 5 V MCU RX line works too): sees the indoor frame (echo) AND the outdoor reply
  GPIO7 <- COMM_TX tap (U3 TX opto drive node): the indoor unit's own frames only
  Both pass through U3 (74LVC14), which inverts them. Listen only, nothing is sent.

  Home Assistant: the script announces its sensors by MQTT discovery (retained), as one HA device
  per board named after Tasmota's DeviceName, so several boards need no YAML for the sensors:
    Backlog DeviceName Living room heat pump; Topic gree_living
  Entity ids follow the device name, e.g. sensor.living_room_heat_pump_compressor_frequency.
  A DeviceName change is picked up within a minute. The device also carries the board's MAC, so HA
  shows it together with the entities of the Tasmota integration (BME280) on one device page.

  Install
    1. Tasmota web UI > Tools > Manage File system: upload this file
    2. Add this line to autoexec.be (create the file if needed):  load("gree_bus.be")
    3. Restart (or console: BrRestart)

  Decoded indoor data -> MQTT tele/<topic>/GREE (on change, at most every GreeInterval s,
  and at least once a minute), also shown on the main page:
    {"Gree":{"Room":20.5,"Coil":7.9,"CoilRaw":79,"Power":"ON","Mode":"cool",
             "Setpoint":22,"Fan":3,"Link":"OK"}}
    Room      indoor unit's own room sensor, 0.5 C steps (reads 1 C lower in heat mode)
    Coil      indoor coil (tube) temperature, from the raw NTC reading (CoilRaw)
    Fan       ACTUAL indoor fan speed 0 = stopped, 1 low, 2 medium, 3 high
    Link      OK while valid frames arrive; after 10 s without one: STANDBY if the unit was OFF
              (normal: the indoor unit stops polling after some time off), LOST if it was ON.
              While Link is not OK, the measured values (Room, Coil, CoilRaw) are null instead of
              repeating old readings; Fan is 0 in STANDBY, null when LOST.
  Outdoor fields (RX tap only, absent until the first outdoor reply is seen):
    CompHz    compressor frequency in Hz, 0 = stopped
    OutCoil   outdoor coil temperature C (condenser in cool, evaporator in heat)
    OutAir    outdoor air temperature C
    OutMode   mode the outdoor unit runs: off / cool / heat (dry, fan_only assumed)
    DischRaw  o5 raw
    CompA     compressor current A (o7 x 0.05, from two clamp-meter readings)
    PowerW    estimated outdoor-unit input power W = 240 V x 0.95 x (CompA + 0.2 A fan/board), 0 when stopped
    LoadRaw   o7 raw
    Out       all outdoor bytes o1..o8 as raw numbers
    DischC    compressor discharge temperature C (o5, curve fitted on one cold reference point)
    OutLink   OK / STANDBY / LOST for the outdoor replies (same rule, using the outdoor mode).
              While not OK the outdoor temperatures and raw bytes are null; CompHz, CompA and PowerW
              are 0 in STANDBY (unit off) and null when LOST, so no energy is counted from old data.

  Console / MQTT commands (cmnd/<topic>/<command>)
    Gree             current decoded values
    GreeInterval <s> minimum seconds between publishes when only temperatures change (default 10, saved)
    BusPublish 0|1   also publish raw frames to tele/<topic>/BUS_RX and BUS_TX (default 0, saved)
    BusGap <ms>      silence that ends a frame                                 (default 300, saved)
    BusLen <n>       fixed frame length once known, 0 = split on silence       (default 0, saved)
    GreeDiscovery 0|1  Home Assistant discovery off (removes the entities) / on (default 1, saved);
                     no value = publish again and show the device name and id
    BusAuto 0|1      switch a tap's polarity by itself when bytes arrive but no valid frame decodes
                     for 20 s, and save the polarity that works (default 1, saved); a silent bus
                     (unit in standby) never triggers a switch; no value = show status
    BusSerial <baud>,<format>  serial settings of both taps, e.g. BusSerial 600,8E1 (default, saved);
                     for other units, found with BusDetect (gree_tools.be)
  Raw frames are written to the log at level 3: use "Weblog 3" to see them in the web console.

  Indoor frame, measured on GWH12KF (2026-10-07): 600 baud 8E1 (one idle bit between bytes),
  9 bytes every 1.0 s:  07 b1 b2 b3 00 b5 b6 ck 0D   with ck = b1 ^ b2 ^ b3 ^ b4 ^ b5 ^ b6
    b1 + (b5 bit 7) * 0.5   room temperature C
    b2                      coil NTC reading (20k NTC B3950 on a 20k divider, 8-bit)
    b3                      bit 3 power, bits 0-2 mode (0 auto 1 cool 2 dry 3 fan 4 heat)
    b6                      bits 4-5 actual indoor fan, bits 0-3 setpoint - 16
  Outdoor reply, ~50 ms after each indoor frame: 08 o1 .. o8 ck 0F  with ck = o1 ^ .. ^ o8
  (heating at 28 C: 08 2C 01 00 4C 78 61 2B 04 57 0F, o7 changes every second).
  Why BusGap 300 ms: TasmotaSerial hands over received bytes in blocks of 10 at baud rates
  <= 9600, i.e. every ~200 ms at 600 baud, so a shorter gap could cut frames in pieces.
  Use "Sleep 10" so the loop runs often enough (see README).
-#

import string
import persist
import mqtt
import math
import json

class GreeBusTap
  var name, gpio, baud, mode, inverted, ser, buf, last_rx, last_frame, last_pub, count, last_valid, opened, junk

  def init(name, gpio, baud, mode, inverted)
    self.name = name
    self.gpio = gpio
    self.baud = baud
    self.mode = mode
    self.last_frame = ""
    self.last_pub = ""
    self.count = 0
    self.open(inverted)
  end

  # (Re)open the RX-only port with the given polarity
  def open(inverted)
    if self.ser != nil
      self.ser.close()
      self.ser = nil
    end
    self.inverted = inverted
    self.buf = bytes()
    self.last_rx = 0
    self.last_valid = nil
    self.junk = 0                                 # bytes received since the last valid frame
    self.opened = tasmota.millis()
    try
      self.ser = serial(self.gpio, -1, self.baud, self.mode, inverted)    # rx only, tx = -1
      log(string.format("BUS: %s listening on GPIO%d%s", self.name, self.gpio, inverted ? " (inverted)" : ""), 2)
    except .. as e, m
      self.ser = nil
      log(string.format("BUS: cannot open %s on GPIO%d (%s: %s)", self.name, self.gpio, str(e), str(m)), 1)
    end
  end

  def close()
    if self.ser != nil
      self.ser.close()
      self.ser = nil
    end
  end

  # New serial settings (baud, mode) and polarity
  def reconfig(baud, mode, inverted)
    self.baud = baud
    self.mode = mode
    self.open(inverted)
  end

  # Collect received bytes; return a list of complete frames (possibly empty)
  def poll(now, gap, flen, maxlen)
    var frames = []
    if self.ser == nil return frames end
    if self.ser.available() > 0
      var c = self.ser.read()
      self.buf = self.buf + c
      self.junk += size(c)
      self.last_rx = now
    end
    if flen > 0                                   # fixed-length framing
      while size(self.buf) >= flen
        frames.push(self.buf[0 .. flen - 1])
        self.buf = self.buf[flen ..]
      end
    elif size(self.buf) >= maxlen                 # runaway stream: flush
      frames.push(self.buf)
      self.buf = bytes()
    end
    if size(self.buf) > 0 && now - self.last_rx >= gap   # silence ends the frame
      frames.push(self.buf)
      self.buf = bytes()
    end
    return frames
  end
end

# Find valid frames  head ... tail  of length n whose byte n-2 = XOR of bytes 1 .. n-3.
# pending: map tap -> leftover bytes, so a frame split across two deliveries is still found.
def gree_scan(pending, tap, chunk, head, n, tail)
  var b = pending.find(tap, bytes()) + chunk
  var out = []
  var used = 0
  var i = 0
  while i + n <= size(b)
    var ok = (b[i] == head && b[i + n - 1] == tail)
    if ok
      var x = 0
      for k: 1 .. n - 3 x = x ^ b[i + k] end
      ok = (x == b[i + n - 2])
    end
    if ok
      out.push(b[i .. i + n - 1])
      i += n
      used = i
    else
      i += 1
    end
  end
  var keep = size(b) - (n - 1)
  if keep < used keep = used end
  pending[tap] = (keep < size(b)) ? b[keep ..] : bytes()
  return out
end

# Decoder for the indoor unit's 9-byte frame:  07 b1 b2 b3 b4 b5 b6 ck 0D
class GreeIndoor
  static var MODES = ["auto", "cool", "dry", "fan_only", "heat"]
  var room, coil, coil_raw, power, mode, setpoint, fan, last_ok, frames, pending

  def init()
    self.last_ok = nil
    self.frames = 0
    self.pending = {}
  end

  # 20k NTC (B = 3950) on a 20k divider read as 8 bits (114 = 20 C on this unit, unit off for hours)
  static def coil_c(raw)
    if raw <= 0 || raw >= 256 return nil end
    return 1.0 / (1.0 / 298.15 + math.log((256.0 - raw) / raw) / 3950.0) - 273.15
  end

  # Scan received bytes (they may contain other frames or half a frame)
  def feed(chunk, now, tap)
    var fr = gree_scan(self.pending, tap, chunk, 0x07, 9, 0x0D)
    for f: fr self.decode(f, 0, now) end
    return size(fr) > 0
  end

  def decode(b, i, now)
    self.room = b[i + 1] + (((b[i + 5] & 0x80) != 0) ? 0.5 : 0.0)
    self.coil_raw = b[i + 2]
    self.coil = GreeIndoor.coil_c(b[i + 2])
    self.power = (b[i + 3] & 0x08) != 0
    var m = b[i + 3] & 0x07
    self.mode = (m < size(GreeIndoor.MODES)) ? GreeIndoor.MODES[m] : str(m)
    self.setpoint = 16 + (b[i + 6] & 0x0F)
    self.fan = (b[i + 6] >> 4) & 0x03
    self.last_ok = now
    self.frames += 1
  end

  def link_ok(now)
    return self.last_ok != nil && now - self.last_ok < 10000
  end

  # OK while frames arrive; STANDBY when they stopped after the unit was switched off (after some
  # time OFF the indoor unit stops talking to the outdoor unit); LOST when they stopped while ON
  def link(now)
    if self.link_ok(now) return "OK" end
    return self.power ? "LOST" : "STANDBY"
  end

  # Fields that should be published immediately when they change
  def state_key(now)
    if self.last_ok == nil return "none" end
    return string.format("%s|%s|%d|%d|%s", self.power ? "ON" : "OFF", self.mode, self.setpoint,
                         self.fan, self.link(now))
  end

  # While the link is not OK the last readings are not repeated: measurements become null,
  # the fan 0 in STANDBY (unit off) or null when LOST
  def to_json(now)
    if self.last_ok == nil return nil end
    var link = self.link(now)
    var room = "null", coil = "null", raw = "null", fan = "null"
    if link == "OK"
      room = string.format("%.1f", self.room)
      coil = (self.coil != nil) ? string.format("%.1f", self.coil) : "null"
      raw = str(self.coil_raw)
      fan = str(self.fan)
    elif link == "STANDBY"
      fan = "0"
    end
    return string.format('{"Room":%s,"Coil":%s,"CoilRaw":%s,"Power":"%s","Mode":"%s","Setpoint":%d,"Fan":%s,"Link":"%s"}',
                         room, coil, raw, self.power ? "ON" : "OFF", self.mode, self.setpoint, fan, link)
  end
end

# Outdoor unit's reply, 11 bytes about 50 ms after each indoor frame (seen on the RX tap only):
#   08 o1 o2 o3 o4 o5 o6 o7 o8 ck 0F   with ck = o1 ^ ... ^ o8
# Mapped from a cool -> off -> heat start-up recording (2026-10-07):
#   o1 compressor frequency Hz (0 = stopped; ramps 1 Hz/s)    o2 1 while the compressor runs
#   o3 always 0 so far (fault code?)                          o4 outdoor coil, same NTC curve as the indoor coil
#   o5 discharge temperature (EXHAUST sensor), own NTC curve, see DISCH_K
#   o6 outdoor air, same NTC curve                            o7 compressor current, 0.05 A per count
#   o8 running mode 0 off, 1 cool, 4 heat (2 dry / 3 fan assumed, same codes as the indoor frame)
class GreeOutdoor
  static var MODES = ["off", "cool", "dry", "fan_only", "heat"]
  # o7 scale from two clamp-meter readings on the outdoor supply (240 V, 2026-10-07):
  # 3.05 A at o7 = 55 and 1.6 A at o7 = 27  ->  I = 0.05 A * o7 (compressor) + ~0.2 A (fan + board)
  static var AMPS_PER_COUNT = 0.05
  static var AUX_AMPS = 0.2
  static var VOLTS = 240
  static var POWER_FACTOR = 0.95
  # o5 discharge sensor: different NTC/divider than the 20k sensors. Fitted on o5 = 41 at 13.6 C
  # (unit off for 6 h, pipe at outdoor temperature, 2026-10-08), NTC B = 3950 assumed.
  static var DISCH_K = 0.3229
  var raw, last_ok, frames, pending

  def init()
    self.last_ok = nil
    self.frames = 0
    self.pending = {}
  end

  def mode()
    var m = self.raw[7]
    return (m < size(GreeOutdoor.MODES)) ? GreeOutdoor.MODES[m] : str(m)
  end

  def comp_amps()
    return self.raw[6] * GreeOutdoor.AMPS_PER_COUNT
  end

  # Estimated outdoor-unit input power (W): 0 while the compressor is stopped
  def power_w()
    if self.raw[0] == 0 && self.raw[6] == 0 return 0 end
    return int(GreeOutdoor.VOLTS * GreeOutdoor.POWER_FACTOR * (self.comp_amps() + GreeOutdoor.AUX_AMPS) + 0.5)
  end

  static def temp_str(raw)
    var c = GreeIndoor.coil_c(raw)
    return (c != nil) ? string.format("%.1f", c) : "null"
  end

  static def disch_str(raw)
    if raw <= 0 || raw >= 256 return "null" end
    var c = 1.0 / (1.0 / 298.15 + math.log(GreeOutdoor.DISCH_K * (256.0 - raw) / raw) / 3950.0) - 273.15
    return string.format("%.1f", c)
  end

  # Fields that should be published immediately when they change: compressor on/off and mode
  def state_key(now)
    if self.last_ok == nil return "NONE" end
    return string.format("%s|%s|%s", self.link(now), self.raw[0] > 0 ? "run" : "stop", self.mode())
  end

  def feed(chunk, now, tap)
    var fr = gree_scan(self.pending, tap, chunk, 0x08, 11, 0x0F)
    for f: fr
      var v = []
      for k: 1 .. 8 v.push(f[k]) end
      self.raw = v
      self.last_ok = now
      self.frames += 1
    end
    return size(fr) > 0
  end

  def link_ok(now)
    return self.last_ok != nil && now - self.last_ok < 10000
  end

  # OK while replies arrive; STANDBY when they stopped after the unit was switched off
  # (the indoor unit stops polling after some time OFF); LOST when they stopped while running
  def link(now)
    if self.last_ok == nil return "NONE" end
    if self.link_ok(now) return "OK" end
    return (self.raw[7] == 0) ? "STANDBY" : "LOST"
  end

  # ',"CompHz":..,"OutCoil":..,"OutAir":..,"OutMode":..,"DischRaw":..,"LoadRaw":..,"Out":[...],"OutLink":"OK"'
  # or "" before the first outdoor frame
  def json_part(now)
    if self.last_ok == nil return "" end
    var link = self.link(now)
    var o = self.raw
    if link != "OK"                 # no repeated old readings: 0 power when the unit is off, null when LOST
      var z = (link == "STANDBY") ? "0" : "null"
      var md = (link == "STANDBY") ? '"off"' : "null"
      return string.format(',"CompHz":%s,"CompA":%s,"PowerW":%s,"OutCoil":null,"OutAir":null,"DischC":null,"OutMode":%s,"DischRaw":null,"LoadRaw":null,"Out":null,"OutLink":"%s"',
                           z, z, z, md, link)
    end
    var s = []
    for v: o s.push(str(v)) end
    return string.format(',"CompHz":%d,"CompA":%.2f,"PowerW":%d,"OutCoil":%s,"OutAir":%s,"DischC":%s,"OutMode":"%s","DischRaw":%d,"LoadRaw":%d,"Out":[%s],"OutLink":"%s"',
                         o[0], self.comp_amps(), self.power_w(), GreeOutdoor.temp_str(o[3]), GreeOutdoor.temp_str(o[5]),
                         GreeOutdoor.disch_str(o[4]), self.mode(), o[4], o[6], s.concat(","), link)
  end
end

class GreeBus
  # ---- hardware / line settings (edit, then BrRestart) ----
  static var BAUD        = 600
  static var RX_GPIO     = 6
  static var TX_GPIO     = 7
  # Starting polarity. RX: the U6 opto output idles low (loop current flowing); Q2 and U3 each
  # invert, so GPIO6 idles low = inverted UART. (Tapped on the 5 V MCU RX line instead, which idles
  # high, GPIO6 idles high = normal; BusAuto finds that by itself.) TX: tap on the U3 opto drive
  # node (idles low, not inverted after U3).
  # With BusAuto on (default) a tap that gives no valid frame for AUTO_MS switches polarity by
  # itself, and the polarity that works is saved.
  static var RX_INVERTED = true
  static var TX_INVERTED = false
  static var AUTO_MS     = 20000
  static var AUTO_BYTES  = 30      # ... and at least this many bytes arrived without a valid frame
  static var LOG_LEVEL   = 3       # raw frames: 3 = DEBUG ("Weblog 3" to see them), 2 = INFO
  static var MAX_LEN     = 80      # keeps the HA state under its 255-character limit
  static var HEARTBEAT   = 60      # republish decoded values at least this often (s)
  # -----------------------------------------------------------
  static var VERSION     = "2026-10-18 rev B"
  # Home Assistant entities: component, object id, name, value template, extra discovery keys
  static var HA = [
    ["sensor", "room_temperature", "Room temperature (unit)", "{{ value_json.Gree.Room }}",
     {"unit_of_meas": "°C", "dev_cla": "temperature", "stat_cla": "measurement"}],
    ["sensor", "coil_temperature", "Indoor coil temperature", "{{ value_json.Gree.Coil }}",
     {"unit_of_meas": "°C", "dev_cla": "temperature", "stat_cla": "measurement"}],
    ["sensor", "setpoint", "Setpoint (unit)", "{{ value_json.Gree.Setpoint }}",
     {"unit_of_meas": "°C", "dev_cla": "temperature"}],
    ["sensor", "mode", "Mode (unit)", "{{ value_json.Gree.Mode }}",
     {"dev_cla": "enum", "options": ["auto", "cool", "dry", "fan_only", "heat"], "ic": "mdi:hvac"}],
    ["sensor", "indoor_fan_speed", "Indoor fan speed", "{{ value_json.Gree.Fan }}",
     {"stat_cla": "measurement", "ic": "mdi:fan"}],
    ["sensor", "coil_raw", "Coil raw", "{{ value_json.Gree.CoilRaw }}", {"ent_cat": "diagnostic"}],
    ["sensor", "compressor_frequency", "Compressor frequency",
     "{{ value_json.Gree.CompHz if value_json.Gree.CompHz is defined else none }}",
     {"unit_of_meas": "Hz", "dev_cla": "frequency", "stat_cla": "measurement", "ic": "mdi:sine-wave"}],
    ["sensor", "outdoor_air_temperature", "Outdoor air temperature",
     "{{ value_json.Gree.OutAir if value_json.Gree.OutAir is defined else none }}",
     {"unit_of_meas": "°C", "dev_cla": "temperature", "stat_cla": "measurement"}],
    ["sensor", "outdoor_coil_temperature", "Outdoor coil temperature",
     "{{ value_json.Gree.OutCoil if value_json.Gree.OutCoil is defined else none }}",
     {"unit_of_meas": "°C", "dev_cla": "temperature", "stat_cla": "measurement"}],
    ["sensor", "outdoor_mode", "Outdoor mode",
     "{{ value_json.Gree.OutMode if value_json.Gree.OutMode is defined else none }}",
     {"dev_cla": "enum", "options": ["off", "cool", "dry", "fan_only", "heat"], "ic": "mdi:hvac"}],
    ["sensor", "compressor_current", "Compressor current",
     "{{ value_json.Gree.CompA if value_json.Gree.CompA is defined else none }}",
     {"unit_of_meas": "A", "dev_cla": "current", "stat_cla": "measurement"}],
    ["sensor", "outdoor_power", "Outdoor power",
     "{{ value_json.Gree.PowerW if value_json.Gree.PowerW is defined else none }}",
     {"unit_of_meas": "W", "dev_cla": "power", "stat_cla": "measurement"}],
    ["sensor", "discharge_temperature", "Discharge temperature",
     "{{ value_json.Gree.DischC if value_json.Gree.DischC is defined else none }}",
     {"unit_of_meas": "°C", "dev_cla": "temperature", "stat_cla": "measurement"}],
    ["sensor", "discharge_raw", "Discharge raw",
     "{{ value_json.Gree.DischRaw if value_json.Gree.DischRaw is defined else none }}",
     {"stat_cla": "measurement", "ent_cat": "diagnostic", "ic": "mdi:thermometer-high"}],
    ["sensor", "outdoor_raw", "Outdoor raw bytes",
     "{{ value_json.Gree.Out | join(' ') if value_json.Gree.Out else none }}",
     {"ent_cat": "diagnostic", "ic": "mdi:numeric"}],
    ["binary_sensor", "power", "Power (unit)", "{{ value_json.Gree.Power }}", {"dev_cla": "power"}],
    ["binary_sensor", "indoor_fan_running", "Indoor fan running",
     "{{ 'ON' if (value_json.Gree.Fan | int(0)) > 0 else 'OFF' }}", {"dev_cla": "running"}],
    ["binary_sensor", "bus_link", "Bus link",
     "{{ 'OFF' if value_json.Gree.Link == 'LOST' else 'ON' }}", {"dev_cla": "connectivity", "ent_cat": "diagnostic"}],
    ["binary_sensor", "compressor_running", "Compressor running",
     "{{ 'ON' if (value_json.Gree.CompHz | default(0) | int(0)) > 0 else 'OFF' }}", {"dev_cla": "running"}],
    ["binary_sensor", "outdoor_link", "Outdoor link",
     "{{ 'ON' if (value_json.Gree.OutLink | default('')) in ['OK', 'STANDBY'] else 'OFF' }}",
     {"dev_cla": "connectivity", "ent_cat": "diagnostic"}]
  ]
  var taps, publish, gap, flen, topic, indoor, outdoor, interval, last_key, last_json, last_pub_ms, auto, saved_inv
  var disc_on, disc_name, disc_check
  var baud, fmt, hooks, paused

  def init()
    self.publish = persist.find("bus_publish", false)
    self.gap = persist.find("bus_gap", 300)
    self.flen = persist.find("bus_len", 0)
    self.interval = persist.find("gree_interval", 10)
    self.auto = persist.find("bus_auto", true)
    self.disc_on = persist.find("gree_disc", true)
    self.disc_name = nil                          # device name last announced to HA (nil = not yet)
    self.disc_check = 0
    var r = tasmota.cmd("Topic", true)            # {"Topic":"tasmota_xxxxxx"}
    self.topic = (r != nil && r.contains("Topic")) ? r["Topic"] : "tasmota"
    self.indoor = GreeIndoor()
    self.outdoor = GreeOutdoor()
    self.last_key = ""
    self.last_json = ""
    self.last_pub_ms = nil
    self.baud = persist.find("bus_baud", self.BAUD)
    self.fmt = persist.find("bus_fmt", "8E1")
    var mode = GreeBus.fmt_mode(self.fmt)
    if mode == nil self.fmt = "8E1" mode = serial.SERIAL_8E1 end
    self.hooks = []
    self.paused = false
    # polarity saved in flash; nil = never saved (then the defaults above are used)
    self.saved_inv = {"RX": persist.find("bus_inv_rx", nil), "TX": persist.find("bus_inv_tx", nil)}
    self.taps = [
      GreeBusTap("RX", self.RX_GPIO, self.baud, mode,
                 self.saved_inv["RX"] != nil ? self.saved_inv["RX"] : self.RX_INVERTED),
      GreeBusTap("TX", self.TX_GPIO, self.baud, mode,
                 self.saved_inv["TX"] != nil ? self.saved_inv["TX"] : self.TX_INVERTED)
    ]
    tasmota.add_fast_loop(/-> self.loop())
    tasmota.add_driver(self)
    tasmota.add_cmd("BusPublish", /cmd, idx, payload -> self.cmd_publish(payload))
    tasmota.add_cmd("BusGap", /cmd, idx, payload -> self.cmd_gap(payload))
    tasmota.add_cmd("BusLen", /cmd, idx, payload -> self.cmd_len(payload))
    tasmota.add_cmd("GreeInterval", /cmd, idx, payload -> self.cmd_interval(payload))
    tasmota.add_cmd("BusAuto", /cmd, idx, payload -> self.cmd_auto(payload))
    tasmota.add_cmd("Gree", /cmd, idx, payload -> self.cmd_gree())
    tasmota.add_cmd("GreeDiscovery", /cmd, idx, payload -> self.cmd_discovery(payload))
    tasmota.add_cmd("BusSerial", /cmd, idx, payload -> self.cmd_serial(payload))
    tasmota.add_rule("Mqtt#Connected", /-> self.on_mqtt_connect())
  end

  # ---- Home Assistant MQTT discovery ----
  def device_name()
    var r = tasmota.cmd("DeviceName", true)       # {"DeviceName":"Living room heat pump"}
    return (r != nil && r.contains("DeviceName") && size(r["DeviceName"]) > 0) ? r["DeviceName"] : self.topic
  end

  def ha_id()
    var mac = tasmota.wifi().find("mac", "")
    if mac == "" return nil end
    return "gree_" + string.tolower(string.replace(mac, ":", ""))
  end

  # Publish (retained) one discovery config per entity, or empty payloads to remove them.
  # Returns the number of messages sent, 0 if the board has no MAC/MQTT yet.
  def discover(remove)
    var uid = self.ha_id()
    if uid == nil || !mqtt.connected() return 0 end
    var name = self.device_name()
    var w = tasmota.wifi()
    var dev = {"ids": [uid], "cns": [["mac", string.tolower(w.find("mac", ""))]], "name": name,
               "mf": "DIY", "mdl": "Gree bridge (ESP32-S3)", "sw": "gree_bus.be " + self.VERSION}
    if w.find("ip", "") != "" dev["cu"] = "http://" + w["ip"] + "/" end
    var n = 0
    for e: self.HA
      var t = string.format("homeassistant/%s/%s/%s/config", e[0], uid, e[1])
      if remove
        mqtt.publish(t, "", true)
      else
        var c = {"name": e[2], "uniq_id": uid + "_" + e[1], "~": "tele/" + self.topic,
                 "stat_t": "~/GREE", "val_tpl": e[3], "avty_t": "~/LWT", "pl_avail": "Online",
                 "pl_not_avail": "Offline", "exp_aft": 180, "dev": dev}
        if e[0] == "binary_sensor" c["pl_on"] = "ON"  c["pl_off"] = "OFF" end
        for k: e[4].keys() c[k] = e[4][k] end
        mqtt.publish(t, json.dump(c), true)
      end
      n += 1
    end
    self.disc_name = remove ? nil : name
    log(string.format("GREE: Home Assistant discovery %s for '%s' (%s, %d entities)",
                      remove ? "removed" : "published", name, uid, n), 2)
    return n
  end

  def on_mqtt_connect()
    self.disc_name = nil                          # announce again on the next second
  end

  # once per second: announce after (re)connect, and again when DeviceName changed (checked every 60 s)
  def check_discovery(now)
    if !self.disc_on || !mqtt.connected() return end
    if self.disc_name != nil && now - self.disc_check < 60000 return end
    self.disc_check = now
    if self.disc_name == nil || self.device_name() != self.disc_name
      self.discover(false)
    end
  end

  def cmd_discovery(payload)
    var p = string.toupper(str(payload))
    if p == "0" || p == "OFF"
      if self.disc_on self.discover(true) end
      self.disc_on = false
    elif p == "1" || p == "ON" || p == "" || payload == nil
      self.disc_on = true
      self.discover(false)
    end
    persist.gree_disc = self.disc_on
    persist.save()
    var uid = self.ha_id()
    tasmota.resp_cmnd(string.format('{"GreeDiscovery":"%s","Device":"%s","Id":"%s"}', self.disc_on ? "ON" : "OFF",
                                    self.device_name(), uid != nil ? uid : ""))
  end

  static def hex(b)
    var parts = []
    for i: 0 .. size(b) - 1
      parts.push(string.format("%02X", b[i]))
    end
    return parts.concat(" ")
  end

  # "8E1" -> serial.SERIAL_8E1 (nil if unknown)
  static def fmt_mode(f)
    import introspect
    if type(f) != 'string' || size(f) != 3 return nil end
    var m = introspect.get(serial, "SERIAL_" + string.toupper(f))
    return (type(m) == 'int') ? m : nil
  end

  # Other scripts (gree_tools.be) get every raw frame: h(tap_name, bytes, now_ms)
  def add_hook(h) if self.hooks.find(h) == nil self.hooks.push(h) end end
  def remove_hook(h) var i = self.hooks.find(h) if i != nil self.hooks.remove(i) end end

  # Free the tap GPIOs for a while (bus speed detection), then listen again
  def pause()
    self.paused = true
    for t: self.taps t.close() end
  end
  def resume()
    for t: self.taps t.open(t.inverted) end
    self.paused = false
  end

  # Change baud / format of both taps and, optionally, the polarity of each (map name -> bool)
  def set_serial(baud, fmt, inv)
    var mode = GreeBus.fmt_mode(fmt)
    if mode == nil || baud < 50 || baud > 115200 return false end
    self.baud = baud
    self.fmt = string.toupper(fmt)
    persist.bus_baud = baud
    persist.bus_fmt = self.fmt
    for t: self.taps
      var i = (inv != nil && inv.contains(t.name)) ? inv[t.name] : t.inverted
      t.reconfig(baud, mode, i)
      if inv != nil && inv.contains(t.name)
        if t.name == "RX" persist.bus_inv_rx = i else persist.bus_inv_tx = i end
        self.saved_inv[t.name] = i
      end
    end
    persist.save()
    log(string.format("BUS: serial %d %s, RX %s, TX %s", baud, self.fmt, self.taps[0].inverted ? "inverted" : "normal",
                      self.taps[1].inverted ? "inverted" : "normal"), 2)
    return true
  end

  def loop()
    if self.paused return end
    var now = tasmota.millis()
    for t: self.taps
      for f: t.poll(now, self.gap, self.flen, self.MAX_LEN)
        var h = GreeBus.hex(f)
        t.count += 1
        log(string.format("BUS: %s %d bytes: %s", t.name, size(f), h), self.LOG_LEVEL)
        var ok_in = self.indoor.feed(f, now, t.name)     # indoor frames are found on either tap
        var ok_out = self.outdoor.feed(f, now, t.name)   # outdoor replies only appear on the RX tap
        if ok_in || ok_out
          t.last_valid = now
          t.junk = 0
          self.save_polarity(t)
        end
        if self.publish && h != t.last_pub      # only publish when the frame changes
          var payload = string.format('{"Bus":{"Tap":"%s","Len":%d,"Data":"%s"}}', t.name, size(f), h)
          mqtt.publish("tele/" + self.topic + "/BUS_" + t.name, payload, false, nil, nil, 3)
          t.last_pub = h
        end
        t.last_frame = h
        for hk: self.hooks
          try hk(t.name, f, now) except .. as e, m log("BUS: hook error " + str(e) + " " + str(m), 2) end
        end
      end
    end
  end

  # Combined JSON: indoor fields plus the outdoor part once outdoor frames are seen
  def gree_json(now)
    var j = self.indoor.to_json(now)
    var o = self.outdoor.json_part(now)
    if j == nil
      return (o == "") ? nil : '{' + o[1 ..] + '}'
    end
    return j[0 .. -2] + o + '}'
  end

  # Remember the polarity that produced valid frames (flash is only written when it changes)
  def save_polarity(t)
    if self.saved_inv.find(t.name) != t.inverted
      self.saved_inv[t.name] = t.inverted
      if t.name == "RX" persist.bus_inv_rx = t.inverted else persist.bus_inv_tx = t.inverted end
      persist.save()
      log(string.format("BUS: %s polarity %s saved", t.name, t.inverted ? "inverted" : "normal"), 2)
    end
  end

  # A tap that receives bytes but no valid frame for AUTO_MS tries the other polarity.
  # A silent tap (unit in standby, nothing connected) is left alone.
  def check_polarity(now)
    if !self.auto || self.paused return end
    for t: self.taps
      var ref = (t.last_valid != nil) ? t.last_valid : t.opened
      if now - ref >= self.AUTO_MS && now - t.opened >= self.AUTO_MS && t.junk >= self.AUTO_BYTES
        log(string.format("BUS: %d bytes but no valid frame on %s for %d s, trying %s polarity", t.junk, t.name,
                          self.AUTO_MS / 1000, t.inverted ? "normal" : "inverted"), 2)
        t.open(!t.inverted)
      end
    end
  end

  # Called by Tasmota once per second: publish decoded values
  def every_second()
    var now = tasmota.millis()
    self.check_polarity(now)
    self.check_discovery(now)
    var j = self.gree_json(now)
    if j == nil return end
    var key = self.indoor.state_key(now) + "|" + self.outdoor.state_key(now)
    var since = (self.last_pub_ms == nil) ? 1000000 : now - self.last_pub_ms
    if key != self.last_key ||
       (j != self.last_json && since >= self.interval * 1000) ||
       since >= self.HEARTBEAT * 1000
      mqtt.publish("tele/" + self.topic + "/GREE", '{"Gree":' + j + '}', false)
      self.last_key = key
      self.last_json = j
      self.last_pub_ms = now
    end
  end

  # Tasmota main web page
  def web_sensor()
    var now = tasmota.millis()
    var d = self.indoor
    if d.last_ok != nil
      var coil = (d.coil != nil) ? string.format("%.1f", d.coil) : "?"
      tasmota.web_send(string.format("{s}Gree room{m}%.1f &deg;C{e}", d.room))
      tasmota.web_send(string.format("{s}Gree coil{m}%s &deg;C (raw %d){e}", coil, d.coil_raw))
      tasmota.web_send(string.format("{s}Gree state{m}%s %s %d &deg;C{e}", d.power ? "ON" : "OFF", d.mode, d.setpoint))
      tasmota.web_send(string.format("{s}Gree indoor fan{m}%d{e}", d.fan))
      tasmota.web_send(string.format("{s}Gree link{m}%s (%d frames){e}", d.link(now), d.frames))
    else
      tasmota.web_send("{s}Gree link{m}no valid frame yet{e}")
    end
    var o = self.outdoor
    if o.last_ok != nil
      var r = o.raw
      tasmota.web_send(string.format("{s}Gree compressor{m}%d Hz, %s, %.2f A, ~%d W{e}", r[0], o.mode(), o.comp_amps(), o.power_w()))
      tasmota.web_send(string.format("{s}Gree outdoor air / coil / discharge{m}%s / %s / %s &deg;C{e}",
                                     GreeOutdoor.temp_str(r[5]), GreeOutdoor.temp_str(r[3]), GreeOutdoor.disch_str(r[4])))
      var s = []
      for v: r s.push(string.format("%d", v)) end
      tasmota.web_send(string.format("{s}Gree outdoor raw (%s){m}%s{e}", o.link(now), s.concat(" ")))
    end
    var ser = (self.baud == self.BAUD && self.fmt == "8E1") ? "" : string.format(", %d %s", self.baud, self.fmt)
    for t: self.taps
      tasmota.web_send(string.format("{s}Bus %s (%d, %s%s){m}%s{e}", t.name, t.count,
                                     t.inverted ? "inv" : "norm", ser, t.last_frame))
    end
  end

  def cmd_gree()
    var j = self.gree_json(tasmota.millis())
    tasmota.resp_cmnd(j != nil ? '{"Gree":' + j + '}' : '{"Gree":null}')
  end

  def cmd_interval(payload)
    if payload != nil && size(str(payload)) > 0
      var v = int(payload)
      if v >= 1 && v <= 3600
        self.interval = v
        persist.gree_interval = v
        persist.save()
      end
    end
    tasmota.resp_cmnd_str(str(self.interval))
  end

  def cmd_publish(payload)
    var p = string.toupper(str(payload))
    if p == "1" || p == "ON"
      self.publish = true
      for t: self.taps t.last_pub = "" end      # next frame of each tap is always sent
    elif p == "0" || p == "OFF"
      self.publish = false
    end
    persist.bus_publish = self.publish
    persist.save()
    tasmota.resp_cmnd_str(self.publish ? "ON" : "OFF")
  end

  def cmd_auto(payload)
    var p = string.toupper(str(payload))
    if p == "1" || p == "ON"
      self.auto = true
    elif p == "0" || p == "OFF"
      self.auto = false
    end
    persist.bus_auto = self.auto
    persist.save()
    tasmota.resp_cmnd(string.format('{"BusAuto":"%s","RX":"%s","TX":"%s"}', self.auto ? "ON" : "OFF",
                      self.taps[0].inverted ? "inverted" : "normal", self.taps[1].inverted ? "inverted" : "normal"))
  end

  def cmd_gap(payload)
    var v = int(payload)
    if v >= 20 && v <= 2000
      self.gap = v
      persist.bus_gap = v
      persist.save()
    end
    tasmota.resp_cmnd_str(str(self.gap))
  end

  def cmd_serial(payload)
    var p = string.split(string.replace(str(payload == nil ? "" : payload), " ", ""), ",")
    if size(p) == 2 && size(p[0]) > 0
      if !self.set_serial(int(p[0]), p[1], nil)
        tasmota.resp_cmnd_str("usage: BusSerial 600,8E1")
        return
      end
    end
    tasmota.resp_cmnd(string.format('{"BusSerial":"%d,%s"}', self.baud, self.fmt))
  end

  def cmd_len(payload)
    if payload != nil && size(str(payload)) > 0
      var v = int(payload)
      if v >= 0 && v <= self.MAX_LEN
        self.flen = v
        persist.bus_len = v
        persist.save()
      end
    end
    tasmota.resp_cmnd_str(str(self.flen))
  end
end

gree_bus = GreeBus()
