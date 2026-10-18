# Tasmota build for the Gree bridge

Prebuilt firmware for the ESP32-S3 on the board, so you do not need to compile anything.

| File | What | md5 |
|---|---|---|
| `gree_tasmota32s3_15.6.0.factory.bin` | First flash of a blank board, written at **0x0** (bootloader, partitions, safeboot and Tasmota) | 1ea5facd3f9c6872a355cce486ddd923 |
| `gree_tasmota32s3_15.6.0.bin` | Later updates: board web page → Firmware Upgrade → Upgrade by file upload | 36a7d1892df516634da7048bfc33d167 |
| `user_config_override.h` | The build options | |
| `MD5SUMS.txt` | md5 of both binaries | |

The board reports `15.6.0(tasmota32)`, ESP32 core 3.3.8.

## What is in it

Tasmota `tasmota32s3` (4 MB layout, PSRAM not used), plus [`user_config_override.h`](user_config_override.h):

- `USE_IR_REMOTE` + `USE_IR_REMOTE_FULL`: the GREE decoder and the `IRhvac` command (needed by `tasmota_irhvac` in Home Assistant).
- `IR_SEND_USE_MODULATION false`: the board drives the unit's demodulated IR receiver line, no 38 kHz carrier.
- `USE_BMP` (BME280 on U5) and `USE_BME68X` (optional sensor on J3).
- `USE_TASMOTA_DISCOVERY` on, the old `USE_HOME_ASSISTANT` off.
- `WIFI_CONFIG_TOOL WIFI_MANAGER`: the setup hotspot opens by itself when the board cannot join its Wi-Fi.
- `OTA_URL ""`: the board never updates itself from the Tasmota server (a stock build lacks the options above).
- Everything is inside `#ifndef FIRMWARE_SAFEBOOT`, so the same file also builds the small safeboot image.

Berry and Matter are part of the standard ESP32-S3 build. The Gree decoder is not compiled in: it is [`../tasmota/gree_bus.be`](../tasmota/gree_bus.be), uploaded to each board.

## Rebuilding

1. Get the Tasmota source at tag **v15.6.0**: `git clone --depth 1 --branch v15.6.0 https://github.com/arendst/Tasmota.git`
2. Copy `user_config_override.h` to `Tasmota/tasmota/user_config_override.h`.
3. With PlatformIO: `pio run -e tasmota32s3-safeboot`, then `pio run -e tasmota32s3`. The factory image needs the safeboot build first.
4. The output is in `build_output/firmware/`: `tasmota32s3.factory.bin` and `tasmota32s3.bin`.

TasmoCompiler (web or Gitpod) works too: board "ESP32 S3", features IR (full), sensors, Berry, then paste the contents of `user_config_override.h` as custom parameters.

## Licence

These binaries are [Tasmota](https://github.com/arendst/Tasmota), licensed under the **GNU GPL v3.0**, built without source changes from the official v15.6.0 tag with the configuration file above. The complete corresponding source is that tag plus `user_config_override.h`. Tasmota is by Theo Arends, Stephan Hadinger and contributors; it includes IRremoteESP8266 (LGPL-2.1) and Berry (MIT), among others.
