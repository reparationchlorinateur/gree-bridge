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
| [`tasmota/gree_tools.be`](tasmota/gree_tools.be) | Optional "Gree tools" page: IR brand detection, bus speed / format / polarity detection, captures for decoding other units ([docs/adapting.md](../docs/adapting.md)) |
| [`tasmota/autoexec.be`](tasmota/autoexec.be) | Loads the scripts at boot (`gree_tools.be` only if it is on the board) |
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
| `BusSerial <baud>,<format>` | Serial settings of both taps, e.g. `BusSerial 600,8E1` (default, saved). For other units; `BusDetect apply` sets it |

## Console commands (`gree_tools.be`)

| Command | What it does |
|---|---|
| `IrDetect` | Brand, model and protocol of the wall remote as decoded by Tasmota (press any button on the remote first); `IrDetect 0` forgets it |
| `BusDetect` | Measures speed, format and polarity of both taps (about 5 s, bus decoder paused). Result in the console, on the Gree tools page and as `{"BusDetect":...}` on `stat/<topic>/RESULT` |
| `BusDetect apply` | Uses the detected settings; turns `BusAuto` off when they are not Gree's 600 8E1 |
| `GreeCapture <s>` | One capture of `<s>` seconds now (1 to 600) |
| `GreeCapture <s>,<every>,<n>` | `<n>` captures of `<s>` seconds, one every `<every>` seconds |
| `GreeCapture startup` | Waits for the next IR command (wall remote, Home Assistant or Apple Home), keeps the 3 s before it, captures 5 s, then 5 s again 1, 2 and 3 minutes later |
| `GreeCapture stop` / `GreeCapture` | Ends the capture / shows its status |
| `GreeMark <text>` | Writes a note into the running capture |

Captures go to `/gree_capture.txt` (the previous one to `/gree_capture_prev.txt`), one line per event: `<ms> RX|TX|IR|IRHVAC|GREE|MARK <data>`, comments start with `#`. Every line is also printed in the console (`CAP: ...`). Format and how to use them: [docs/adapting.md](../docs/adapting.md).

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
berry test_gree_bus.be          # 74 tests: indoor and outdoor frames, links, polarity, discovery, commands, hooks
berry test_gree_matter.be       # 20 tests: mode and setpoint mapping, hold logic, fan and display, room temperature
berry test_gree_tools.be        # 46 tests: speed detection on simulated lines (300-9600 baud, 7/8 bits, parity),
                                #           IR brand, captures (single, sequence, start-up), web page
berry test_gree_integration.be  # 10 tests: gree_bus.be + gree_tools.be together
```

`test_gree_bus.be` also replays real captured frames. The mocks are `persist.be`, `mqtt.be`, `gpio.be` (pin levels from a simulated line), `path.be` and `webserver.be`.
