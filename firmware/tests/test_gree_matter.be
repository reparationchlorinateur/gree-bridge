# Host test for gree_matter.be with mocks (Tasmota, Matter plugins copied from v15.6.0 setters, bus)
NOW = 0
FAILED = false
UPDATES = []
IRSENT = 0
CMDS = []
RESP = []
TIMERS = []
LOGS = []
def log(m, l) LOGS.push(m) end
class MockTasmota
  var rules, drivers, cmds
  def init() self.rules = {} self.drivers = [] self.cmds = {} end
  def add_rule(p, f) self.rules[p] = f end
  def add_driver(d) self.drivers.push(d) end
  def add_cmd(n, f) self.cmds[n] = f end
  def set_timer(ms, f) TIMERS.push(f) end
  def resp_cmnd(s) RESP.push(s) end
  def cmd(c, q)
    CMDS.push(c)
    if c == "FriendlyName1" return {"FriendlyName1": "Tasmota"} end
    return {}
  end
  def millis() return NOW end
  var opt151
  def get_option(n) return (n == 151) ? (self.opt151 == nil ? 1 : self.opt151) : 0 end
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
  def active_setpoint() return self.shadow_system_mode == 4 ? self.shadow_heating_setpoint : self.shadow_cooling_setpoint end
  def mode_to_irhvac()
    var m = self.shadow_system_mode
    if m == 4 return "Heat" elif m == 1 return "Auto" elif m == 7 return "Fan" elif m == 8 return "Dry" end
    return "Cool"
  end
  var ir_vendor, ir_model
  def get_endpoint() return self.endpoint end
  def get_name() return "hp" end
end
class Fan : Plug
  static var TYPE = "v_fan"
  var shadow_fan_mode
  def init(ep) self.endpoint = ep self.shadow_fan_mode = 0 end
  def set_fan_mode(m) if m != self.shadow_fan_mode self.shadow_fan_mode = m self.attribute_updated(0x0202, 0) end end
  def get_endpoint() return self.endpoint end
  def get_name() return "fan" end
end
class Relay : Plug
  static var TYPE = "v_relay"
  var shadow_onoff
  def init(ep) self.endpoint = ep self.shadow_onoff = false end
  def get_endpoint() return self.endpoint end
  def get_name() return "relay" end
end
class Opt : Plug
  static var TYPE = "v_hvac_option"
  var hvac_ep, option_name, shadow_onoff
  def init(name) self.endpoint = 3 self.hvac_ep = 2 self.option_name = name self.shadow_onoff = false end
  def get_endpoint() return self.endpoint end
  def get_name() return "opt" end
end
class Comm
  var open
  def init() self.open = true end
  def stop_basic_commissioning() self.open = false end
  def start_root_basic_commissioning() self.open = true end
  def is_root_commissioning_open() return self.open end
  def compute_manual_pairing_code() return "00553552784" end
end
class Dev
  var plugins, plugins_config, plugins_persist, saved, commissioning
  def init() self.saved = 0 self.commissioning = Comm() end
  def adjust_next_ep() end
  def save_param() self.saved += 1 end
end
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

check("thermostat sync never sends IR", IRSENT == 0 && size(CMDS) == 0)

# ---- extra endpoints: fan, dry, swing (2026-11-13)
import json
var fan = Fan(5), dry = Relay(6), sw = Relay(7)
hv.ir_vendor = "GREE" hv.ir_model = -1
dev.plugins = [hv, lt, fan, dry, sw]
dev.plugins_config = {"5": {"type": "v_fan"}, "6": {"type": "v_relay", "gree": "dry"}, "7": {"type": "v_relay", "gree": "swing"}}
ind.lnk = "OK" ind.power = true ind.mode = "cool" ind.setpoint = 20
tasmota.rules["IRHVAC"]({"Vendor": "GREE", "Power": "On", "Mode": "Cool", "Temp": 20, "FanSpeed": "Medium", "SwingV": "Middle", "Light": "On"})
tick(16)
check("fan shows Medium = 2", fan.shadow_fan_mode == 2)
check("dry off while cooling", dry.shadow_onoff == false)
check("swing off (fixed Middle)", sw.shadow_onoff == false)
check("still no IR", size(CMDS) == 0)

