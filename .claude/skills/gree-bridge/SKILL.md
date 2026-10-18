---
name: gree-bridge
description: Build, install, troubleshoot and adapt the Gree bridge, an ESP32-S3 board running Tasmota that sits inside a mini-split indoor unit, drives the unit's IR receiver line and listens to the indoor/outdoor communication bus, for Home Assistant and Apple Home (Matter). Use it whenever someone is flashing or configuring a Gree bridge board, wiring it to an indoor unit's control board, setting up the Home Assistant package or Apple Home pairing, debugging missing bus frames or IR, using the board's Gree tools page (IR brand detection, BusDetect, GreeCapture), or decoding a gree_capture.txt or raw bus bytes to support another AC model or brand, even if they only paste hex bytes or a capture file and never say "Gree bridge".
---

# Gree bridge

The Gree bridge is a small ESP32-S3 board (rev B) that plugs into the logic side of a mini-split's indoor control board with one 5-wire cable (J1): +12 V, the IR receiver's data line, two high-impedance taps on the indoor/outdoor communication optocouplers, and ground. It runs Tasmota 15.6.0 plus Berry scripts:

- `gree_bus.be` decodes the Gree indoor/outdoor bus (600 baud 8E1 on a Gree GWH12KF / board GRJ819-A3) and publishes it to Home Assistant by MQTT discovery;
- `gree_matter.be` keeps Tasmota's Matter thermostat (Apple Home) in line with the bus;
- `gree_tools.be` adds the "Gree tools" page: IR brand detection, bus speed / format / polarity detection and captures, used to adapt the board to other units.

Control is by IR on the unit's own receiver line, so it works with any brand Tasmota's IR library knows. Reading the unit's real state needs a decoder for that unit's bus, which is what the capture workflow is for.

## Safety comes first

The person is working inside an appliance that has mains voltage and a ~56 V communication loop on the same board as the logic side. Mistakes there can kill or start a fire, so these are not negotiable, whatever the person asks:

- Breaker off before opening the unit and before any soldering, plugging or unplugging. Capacitors stay charged for a while.
- Only the logic side: logic `GND` (never `GND/` or anything past the isolation slots), the IR receiver output, the logic-side pins of the optocouplers. Before connecting anything, the logic ground must measure open (megohms) to N and to L, power off.
- With the unit powered: voltmeter or scope only, probe ground on logic ground, no soldering. Never connect a computer to the board's programming header (J5) while it is in a powered unit; flash on the bench.
- If a step needs the hot side, or the person is unsure which side a point is on, stop and say so. Ask for a photo of the board (power off) and point at the parts; on GRJ819-A3 the hot side is marked with a lightning symbol and `GND/`, `DC+`.

Full text: `references/SAFETY.md`. Repeat the relevant rule at the moment it applies (before wiring, before probing), briefly; people skim long warnings.

## Find your way

When the repository is available (Claude Code in the cloned repo), the authoritative files are there: `docs/`, `firmware/`, `homeassistant/`, `hardware/`. The `references/` folder of this skill holds copies of the docs for use without the repository (the Claude app):

| Task | Read |
|---|---|
| Flash, configure, wire, Home Assistant, Apple Home, no Home Assistant, updates, troubleshooting table | `references/install.md` |
| Console commands, MQTT output, the scripts, the Gree tools commands, tests | `references/firmware.md` |
| The Gree bus: frame layouts, field meanings, NTC formulas, tap points on GRJ819-A3 | `references/protocol.md` |
| Another unit or brand: tap points, IR brand, BusDetect, capture plan, decoding, sharing | `references/adapting.md` |
| Board hardware: connectors, circuit, BOM, assembly | `references/hardware.md` |
| A capture file to look at | run `scripts/analyze_capture.py` (below) |

Read the one that matches the task; don't load everything up front. The two pictures the docs refer to are in `assets/images/`: `j1_wiring.png` (where each J1 wire goes) and `gree_board_taps.jpg` (tap points and hot side on GRJ819-A3); show or describe them when the person wires the board, since "top-left pin" only makes sense with the photo.

The tap points in the docs are for the Gree GRJ819-A3 indoor board (GWH12KF units of about 2013). For any other model or year, ask for the indoor board's label and a photo (power off) before giving wiring steps, and use `references/adapting.md` if it differs. Fixed-speed (non-inverter) units may have no data bus at all: IR only.

## Working with the person

Many people doing this are handy but not firmware developers. Ask for what you need to know before giving steps: the unit's model number, the indoor board's label, what is already done (flashed? wired? Home Assistant?), and what they see. Give one stage at a time with the exact console lines, and ask them to report what the board shows before moving on. Prefer the board's web page and console over custom tooling.

If they want to do it all in one evening, give the whole plan in order (bench flash and setup, then breaker off for wiring, then breaker on to test), so they can see the end, but keep the gates: wiring only with the breaker off, and the bus taps only once the tap points are confirmed for their board. IR alone (three wires) is a good first evening.

If you can reach the board over the network yourself (Claude Code on their LAN), you can run console commands through Tasmota's HTTP API, with the web password if one is set:

