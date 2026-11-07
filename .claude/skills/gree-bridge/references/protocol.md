<!-- Copy of docs/protocol.md from the gree-bridge repository (github.com/reparationchlorinateur/gree-bridge), made by skill/build_skill.py. Links are relative to that file in the repository. -->

# Gree indoor/outdoor bus and IR line: notes

What was measured on a Gree **GWH12KF** (inverter mini-split, R410A, about 2013) with indoor main board **GRJ819-A3** (label 301484411), with a logic analyzer and then live from the bridge. This is what `firmware/tasmota/gree_bus.be` decodes. Other Gree units of the same era probably use the same bus, but nothing here is official: it comes from captures, and a few fields are still guesses (marked).

A second, newer Gree bus ("protocol B": 1200 baud, 20-byte frames, sum checksum) was found on a Gree-built **Willis MGW12KCH15S/I** (2015) and is decoded too: see [Protocol B](#protocol-b-newer-gree-units-1200-baud) below. `gree_bus.be` decodes whichever of the two arrives, into the same fields.

## The indoor board

- No Wi-Fi module or wired-controller header on this board, so no UART port to plug into: the bridge listens to the indoor/outdoor bus instead.
- Two sides separated by an isolation barrier (routed slots, transformer, optocouplers):
  - **hot side:** mains, switching power supply, the communication loop; marked with a lightning symbol, `DC+`, `GND/` (with a slash);
  - **logic side:** the MCU, IR receiver, display; `+5V`, `+12V`, `GND`.
- Field wiring: terminal 1 = N, 2 = communication (black), 3 = L. With wire 2 lifted at the outdoor unit there are 53 to 57 V DC between 1 and 2.
- Two unpopulated headers (CN1, 4 pins, and CN2, 2x3) sit beside the MCU, probably programming or factory test. Not used; do not connect a programmer to them.

## The communication loop

A single-wire DC current loop powered by the outdoor unit (about 56 V). Each side sends by interrupting the loop with its TX optocoupler; both RX optocouplers see every bit, so the indoor unit hears its own frames as an echo.

On GRJ819-A3:
- **U6 = RX opto** (LED on the hot side, transistor on the logic side). Its pin 4 (collector, logic side, top pin next to D16) is the **RX tap**: it sees both the indoor frames (echo) and the outdoor replies. It is a low-voltage node: about **0.10 V idle / 1.07 V during bits**. The bridge reads it with a transistor stage that switches at about 0.55 V and draws about 10 µA.
- **U3 = TX opto** (mounted the other way round: LED on the logic side, driven by the MCU). The LED drive node is the **TX tap**: full logic levels, indoor frames only.

![RX and TX tap points on the GRJ819-A3 board](images/gree_board_taps.jpg)

Where to solder the two bus taps on the GRJ819-A3 indoor board (component side, oriented as in the photo; the top row of pins of both optocouplers is the logic side):

- **Blue: RX tap** → J1-3. U6 (RX opto), top-left pin, next to D16.
- **Green: TX tap** → J1-4. U3 (TX opto), top-left pin: the LED side, toward the MCU.
- **Red box: hot side** (communication loop, about 56 V, mains nearby). The bottom pins of U3 and U6 are on the hot side: never solder, probe or route a wire there.

### Finding the tap points on another board

Power off for any soldering. Then, with the unit running and **only a voltmeter or scope on the logic side** (probe ground on logic `GND`):
1. Find the optocouplers that straddle the isolation slots near the communication terminal's resistors (on GRJ819-A3: 4 x 13 kΩ in series from the black wire, then a diode).
2. On the logic side of each opto, look for a node that toggles about once a second in short bursts (a frame every second, 600 baud: bits are 1.67 ms).
3. The RX opto's output sees two bursts a second (indoor frame, then the outdoor reply about 50 ms after it ends). The TX opto's drive sees only one.
4. Check the levels: the bridge's RX input wants a node between about 0.1 and 5 V with its switching point near the middle (0.55 V threshold); the TX input wants a logic-level signal.

The decoder only accepts frames with a valid checksum and tries both polarities by itself (`BusAuto`), so a wrong polarity guess is harmless.

## Line format

**600 baud, 8 data bits, even parity, LSB first, one idle bit between bytes** (about 20 ms per byte). The taps idle LOW (inverted UART) on GRJ819-A3. No parity or checksum errors in about 10,000 captured bytes.

## Indoor frame (indoor → outdoor)

One **9-byte frame every 1.00 s**, starting about 25 s after power-up:

```
07 b1 b2 b3 00 b5 b6 ck 0D        ck = b1 ^ b2 ^ b3 ^ b4 ^ b5 ^ b6
```

| Byte | Meaning |
|---|---|
| b0 | 0x07, constant (start) |
| b1 + b5 bit 7 | **room temperature**, °C, 0.5 °C steps (room = b1 + 0.5 when b5 bit 7 is set). In heat mode it reads 1 °C lower (heat-mode compensation) |
| b2 | **indoor coil temperature**, raw 8-bit NTC reading (formula below) |
| b3 | **power + mode**, as in the IR remote: bit 3 = on, bits 0-2 mode (0 auto, 1 cool, 2 dry, 3 fan, 4 heat). Seen: 0x03/0x04 off, 0x09 cool on, 0x0C heat on |
| b4 | 0x00, constant |
| b5 | bit 7 = room + 0.5 °C; low bits 0x03 constant |
| b6 | `0x80 | fan << 4 | (setpoint − 16)`. The fan bits are the **actual** indoor fan speed (0 stopped, 1 low, 2 medium, 3 high), not the remote setting: in heat the fan stays 0 until the coil is warm |
| ck | XOR of b1 to b6 |
| b8 | 0x0D, constant (end) |

NTC formula for the 20 kΩ sensors (B 3950 on a 20 kΩ divider):

```
T = 1 / (1/298.15 + ln((256 − raw) / raw) / 3950) − 273.15
```

114 ≈ 20 °C, 78 ≈ 7 °C (evaporator while cooling), 165 ≈ 39 °C.

After the unit has been off for a while (hours), the indoor unit **stops polling**: the bus goes silent and the outdoor unit stays powered. Frames resume as soon as the unit is switched on, and the outdoor replies at once. The firmware reports this as `STANDBY`, not `LOST`.

## Outdoor reply (outdoor → indoor, RX tap only)

About 50 ms after each indoor frame ends:

```
08 o1 o2 o3 o4 o5 o6 o7 o8 ck 0F        ck = o1 ^ ... ^ o8
```

| Byte | Meaning | Confidence |
|---|---|---|
| o1 | **compressor frequency, Hz**. 0 when stopped; ramps about 1 Hz/s after start | confirmed |
| o2 | 1 while the compressor runs, 0 when stopped | confirmed |
| o3 | always 0 so far (fault code?) | unknown |
| o4 | **outdoor coil temperature**, same NTC formula as the indoor coil (condenser in cool, evaporator in heat) | confirmed |
| o5 | **compressor discharge temperature**, different sensor and divider. Fit from one cold reference point: `T = 1 / (1/298.15 + ln(0.3229 × (256 − raw) / raw) / 3950) − 273.15`. Published raw (`DischRaw`) and as an estimate (`DischC`) | estimate |
| o6 | **outdoor air temperature**, same NTC formula (checked against a thermometer outside) | confirmed |
| o7 | **compressor current, 0.05 A per count**. Clamp meter on the outdoor supply: outdoor current ≈ 0.05 A × o7 + 0.2 A (fan and board). The firmware estimates outdoor power as 240 V × 0.95 × (that current) | calibrated on one unit |
| o8 | **running mode**: 0 off, 1 cool, 4 heat (dry and fan assumed 2 and 3). Stays at the mode when the thermostat stops the compressor; 0 only when the unit is switched off | confirmed for off/cool/heat |
| ck | XOR of o1 to o8 | |

Example, heating at 28 °C: indoor `07 15 9A 0C 00 03 BC 3C 0D` (room 21.0, coil about 34.6 °C, heat on, fan 3, setpoint 28), outdoor `08 2C 01 00 4C 78 61 2B 04 57 0F`.

### A real start-up, recorded with the board

[`captures/gwh12kf_startup_heat.txt`](captures/gwh12kf_startup_heat.txt) (October 2026, about 5 °C outside, 18 °C inside): the unit off for 3 minutes, then switched on in Heat 24 °C with the wall remote. Read with the Skill's analysis script, it shows:

- the remote command at +3.0 s; the indoor frame shows it 1 s later (b3 `04` → `0C`: power bit on, mode 4 = heat);
- the outdoor unit starts the compressor 2 s later at 16 Hz (o1 `10`, `11`, `12`, ... one more Hz per second), o2 → 1, o8 → 4 (heat); 46 Hz after one minute, 51 Hz after three;
- the indoor fan stays at 0 while the coil warms (19 → 30 → 41 °C), goes to 1 at about 2 minutes (b6 `88` → `98`) and to 2 at 3 minutes (`A8`);
- the outdoor coil drops from 13 °C to about −2 °C (evaporator), the discharge temperature rises, the compressor current settles around 2 to 2.5 A.

Still open: the scale of o5 at high temperatures (needs a thermometer on the discharge pipe), o3 fault codes, the codes for dry, fan and auto in o8, defrost behaviour.

## Protocol B: newer Gree units (1200 baud)

Measured on two **Willis MGW12KCH15S/I** indoor units (made by Gree, 12,000 BTU/h inverter, 208/230 V, built 2015-04; [rating label](images/willis_mgw12kch15s_label.jpg)), indoor board label **30148875** (M836F2UBJ, V1.3), November 2026, with the bridge's own captures (`BusDetect`, `GreeCapture startup`) and commands from Home Assistant. Same IR protocol as the GWH12KF (`GREE`), different bus.

![Bus taps on the Willis MGW12KCH15S indoor board](images/willis_mgw12kch15s_board_taps.jpg)

Tap points on this board: the two bus optocouplers below the `COM-OUT` terminal, **U9** (Toshiba TLP785) and **U8** (Sharp PC817), pins 2 and 4 as wired on these units (green and blue wires in the photo). As on GRJ819-A3, one opto drives the loop (TX tap: indoor frames only) and the other receives it (RX tap: every frame on the loop). Measure on your own board before soldering ([finding the tap points](#finding-the-tap-points-on-another-board)): the photo shows where they went on this unit, not a checked pinout. The main page tells the taps apart: only the RX tap shows `31 10` (outdoor) frames.

### Line format

**1200 baud, 8E1** (BusDetect: 0 errors on both taps). RX tap inverted, TX tap normal, as on GWH12KF, so `BusAuto`'s starting values fit. Set the speed with `BusSerial 1200,8E1` or the Gree tools page (**Detect speed and format**, then **Use the detected settings**).

About every 1.1 s the loop carries a group of four 20-byte frames:

```
31 10 00 b3 .. b18 ck     outdoor unit, main frame
31 20 00 b3 .. b18 ck     indoor unit, main frame
32 10 00 .. ck            outdoor unit, second frame
32 20 00 .. ck            indoor unit, second frame
ck = (b0 + b1 + ... + b18) & 0xFF
```

The TX tap sees `31 20` and `32 20` about 0.55 s apart; the RX tap sees all four back to back. **Temperatures are whole degrees C + 40** (0x3B = 19 °C), so there is no thermistor curve to fit: room, coil, outdoor air, outdoor coil and discharge are all read directly.

### Indoor frame `31 20`

| Byte | Meaning | Confidence |
|---|---|---|
| b3 | **power + mode**: bit 4 = on, bits 0-2 mode (1 cool, 2 dry, 3 fan, 4 heat). `00` when off (no mode: the decoder keeps the last one) | confirmed with commands |
| b4 | **actual indoor fan**: 1 low, 2 medium, 3 high; `00` or `80` = stopped (in heat the fan waits until the coil is warm, as on GWH12KF) | confirmed for 0-3 |
| b5 | flags, `08` / `28` alternating | unknown |
| b6 | **setpoint** + 40. Always 25 °C (`41`) while off: the decoder keeps the last setpoint seen while on | confirmed |
| b7 | **room temperature** + 40 (whole degrees) | confirmed |
| b9 | **indoor coil temperature** + 40 | confirmed (rises 20 → 27 → 37 °C in heat) |
| b10 | `01`, `07` in heat | unknown |
| b12 | `00` off, `08`, `0A` while heating | unknown |
| ck | sum of b0 to b18 | |

### Outdoor frame `31 10`

| Byte | Meaning | Confidence |
|---|---|---|
| b3 | bit 4 = compressor running, bits 0-2 **running mode** (0 off, 1 cool, 2 dry, 3 fan, 4 heat). `04` = heat requested, compressor not started yet | confirmed |
| b4 | **compressor frequency, Hz** (0 when stopped). Starts at 16 Hz and ramps up (held at 33 Hz for the first minutes of one heat start); up to 78 Hz seen | confirmed |
| b7 | **compressor current, 0.1 A per count** (`0A` at 33 Hz, `18` at 60 Hz, `29` at 78 Hz) | assumed, check with a clamp meter |
| b10 | 79 to 92, also 81 with the unit off for hours (so not a heatsink temperature + 40) | unknown |
| b12 | **outdoor air temperature** + 40 | checked: 8 and 9 °C against 7.4 °C from a weather station |
| b13 | **outdoor coil temperature** + 40 (drops below the air in heat: evaporator) | confirmed |
| b14 | **discharge temperature** + 40 (11 °C after hours off, 44 °C after 3 minutes of heating, 88 to 98 °C at 53 to 78 Hz) | confirmed by its behaviour |
| b17 | 0 stopped, 2-3 at low load, 5-7 at high load: outdoor fan stage? | guess |
| ck | sum of b0 to b18 | |

The two second frames hardly change: `32 20` is `00 80 00…` while off and all zero while on; `32 10` carries `41`/`46`/`4B` in b12 (a frequency or capacity limit?) and `28` in b15-b19. The decoder checks and skips them.

`gree_bus.be` publishes these under the same JSON names as protocol A (`Room`, `Coil`, `Setpoint`, `Mode`, `Fan`, `CompHz`, `CompA`, `PowerW`, `OutAir`, `OutCoil`, `DischC`, `OutMode`, ...). `CoilRaw` and `DischRaw` hold the raw bytes (temperature + 40), `LoadRaw` is b7 and `Out` lists b3 to b18.

### A real start-up

[`captures/protocol_b_startup_heat.txt`](captures/protocol_b_startup_heat.txt): unit off for 85 s, then Heat 22 °C from Home Assistant (about 8 °C outside, 19 °C inside). b3 goes `00` → `14` one second after the command; the outdoor unit answers with mode 4 (`04`), then starts the compressor (`14`, 33 Hz). The indoor fan stays stopped until the coil reaches about 27 °C (3 minutes), then runs at low speed.

Still open: b7's scale (clamp meter), b10 and b17 outdoor, b5/b10/b12 indoor, the `32 10` frame, auto mode, defrost, error codes.

## IR line

The indoor board's IR receiver output is a demodulated, active-low signal (idle high). Gree YB1F2 remote frames decode cleanly with IRremoteESP8266's `GREE` protocol (9 ms header). The bridge:
- reads that line (GPIO4, through a Schmitt trigger), so wall-remote presses reach Home Assistant and Apple Home;
- sends on it by pulling it low through a 220 Ω resistor and a MOSFET (GPIO5), with no 38 kHz carrier (`IR_SEND_USE_MODULATION false`). The receiver's own output is not disturbed when the bridge is idle, so the wall remote keeps working.

Seen on the first board: with the unit off, the IR line carries some noise that the IR library reports as very short `UNKNOWN` codes (3 bits) and sometimes as `SONY` 12-bit codes. `gree_tools.be` ignores them (they never count as the remote, nor start a capture). The library's guess of the remote model varies between presses of the same remote (`YBOFB` / `YAW1F`); model `-1` (default) in the Home Assistant package and the Matter endpoint works with this remote.