def last_ir() var c = CMDS[-1] return json.load(c[7 ..]) end
# Home app: fan to 3 (Max)
fan.shadow_fan_mode = 3
tick(1)
check("fan change sends one IRhvac", size(CMDS) == 1 && CMDS[0][0 .. 6] == "IRhvac ")
var ir = last_ir()
check("fan Max sent, rest kept", ir["FanSpeed"] == "Max" && ir["Mode"] == "Cool" && ir["Temp"] == 20 && ir["SwingV"] == "Middle" && ir["Light"] == "On" && ir["Power"] == "On")
check("thermostat fan follows", hv.ir_fan == "Max")
tasmota.rules["IRHVAC"](ir)
tick(2)
check("no resend", size(CMDS) == 1)
# Home app: fan off = Auto
fan.shadow_fan_mode = 0
tick(1)
check("fan off -> Auto", last_ir()["FanSpeed"] == "Auto" && size(CMDS) == 2)
tasmota.rules["IRHVAC"](last_ir())
# Home app: swing on
sw.shadow_onoff = true
tick(1)
check("swing on -> SwingV Auto", last_ir()["SwingV"] == "Auto" && size(CMDS) == 3)
tasmota.rules["IRHVAC"](last_ir())
tick(1)
check("swing shows on", sw.shadow_onoff == true)
sw.shadow_onoff = false
tick(1)
check("swing off -> back to Middle", last_ir()["SwingV"] == "Middle" && size(CMDS) == 4)
tasmota.rules["IRHVAC"](last_ir())
# Home app: dry on
dry.shadow_onoff = true
tick(1)
ir = last_ir()
check("dry on -> Power On Mode Dry", ir["Mode"] == "Dry" && ir["Power"] == "On" && size(CMDS) == 5)
check("thermostat shows dry (8)", hv.shadow_system_mode == 8)
tasmota.rules["IRHVAC"](ir)
ind.mode = "dry"
tick(20)
check("bus dry: stays dry, relay on", hv.shadow_system_mode == 8 && dry.shadow_onoff == true && size(CMDS) == 5)
dry.shadow_onoff = false
tick(1)
check("dry off -> Power Off", last_ir()["Power"] == "Off" && size(CMDS) == 6 && hv.shadow_system_mode == 0)
tasmota.rules["IRHVAC"](last_ir())
ind.power = false
tick(20)
check("unit off: relay off, no more IR", dry.shadow_onoff == false && size(CMDS) == 6)
# dry off while heating does nothing
ind.power = true ind.mode = "heat" ind.setpoint = 21
tasmota.rules["IrReceived#IRHVAC"]({"Vendor": "GREE", "Power": "On", "Mode": "Heat", "Temp": 21, "FanSpeed": "Auto"})
tick(20)
check("heat followed", hv.shadow_system_mode == 4 && dry.shadow_onoff == false)
check("remote heard: no IR sent", size(CMDS) == 6)

# ---- Matter off: the device exists (Tasmota creates it) but nothing is touched
tasmota.opt151 = 0
var sent0 = size(CMDS)
fan.shadow_fan_mode = 1
tick(2)
check("Matter off: no IR, no crash", size(CMDS) == sent0)
tasmota.cmds["GreeMatter"]("GreeMatter", 0, "")
check("Matter off: status says OFF", json.load(RESP[-1])["GreeMatter"]["Matter"] == "OFF")
tasmota.cmds["GreeMatter"]("GreeMatter", 0, "Diner fr")
check("Matter off: turns it on", json.load(RESP[-1])["GreeMatter"]["Matter"] == "turning on, restarting twice")
for f: TIMERS f() end TIMERS = []
check("SetOption151 1 sent", CMDS[-1] == "Backlog SetOption151 1; Restart 1")
gm.apply_setup()
check("Matter still off: setup waits", dev.plugins_config.find("2") == nil)
import persist
persist.gree_matter_setup = nil
tasmota.opt151 = 1
fan.shadow_fan_mode = 0
tick(1)
CMDS = []

# ---- set-up command
check("parse 'Chambre'", gm.parse_room("Chambre")[0] == "Chambre" && gm.parse_room("Chambre")[1] == "en")
check("parse ' Sous-sol fr '", gm.parse_room(" Sous-sol fr ")[0] == "Sous-sol" && gm.parse_room(" Sous-sol fr ")[1] == "fr")
check("parse 'Salle de bain FR'", gm.parse_room("Salle de bain FR")[0] == "Salle de bain")
var rc = gm.room_config("Chambre", "fr")
check("config names carry the room", rc["2"]["name"] == "Thermopompe Chambre" && rc["6"]["name"] == "Déshumidification Chambre" && rc["10"]["filter"] == "Gree#OutAir")
check("config roles", rc["5"]["gree"] == "fan" && rc["7"]["gree"] == "swing" && rc["4"]["option"] == "Turbo")
check("english names", gm.room_config("Salon", "en")["5"]["name"] == "Salon fan")
CMDS = []
tasmota.cmds["GreeMatter"]("GreeMatter", 0, "Chambre fr")
check("setup answers", size(RESP) > 0 && json.load(RESP[-1])["GreeMatter"]["Room"] == "Chambre")
for f: TIMERS f() end TIMERS = []
check("FriendlyName1 set", CMDS[0] == "FriendlyName1 Chambre")
check("config written and saved", dev.plugins_config["2"]["name"] == "Thermopompe Chambre" && dev.plugins_persist == true && dev.saved == 1)
for f: TIMERS f() end TIMERS = []
check("restart", CMDS[-1] == "Restart 1")
tasmota.cmds["GreeMatterPair"]("GreeMatterPair", 0, "0")
check("pair 0 closes", json.load(RESP[-1])["GreeMatterPair"]["Open"] == false)
tasmota.cmds["GreeMatterPair"]("GreeMatterPair", 0, "1")
check("pair 1 opens with code", json.load(RESP[-1])["GreeMatterPair"]["Code"] == "00553552784")
print(FAILED ? "SOME TESTS FAILED" : "ALL PASS")
