# Gree bridge

A small ESP32-S3 board that goes inside a **mini-split indoor unit** and makes it part of your home, from **Home Assistant**, from **Apple Home** (Matter, straight from the board), or both. It runs [Tasmota](https://tasmota.github.io/) plus a few small Berry scripts.

- **IR control, most brands**: the board drives the unit's own IR receiver line and hears the wall remote on it. This works on most units whose IR receiver feeds the control board directly (most do, especially older ones), with any AC brand Tasmota's IR library knows: Gree, Daikin, Mitsubishi, Fujitsu, LG, Samsung, Panasonic, Toshiba, Midea and many more.
- **The unit's real state, Gree**: it also listens to the indoor/outdoor bus, so you see what the unit is really doing (compressor speed and current, outdoor temperature, coil temperatures...). This is decoded and tested on a **Gree GWH12KF** only; other Gree units of the same era probably use the same bus (not checked). For other units, the board's Gree tools page and the Claude Skill help record and decode the bus ([adapting to other units](docs/adapting.md)).

> ⚠️ **Read [SAFETY.md](SAFETY.md) before opening a unit.** This board connects to the logic side of the indoor unit's control board, which sits next to mains voltage and a 56 V communication loop. It was built and tested on **one** model (Gree GWH12KF, indoor board GRJ819-A3); the IR part has not been tried on other brands yet. You do this at your own risk; it can void your warranty.

![Board, top](docs/images/board_top.png)

## What it does

- **Controls the unit by IR**, without any IR LED: it drives the unit's own IR receiver line (the wall remote keeps working). Uses Tasmota's IR library (protocol `GREE` here; other brands use their own protocol the same way), so modes, setpoint, fan, swing, turbo, display, etc. are all available.
- **Hears the wall remote** on the same line, so Home Assistant / Apple Home learn about remote presses.
- **Reads the indoor/outdoor bus** (600 baud, one frame per second each way) through two high-impedance taps, listen only: room temperature, indoor coil, mode, setpoint, indoor fan, compressor frequency and current, estimated outdoor power, outdoor air and coil temperatures, discharge temperature, link status. So the app shows the **real** state of the unit, even after a missed remote press or a restart.
- **BME280** (temperature, humidity, pressure) on a plug-in breakout, plus an I2C connector for more sensors.
- **Home Assistant**: everything appears by MQTT discovery; a generated package per room adds the IR climate entity (via `tasmota_irhvac`), turbo and display switches, an energy counter for the Energy dashboard, and an automation that keeps the climate in line with the unit's own state.
- **Apple Home without Home Assistant**: Tasmota's Matter thermostat (v.HVAC) over your normal Wi-Fi, kept in sync with the bus by `gree_matter.be`. Siri, Home app scenes and remote access through a home hub. Other Matter apps (Google Home, Alexa, SmartThings) should work too (not tested).
- **Other units and brands**: a "Gree tools" page detects the wall remote's IR brand, measures the bus speed, format and polarity, and records short captures for decoding; a Claude Skill in this repository walks you through it and decodes the captures ([docs/adapting.md](docs/adapting.md)).
- Wi-Fi recovery hotspot (press BOOT 6 times), OTA updates from the web page.

![Schematic](docs/images/schematic.png)

## What's in this repository

| Folder | Contents |
|---|---|
| [`hardware/`](hardware/) | KiCad 7 project (opens in 7, 8, 9), schematic PDF, assembly sheet (part directions), Gerbers, combined BOM (Mouser + LCSC numbers), JLCPCB assembly files |
| [`hardware/case/`](hardware/case/) | 3D-printable case (PETG, no supports, snap-fit lid): STL, STEP, OpenSCAD source, fit check. Not printed yet |
| [`firmware/`](firmware/) | Tasmota build settings and prebuilt binaries (ESP32-S3), Berry scripts `gree_bus.be` and `gree_matter.be`, GPIO template, host tests |
| [`homeassistant/`](homeassistant/) | Room package generator (`new_room.sh`), package template, example dashboard card |
| [`docs/`](docs/) | [Install guide](docs/install.md) (also without Home Assistant), [hardware description](docs/hardware.md), [bus protocol notes](docs/protocol.md), [adapting to other units](docs/adapting.md), [ordering assembled boards from JLCPCB](docs/order-jlcpcb.md), interactive board viewer |
| [`.claude/skills/gree-bridge/`](.claude/skills/gree-bridge/), [`skill/`](skill/) | Claude Skill: install help, adapting to other units, capture analysis script ([how to add it](skill/README.md)) |

## Quick start

1. **Get a board**: order it assembled from JLCPCB with the files in [`hardware/jlcpcb/`](hardware/jlcpcb/) ([how](docs/order-jlcpcb.md)), or order bare PCBs and solder the parts in [`hardware/bom.csv`](hardware/bom.csv) ([assembly sheet](hardware/gree_bridge_revB_assembly_sheet.pdf)). Add the connectors and a GY-BME280 breakout.
2. **Flash** [`firmware/build/gree_tasmota32s3_15.6.0.factory.bin`](firmware/build/) through the J5 header with a 3.3 V USB-serial adapter, from Chrome.
3. **Configure**: Wi-Fi, names, the GPIO template, upload the three scripts.
4. **Install** in the indoor unit (5-wire cable to J1, [where each wire goes](docs/images/gree_board_taps.jpg)), with the breaker off, ideally in the [printed case](hardware/case/).
5. **Connect** to Home Assistant (MQTT + a generated package) and/or pair with Apple Home.

Every step, with the exact console lines: **[docs/install.md](docs/install.md)**.

## Status and compatibility

- Rev B hardware, firmware working since October 2026 on a Gree **GWH12KF** (inverter, R410A, about 2013) with indoor board **GRJ819-A3 / 301484411**: IR both ways, both bus taps, Home Assistant, Apple Home (Matter).
- Other Gree units that use the same 600 baud indoor/outdoor loop and a demodulated IR receiver line will probably work, but the tap points differ from board to board. The bus decoder only accepts frames with a valid checksum and finds the tap polarity by itself (`BusAuto`), so a wrong guess is harmless, but measure before you solder (see [SAFETY.md](SAFETY.md) and [docs/protocol.md](docs/protocol.md)).
- Not affiliated with or endorsed by Gree. "Gree" is used only to say which units this is for.

## Licences

- Software (Berry scripts, Home Assistant files, tests, shell and Python scripts, including the Skill's analysis script): [MIT](LICENSE).
- Hardware (KiCad files, Gerbers, BOM) and documentation: [CC BY-SA 4.0](hardware/LICENSE.md).
- The prebuilt firmware is Tasmota (GPL-3.0) built with [`user_config_override.h`](firmware/build/user_config_override.h); see [`firmware/build/README.md`](firmware/build/README.md).

Built on the work of the Tasmota project (Theo Arends, Stephan Hadinger and contributors), IRremoteESP8266, Berry, and the `tasmota_irhvac` Home Assistant integration.
