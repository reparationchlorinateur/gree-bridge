# Ordering assembled boards from JLCPCB

JLCPCB can make the PCB and solder every SMD part, the ESP32-S3 module included. You then only solder the three connectors (J1, J3, J5) and the header for the BME280 breakout (U5), which takes a few minutes per board. Prices below are from October 2026 and change often.

Files, all in [`hardware/`](../hardware/):

| File | Use |
|---|---|
| `fabrication/gree_bridge_revB_gerbers.zip` | Gerbers and drill files (upload as is) |
| `jlcpcb/bom_jlcpcb.csv` | BOM for JLCPCB: SMD parts only, every line mapped to an LCSC part number |
| `jlcpcb/cpl_jlcpcb.csv` | Placement file for the same parts, rotations and positions already corrected and checked in JLCPCB's preview |
| `jlcpcb/*_with_connectors.csv` | Same, plus J1, J3 and J5, if you want JLCPCB to hand-solder the connectors too (more expensive than doing it yourself) |

## Steps

1. On jlcpcb.com, **Add gerber file**: `gree_bridge_revB_gerbers.zip`. It should read 75 x 54 mm, 2 layers.
2. PCB options: FR-4, 2 layers, 1.6 mm, 1 oz, HASL (lead free if you prefer), any colour, quantity 5 or 10. Leave the rest at the defaults.
3. Turn on **PCB Assembly**:
   - PCBA type **Standard** (the ESP32-S3-WROOM-1 module, LCSC C2913202, is "Standard only" because it needs an X-ray check). See below for the Economic option.
   - Assembly side **Top**, quantity = all boards.
   - **Edge rails / fiducials: added by JLCPCB** (the board is under the 70 x 70 mm minimum for Standard).
   - **Confirm Parts Placement: Yes** (a small fee; you get to check the placement before they build).
   - In the remark field, something like: *"ESP32 module antenna overhangs the top (long) edge by 6 mm: no rail, V-cut or tab may touch or lift the module on that edge. J1, J3, J5 and U5 are not in the BOM (soldered by the customer)."*
4. Upload `bom_jlcpcb.csv` as the BOM and `cpl_jlcpcb.csv` as the CPL. Check that every line matched the LCSC number in the file (26 lines). If a part is out of stock, pick an equivalent with the same value, package and rating, or leave it off and fit it by hand.
5. On the placement preview, check the parts in the list below, then save to cart. JLCPCB's engineers review the files (a few hours to a day) and, with Confirm Parts Placement, send you their placement to approve.

## Placement check list

As seen from the top, with the antenna edge at the top. These are already right in `cpl_jlcpcb.csv` (U1 rotation 270, U4 at its pad centre), but the preview is the place to catch anything a JLCPCB library change could move.

| Ref | Correct orientation |
|---|---|
| **U4** ESP32-S3 module | Antenna end hanging off the **top** board edge, castellated pads on the pads. Pin 1 top-left |
| **U3** SOIC-14 | Pin 1 dot at **top-left** |
| **U1** TSOT-23-6 | Pin 1 dot at **top-left**, at the silkscreen triangle; pins 1-3 on the left (D1 side) |
| **U2** SOT-223 | Three small leads on the **left**, big tab on the **right** |
| **Q1** SOT-23 | Two leads on the **right**, single lead on the **left** (toward R7) |
| **Q2** SOT-23 | Two leads on the **left**, single lead on the **right** (toward R16) |
| **D1** | Cathode band on the **right** (toward U1) |
| **D2** | Cathode band on the **left** |
| **D3, D4** LEDs | Cathode on the **left** |
| **SW1, SW2, L1** | Legs or terminals on the pads (a 90° error leaves them off the pads) |

## Cost (October 2026, USD)

For 10 boards, Standard, every SMD part placed: PCB about $5, assembly about $177 (setup and stencil about $34, parts about $82, feeder fees about $40, X-ray $16.50, the rest small), so about **$182 before shipping and duty**, or about $18 per board. 5 boards cost about $135 in total, so 10 is the better deal.

**Economic option:** leave the ESP32 module (U4) off the BOM and the price drops to about $8 per board for parts and assembly at 10 boards, but you then solder the ESP32 module yourself (side pads, then the centre pad through the 1.0 mm hole from the back, or hot air). Economic also charges about $3 per order for each "Extended" part type.

## Substitutes used in the JLCPCB BOM

Where the exact Mouser part is not stocked at LCSC, or only as an Extended part:

| BOM line | Original | JLCPCB part | Difference |
|---|---|---|---|
| C1 C2 C6 | YAGEO CC1206KKX7R8BB106 | C14860 Samsung CL31B106KAHNNNE | same 10 µF 25 V X7R 1206 |
| C4 C5 C7 C8 | TDK C3216X5R1E226M160AB | C12891 Samsung CL31A226KAHNNNE | same 22 µF 25 V X5R, ±10 % |
| C10 | YAGEO CC0805KKX7R8BB105 | C28323 Samsung CL21B105KBFNNNE | 1 µF, 50 V (better) |
| C12 C13 C14 | YAGEO CC0805JRNPO9BN101 | C1790 Samsung CL21C101JBANNNC | same 100 pF C0G |
| D1 D2 | onsemi SS14 | C2480 MDD SS14 | Vf 0.55 V vs 0.50 V |
| F1 | Bel Fuse 0ZCJ0050AF2E | C883126 BHFUSE BSMD1206-050-30V | 30 V (better), Imax 40 A vs 100 A |
| R1-R16 | YAGEO RC0805FR-07… | UNI-ROYAL 0805W8F… (Basic) | same 1 % 0805 |
| SW1 SW2 | C&K PTS645SL43 (1.3 N) | C221880 C&K PTS645SM43 | 1.6 N actuation force |
| U3 | TI SN74LVC14ADRG4 | C133541 TI SN74LVC14ADR | same device |

## After delivery

Solder J1 and J3 (vertical JST XH, from the top), J5 (1x6 header) and a 1x6 header for the BME280 breakout on U5 (see [hardware.md](hardware.md), "BME280 corner"). Then follow [install.md](install.md) from step 1.
