/* Gree bridge rev B (fw2): Tasmota custom build, same options as the TasmoCompiler recipe in the README. */
#ifndef _USER_CONFIG_OVERRIDE_H_
#define _USER_CONFIG_OVERRIDE_H_

#ifndef FIRMWARE_SAFEBOOT          // the small recovery image keeps its own minimal feature set

#ifndef USE_IR_REMOTE
#define USE_IR_REMOTE
#endif
#ifndef USE_IR_REMOTE_FULL
#define USE_IR_REMOTE_FULL          // all IRremoteESP8266 protocols: GREE decoder and IRhvac
#endif
#undef  IR_SEND_USE_MODULATION
#define IR_SEND_USE_MODULATION false // demodulated output: the board drives the IR receiver line, not an IR LED
#ifndef USE_BMP
#define USE_BMP                     // BME280 on the board (0x76)
#endif
#ifndef USE_BME68X
#define USE_BME68X                  // optional second sensor on J3
#endif
#undef  USE_HOME_ASSISTANT          // keep Tasmota discovery (HA Tasmota integration)
#ifndef USE_TASMOTA_DISCOVERY
#define USE_TASMOTA_DISCOVERY
#endif
#undef  WIFI_CONFIG_TOOL
#define WIFI_CONFIG_TOOL WIFI_MANAGER // setup hotspot when Wi-Fi fails

#endif  // FIRMWARE_SAFEBOOT

// No OTA URL: the official tasmota32s3.bin lacks the options above. Update with this custom .bin (Firmware Upgrade > upload).
#undef  OTA_URL
#define OTA_URL ""

#endif  // _USER_CONFIG_OVERRIDE_H_
