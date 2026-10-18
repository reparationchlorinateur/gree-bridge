# Gree indoor/outdoor bus and IR line: notes

What was measured on a Gree **GWH12KF** (inverter mini-split, R410A, about 2013) with indoor main board **GRJ819-A3** (label 301484411), with a logic analyzer and then live from the bridge. This is what `firmware/tasmota/gree_bus.be` decodes. Other Gree units of the same era probably use the same bus, but nothing here is official: it comes from captures, and a few fields are still guesses (marked).

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

Still open: the scale of o5 at high temperatures (needs a thermometer on the discharge pipe), o3 fault codes, the codes for dry, fan and auto in o8, defrost behaviour.

## IR line

The indoor board's IR receiver output is a demodulated, active-low signal (idle high). Gree YB1F2 remote frames decode cleanly with IRremoteESP8266's `GREE` protocol (9 ms header). The bridge:
- reads that line (GPIO4, through a Schmitt trigger), so wall-remote presses reach Home Assistant and Apple Home;
- sends on it by pulling it low through a 220 Ω resistor and a MOSFET (GPIO5), with no 38 kHz carrier (`IR_SEND_USE_MODULATION false`). The receiver's own output is not disturbed when the bridge is idle, so the wall remote keeps working.
