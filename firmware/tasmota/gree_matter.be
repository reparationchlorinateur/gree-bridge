# gree_matter.be - Apple Home (Matter) for the Gree bridge (2026-11-13)
#
# Tasmota's Matter "v.HVAC" endpoint makes the board a thermostat in the Apple Home app (or any Matter
# controller). What is set there is sent to the unit by Tasmota itself as an IRHVAC command.
# This script keeps that thermostat telling the truth, from what the board already knows:
#   - the unit's own on/off, mode and setpoint and its room temperature, from the Gree bus
#     (gree_bus.be), so the Home app also shows changes made from Home Assistant or the wall remote;
#     while the bus is quiet (unit off for a while) the room temperature comes from the BME280, which
#     reads the room well when the unit is not blowing over it;
#   - the last complete IR state (Home Assistant's IRhvac commands, the wall remote's frames), so
#     commands from the Home app keep the fan speed and the display (Light option) the unit has.
# It also drives the extra Home app controls Matter's thermostat does not have, by sending IRhvac
# itself (the full last state with one thing changed):
#   - fan speed: a "v.Fan" endpoint, 3 steps = Min / Medium / Max, fan off = Auto;
#   - dry mode: a "v.Relay" endpoint, on = unit in Dry, off = unit off (only when it is in Dry);
#   - swing: a "v.Relay" endpoint, on = louvre sweeping, off = back to the last fixed position.
# Turbo and display are "v.HVAC option" endpoints, handled by Tasmota; BME280 temperature and
# humidity and the outdoor air temperature (bus, "Gree#OutAir") are plain Tasmota sensor endpoints.
# After any IR command or Home app change it waits 15 s before following the bus again, so a
# command on its way is not undone. In Auto the bus shows the mode the unit chose, so Auto is kept
# while the last IR state says Auto. Does nothing while Matter is off.
#
# Set-up, one command in the console:  GreeMatter <room>   (or  GreeMatter <room> fr  for French
# names). It turns Matter on if needed, names the board after the room (FriendlyName1: the bridge
# name the Home app keeps from pairing) and writes all the endpoints with the room in their names,
# so several boards in one house never look the same in the Home app. The board restarts.
# GreeMatterPair 0 / 1 closes / opens the pairing window: an unpaired board opens it by itself after
# every restart and the Home app only lists "Matter Accessory", so pair one board at a time.
# Loaded by autoexec.be after gree_bus.be.

import global

