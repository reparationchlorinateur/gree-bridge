# Firmware

The board runs **Tasmota 15.6.0** (custom ESP32-S3 build, in [`build/`](build/)) plus two Berry scripts that are uploaded to its file system. The scripts are the same on every board; each board only differs by its settings (Wi-Fi, `DeviceName`, `Topic`, passwords).

Step-by-step setup: [docs/install.md](../docs/install.md).

## Files

| File | What it is |
|---|---|
| [`build/gree_tasmota32s3_15.6.0.factory.bin`](build/) | First flash of a blank board, at address 0x0 |
| [`build/gree_tasmota32s3_15.6.0.bin`](build/) | Updates from the board's web page (Firmware Upgrade) |
| [`build/user_config_override.h`](build/user_config_override.h) | The build options; how to rebuild: [`build/README.md`](build/README.md) |
| [`tasmota/gree_bus.be`](tasmota/gree_bus.be) | Bus decoder: indoor frames and outdoor replies on both taps, main-page rows, MQTT `tele/<topic>/GREE`, Home Assistant discovery, polarity auto-detect |
| [`tasmota/gree_matter.be`](tasmota/gree_matter.be) | Apple Home (Matter) glue: keeps Tasmota's Matter thermostat (v.HVAC) in line with the bus and the last IR command. Idle until Matter is turned on |
| [`tasmota/autoexec.be`](tasmota/autoexec.be) | Loads both scripts at boot |
| [`tasmota/template.json`](tasmota/template.json) | GPIO template |
| [`tests/`](tests/) | Host tests for both scripts, with mocks of the Tasmota API |

## Console commands (`gree_bus.be`)

Also over MQTT as `cmnd/<topic>/<command>`. Values marked "saved" survive a restart.

| Command | What it does |
|---|---|
| `Gree` | Current decoded values (JSON) |
| `GreeInterval <s>` | Minimum seconds between publishes when only temperatures change (default 10, saved) |
| `GreeDiscovery 0\|1` | Home Assistant discovery off (removes the entities) / on (default 1, saved). No value = publish again and show the device name and id |
| `BusAuto 0\|1` | Switch a tap's polarity by itself when bytes arrive but no valid frame decodes for 20 s, and save the polarity that works (default 1, saved). No value = show the status and the current polarities |
| `BusPublish 0\|1` | Also publish raw frames to `tele/<topic>/BUS_RX` and `BUS_TX` (default 0, saved) |
| `BusGap <ms>` | Silence that ends a raw frame (default 300, saved) |
| `BusLen <n>` | Fixed raw frame length, 0 = split on silence (default 0, saved) |

Raw frames are written to the log at level 3: `Weblog 3` shows them in the web console (`Weblog 2` to go back).

## MQTT output

`tele/<topic>/GREE`, on every change of power, mode, setpoint, fan or link, at most every `GreeInterval` seconds for temperature-only changes, and at least once a minute:

```json
{"Gree":{"Room":20.5,"Coil":7.9,"CoilRaw":79,"Power":"ON","Mode":"cool","Setpoint":22,"Fan":3,"Link":"OK",
 "CompHz":46,"CompA":1.90,"PowerW":478,"OutCoil":27.5,"OutAir":7.9,"DischC":34.6,"OutMode":"cool","DischRaw":84,
 "LoadRaw":38,"Out":[46,1,0,135,84,79,38,1],"OutLink":"OK"}}
```

- `Link` / `OutLink`: `OK` while valid frames arrive; after 10 s without one, `STANDBY` if the unit was off (normal, the indoor unit stops polling after a while) or `LOST` if it was on.
- While a link is not OK, its measured values are `null` (compressor values 0 in `STANDBY`), so Home Assistant never repeats old readings or counts energy from them.
- Field meanings: [docs/protocol.md](../docs/protocol.md).

The IR side is plain Tasmota: `IrReceived` messages on `tele/<topic>/RESULT` for wall-remote presses, and the `IRhvac` command to send.

## Apple Home glue (`gree_matter.be`)

Tasmota's Matter v.HVAC thermostat sends IR commands by itself, but it only knows what it sent. `gree_matter.be` fills in the rest:
- the thermostat's mode, setpoint and room temperature follow the unit's real state from the bus, about 15 s after a change made with the wall remote or Home Assistant;
- the room temperature comes from the unit's sensor, or from the BME280 once the bus has been silent for a while (unit off);
- the fan speed and display state the Home app sends are the ones from the last IR command, so a Home app change does not reset them.

It never sends IR itself. It does nothing until Matter is on (`SetOption151 1`) and a v.HVAC endpoint exists.

## Tests

The scripts are tested on a computer with the [Berry](https://github.com/berry-lang/berry) interpreter and small mocks of the Tasmota API (`persist.be`, `mqtt.be`, and mocks inside the test files). Build Berry, then from the `tests/` folder:

```
berry test_gree_bus.be      # 65 tests: indoor and outdoor frames, links, polarity, discovery, commands
berry test_gree_matter.be   # 20 tests: mode and setpoint mapping, hold logic, fan and display, room temperature
```

`test_gree_bus.be` also replays real captured frames.
