<!-- Copy of SAFETY.md from the gree-bridge repository (github.com/reparationchlorinateur/gree-bridge), made by skill/build_skill.py. Links are relative to that file in the repository. -->

# Safety and disclaimer

**Read this before you open an indoor unit.**

## What you are connecting to

A mini-split indoor unit is powered from the mains (240 V in North America, 230 V elsewhere), usually from the outdoor unit through the interconnect cable. Its control board has two parts:

- a **hot side**: mains rectifier, switching power supply, and the indoor/outdoor **communication loop**, a DC current loop of about **56 V** shared with the outdoor unit;
- a **logic side**: the microcontroller, the IR receiver, the display, with low-voltage rails (+5 V, +12 V) and a logic ground.

They are separated by an isolation barrier (transformer and optocouplers). **This board connects only to the logic side**: +12 V, logic GND, the IR receiver line, and the logic-side pins of the two communication optocouplers. It never touches the hot side or the 56 V loop.

On the board this was developed on (GRJ819-A3), the hot side is marked with a lightning symbol and labels like `GND/` (with a slash) and `DC+`; the logic side has `+5V`, `+12V`, `GND`. **Other boards differ.**

## Before you connect anything

1. **Switch the unit off at the breaker** (not just with the remote) before opening it, and every time you plug or unplug the cable. Capacitors on the hot side can stay charged for a while after power-off.
2. **Check the isolation yourself** with an ohmmeter, power off: the logic GND must be **open** (megohms) to **N** and to **L** of the unit's terminal block. If it is not, stop: that board's logic side is not isolated, and nothing connected to it is safe to touch.
3. **Identify the tap points** on your own board (see [docs/protocol.md](docs/protocol.md); on GRJ819-A3, the [photo](docs/images/gree_board_taps.jpg) shows them and the hot side). With the unit running and only a voltmeter or scope on the logic side, check that each point has the expected levels before soldering a wire to it.
4. Use the logic ground (`GND`), **never** the hot ground (`GND/` or similar).

## While it is installed

- **Never connect a computer to J5 (the programming header) while the board is inside a powered unit.** Flash and test it on the bench, powered from the USB-serial adapter. Once installed, update it over Wi-Fi only.
- Route the cable away from the hot side, heat sinks and moving parts (fan), and fix the board so it cannot move or touch anything. A printed case is recommended.
- The board draws its power from the unit's +12 V logic rail through a 0.5 A resettable fuse.

## Disclaimer

This project is shared in the hope that it is useful, **without any warranty**. You are responsible for your own installation and its safety. Opening the unit and connecting anything to its control board may void the manufacturer's warranty and, depending on where you live, may need to be done by a qualified person. The author is not responsible for damage to your equipment, your home, or yourself.

It was tested on one Gree model only (GWH12KF, indoor board GRJ819-A3). Not affiliated with or endorsed by Gree.
