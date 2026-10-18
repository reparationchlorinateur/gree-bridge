<!-- Copy of docs/adapting.md from the gree-bridge repository (github.com/reparationchlorinateur/gree-bridge), made by skill/build_skill.py. Links are relative to that file in the repository. -->

# Adapting the bridge to another unit

The board was built for a Gree GWH12KF (indoor board GRJ819-A3), but most of it is generic:

- **IR control** works on any unit whose indoor board takes the IR receiver's demodulated output, which is most units, especially older ones. Tasmota's IR library knows dozens of AC brands.
- **Reading the unit** (the indoor/outdoor bus) is brand-specific, and can even differ between Gree generations. The board can measure the line's speed and format and record captures, so the protocol can be decoded later, by you or with Claude (see "Decoding with Claude" below).

> ⚠️ Read **[SAFETY.md](../SAFETY.md)** first. Everything here is on the logic side of the indoor board only. Breaker off for any soldering, plugging or unplugging; measure with a voltmeter or scope only, unit running, probe ground on the logic ground.

The tools are on the board's **Gree tools** page (button on the main page; needs `gree_tools.be` on the board, see [install.md](install.md), step 5) and as console commands ([firmware/README.md](../firmware/README.md)).

## 1. Find the tap points

1. Identify the IR receiver (3-pin module behind the display window). Its output pin goes to the indoor board: that is the **IR** line (J1-2). Check with a scope or logic probe: idle high, short low bursts when you press the remote.
2. Find the communication optocouplers next to the indoor/outdoor terminal's resistors. On the logic side of each, look for a node that changes in short bursts about once a second. The RX opto's output sees two bursts (the indoor frame and the outdoor reply); the TX opto's drive sees one. On GRJ819-A3 they are [U6 and U3](images/gree_board_taps.jpg). More detail: [protocol.md](protocol.md), "Finding the tap points".
3. Check the levels: the RX input (J1-3) switches at about 0.55 V and suits a low-level opto output (0.1 V / 1 V on GRJ819-A3) as well as a 3.3 or 5 V logic line; the TX input (J1-4) wants a logic-level signal.
4. Power: J1-1 takes 7 to 24 V from the logic side (the board's buck converter makes 5 V and 3.3 V). Use the logic ground.

You can start with IR only (J1-1, J1-2, J1-5) and add the taps later. Fixed-speed (non-inverter) units may have no data bus at all between the indoor and outdoor units, only switched wires: IR is then all there is to connect.

## 2. IR: which brand?

On the Gree tools page, **IR remote** shows what Tasmota decoded the last time someone pressed the wall remote: brand (vendor), model and protocol. Press any button on the remote and reload the page. The console shows it too (`IR: remote detected: ...`), and `IrDetect` gives the details.

- A brand is shown: use that name as `protocol:` in the Home Assistant room package and as the vendor of the Matter v.HVAC endpoint (Apple Home). The page shows both.
- "Not recognised as an AC remote (protocol, bits)": the remote's protocol is not one Tasmota decodes as an AC. Make a capture (below): with captures, the raw IR timings are recorded too (SetOption58), and the protocol can be identified from them.
- Nothing happens: the IR line is not connected or not the receiver's output.

Check that sending works too, from the console, for example: `IRhvac {"Vendor":"<brand>","Power":"On","Mode":"Cool","Temp":22}`. Most units beep when they accept a command.

## 3. Bus: speed, format, polarity

Switch the unit on, then on the Gree tools page press **Detect speed and format** (or the console command `BusDetect`). For about 5 seconds the bus decoder is paused and each tap's pin is measured directly:

- **polarity** from the idle level (idle low = inverted),
- **speed** from the pulse widths (300 to 19200 baud; a non-standard speed shows as "about N baud"),
- **format** by decoding the bytes with each common format (8E1, 8N1, 7E1, ...) and keeping the one without framing or parity errors.

The result shows the bytes it decoded, the bytes per burst (for example `[9, 11]`: a 9-byte frame and an 11-byte reply), the gaps between bursts in ms (on GWH12KF the reply follows about 50 ms after the frame), and how many valid Gree frames it found. **Use the detected settings** applies them (`BusSerial` and the polarity of each tap); when they are not Gree's 600 8E1, `BusAuto` is turned off, because it looks for Gree frames and would keep flipping the polarity.

"No activity": the unit may be in standby (the indoor unit stops talking some time after it is switched off), or the tap is not on the right node.

## 4. Captures

A capture records, with millisecond times: the raw bytes from both taps, every IR command (wall remote, with raw timings, and the ones the board sends), the decoded Gree values when there are any, and your notes. It goes to `/gree_capture.txt` on the board (the previous one is kept as `/gree_capture_prev.txt`), is printed live in the console, and can be downloaded from the Gree tools page.

Short captures are enough, because the unit repeats its state every second. A real example from the GWH12KF: [captures/gwh12kf_startup_heat.txt](captures/gwh12kf_startup_heat.txt) (see [protocol.md](protocol.md), "A real start-up"). A good set for a new unit:

1. **Start-up sequence**: unit off for 3 minutes (the compressor waits that long before it may restart), press **Start-up sequence** (`GreeCapture startup`), then switch the unit on with the remote in a mode where the compressor will start: **Cool** with the setpoint well below the room temperature, or, when it is cold outside, **Heat** with the setpoint well above it. The capture keeps the 3 s before the command, records 5 s after it, then 5 s again 1, 2 and 3 minutes later (fan start, compressor start and ramp-up).
2. **One change at a time**, each with **Capture 5 s now** (`GreeCapture 5`) started just before the change: setpoint +1 °C, then +1 again; each mode (Cool, Heat, Dry, Fan, Auto); each fan speed; off.
3. While a capture runs, add a note when something happens that the bus might show: `GreeMark outdoor fan started`, `GreeMark defrost`, `GreeMark compressor stopped`.
4. Note the room and outdoor temperatures from a thermometer: they calibrate the temperature fields.

`GreeCapture 5,60,10` gives 10 captures of 5 s, one per minute: useful for slow things (defrost, temperatures).

**Download each capture before starting the next one**: the board keeps only the last two (`/gree_capture.txt` and `/gree_capture_prev.txt`). Name them after what you did (`startup-cool.txt`, `setpoint-22-23.txt`, ...).

Raw bytes are split on silence (`BusGap`, 300 ms), so a reply that follows a frame within 300 ms is in the same line as the frame; the analysis script separates them again. For the delay between frame and reply, use the gaps shown by the bus detection.

## 5. Decoding

The analysis script `.claude/skills/gree-bridge/scripts/analyze_capture.py` (plain Python 3) reads one or more captures and shows:

- **frames**: the capture split into frames (Gree layouts when they fit, otherwise header bytes and lengths it learns), with how often each one repeats;
- **checksum**: which checksum (XOR, sum, two's complement, CRC-8) over which bytes matches every frame of each type;
- **columns**: for each byte: constant or not, values, range, as an NTC temperature and as value − 40 (both common in HVAC);
- **events**: for each IR command or note, which bytes changed after it (for example setpoint 22 → 21: `b6 B6->B5`, so the setpoint is in the low bits of byte 6). Bytes that were already changing before it (temperatures, counters) and the checksum are listed apart as "drifting";
- **timeline**: every change of every byte with its time, including the ones no command explains (the compressor starting by itself, a defrost).

```
python3 .claude/skills/gree-bridge/scripts/analyze_capture.py gree_capture.txt
python3 .claude/skills/gree-bridge/scripts/analyze_capture.py startup-cool.txt setpoint-22-23.txt   # several, read as one
```

In short captures a slowly changing temperature can look as if a command changed it; check the timeline and repeat the command once before trusting a field.

Then a decoder is written for the new layout, in the style of `GreeIndoor` / `GreeOutdoor` in `gree_bus.be` (a class with `feed(frame)` that checks the checksum and fills the fields, plus the Home Assistant discovery list).

## Decoding with Claude

This repository has a Claude Skill (`.claude/skills/gree-bridge/`) with these guides, the safety rules and the analysis script, so Claude can walk you through the steps above and decode your captures:

- **Claude Code**: open the downloaded repository folder in Claude Code; the skill is picked up by itself. Ask, for example, "help me adapt the Gree bridge to my Midea unit" or "decode this capture".
- **Claude app** (claude.ai, desktop, mobile): download [`skill/gree-bridge.zip`](../skill/gree-bridge.zip) and add it under Settings → Capabilities → Skills → Upload skill (paid plans, with code execution turned on). Then attach your capture file to a chat.

## Sharing what you found

Open an issue on this repository with the unit's model number, the indoor board's label and photos of the tap points (power off), the IR brand shown, the BusDetect result and your captures. Captures contain nothing personal: bus bytes, IR codes, times since the capture started and your notes.
