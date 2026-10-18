#!/usr/bin/env python3
"""
Gree bridge rev B case - layout script (2026-10-17)

Reads the frozen board file (KiCad 7) and writes every position the case needs:
    gree_case_params.scad   (for gree_case.scad, generated - do not edit by hand)
    out/params.json         (same values, for gree_case_cq.py / fit_check.py / render_gree.py)
    out/board_parts.json    (board outline + component envelopes in case coordinates)

Design knobs are in the DESIGN block below; edit them here and run ./build.sh.

Case frame (all outputs):  X = kx - X0,  Y = Y0 - ky,  Z = 0 at the base bottom (mounting face).
Seen from above with the lid on, the board reads like KiCad's top view: antenna at the back (+Y),
J1 on the left (-X), BME280 corner at the front right.
usage: python3 layout_gree.py [path/to/gree_bridge.kicad_pcb]
"""
import json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PCB = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '../kicad/gree_bridge.kicad_pcb')

# ----------------------------------------------------------------------------------------------
# DESIGN knobs (mm)
# ----------------------------------------------------------------------------------------------
D = dict(
    wall=2.0, floor_t=2.0, lid_t=2.0,
    fit=0.3,                # lid lip to base wall, cap to opening (per side)
    board_gap=0.5,          # board outline to inner wall (0.3 fit + PCB outline tolerance)
    ant_air=5.0,            # air from the module antenna end / sides to the inner wall
    under_gap=5.0,          # floor top to board bottom (THT tails, untrimmed U5 pins 4.4)
    lid_air=14.7,           # board top to lid inner surface (J1 plug 9.8 + bent wires, 1.9 mm OD worst case)
    seam=0.2,               # lid rides on its 3 columns (board clamped); rim floats this much over the wall top
    lip_t=1.6, lip_h=3.0,
    r_out=3.0, r_bump=2.0, r_in=1.0,
    cham_bot=0.6, cham_top=0.8,
    # screws: 3 x M3 x 20 pan head from the lid, through lid column + board, into the base boss
    screw_clear=3.4, pilot_d=2.5, pilot_bottom=1.0,
    use_inserts=False, insert_d=4.0, insert_depth=5.5,
    cbore_d=6.2, cbore_depth=4.0,
    col_d=6.4, col_boss_d=8.4, col_boss_h=4.0,
    boss_d=6.4, boss_flare_d=9.0, boss_flare_h=2.0,
    # light holes / buttons
    led_hole_d=2.4, led_tube_od=4.0, led_tube_gap=2.5, led_skin=0.0,
    rst_hole_d=2.2, rst_tube_od=4.6, rst_tube_gap=1.0,
    boot_w=5.0, boot_t=1.0, boot_slot=0.8, boot_hinge_kx=159.0, boot_tip_kx=170.8,
    stem_d=3.0, stem_gap=0.3,
    # J5 programming opening + snap cap
    j5_open=(4.6, 17.8), j5_recess=1.0, j5_recess_d=1.0, cap_plug_fit=0.15, cap_wall=0.8,
    cap_plug_below=1.6, cap_bump=0.45,
    # J1 cable window (left wall) + zip-tie block, J3 knock-out (front wall)
    win_w=13.0, win_h=4.0, win_r=1.0,
    tie_depth=5.0, tie_tunnel=(3.6, 1.8),
    j3_ko_w=13.0, ko_membrane=0.6,
    # vents
    vent_w=1.6, vent_w_bme=1.5,
    vents_lid_general=True, vents_lid_bme=True,     # set False if the spot can get drips / dust from above
    # ears (diagonal): left near the front, right near the back
    ear_len=17.0, ear_w=14.0, ear_t=3.0, ear_hole=4.3, ear_slot=(2.0, 5.2), ear_gusset=1.5,
    ear_left_ky=146.0, ear_right_ky=108.0,
    # BME280 baffles
    baffle_t=1.0, baffle_gap=0.6, rib_gap=0.4,
    # text
    label="GREE BRIDGE", label_size=4.6, label_depth=0.8, legend_size=2.8, legend_depth=0.6,
)

