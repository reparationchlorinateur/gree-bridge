# gree_matter.be - Apple Home (Matter) for the Gree bridge (2026-10-17)
#
# Tasmota's Matter "v.HVAC" endpoint makes the board a thermostat in the Apple Home app (or any Matter
# controller). What is set there is sent to the unit by Tasmota itself as an IRHVAC command.
# This script only keeps that thermostat telling the truth, from what the board already knows:
#   - the unit's own on/off, mode and setpoint and its room temperature, from the Gree bus
#     (gree_bus.be), so the Home app also shows changes made from Home Assistant or the wall remote;
#     while the bus is quiet (unit off for a while) the room temperature comes from the BME280, which
#     reads the room well when the unit is not blowing over it;
#   - the last complete IR state (Home Assistant's IRhvac commands, the wall remote's frames), so
#     commands from the Home app keep the fan speed and the display (Light option) the unit has.
# It never sends IR. After any IR command or Home app change it waits 15 s before following the bus
# again, so a command on its way is not undone. In Auto the bus shows the mode the unit chose, so
# Auto is kept while the last IR state says Auto. Does nothing while Matter is off.
#
# Matter endpoints (Configuration > Matter): one "v.HVAC" (Vendor GREE, Temp sensor "Gree#Room" so the
# Home app shows a room temperature) and one "v.HVAC option" (HVAC endpoint = that endpoint number,
# Option Light) for the display. Loaded by autoexec.be after gree_bus.be.

import global

class GreeMatter
  static var HOLD_MS = 15000
  var last_ir          # last complete IRHVAC state seen (map), nil until the first one
  var hold_until       # millis: do not follow the bus before this
  var mine             # [mode, cool, heat] as last set here, to notice changes made in the Home app
  var bme_next         # millis: next BME280 read while the bus is quiet

  def init()
    self.hold_until = 0
    self.bme_next = 0
    tasmota.add_rule("IRHVAC", /v -> self.on_ir(v))                 # IRhvac command result
    tasmota.add_rule("IrReceived#IRHVAC", /v -> self.on_ir(v))      # wall remote heard
    tasmota.add_driver(self)
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

  def on_ir(v)
    if !isinstance(v, map) || v.find("Vendor") != "GREE"   return end
    self.last_ir = v
    self.hold_until = tasmota.millis() + self.HOLD_MS
  end

  # [v.HVAC plugin, [its option plugins]] or nil
  def plugins()
    var d = global.matter_device
    if d == nil || d.plugins == nil   return nil end
    var hvac = nil
    for pl: d.plugins
      if pl.TYPE == "v_hvac"   hvac = pl   break   end
    end
    if hvac == nil   return nil end
    var opts = []
    for pl: d.plugins
      if pl.TYPE == "v_hvac_option" && pl.hvac_ep == hvac.endpoint   opts.push(pl)   end
    end
    return [hvac, opts]
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
    var hvac = p[0]
    self.sync_options(hvac, p[1])

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
