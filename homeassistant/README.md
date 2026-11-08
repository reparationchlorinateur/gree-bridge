# Home Assistant files

The board announces all its sensors to Home Assistant by **MQTT discovery** (one device per board, named after its Tasmota `DeviceName`), so the sensors need no YAML. These files add what discovery cannot: the IR climate entity, two switches, an energy counter and an automation. Optional: Apple Home through Home Assistant's HomeKit Bridge.

Needs: the MQTT integration with a broker, the [`tasmota_irhvac`](https://github.com/hristo-atanasov/Tasmota-IRHVAC) custom integration (HACS), and packages enabled in `configuration.yaml`:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

## Make a room's package

Set the board's `DeviceName` and `Topic` first (see [docs/install.md](../docs/install.md), step 3), then, in this folder on Linux or macOS:

```
./new_room.sh "Bedroom heat pump" gree_bedroom
```

The first argument is the board's `DeviceName`, the second its `Topic`. It writes `packages/gree_bedroom.yaml` and rebuilds `packages/gree_homekit.yaml`. Copy the room file to `/config/packages/` on Home Assistant, check the configuration and restart.

What each room package contains (`bedroom_heat_pump` stands for your room's slug):

| Entity | What it does |
|---|---|
| `climate.bedroom_heat_pump` | IR thermostat through `tasmota_irhvac` (protocol `GREE`): off, heat, cool, dry, fan only, auto; fan auto/min/medium/max; swing off/vertical. Room temperature from the unit's own sensor |
| `switch.bedroom_heat_pump_turbo` | Turbo on/off (`tasmota_irhvac.set_turbo`) |
| `switch.bedroom_heat_pump_display` | The unit's LED display on/off (`tasmota_irhvac.set_light`) |
| `sensor.bedroom_heat_pump_outdoor_energy` | kWh integrated from the estimated outdoor power, for the Energy dashboard |
| automation "Bedroom heat pump: follow the unit (Gree bus)" | Keeps the climate in line with the unit's real on/off, mode and setpoint from the bus (after a restart, a missed remote press, or a change from Apple Home). Waits until things have been steady for 15 s, then writes a state-only message to the climate's state topic. **It never sends IR.** Each correction goes to the logbook |

The `# homekit:` line at the top of each room file is what `new_room.sh` reads to build `gree_homekit.yaml`.

## Apple Home: two ways, pick one per room

- **Matter, straight from the board** (recommended, works even without Home Assistant): see [docs/install.md](../docs/install.md), step 7b. Do **not** copy `gree_homekit.yaml`.
- **Home Assistant's HomeKit Bridge**: copy `packages/gree_homekit.yaml` too. It is one bridge ("Gree heat pumps", port 21070) listing every room made so far; pair it once in the Home app. Run `new_room.sh` again for each new room and copy the updated file.

Using both for the same room makes the unit appear twice in the Home app.

## Sensors from discovery

For a board with `DeviceName` "Bedroom heat pump" (entity ids start with `bedroom_heat_pump_`):

| Entity | Source |
|---|---|
| `sensor…_room_temperature_unit`, `…_coil_temperature`, `…_setpoint_unit`, `…_mode_unit`, `…_indoor_fan_speed` | indoor frame |
| `binary_sensor…_power_unit`, `…_indoor_fan_running`, `…_bus_link` | indoor frame |
| `sensor…_compressor_frequency`, `…_compressor_current`, `…_outdoor_power`, `…_outdoor_air_temperature`, `…_outdoor_coil_temperature`, `…_outdoor_mode`, `…_discharge_temperature` | outdoor reply |
| `binary_sensor…_compressor_running`, `…_outdoor_link` | outdoor reply |
| `sensor…_coil_raw`, `…_discharge_raw`, `…_outdoor_raw_bytes` | diagnostics |
| `sensor…_bme280_temperature`, `sensor…_bme280_humidity`, `sensor…_bme280_pressure` (and dew point) | Tasmota integration (BME280) |

## Dashboard

[`dashboard_card_example.yaml`](dashboard_card_example.yaml): a thermostat card with outdoor temperature, power, humidity and pressure, plus the turbo and display switches. It uses the simple-thermostat and card-tools cards from HACS.

With the built-in cards only (no HACS), stack a small entities card under a thermostat or tile card:

```yaml
type: vertical-stack
cards:
  - type: thermostat
    entity: climate.bedroom_heat_pump
  - type: entities
    entities:
      - entity: sensor.bedroom_heat_pump_outdoor_power
        name: Power
      - entity: sensor.bedroom_heat_pump_bme280_humidity
        name: Humidity
      - entity: sensor.bedroom_heat_pump_bme280_pressure
        name: Pressure
      - entity: input_select.bedroom_vertical      # see "Louvre position" below
        name: Air direction
```

The BME280 sits in the unit's air path: while the unit runs, its humidity and temperature are those of the air going through the unit, not of the room.

## Display on or off per room

`switch.<room>_heat_pump_display` turns the unit's LED display on or off. Every IR command Home Assistant sends (mode, setpoint, fan) carries the display state too, using the last one set, so a room stays dark or lit without touching it again. After a Home Assistant restart the climate starts from `default_light_mode` in the room's package (`"On"` in the template): for a bedroom, set it to `"Off"` in that room's file, otherwise the first command after a restart lights the display again.

## Louvre position (air direction)

The climate only offers swing off / vertical. For fixed positions (highest, high, middle, low, lowest, auto), a dropdown helper plus an automation works well with `tasmota_irhvac`:

1. Settings → Devices & services → Helpers → Dropdown, for example `input_select.bedroom_vertical`, options `off`, `highest`, `high`, `middle`, `low`, `lowest`, `auto`.
2. An automation from the community blueprint "Climate Vane Control - Tasmota-IRHVAC" (nao-pon) with the room's climate and that helper: picking a position sends it to the unit (`SwingV` in the IR command).
3. Put the helper on the room's card (example above).

If you replace an older IR board by a Gree bridge, point these automations at the new `climate.<room>_heat_pump`: an automation still aimed at the old climate does nothing, with no error on the card.