# Component heights above the board top (datasheet maxima, mm) - see README
H = {
    "C_1206": 1.8, "C_0805": 1.45, "R_0805": 0.6, "D_SMA": 2.6, "LED_1206": 1.2, "Fuse_1206": 1.3,
    "SOT-23": 1.2, "TSOT-23-6": 1.1, "SOT-223": 1.8, "SOIC-14": 1.75,
    "L1": 4.5, "SW_body": 3.5, "SW_act": 4.3, "U4": 3.25,
    "XH_header": 7.0, "XH_mated": 9.8, "J5_body": 2.54, "J5_pins": 8.54,
    "U5_header": 2.5, "U5_top": 6.0, "dupont": 14.5,
}
WIRE_OD = 1.9          # SXH-001T-P0.6 accepts 0.9-1.9 mm insulation: worst case
WIRE_BEND_R = 2.5      # inner bend radius of the J1 wires above the plug
# below the board bottom
HB = {"XH_tail": 3.4, "J5_tail": 1.7, "U5_tail_untrimmed": 4.4, "U4_hole_blob": 1.0}


def main():
    import pcbnew
    b = pcbnew.LoadBoard(PCB)
    mm = pcbnew.ToMM
    fps = {f.GetReference(): f for f in b.GetFootprints()}

    # ---- board outline from Edge.Cuts -------------------------------------------------------
    ps = pcbnew.SHAPE_POLY_SET()
    b.GetBoardPolygonOutlines(ps)
    assert ps.OutlineCount() == 1
    def chain(c):
        return [(mm(c.CPoint(i).x), mm(c.CPoint(i).y)) for i in range(c.PointCount())]
    outer = chain(ps.Outline(0))
    slots = [chain(ps.Hole(0, i)) for i in range(ps.HoleCount(0))]
    bx0, bx1 = min(p[0] for p in outer), max(p[0] for p in outer)
    by0, by1 = min(p[1] for p in outer), max(p[1] for p in outer)
    assert abs(bx1 - bx0 - 75) < 0.01 and abs(by1 - by0 - 54) < 0.01, (bx0, bx1, by0, by1)
    t_pcb = mm(b.GetDesignSettings().GetBoardThickness())

    holes = {}
    for r in ("H1", "H2", "H3"):
        p = fps[r].GetPosition()
        holes[r] = (mm(p.x), mm(p.y))

    def fab_bbox(f, layer="F.Fab"):
        xs, ys = [], []
        for g in f.GraphicalItems():
            if g.GetLayerName() != layer or g.GetClass() in ("PCB_TEXT", "FP_TEXT"):
                continue
            bb = g.GetBoundingBox()
            xs += [mm(bb.GetX()), mm(bb.GetRight())]; ys += [mm(bb.GetY()), mm(bb.GetBottom())]
        if not xs:
            return None
        return [min(xs), min(ys), max(xs), max(ys)]

    def pos(r):
        p = fps[r].GetPosition(); return (mm(p.x), mm(p.y))

    u4 = fab_bbox(fps["U4"])             # module body 148..166 x 94..119.5
    ant = [u4[0], u4[1], u4[2], by0]       # overhang (antenna end) 148..166 x 94..100
    u5 = fab_bbox(fps["U5"])
    u5_pads = sorted([(mm(p.GetPosition().x), mm(p.GetPosition().y)) for p in fps["U5"].Pads()])
    j1 = fab_bbox(fps["J1"]); j3 = fab_bbox(fps["J3"]); j5 = fab_bbox(fps["J5"])
    j1_pins = sorted([(mm(p.GetPosition().x), mm(p.GetPosition().y)) for p in fps["J1"].Pads()], key=lambda q: q[1])
    j3_pins = sorted([(mm(p.GetPosition().x), mm(p.GetPosition().y)) for p in fps["J3"].Pads()])
    j5_pins = sorted([(mm(p.GetPosition().x), mm(p.GetPosition().y)) for p in fps["J5"].Pads()], key=lambda q: q[1])
    sw1, sw2, d3, d4 = pos("SW1"), pos("SW2"), pos("D3"), pos("D4")

    # ---- case frame ------------------------------------------------------------------------
    w, g = D["wall"], D["board_gap"]
    X0 = bx0 - g - w
    Y0 = by1 + g + w
    X = lambda kx: round(kx - X0, 4)
    Y = lambda ky: round(Y0 - ky, 4)
    def rectK(x0, y0, x1, y1):           # KiCad rect -> case rect [X0,Y0,X1,Y1]
        return [X(x0), Y(y1), X(x1), Y(y0)]

    z_pb = D["floor_t"] + D["under_gap"]
    z_pt = z_pb + t_pcb
    z_li = z_pt + D["lid_air"]
    z_wall = z_li - D["seam"]
    z_top = z_li + D["lid_t"]

    # outlines (case coords): main box + antenna bump (the bump reaches down into the main box)
    main_i = rectK(bx0 - g, by0 - g, bx1 + g, by1 + g)
    bump_i = [X(ant[0] - D["ant_air"]), main_i[3] - 7.0, X(ant[2] + D["ant_air"]), Y(ant[1] - D["ant_air"])]
    main_o = [main_i[0] - w, main_i[1] - w, main_i[2] + w, main_i[3] + w]
    bump_o = [bump_i[0] - w, bump_i[1], bump_i[2] + w, bump_i[3] + w]

    P = {}
    P.update({k: v for k, v in D.items() if not isinstance(v, (tuple, str, bool))})
    P.update(dict(X0=X0, Y0=Y0, t_pcb=t_pcb, z_pb=z_pb, z_pt=z_pt, z_li=z_li, z_wall=z_wall, z_top=z_top,
                  main_o=main_o, bump_o=bump_o, main_i=main_i, bump_i=bump_i))
    P["use_inserts"] = D["use_inserts"]
    P["label"] = D["label"]
    P["board"] = rectK(bx0, by0, bx1, by1)
    P["antenna"] = rectK(*ant)
    P["esp_module"] = rectK(*u4)
    P["holes"] = [[X(holes[r][0]), Y(holes[r][1])] for r in ("H1", "H2", "H3")]

    # ---- lid features ----------------------------------------------------------------------
    P["led"] = [[X(d4[0]), Y(d4[1])], [X(d3[0]), Y(d3[1])]]               # D4 red PWR, D3 green LINK
    P["z_led_tube"] = z_pt + H["LED_1206"] + D["led_tube_gap"]
    P["rst"] = [X(sw1[0]), Y(sw1[1])]
    P["z_rst_tube"] = z_pt + H["SW_act"] + D["rst_tube_gap"]
    P["boot"] = [X(sw2[0]), Y(sw2[1])]
    P["boot_x"] = [X(D["boot_hinge_kx"]), X(D["boot_tip_kx"])]
    P["boot_y"] = [Y(sw2[1]) - D["boot_w"] / 2, Y(sw2[1]) + D["boot_w"] / 2]
    P["z_stem"] = z_pt + H["SW_act"] + D["stem_gap"]
    j5c = (sum(p[0] for p in j5_pins) / 6, (j5_pins[0][1] + j5_pins[-1][1]) / 2)
    ow, ol = D["j5_open"]
    P["j5_open"] = [X(j5c[0]) - ow / 2, Y(j5c[1]) - ol / 2, X(j5c[0]) + ow / 2, Y(j5c[1]) + ol / 2]
    # BME280 baffles (lid) and ribs (base): along the two milled slots of the island
    sA = [s for s in slots if max(p[0] for p in s) - min(p[0] for p in s) > 5][0]     # horizontal slot (y = 140)
    sB = [s for s in slots if max(p[1] for p in s) - min(p[1] for p in s) > 5][0]     # vertical slot (x = 157.8)
    sA_bb = [min(p[0] for p in sA), min(p[1] for p in sA), max(p[0] for p in sA), max(p[1] for p in sA)]
    sB_bb = [min(p[0] for p in sB), min(p[1] for p in sB), max(p[0] for p in sB), max(p[1] for p in sB)]
    P["slotA"] = rectK(*sA_bb); P["slotB"] = rectK(*sB_bb)
    yA = (sA_bb[1] + sA_bb[3]) / 2           # 140.0
    xB = (sB_bb[0] + sB_bb[2]) / 2           # 157.8
    # baffle A: along y = 140 (between H3 column / D3 and the breakout), from baffle B to the right wall
    P["baffleA"] = [X(157.0), Y(140.2), main_i[2], Y(139.1)]
    # baffle B: between J3 (x <= 156.2) and the breakout (x >= 158.7), from baffle A to the front wall
    P["baffleB"] = [X(157.0), main_i[1], X(158.0), Y(139.1)]
    P["z_baffle"] = z_pt + D["baffle_gap"]
    P["ribA"] = [X(sA_bb[0] - 6.2), Y(sA_bb[3]), main_i[2], Y(sA_bb[1])]
    P["ribB"] = [X(sB_bb[0]), main_i[1], X(sB_bb[2]), Y(yA)]
    P["z_rib"] = z_pb - D["rib_gap"]
    # rest ribs under J1 (left of its pins) and next to J5 (plug-in forces), touching the board bottom
    P["rest_j1"] = rectK(101.0, j1[1], 102.4, j1[3])
    P["rest_j5"] = rectK(169.0, 105.5, 170.2, 118.0)

    # J1 cable window: centred on the pin row, through the left wall
    j1yc = (j1_pins[0][1] + j1_pins[-1][1]) / 2
    P["win"] = [Y(j1yc) - D["win_w"] / 2, Y(j1yc) + D["win_w"] / 2, z_li - D["win_h"], z_li]
    td, (tw, th) = D["tie_depth"], D["tie_tunnel"]
    P["tie"] = [-td, P["win"][0], 0.0, P["win"][1], P["win"][2]]              # x0, y0, x1, y1, ztop
    P["tie_tunnel"] = [-td + 0.8, -td + 0.8 + tw, P["win"][2] - 0.9 - th, P["win"][2] - 0.9]
    # J3 knock-out in the front wall, centred on J3
    j3xc = (j3_pins[0][0] + j3_pins[-1][0]) / 2
    P["ko"] = [X(j3xc) - D["j3_ko_w"] / 2, X(j3xc) + D["j3_ko_w"] / 2, z_li - D["win_h"], z_li]

    # lid lip interruptions (J1 window, J3 knock-out up to baffle B, J5 opening)
    P["lip_cut"] = [
        [-1.0, P["win"][0] - 2.0, 4.5, P["win"][1] + 2.0],
        [P["ko"][0] - 2.0, -1.0, P["baffleB"][0], 4.5],
        [P["j5_open"][0] - 2.1, P["j5_open"][1] - 3.6, main_o[2] + 1, main_i[3] + 1.0],
    ]

    # vents
    vw = D["vent_w"]; vb = D["vent_w_bme"]
    P["vent_lid"] = [[x, Y(122.5), x, Y(103.5)] for x in [X(128.5 + 3 * i) for i in range(6)]]           # over buck + LDO
    P["vent_lid_bme"] = [[X(160.4 + 2.5 * i), Y(151.6), X(160.4 + 2.5 * i), Y(142.8)] for i in range(5)]  # over BME280
    if not D["vents_lid_general"]:
        P["vent_lid"] = []
    if not D["vents_lid_bme"]:
        P["vent_lid_bme"] = []
    P["vent_right"] = [Y(152.0 - 3.0 * i) for i in range(4)]            # right wall, BME corner (y centres)
    P["vent_front"] = [X(161.5 + 3.0 * i) for i in range(5)]            # front wall, BME corner (x centres)
    P["z_vent_bme"] = [D["floor_t"] + 0.6, z_li - D["lip_h"] - 1.5]
    P["vent_left"] = [Y(k) for k in (103.5, 106.5, 109.5, 134.5, 137.5, 140.5, 143.5)]
    P["vent_back"] = [X(k) for k in (149.0, 153.0, 157.0, 161.0, 165.0)]
    P["z_vent"] = [z_pt + 1.4, z_li - D["lip_h"] - 2.3]
    P["z_vent_back"] = [D["floor_t"] + 1.5, z_li - D["lip_h"] - 2.3]

    # ears (diagonal)
    el, ew = D["ear_len"], D["ear_w"]
    P["ear_left"] = [main_o[0] - el, Y(D["ear_left_ky"]) - ew / 2, main_o[0] + 1.0, Y(D["ear_left_ky"]) + ew / 2]
    P["ear_right"] = [main_o[2] - 1.0, Y(D["ear_right_ky"]) - ew / 2, main_o[2] + el, Y(D["ear_right_ky"]) + ew / 2]
    P["ear_hole_off"] = 8.5          # from the outer wall
    P["ear_slot_off"] = [3.6, 14.0]
    P["ear_slot"] = list(D["ear_slot"])

    # text: label pocket + legends [text, x, y, size, rot, halign]
    P["label_pocket"] = [X(108.5), Y(150.5), X(154.5), Y(141.9)]
    P["label_xy"] = [(P["label_pocket"][0] + P["label_pocket"][2]) / 2, (P["label_pocket"][1] + P["label_pocket"][3]) / 2]
    ls = D["legend_size"]
    P["legends"] = [
        ["PWR", X(d4[0]), Y(d4[1]) - 4.1, ls, 0, "center"],
        ["LINK", X(d3[0]) - 2.7, Y(d3[1]), ls, 0, "right"],
        ["RST", X(sw1[0]) - 2.2, Y(sw1[1]), ls, 0, "right"],
        ["BOOT", X(sw2[0]) - 2.5, Y(sw2[1]) + 5.2, ls, 0, "center"],
        ["PROG", X(j5c[0]) - ow / 2 - D["j5_recess"] - 2.6, Y(j5c[1]) - 1.5, ls, 90, "center"],
        ["1", X(j5c[0]) - ow / 2 - D["j5_recess"] - 2.6, Y(j5_pins[0][1]) + 0.2, 2.4, 0, "center"],
        ["I2C", X(j3xc) + 2.5, 3.8, 2.5, 0, "center"],
    ]

    # ---- board + component envelopes (case coords), for the fit check / renders / STEP ------------
    parts = []   # {ref, kind, box:[x0,y0,z0,x1,y1,z1], color, kicad:[...]}
    def add(ref, kind, kbox, z0, z1, color="body"):
        r = rectK(*kbox)
        parts.append(dict(ref=ref, kind=kind, box=[r[0], r[1], round(z0, 4), r[2], r[3], round(z1, 4)],
                          kicad=[round(v, 3) for v in kbox], color=color))
    def pkg(f):
        fp = f.GetFPIDAsString()
        for key in ("C_1206", "C_0805", "R_0805", "D_SMA", "LED_1206", "Fuse_1206", "TSOT-23-6", "SOT-223", "SOIC-14", "SOT-23"):
            if key in fp:
                return key
        return None
    for ref, f in sorted(fps.items()):
        if ref in ("H1", "H2", "H3"):
            continue
        k = pkg(f)
        if k:
            bb = fab_bbox(f)
            if k in ("SOT-23", "TSOT-23-6", "SOT-223", "SOIC-14"):     # include the gull-wing leads: pads bbox
                pxs = [mm(p.GetPosition().x) for p in f.Pads()]; pys = [mm(p.GetPosition().y) for p in f.Pads()]
                bb = [min(bb[0], min(pxs)), min(bb[1], min(pys)), max(bb[2], max(pxs)), max(bb[3], max(pys))]
            add(ref, k, bb, z_pt, z_pt + H[k], "led_r" if ref == "D4" else "led_g" if ref == "D3" else "smd")
    add("L1", "inductor", fab_bbox(fps["L1"]), z_pt, z_pt + H["L1"], "dark")
    add("U4", "module", u4, z_pt, z_pt + H["U4"], "metal")
    for ref in ("SW1", "SW2"):
        bb = fab_bbox(fps[ref]); c = pos(ref)
        add(ref, "switch_body", bb, z_pt, z_pt + H["SW_body"], "dark")
        pxs = [mm(p.GetPosition().x) for p in fps[ref].Pads()]; pys = [mm(p.GetPosition().y) for p in fps[ref].Pads()]
        add(ref, "switch_legs", [min(pxs) - 0.78, min(pys) - 0.65, max(pxs) + 0.78, max(pys) + 0.65], z_pt, z_pt + 1.0, "metal")
        add(ref, "switch_actuator", [c[0] - 1.75, c[1] - 1.75, c[0] + 1.75, c[1] + 1.75], z_pt, z_pt + H["SW_act"], "dark")
    add("J1", "xh_header", j1, z_pt, z_pt + H["XH_header"], "white")
    add("J1", "xhp_plug", j1, z_pt + 2.0, z_pt + H["XH_mated"], "plug")
    add("J3", "xh_header", j3, z_pt, z_pt + H["XH_header"], "white")
    add("J3", "xhp_plug_optional", j3, z_pt + 2.0, z_pt + H["XH_mated"], "plug")      # only if a J3 cable is fitted
    add("J5", "header_body", [j5[0], j5[1], j5[2], j5[3]], z_pt, z_pt + H["J5_body"], "dark")
    add("J5", "header_pins", [j5c[0] - 0.32, j5_pins[0][1] - 0.32, j5c[0] + 0.32, j5_pins[-1][1] + 0.32], z_pt, z_pt + H["J5_pins"], "gold")
    hx0 = u5_pads[0][0] - 1.27; hx1 = u5_pads[-1][0] + 1.27; hy = u5_pads[0][1]
    add("U5", "bme_header", [hx0, hy - 1.27, hx1, hy + 1.27], z_pt, z_pt + H["U5_header"], "dark")
    add("U5", "bme_breakout", u5, z_pt + H["U5_header"], z_pt + H["U5_top"], "bme")
    # J1 wires (5 in a row along y, worst-case 1.9 mm OD): riser, bend, run out through the window
    wy0 = j1_pins[0][1] - WIRE_OD / 2; wy1 = j1_pins[-1][1] + WIRE_OD / 2
    xr = j1_pins[0][0]
    zw0 = z_pt + H["XH_mated"]
    z_run = zw0 + WIRE_BEND_R + WIRE_OD / 2                          # wire centre line of the horizontal run
    add("J1", "wires_riser_bend", [xr - WIRE_BEND_R - WIRE_OD / 2, wy0, xr + WIRE_OD / 2, wy1], zw0, z_run + WIRE_OD / 2, "wire")
    add("J1", "wires_run", [X0 - 3.0, wy0, xr - WIRE_BEND_R - WIRE_OD / 2, wy1], z_run - WIRE_OD / 2, z_run + WIRE_OD / 2, "wire")
    # Dupont 1x6 on J5 (programming cable), reaches up through the lid opening
    add("J5", "dupont_1x6", [j5c[0] - 1.27, j5_pins[0][1] - 1.27, j5c[0] + 1.27, j5_pins[-1][1] + 1.27],
        z_pt + H["J5_body"], z_pt + H["J5_body"] + H["dupont"], "plug")
    # below the board
    zb = z_pb
    for (px, py) in j1_pins + j3_pins:
        add("J1/J3", "xh_tail", [px - 0.6, py - 0.6, px + 0.6, py + 0.6], zb - HB["XH_tail"], zb, "gold")
    for (px, py) in j5_pins:
        add("J5", "j5_tail", [px - 0.85, py - 0.85, px + 0.85, py + 0.85], zb - HB["J5_tail"], zb, "gold")
    for (px, py) in u5_pads:
        add("U5", "u5_tail_untrimmed", [px - 0.85, py - 0.85, px + 0.85, py + 0.85], zb - HB["U5_tail_untrimmed"], zb, "gold")
    ch = [p for p in fps["U4"].Pads() if mm(p.GetDrillSize().x) > 0.9][0].GetPosition()
    add("U4", "centre_pad_solder", [mm(ch.x) - 1.0, mm(ch.y) - 1.0, mm(ch.x) + 1.0, mm(ch.y) + 1.0], zb - HB["U4_hole_blob"], zb, "gold")

    # THT pads (bottom side) for the rib / boss clearance check
    tht = []
    for f in fps.values():
        for p in f.Pads():
            if mm(p.GetDrillSize().x) > 0 and p.GetAttribute() != pcbnew.PAD_ATTRIB_NPTH:
                q = p.GetPosition(); tht.append([f.GetReference(), X(mm(q.x)), Y(mm(q.y)), round(max(mm(p.GetSize().x), mm(p.GetSize().y)) / 2, 3)])

    board = dict(outer=[[X(x), Y(y)] for x, y in outer], slots=[[[X(x), Y(y)] for x, y in s] for s in slots],
                 holes=P["holes"], hole_d=3.2, z0=z_pb, z1=z_pt, keepout_r=3.3)

    # ---- write ---------------------------------------------------------------------------------
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    json.dump(P, open(os.path.join(HERE, "out", "params.json"), "w"), indent=1)
    json.dump(dict(parts=parts, board=board, tht=tht, heights=H, below=HB, wire_od=WIRE_OD, wire_bend_r=WIRE_BEND_R,
                   kicad=dict(board=[bx0, by0, bx1, by1], antenna=ant, module=u4, holes=holes, X0=X0, Y0=Y0)),
              open(os.path.join(HERE, "out", "board_parts.json"), "w"), indent=1)

    def scad(v):
        if isinstance(v, bool): return "true" if v else "false"
        if isinstance(v, (int, float)): return f"{v:.4f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v)
        if isinstance(v, str): return json.dumps(v)
        if isinstance(v, (list, tuple)): return "[" + ", ".join(scad(x) for x in v) + "]"
        raise TypeError(v)
    lines = ["// generated by layout_gree.py from gree_bridge.kicad_pcb - do not edit by hand (edit the DESIGN knobs there)",
             f"// case frame: X = kicad_x - {X0:g}, Y = {Y0:g} - kicad_y, Z = 0 at the base bottom"]
    for k, v in P.items():
        lines.append(f"{k} = {scad(v)};")
    lines.append("board_outer = " + scad(board["outer"]) + ";")
    lines.append("board_slots = " + scad(board["slots"]) + ";")
    lines.append("parts = " + scad([[p["box"], p["color"]] for p in parts]) + ";")
    open(os.path.join(HERE, "gree_case_params.scad"), "w").write("\n".join(lines) + "\n")

    print(f"board {bx0:g}..{bx1:g} x {by0:g}..{by1:g}, t {t_pcb}, {len(slots)} slots, holes {holes}")
    print(f"case outer X {main_o[0]:g}..{main_o[2]:g}  Y {main_o[1]:g}..{bump_o[3]:g}  Z 0..{z_top:g}  "
          f"({main_o[2]-main_o[0]:g} x {bump_o[3]-main_o[1]:g} x {z_top:g} mm, ears +{2*D['ear_len']:g} in X)")
    print(f"z: floor top {D['floor_t']}, board {z_pb:g}..{z_pt:g}, wall top {z_wall:g}, lid inner {z_li:g}, top {z_top:g}")
    print(f"{len(parts)} envelopes, {len(tht)} THT pads -> gree_case_params.scad, out/params.json, out/board_parts.json")


if __name__ == "__main__":
    main()