class GreeMatter
  static var VERSION = "2026-11-13"
  static var HOLD_MS = 15000
  # endpoint roles when the configuration has no "gree" key (the numbers GreeMatter writes)
  static var DEFAULT_ROLES = {5: "fan", 6: "dry", 7: "swing"}
  static var NAMES = {
    "en": {"hvac": "%s heat pump", "Light": "%s display", "Turbo": "%s turbo", "fan": "%s fan",
           "dry": "%s dry mode", "swing": "%s swing", "temp": "%s temperature",
           "hum": "%s humidity", "out": "%s outdoor"},
    "fr": {"hvac": "Thermopompe %s", "Light": "Affichage %s", "Turbo": "Turbo %s", "fan": "Ventilation %s",
           "dry": "Déshumidification %s", "swing": "Oscillation %s", "temp": "Température %s",
           "hum": "Humidité %s", "out": "Extérieur %s"}
  }
  var last_ir          # last complete IRHVAC state seen (map), nil until the first one
  var hold_until       # millis: do not follow the bus before this
  var mine             # [mode, cool, heat] as last set here, to notice changes made in the Home app
  var bme_next         # millis: next BME280 read while the bus is quiet
  var set_fan, set_dry, set_swing   # values last written here to the extra endpoints (nil = not yet)
  var fix_swingv       # last fixed louvre position seen in an IR state (what swing off goes back to)

  def init()
    self.hold_until = 0
    self.bme_next = 0
    self.fix_swingv = "Off"
    tasmota.add_rule("IRHVAC", /v -> self.on_ir(v))                 # IRhvac command result
    tasmota.add_rule("IrReceived#IRHVAC", /v -> self.on_ir(v))      # wall remote heard
    tasmota.add_cmd("GreeMatter", /c, i, p -> self.cmd_setup(p))
    tasmota.add_cmd("GreeMatterPair", /c, i, p -> self.cmd_pair(p))
    tasmota.add_driver(self)
    self.pending_setup()
  end

  static def to_matter(m)
    if m == "auto"         return 1
    elif m == "cool"       return 3
    elif m == "heat"       return 4
    elif m == "fan_only"   return 7
    elif m == "dry"        return 8
    end
    return 3
  end

  # the Matter device, or nil while Matter is off (Tasmota creates matter_device even then)
  static def matter()
    var d = global.matter_device
    if d == nil || tasmota.get_option(151) != 1   return nil end
    return d
  end

  def on_ir(v)
    if !isinstance(v, map) || v.find("Vendor") != "GREE"   return end
    self.last_ir = v
    var sv = v.find("SwingV")
    if sv != nil && sv != "Auto"   self.fix_swingv = sv   end
    self.hold_until = tasmota.millis() + self.HOLD_MS
  end

  # ---------------------------------------------------------------- set-up commands
  # The endpoint configuration for a room (map for matter_device.plugins_config)
  static def room_config(room, lang)
    import string
    var n = GreeMatter.NAMES.find(lang, GreeMatter.NAMES["en"])
    def nm(k) return string.format(n[k], room) end
    return {
      "2": {"type": "v_hvac", "name": nm("hvac"), "vendor": "GREE", "model": -1, "min_temp": 16,
            "max_temp": 30, "fan": "Auto", "temp_filter": "Gree#Room"},
      "3": {"type": "v_hvac_option", "name": nm("Light"), "hvac_ep": 2, "option": "Light"},
      "4": {"type": "v_hvac_option", "name": nm("Turbo"), "hvac_ep": 2, "option": "Turbo"},
      "5": {"type": "v_fan", "name": nm("fan"), "gree": "fan"},
      "6": {"type": "v_relay", "name": nm("dry"), "gree": "dry"},
      "7": {"type": "v_relay", "name": nm("swing"), "gree": "swing"},
      "8": {"type": "temperature", "name": nm("temp"), "filter": "BME280#Temperature"},
      "9": {"type": "humidity", "name": nm("hum"), "filter": "BME280#Humidity"},
      "10": {"type": "temperature", "name": nm("out"), "filter": "Gree#OutAir"}
    }
  end

  # "Chambre" / "Chambre fr" / "Salle de bain fr" -> [room, lang]
  static def parse_room(p)
    import string
    p = string.tr(str(p), "\"", "")
    while size(p) > 0 && p[size(p) - 1] == " "   p = (size(p) > 1) ? p[0 .. size(p) - 2] : ""   end
    while size(p) > 0 && p[0] == " "             p = (size(p) > 1) ? p[1 .. size(p) - 1] : ""   end
    var lang = "en"
    if size(p) > 3
      var tail = string.tolower(p[size(p) - 3 .. size(p) - 1])
      if tail == " fr" || tail == " en"
        lang = tail[1 .. 2]
        p = p[0 .. size(p) - 4]
      end
    end
    return [p, lang]
  end

  def cmd_setup(p)
    import json
    var d = self.matter()
    if p == nil || size(str(p)) == 0
      var r = {"Matter": d != nil ? "ON" : "OFF", "Bridge": tasmota.cmd("FriendlyName1", true).find("FriendlyName1"),
               "Version": self.VERSION}
      if d != nil
        var eps = {}
        if d.plugins != nil   for pl: d.plugins   if pl.get_endpoint() > 1   eps[str(pl.get_endpoint())] = pl.TYPE + " " + str(pl.get_name())   end   end   end
        r["Endpoints"] = eps
      end
      tasmota.resp_cmnd(json.dump({"GreeMatter": r}))
      return
    end
    var rl = self.parse_room(p)
    if size(rl[0]) == 0 || size(rl[0]) > 20
      tasmota.resp_cmnd('{"GreeMatter":"room name: 1 to 20 characters"}')
      return
    end
    import persist
    persist.gree_matter_setup = rl
    persist.save()
    if d == nil
      # Matter off: turn it on; the configuration is written after the restart (pending_setup)
      tasmota.resp_cmnd(json.dump({"GreeMatter": {"Room": rl[0], "Matter": "turning on, restarting twice"}}))
      tasmota.set_timer(500, /-> tasmota.cmd("Backlog SetOption151 1; Restart 1"))
      return
    end
    tasmota.resp_cmnd(json.dump({"GreeMatter": {"Room": rl[0], "Names": rl[1], "Restart": true}}))
    tasmota.set_timer(500, /-> self.apply_setup())
  end

  # writes the room's endpoints and bridge name, then restarts
  def apply_setup()
    import persist
    var rl = persist.find("gree_matter_setup")
    var d = self.matter()
    if rl == nil || d == nil   return end
    persist.gree_matter_setup = nil
    persist.save()
    tasmota.cmd("FriendlyName1 " + rl[0], true)
    d.plugins_config = self.room_config(rl[0], rl[1])
    d.adjust_next_ep()
    d.plugins_persist = true
    d.save_param()
    log("GRE: Matter endpoints written for " + rl[0], 2)
    tasmota.set_timer(1000, /-> tasmota.cmd("Restart 1"))
  end

  # a set-up waiting for Matter to start (GreeMatter given while Matter was off)
  def pending_setup()
    import persist
    if persist.find("gree_matter_setup") == nil   return end
    tasmota.set_timer(8000, /-> self.apply_setup())
  end

  def cmd_pair(p)
    var d = self.matter()
    if d == nil   tasmota.resp_cmnd('{"GreeMatterPair":"Matter is off"}')   return end
    var c = d.commissioning
    if p == "0"
      c.stop_basic_commissioning()
    elif p == "1"
      if !c.is_root_commissioning_open()   c.start_root_basic_commissioning()   end
    end
    var is_open = c.is_root_commissioning_open()
    var r = '{"GreeMatterPair":{"Open":' + (is_open ? "true" : "false")
    if is_open   r += ',"Code":"' + str(c.compute_manual_pairing_code()) + '"'   end
    tasmota.resp_cmnd(r + '}}')
  end

  # ---------------------------------------------------------------- endpoints
  # {"hvac": v.HVAC plugin, "opts": [its option plugins], "fan":, "dry":, "swing": plugins or nil} or nil
  def plugins()
    var d = self.matter()
    if d == nil || d.plugins == nil   return nil end
    var r = {"opts": []}
    for pl: d.plugins
      if pl.TYPE == "v_hvac" && r.find("hvac") == nil   r["hvac"] = pl   end
    end
    if r.find("hvac") == nil   return nil end
    var cfg = d.plugins_config
    for pl: d.plugins
      var ep = pl.get_endpoint()
      if pl.TYPE == "v_hvac_option" && pl.hvac_ep == r["hvac"].endpoint
        r["opts"].push(pl)
      elif pl.TYPE == "v_fan" || pl.TYPE == "v_relay"
        var c = (cfg != nil) ? cfg.find(str(ep)) : nil
        var role = (c != nil) ? c.find("gree") : nil
        if role == nil   role = self.DEFAULT_ROLES.find(ep)   end
        if role == "fan" && pl.TYPE == "v_fan"            r["fan"] = pl
        elif (role == "dry" || role == "swing") && pl.TYPE == "v_relay"   r[role] = pl
        end
      end
    end
    return r
  end

  # Fan and options (Light, Turbo...) follow the last IR state; the display is on until one is seen
  def sync_options(hvac, opts)
    if self.last_ir != nil
      var fan = self.last_ir.find("FanSpeed")
      if fan != nil   hvac.ir_fan = fan   end
    end
    for o: opts
      var on = nil
      if self.last_ir != nil
        var v = self.last_ir.find(o.option_name)
        if v != nil   on = (v == "On")   end
      elif o.option_name == "Light"
        on = true
      end
      if on != nil && o.shadow_onoff != on
        o.shadow_onoff = on
        o.attribute_updated(0x0006, 0x0000)
      end
    end
  end

  # IR fan name -> Matter fan mode (0 off = Auto, 1 low = Min, 2 medium, 3 high = Max)
  static def fan_to_matter(f)
    if f == "Min" || f == "Low"           return 1
    elif f == "Medium"                    return 2
    elif f == "Max" || f == "High"        return 3
    end
    return 0
  end
  static def matter_to_fan(m)
    if m == 1   return "Min"   elif m == 2   return "Medium"   elif m >= 3   return "Max"   end
    return "Auto"
  end

  # the full IR state with the changes asked, sent to the unit
  def send_ir(hvac, opts, change)
    import json
    var p = {}
    if self.last_ir != nil   for k: self.last_ir.keys()   p[k] = self.last_ir[k]   end   end
    p["Vendor"] = hvac.ir_vendor
    p["Model"] = hvac.ir_model
    p["Power"] = hvac.shadow_system_mode == 0 ? "Off" : "On"
    p["Mode"] = hvac.mode_to_irhvac()
    p["Celsius"] = "On"
    p["Temp"] = int(hvac.active_setpoint() / 100)
    p["FanSpeed"] = hvac.ir_fan
    if p.find("SwingV") == nil   p["SwingV"] = "Off"   end
    if p.find("SwingH") == nil   p["SwingH"] = "Off"   end
    for o: opts   p[o.option_name] = o.shadow_onoff ? "On" : "Off"   end
    for k: change.keys()   p[k] = change[k]   end
    for k: ["Command", "Protocol", "Bits", "Data", "Repeat", "IRHVAC"]   if p.contains(k)   p.remove(k)   end   end
    var cmd = "IRhvac " + json.dump(p)
    log("GRE: Matter " + cmd, 2)
    tasmota.cmd(cmd, true)
    self.hold_until = tasmota.millis() + self.HOLD_MS
  end

  static def set_relay(pl, on)
    if pl.shadow_onoff != on
      pl.shadow_onoff = on
      pl.attribute_updated(0x0006, 0x0000)
    end
  end

  # the fan, dry and swing endpoints: Home app changes are sent, otherwise they show the unit's state
  def sync_extras(p)
    var hvac = p["hvac"]
    var opts = p["opts"]
    var fan = p.find("fan")
    var dry = p.find("dry")
    var swing = p.find("swing")
    # changes made in the Home app (the endpoint no longer shows what was last written here)
    if fan != nil && self.set_fan != nil && fan.shadow_fan_mode != self.set_fan
      hvac.ir_fan = self.matter_to_fan(fan.shadow_fan_mode)
      self.set_fan = fan.shadow_fan_mode
      self.send_ir(hvac, opts, {"FanSpeed": hvac.ir_fan})
    end
    if dry != nil && self.set_dry != nil && dry.shadow_onoff != self.set_dry
      self.set_dry = dry.shadow_onoff
      if dry.shadow_onoff
        hvac.set_system_mode(8)
        self.send_ir(hvac, opts, {"Power": "On", "Mode": "Dry"})
      elif hvac.shadow_system_mode == 8
        hvac.set_system_mode(0)
        self.send_ir(hvac, opts, {"Power": "Off"})
      end
      self.mine = [hvac.shadow_system_mode, hvac.shadow_cooling_setpoint, hvac.shadow_heating_setpoint]
    end
    if swing != nil && self.set_swing != nil && swing.shadow_onoff != self.set_swing
      self.set_swing = swing.shadow_onoff
      self.send_ir(hvac, opts, {"SwingV": swing.shadow_onoff ? "Auto" : self.fix_swingv})
    end
    # show the state
    if fan != nil
      var m = self.fan_to_matter(hvac.ir_fan)
      if fan.shadow_fan_mode != m   fan.set_fan_mode(m)   end
      self.set_fan = fan.shadow_fan_mode
    end
    if dry != nil
      self.set_relay(dry, hvac.shadow_system_mode == 8)
      self.set_dry = dry.shadow_onoff
    end
    if swing != nil
      self.set_relay(swing, self.last_ir != nil && self.last_ir.find("SwingV") == "Auto")
      self.set_swing = swing.shadow_onoff
    end
  end

  def set_room(hvac, c)
    var t = int(c * 100 + (c < 0 ? -0.5 : 0.5))
    if t != hvac.shadow_local_temperature
      hvac.shadow_local_temperature = t
      hvac.attribute_updated(0x0201, 0x0000)
    end
  end

  # BME280 temperature (C) from Tasmota's sensors, or nil
  def bme_temp()
    import json
    var s = json.load(tasmota.read_sensors())
    if !isinstance(s, map)   return nil end
    var b = s.find("BME280")
    if !isinstance(b, map)   return nil end
    var t = b.find("Temperature")
    if t == nil   return nil end
    t = real(t)
    if s.find("TempUnit") == "F"   t = (t - 32) / 1.8   end
    return t
  end

  def every_second()
    var p = self.plugins()
    if p == nil   return end
    var hvac = p["hvac"]
    self.sync_options(hvac, p["opts"])
    self.sync_extras(p)

    var g = global.gree_bus
    var now = tasmota.millis()
    var ind = (g != nil) ? g.indoor : nil
    var link = (ind != nil && ind.last_ok != nil) ? ind.link(now) : "NONE"

    if link == "OK" && ind.room != nil                  # room temperature: unit's own sensor
      self.set_room(hvac, ind.room)
    elif now >= self.bme_next                           # bus quiet: BME280, every 30 s
      self.bme_next = now + 30000
      var t = self.bme_temp()
      if t != nil   self.set_room(hvac, t)   end
    end
    if link == "NONE"   return end

    # changed in the Home app (Tasmota already sent the IR): give the unit time
    var cur = [hvac.shadow_system_mode, hvac.shadow_cooling_setpoint, hvac.shadow_heating_setpoint]
    if self.mine != nil && (cur[0] != self.mine[0] || cur[1] != self.mine[1] || cur[2] != self.mine[2])
      self.hold_until = now + self.HOLD_MS
      self.mine = cur
    end
    if now < self.hold_until || link == "LOST"   return end

    var mode = 0
    if ind.power
      mode = self.to_matter(ind.mode)
      if self.last_ir != nil && self.last_ir.find("Power") == "On" && self.last_ir.find("Mode") == "Auto"
        mode = 1
      end
    end
    var sp = ind.setpoint * 100
    if mode == 4
      hvac.set_heating_setpoint(sp)
    elif mode != 0 && mode != 1
      hvac.set_cooling_setpoint(sp)
    end
    hvac.set_system_mode(mode)
    self.mine = [hvac.shadow_system_mode, hvac.shadow_cooling_setpoint, hvac.shadow_heating_setpoint]
  end
end

gree_matter = GreeMatter()
