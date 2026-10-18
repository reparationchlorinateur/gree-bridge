# Host test for gree_matter.be with mocks (Tasmota, Matter plugins copied from v15.6.0 setters, bus)
NOW = 0
FAILED = false
UPDATES = []
IRSENT = 0
class MockTasmota
  var rules, drivers
  def init() self.rules = {} self.drivers = [] end
  def add_rule(p, f) self.rules[p] = f end
  def add_driver(d) self.drivers.push(d) end
  def millis() return NOW end
  def read_sensors() return '{"Time":"x","BME280":{"Temperature":18.9,"Humidity":60.3},"TempUnit":"C"}' end
end
tasmota = MockTasmota()

class Plug
  var endpoint
  def attribute_updated(c, a) UPDATES.push([self.endpoint, c, a]) end
end
class Hvac : Plug
  static var TYPE = "v_hvac"
  var shadow_local_temperature, shadow_cooling_setpoint, shadow_heating_setpoint, shadow_system_mode, ir_fan
  def init() self.endpoint = 2 self.shadow_cooling_setpoint = 2400 self.shadow_heating_setpoint = 2000 self.shadow_system_mode = 0 self.ir_fan = "Auto" end
  def clamp_temp(t) t = int(t) if t < 1600 t = 1600 end if t > 3000 t = 3000 end return t end
  def set_system_mode(mode) mode = int(mode) if mode != self.shadow_system_mode self.shadow_system_mode = mode self.attribute_updated(0x0201, 0x1C) end return true end
  def set_cooling_setpoint(t) t = self.clamp_temp(t) if t != self.shadow_cooling_setpoint self.shadow_cooling_setpoint = t self.attribute_updated(0x0201, 0x11) end end
  def set_heating_setpoint(t) t = self.clamp_temp(t) if t != self.shadow_heating_setpoint self.shadow_heating_setpoint = t self.attribute_updated(0x0201, 0x12) end end
  def send_irhvac() IRSENT += 1 end
end
class Opt : Plug
  static var TYPE = "v_hvac_option"
  var hvac_ep, option_name, shadow_onoff
  def init(name) self.endpoint = 3 self.hvac_ep = 2 self.option_name = name self.shadow_onoff = false end
end
class Dev var plugins end
class Ind
  var room, power, mode, setpoint, last_ok, lnk
  def link(now) return self.lnk end
end
class Bus var indoor end

import global
global.matter_device = nil
global.gree_bus = nil
var f0 = open("../tasmota/gree_matter.be") var src0 = f0.read() f0.close() compile(src0)()
var gm = global.gree_matter
def tick(n) for i: 1..n NOW += 1000 gm.every_second() end end
def check(name, cond) print((cond ? "PASS " : "FAIL ") + name) if !cond FAILED = true end end
FAILED = false

# no Matter yet: nothing happens
tick(2)
check("no matter device: no crash", true)

var hv = Hvac(), lt = Opt("Light")
var dev = Dev() dev.plugins = [hv, lt]
global.matter_device = dev
tick(1)
check("display on before any IR", lt.shadow_onoff == true)
check("no bus yet: room temp from BME280", hv.shadow_local_temperature == 1890)
check("no bus yet: mode untouched", hv.shadow_system_mode == 0)

var ind = Ind() ind.room = 18.5 ind.power = false ind.mode = "cool" ind.setpoint = 16 ind.last_ok = 1 ind.lnk = "STANDBY"
var bus = Bus() bus.indoor = ind
global.gree_bus = bus
tick(1)
check("unit off -> mode 0", hv.shadow_system_mode == 0)
check("STANDBY keeps BME280 room temp", hv.shadow_local_temperature == 1890)
ind.lnk = "OK"
tick(1)
check("room temp 18.5 -> 1850", hv.shadow_local_temperature == 1850)

# remote turns the unit on Cool 19, IR heard
tasmota.rules["IrReceived#IRHVAC"]({"Vendor": "GREE", "Power": "On", "Mode": "Cool", "Temp": 19, "FanSpeed": "Max", "Light": "Off", "Turbo": "On"})
ind.power = true ind.mode = "cool" ind.setpoint = 19
tick(5)
check("held for 15 s after IR", hv.shadow_system_mode == 0)
check("fan follows IR", hv.ir_fan == "Max")
check("display follows IR (off)", lt.shadow_onoff == false)
tick(11)
check("after hold: cool", hv.shadow_system_mode == 3)
check("cooling setpoint 1900", hv.shadow_cooling_setpoint == 1900)

# Home app sets heat 22 (plugin writes its shadow and sends IR itself)
hv.set_system_mode(4) hv.set_heating_setpoint(2200)
tick(3)
check("Home app change held (bus still cool)", hv.shadow_system_mode == 4 && hv.shadow_heating_setpoint == 2200)
ind.mode = "heat" ind.setpoint = 22
tick(14)
check("follows bus heat 22", hv.shadow_system_mode == 4 && hv.shadow_heating_setpoint == 2200)

# remote missed: unit switched off, nothing heard
ind.power = false
tick(1)
check("unit off followed at once (no hold)", hv.shadow_system_mode == 0)

# Auto from HA: IRhvac result, bus shows cool 20
tasmota.rules["IRHVAC"]({"Vendor": "GREE", "Power": "On", "Mode": "Auto", "Temp": 25, "FanSpeed": "Auto", "Light": "On"})
ind.power = true ind.mode = "cool" ind.setpoint = 20
tick(16)
check("Auto kept while unit runs", hv.shadow_system_mode == 1)
check("display back on", lt.shadow_onoff == true)

# bus lost while running: keep
ind.lnk = "LOST" ind.power = true ind.mode = "heat"
tick(2)
check("LOST: unchanged", hv.shadow_system_mode == 1)

check("never sends IR", IRSENT == 0)
print(FAILED ? "SOME TESTS FAILED" : "ALL PASS")