```
curl -s -u admin:<WebPassword> "http://<board ip>/cm?cmnd=BusDetect"
curl -s -u admin:<WebPassword> "http://<board ip>/cm?cmnd=GreeCapture%205"
curl -s -u admin:<WebPassword> -o gree_capture.txt "http://<board ip>/ufsd?download=/gree_capture.txt"
```

Ask before sending commands that make the unit do something (IRhvac, BusDetect apply). Reading status (`Gree`, `IrDetect`, `BusSerial`, `BusAuto`) is harmless.

## Adapting to another unit (summary)

Details and the reasons behind each step are in `references/adapting.md`.

1. **Tap points** on the new board, logic side only, measured with the unit running (voltmeter or scope). IR first: IR alone already gives control.
2. **IR brand**: press the wall remote; the Gree tools page (or `IrDetect`) shows the brand, model and protocol Tasmota decoded. That brand goes into the Home Assistant package (`protocol:`) and the Matter endpoint (vendor). Not recognised: make a capture, which records raw IR timings.
3. **Bus**: unit on, `BusDetect` (Gree tools page: Detect speed and format). It reports baud, format (8E1, 8N1, ...), polarity, sample bytes and bytes per burst. `BusDetect apply` uses them.
4. **Captures**: the start-up sequence (`GreeCapture startup`, then switch the unit on with the remote in a mode where the compressor will start: Cool well below the room temperature, or Heat well above it when it is cold outside), then one 5 s capture per single change (setpoint, mode, fan, off), with `GreeMark` notes for things the person hears or sees, and thermometer readings for calibration. The board keeps only the last two captures: have them download each one, named after what they did.
5. **Decode**: run the analysis script, then interpret (next section).
6. **Decoder**: write a Berry class for the new frames in the style of `GreeIndoor` / `GreeOutdoor` in `firmware/tasmota/gree_bus.be` (checksum check in `feed()`, fields, `to_json()`, Home Assistant discovery entries), and host tests in the style of `firmware/tests/`.

## Decoding a capture

Paths are relative to this skill's folder; in the repository the script is `.claude/skills/gree-bridge/scripts/analyze_capture.py`.

```
python3 scripts/analyze_capture.py gree_capture.txt              # full report
python3 scripts/analyze_capture.py gree_capture.txt --section events
python3 scripts/analyze_capture.py gree_capture.txt --json       # for further processing
```

`assets/example_capture_gwh12kf_real.txt` is a real start-up capture from a GWH12KF (Heat 24 °C after 3 minutes off; what it shows is described in `references/protocol.md`, "A real start-up"), and `assets/example_capture.txt` a synthetic one in Cool; use them to see what a good capture looks like.

Several capture files can be given at once; they are read as one, in order. The script splits the data into frames (Gree layouts when they fit, otherwise header bytes and lengths it learns), finds the checksum (XOR, sum, two's complement, CRC-8) per frame type, profiles every byte, lists which bytes changed after each IR command or note (bytes already drifting before it, and the checksum, are listed apart), and gives a timeline of every byte change, including the ones no event explains. Then reason about it:

- **Structure first**: constant bytes (headers, terminators, model codes), the checksum, request vs reply (the indoor unit usually polls about once a second; the outdoor reply follows within ~50-250 ms on the RX tap only).
- **Commands are the key**: an IR command with a known state (`Temp`, `Mode`, `FanSpeed`, `Power`) followed by a byte change identifies the field. A setpoint step of 1 °C that moves a nibble by 1 gives the setpoint and its offset (Gree: `setpoint - 16` in the low nibble of b6; other units often `value + 40` or `value * 2`).
- **Temperatures** move slowly and smoothly. Try the 8-bit NTC divider formula (20 kOhm, B 3950: `T = 1/(1/298.15 + ln((256-raw)/raw)/3950) - 273.15`), `raw - 40` and `raw / 2`, and compare with the thermometer readings and the unit's display. Gree reports the actual fan speed and coil temperatures, not the remote's settings, so expect delays (fan starts when the coil is warm in heat).
- **Compressor fields** start at 0, ramp after the outdoor unit starts (about 1 Hz per second on GWH12KF) and go back to 0 when it stops; current tracks frequency.
- **Don't trust one coincidence.** In 5 s windows a slow temperature can change right after a command by chance; check the timeline (was it moving before? does it keep moving?) and ask for the command to be repeated before calling a field confirmed. A change no event explains (the compressor starting on its own) is information too.
- **State what is confirmed and what is a guess.** Present a table per frame type: byte, meaning, formula, confidence (confirmed by a command / consistent / guess), and say which capture would confirm the guesses (for example "set 18 then 30 °C to confirm the setpoint range", "a capture in heat during a defrost").

## Sharing results

Encourage the person to open an issue on the repository (github.com/reparationchlorinateur/gree-bridge) with the model number, indoor board label, tap-point photos (power off), the IR brand, the BusDetect result and the captures. Captures contain no personal data: bus bytes, IR codes, relative times and notes. Remind them not to post photos showing anything personal, and never to post Wi-Fi or web passwords (the board's configuration backup contains them).
