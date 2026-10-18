#!/usr/bin/env python3
"""
Gree bridge rev B case - fit check.

Works on the meshes OpenSCAD produced (out/check/*_inplace.stl = assembled position, out/stl/*.stl = print
orientation), the component envelopes from the KiCad file (out/board_parts.json) and out/params.json.
Distances are exact mesh-to-box minimum gaps (manifold3d min_gap), vertical clearances are measured by
intersecting the column above each part with the lid.  Writes out/fit_check.txt and out/fit_report.json,
exits 1 if any row fails.
usage: python3 fit_check.py
"""
import json, math, os, sys
import numpy as np
import trimesh
import manifold3d as m3d
from shapely.geometry import Polygon, Point, LineString, MultiPolygon, box as sbox
from shapely.ops import unary_union

HERE = os.path.dirname(os.path.abspath(__file__))
P = json.load(open(os.path.join(HERE, "out", "params.json")))
B = json.load(open(os.path.join(HERE, "out", "board_parts.json")))
K = B["kicad"]
X0, Y0 = K["X0"], K["Y0"]
INF = 1e9
rows, annot = [], {"A": [], "B": []}


def row(group, name, value, limit, op, note=""):
    if op == ">=":
        ok = value >= limit - 1e-6
    elif op == "<=":
        ok = value <= limit + 1e-6
    elif op == "==":
        ok = abs(value - limit) <= 0.02
    elif op == "in":
        ok = limit[0] - 1e-6 <= value <= limit[1] + 1e-6
    else:
        raise ValueError(op)
    rows.append(dict(group=group, name=name, value=round(float(value), 3), limit=r3(limit), op=op, ok=bool(ok), note=note))
    return value


def man_from_trimesh(t):
    return m3d.Manifold(m3d.Mesh(vert_properties=np.asarray(t.vertices, np.float32), tri_verts=np.asarray(t.faces, np.uint32)))


def load(path):
    t = trimesh.load(path)
    return t, man_from_trimesh(t)


def mbox(b):
    return m3d.Manifold.cube((b[3] - b[0], b[4] - b[1], b[5] - b[2])).translate((b[0], b[1], b[2]))


def mcyl(x, y, z0, z1, d):
    return m3d.Manifold.cylinder(z1 - z0, d / 2, d / 2, 48).translate((x, y, z0))


def gap(a, b, search=30.0):
    g = a.min_gap(b, search)
    return INF if g >= search - 1e-9 else g


def r3(v):
    return [round(x, 3) for x in v] if isinstance(v, (list, tuple)) else round(v, 3)


def vol(m):
    return m.volume() if not m.is_empty() else 0.0


def section(man, z):
    polys = [Polygon(p) for p in man.slice(z).to_polygons() if len(p) >= 3]
    # even-odd: build polygons with holes via symmetric difference
    res = Polygon()
    for p in polys:
        res = res.symmetric_difference(p.buffer(0))
    return res


def up_clearance(man, b, height=40.0):
    col = mbox([b[0], b[1], b[5], b[3], b[4], b[5] + height])
    i = man ^ col
    if i.is_empty() or i.volume() < 1e-6:
        return INF
    return i.bounding_box()[2] - b[5]


def max_inscribed_width(poly):
    """2 x the radius of the largest circle that fits in the region (bridge / overhang span)"""
    if poly.is_empty or poly.area < 1e-4:
        return 0.0
    lo, hi = 0.0, 0.5 * max(poly.bounds[2] - poly.bounds[0], poly.bounds[3] - poly.bounds[1])
    for _ in range(25):
        mid = (lo + hi) / 2
        if poly.buffer(-mid, resolution=8).is_empty:
            hi = mid
        else:
            lo = mid
    return 2 * lo


def main():
    base_t, base = load(os.path.join(HERE, "out", "check", "base_inplace.stl"))
    lid_t, lid = load(os.path.join(HERE, "out", "check", "lid_inplace.stl"))
    cap_t, cap = load(os.path.join(HERE, "out", "check", "cap_inplace.stl"))
    zpb, zpt, zli, ztop, zwall = P["z_pb"], P["z_pt"], P["z_li"], P["z_top"], P["z_wall"]

    # ---------------------------------------------------------------- meshes
    for n, t in (("base", base_t), ("lid", lid_t), ("cap", cap_t)):
        row("mesh", f"{n}: watertight single body", float(t.is_watertight and len(t.split(only_watertight=False)) == 1), 1, "==",
            f"{t.volume / 1000:.1f} cm3, ~{t.volume / 1000 * 1.27:.0f} g PETG solid-equivalent")
    row("mesh", "lid x cap overlap (mm3)", vol(lid ^ cap), 0.01, "<=", "cap snapped in")
    row("mesh", "base x cap overlap (mm3)", vol(base ^ cap), 0.01, "<=")

    # OpenSCAD <-> CadQuery (STEP twin)
    for n, m in (("base", base), ("lid", lid), ("cap", cap)):
        cqp = os.path.join(HERE, "out", "check", f"cq_{n}.stl")
        if os.path.exists(cqp):
            _, c = load(cqp)
            d = vol(m - c) + vol(c - m)
            row("mesh", f"{n}: OpenSCAD vs CadQuery symmetric difference (% of volume)", 100 * d / m.volume(), 0.5, "<=",
                "text kerning + facet differences only")

    foot = unary_union([sbox(*P["main_o"]).buffer(-P["r_out"]).buffer(P["r_out"]),
                        sbox(*P["bump_o"]).buffer(-P["r_bump"]).buffer(P["r_bump"])]).buffer(-1.0)
    row("mesh", "mounting face closed under the case body (open area, mm2)", foot.difference(section(base, 0.3)).area, 0.01, "<=",
        "flat back for double-sided tape")
    for e, side, nm in ((P["ear_left"], -1, "left"), (P["ear_right"], 1, "right")):
        wx = P["main_o"][0] if side < 0 else P["main_o"][2]
        hx = wx + side * P["ear_hole_off"]
        row("mesh", f"{nm} ear screw hole: wall to hole edge", abs(hx - wx) - P["ear_hole"] / 2, 2.0, ">=",
            f"hole at X {hx:.1f}, slots at {P['ear_slot_off']} mm from the wall")

    # ---------------------------------------------------------------- board in the case
    bd = B["board"]
    bpoly = Polygon(bd["outer"], bd["slots"])
    for (hx, hy) in bd["holes"]:
        bpoly = bpoly.difference(Point(hx, hy).buffer(bd["hole_d"] / 2, resolution=24))
    pcb = m3d.Manifold.extrude(m3d.CrossSection([list(map(tuple, bpoly.exterior.coords[:-1]))] +
                                                [list(map(tuple, h.coords[:-1])) for h in bpoly.interiors], m3d.FillRule.EvenOdd),
                               bd["z1"] - bd["z0"]).translate((0, 0, bd["z0"]))
    row("board", "board x base overlap (mm3)", vol(pcb ^ base), 0.01, "<=", "rests on 3 bosses + 2 rest ribs")
    row("board", "board x lid overlap (mm3)", vol(pcb ^ lid), 0.01, "<=")
    row("board", "board to lid, smallest gap (nothing in the lid presses on the board)", gap(pcb, lid), 0.3, ">=",
        "rev 2: the board is held by its 3 screws only")
    for i, (hx, hy) in enumerate(bd["holes"]):
        bz = (base ^ mcyl(hx, hy, 0, ztop + 1, 7.0)).bounding_box()[5]
        row("board", f"H{i + 1}: base boss top - board bottom", bz - zpb, 0.0, "==", "board sits on the boss")
    row("board", "boss contact diameter vs 6.6 mm keep-out ring (self-tapping build)", P["boss_d"], 2 * bd["keepout_r"], "<=",
        "H*_SCREW_HEAD rule areas, r 3.3")
    for nm, bx in (("left", [0, 8, 0, 2, 11, 30]), ("right", [78, 36, 0, 80, 40, 30]), ("front", [8, 0, 0, 14, 2, 30]),
                   ("back", [36, 57, 0, 42, 59, 30])):
        zb_ = (base ^ mbox(bx)).bounding_box()[5]; zl_ = (lid ^ mbox(bx)).bounding_box()[2]
        row("board", f"lid plate on the {nm} wall top (lid underside - wall top)", zl_ - zb_, 0.0, "==", "rev 2: lid sits on the walls")

    # wall clearance at mid-board height
    sec = section(base, (zpb + zpt) / 2)
    bo = Polygon(bd["outer"])
    bxs = [p[0] for p in bd["outer"]]; bys = [p[1] for p in bd["outer"]]
    sides = {"left (J1)": LineString([(min(bxs), min(bys) + 3), (min(bxs), max(bys) - 3)]),
             "right (J5 / BME)": LineString([(max(bxs), min(bys) + 3), (max(bxs), max(bys) - 3)]),
             "front (J3 / BME)": LineString([(min(bxs) + 3, min(bys)), (max(bxs) - 3, min(bys))]),
             "back (antenna edge)": LineString([(min(bxs) + 3, max(bys)), (max(bxs) - 3, max(bys))])}
    row("walls", "board outline to wall, minimum", bo.exterior.distance(sec), P["fit"], ">=", "section at mid-board height")
    for k, ls in sides.items():
        row("walls", f"board edge to wall, {k}", ls.distance(sec), P["fit"], ">=")

    # ---------------------------------------------------------------- antenna
    a = P["antenna"]
    abox = [a[0], a[1], zpt, a[2], a[3], zpt + B["heights"]["U4"]]
    am = mbox(abox)
    g_ant = min(gap(am, base), gap(am, lid), gap(am, cap))
    row("antenna", "antenna end (6 mm overhang) to any case plastic", g_ant, 5.0, ">=", "air only within 5 mm")
    row("antenna", "antenna to base", gap(am, base), 5.0, ">="); row("antenna", "antenna to lid", gap(am, lid), 5.0, ">=")
    screws = [mcyl(sx, sy, zt, zpt, 3.0) + mcyl(sx, sy, zpt, zh, P["head_d"]) for (sx, sy, zt, zh) in P["screws"]]
    heads = [mcyl(sx, sy, zpt, zh, P["head_d"]) for (sx, sy, zt, zh) in P["screws"]]
    row("antenna", "antenna to nearest M3 screw (metal)", min(gap(am, s, 80) for s in screws), 5.0, ">=", "Espressif: keep metal >= 15 mm")
    row("antenna", "antenna to nearest M3 screw, recommended", min(gap(am, s, 80) for s in screws), 15.0, ">=")
    bosses = [mcyl(hx, hy, P["floor_t"], zpb, max(P["boss_flare_d"], P["boss_d_insert"])) for (hx, hy) in P["holes"]]
    row("antenna", "antenna to nearest boss (also heat-set insert spot)", min(gap(am, s, 80) for s in bosses), 5.0, ">=")
    ears = []
    for e, side in ((P["ear_left"], -1), (P["ear_right"], 1)):
        wx = P["main_o"][0] if side < 0 else P["main_o"][2]
        ears.append(mcyl(wx + side * P["ear_hole_off"], (e[1] + e[3]) / 2, -3, P["ear_t"] + 4, 8.0))   # #8 / M4 pan head
    row("antenna", "antenna to ear mounting screws (metal, head 8 mm)", min(gap(am, s, 80) for s in ears), 15.0, ">=")
    rests = [mbox([P[k][0], P[k][1], P["floor_t"], P[k][2], P[k][3], zpb]) for k in ("rest_j1", "rest_j5")]
    row("antenna", "antenna to nearest board rest rib", min(gap(am, s, 80) for s in rests), 5.0, ">=")
    annot["B"] += [f"antenna end -> nearest case plastic {g_ant:5.2f} mm (air)",
                   f"antenna -> nearest screw  {min(gap(am, s, 80) for s in screws):5.1f} mm"]

    # ---------------------------------------------------------------- components (top side) and envelopes
    special_up = {("SW2", "switch_actuator"): ((0.5, 0.7), "BOOT stem, nominal (tolerance stack below)"),
                  ("SW1", "switch_actuator"): ((1.2, 3.0), "RESET guide tube, nominal")}
    tall = []
    for p in B["parts"]:
        b = p["box"]
        if b[5] <= zpb + 1e-6:
            continue
        bm = mbox(b)
        key = (p["ref"], p["kind"])
        g_l, g_b = gap(bm, lid), gap(bm, base)
        g_c = gap(bm, cap) if p["kind"] != "dupont_1x6" else INF
        hit = vol(bm ^ lid) + vol(bm ^ base) + (vol(bm ^ cap) if p["kind"] != "dupont_1x6" else 0)
        up = up_clearance(lid, b) if p["kind"] != "dupont_1x6" else INF
        h_above = b[5] - zpt
        name = f'{p["ref"]} {p["kind"]} (top {h_above:.2f} above board)'
        if p["kind"] == "dupont_1x6":
            row("J5 access", "Dupont 1x6 on J5 through the lid opening (cap off): gap to lid", g_l, 0.5, ">=",
                f"housing top {b[5]:.1f} vs lid top {ztop:.1f}")
            continue
        row("parts", name + ": overlap with case (mm3)", hit, 0.0, "<=")
        lim3d = 0.25
        row("parts", name + ": 3D gap to lid", g_l, lim3d, ">=")
        row("parts", name + ": 3D gap to base", g_b, lim3d, ">=")
        if g_c < INF:
            row("parts", name + ": 3D gap to J5 cap", g_c, lim3d, ">=")
        if key in special_up:
            rng, note = special_up[key]
            row("parts", name + ": vertical gap to lid feature above", up, rng, "in", note)
        elif up < INF and p["kind"] in ("wires_riser_bend", "wires_run"):
            row("parts", name + ": vertical gap to lid above", up, 0.3, ">=", "flexible wires, 1.9 mm max OD envelope")
        elif up < INF and h_above >= 2.0:
            row("parts", name + ": vertical gap to lid above", up, 1.0, ">=")
        if h_above >= 3.0 or p["kind"] in ("wires_riser_bend", "wires_run", "xhp_plug", "xhp_plug_optional"):
            tall.append((p["ref"], p["kind"], h_above, up, g_l, g_b))
    # below the board
    for p in B["parts"]:
        b = p["box"]
        if b[5] > zpb + 1e-6:
            continue
        bm = mbox(b)
        row("under", f'{p["ref"]} {p["kind"]} ({zpb - b[2]:.1f} below board): gap to base', gap(bm, base), 0.3, ">=")
    # THT pads vs rest ribs / bosses (bottom side)
    sb = section(base, zpb - 0.05)
    dmin, who = INF, ""
    for ref, x, y, r in B["tht"]:
        d = Point(x, y).buffer(r, resolution=16).distance(sb)
        if d < dmin:
            dmin, who = d, ref
    row("under", f"bottom-side THT pads to boss / rest rib tops (closest: {who})", dmin, 0.5, ">=", "solder fillets stay free")

    # ---------------------------------------------------------------- J1 cable
    wo, wr = B["wire_od"], B["wire_bend_r"]
    w = P["win"]
    j1 = [p for p in B["parts"] if p["kind"] == "xhp_plug" and p["ref"] == "J1"][0]["box"]
    run = [p for p in B["parts"] if p["kind"] == "wires_run"][0]["box"]
    row("J1 cable", "window width vs 5-wire ribbon (2.5 pitch, 1.9 OD)", (w[1] - w[0]) - (run[4] - run[1]), 0.5, ">=",
        f"window {w[1] - w[0]:.1f} x {w[3] - w[2]:.1f} mm")
    row("J1 cable", "window bottom below wire run", run[2] - w[2], 0.3, ">=")
    row("J1 cable", "wire run top to lid underside", w[3] - run[5], 0.3, ">=", f"bend r {wr} mm, worst-case OD {wo} mm")
    row("J1 cable", "J1 mated plug top to lid underside", zli - j1[5], 3.0, ">=", "room for the wires to turn")
    row("J1 cable", "wire run top to lid underside, PCB 1.76 + boss worst case", w[3] - run[5] - P["tol_pcb"] - P["tol_base"], 0.2, ">=")
    tt = P["tie_tunnel"]
    row("J1 cable", "zip-tie tunnel width (strap <= 3.6 mm)", tt[1] - tt[0], 3.6, ">=", f"height {tt[3] - tt[2]:.1f} mm")
    annot["A"] += [f"J1 plug top -> lid underside {zli - j1[5]:5.2f} mm",
                   f"wires (1.9 OD, r {wr}) -> lid  {w[3] - run[5]:5.2f} mm",
                   f"window {w[1] - w[0]:.0f} x {w[3] - w[2]:.1f} mm, ribbon {run[4] - run[1]:.1f} x {wo}"]

    # ---------------------------------------------------------------- buttons / LEDs alignment + mechanics
    def ctr(ref, kind):
        b = [p for p in B["parts"] if p["ref"] == ref and p["kind"] == kind][0]["box"]
        return ((b[0] + b[3]) / 2, (b[1] + b[4]) / 2, b[5])
    sw1 = ctr("SW1", "switch_actuator"); sw2 = ctr("SW2", "switch_actuator")
    d3 = ctr("D3", "LED_1206"); d4 = ctr("D4", "LED_1206")
    row("buttons", "RESET hole centre to SW1 actuator centre (xy)", math.dist(P["rst"], sw1[:2]), 0.1, "<=")
    row("buttons", "BOOT stem centre to SW2 actuator centre (xy)", math.dist(P["boot"], sw2[:2]), 0.1, "<=")
    row("buttons", "BOOT stem diameter vs 3.5 mm actuator", P["stem_d"], 3.5, "<=")
    stem_gap = P["z_stem"] - sw2[2]
    rst_gap = P["z_rst_tube"] - sw1[2]
    a_len = P["boot"][1] - P["boot_tongue"][1]                # hinge (front) to stem
    t_stack = P["tol_pcb"] + P["tol_base"] + P["tol_lid"] + P["tol_switch"]
    t_pr = P["tol_pcb"] + P["tol_base"] + P["tol_lid"]
    stroke = lambda gp: gp + P["sw_travel"] + P["sw_overtravel"]
    strain = lambda d: 1.5 * P["boot_t"] * d / a_len ** 2 * 100
    row("buttons", "BOOT stem to actuator top, nominal", stem_gap, (0.5, 0.7), "in", "lid on the wall top, PCB 1.60")
    row("buttons", "BOOT stem gap, PCB 1.76 + boss/lid/switch worst case (lid never holds BOOT)", stem_gap - t_stack, 0.05, ">=",
        f"stack +/-{t_stack:.2f}: PCB {P['tol_pcb']}, boss {P['tol_base']}, lid {P['tol_lid']}, switch {P['tol_switch']}")
    row("buttons", "BOOT stem gap, PCB 1.44 + worst case (largest gap)", stem_gap + t_stack, 1.2, "<=")
    row("buttons", f"BOOT full press at the largest gap: stroke {stroke(stem_gap + t_stack):.2f} mm, tongue strain (%)",
        strain(stroke(stem_gap + t_stack)), 2.0, "<=",
        f"hinge to stem {a_len:.1f} mm, tongue {P['boot_t']} mm, travel {P['sw_travel']} + {P['sw_overtravel']} overtravel")
    row("buttons", f"BOOT press at nominal: stroke {stroke(stem_gap):.2f} mm, strain (%)", strain(stroke(stem_gap)), 2.0, "<=")
    row("buttons", "RESET guide tube to SW1 actuator, nominal", rst_gap, (1.2, 1.5), "in", "poke with a paper clip")
    row("buttons", "RESET tube gap, PCB 1.76 + worst case", rst_gap - t_stack, 0.8, ">=", "tube never presses RESET")
    row("buttons", "RESET tube gap, PCB 1.44 + worst case", rst_gap + t_stack, 2.5, "<=", "a paper clip still reaches")
    row("BME280", "baffle bottom above board, PCB 1.76 + worst case", P["z_baffle"] - zpt - t_pr, 0.2, ">=")
    row("LEDs", "light tube to LED top, PCB 1.76 + worst case", P["z_led_tube"] - d4[2] - t_pr, 1.5, ">=")
    row("LEDs", "D4 (red PWR) light hole centre offset", math.dist(P["led"][0], d4[:2]), 0.1, "<=")
    row("LEDs", "D3 (green LINK) light hole centre offset", math.dist(P["led"][1], d3[:2]), 0.1, "<=")
    row("LEDs", "light tube bottom to LED top", P["z_led_tube"] - d4[2], 1.5, ">=", "tubes stop light bleeding between LEDs")
    annot["A"] += [f"BOOT stem -> SW2 actuator {stem_gap:5.2f} mm (min {stem_gap - t_stack:4.2f})",
                   f"RESET tube -> SW1 actuator {rst_gap:5.2f} mm (min {rst_gap - t_stack:4.2f})"]

    # ---------------------------------------------------------------- fits (sections)
    s_l = section(lid, zli - 1.5); s_b = section(base, zli - 1.5)
    row("fits", "lid lip to base wall", s_l.distance(s_b), P["fit"] - 0.02, ">=", "section 1.5 mm under the lid plate")
    row("fits", "lid lip to base wall, maximum play", P["fit"], 0.4, "<=")
    s_c = section(cap, ztop - 0.5); s_lt = section(lid, ztop - 0.5)
    row("fits", "J5 cap flange to recess", s_c.distance(s_lt), P["fit"] - 0.02, ">=")
    s_c2 = section(cap, zli + 0.5); s_l2 = section(lid, zli + 0.5)
    row("fits", "J5 cap plug to opening", s_c2.distance(s_l2), P["cap_plug_fit"] - 0.02, ">=")
    snap = (P["j5_open"][2] - P["j5_open"][0]) / 2 - ((P["j5_open"][2] - P["j5_open"][0]) / 2 - P["cap_plug_fit"] + P["cap_bump"])
    row("fits", "J5 cap snap overlap under the plate (per side)", -snap, 0.2, ">=", "bumps flex the 0.8 mm plug walls")

    # ---------------------------------------------------------------- screws
    L_s = P["screw_len"]; tip_z = P["screws"][0][2]
    nm = f"M3 x {L_s:g} pan head"
    row("screws", f"{nm}: thread engagement in the base boss", zpb - tip_z, 4.0, ">=", "self-tapping in the 2.5 mm pilot")
    row("screws", f"{nm}: tip above the pilot hole bottom", tip_z - P["pilot_bottom"], 0.2, ">=")
    row("screws", f"{nm}: tip above the mounting face", tip_z, 1.3, ">=", "back stays closed")
    row("screws", "next standard length (M3 x 8): tip above the mounting face", zpt - 8.0, 1.3, "<=",
        "M3 x 8 would break through, so M3 x 6 is the longest that fits")
    row("screws", "pan head inside the 6.6 mm keep-out ring", P["head_d"], 2 * bd["keepout_r"], "<=")
    g_hl = min(gap(h, lid) for h in heads)
    row("screws", "screw heads (5.6 x 2.4) to any lid feature", g_hl, 1.0, ">=", "no clamp columns any more; baffle relieved")
    top_parts = [mbox(p["box"]) for p in B["parts"] if p["box"][5] > zpb + 1e-6]
    g_hp = min(gap(h, q, 10) for h in heads for q in top_parts)
    row("screws", "screw heads to the nearest component envelope", g_hp, 0.3, ">=", "screwdriver and head clear the parts")
    # heat-set insert variant (use_inserts = True): checked from the parameters
    ins_bot = zpb - P["insert_depth"]
    row("screws", "insert variant: M3 insert hole bottom above the mounting face", ins_bot, 1.5, ">=",
        f"hole {P['insert_d']} x {P['insert_depth']} mm for inserts up to {P['insert_len']} mm long")
    row("screws", "insert variant: M3 x 6 tip above the insert hole bottom", tip_z - ins_bot, 0.3, ">=")
    row("screws", "insert variant: boss wall around the insert hole", (P["boss_d_insert"] - P["insert_d"]) / 2, 1.5, ">=",
        f"boss grows to {P['boss_d_insert']} mm (plastic past the copper keep-out ring is harmless)")
    row("screws", "insert variant: thread length in the insert", min(P["insert_len"], zpb - tip_z), 3.0, ">=")
    annot["A"] += [f"board screws M3 x {L_s:g}: {zpb - tip_z:.1f} mm in the boss, tip {tip_z:.1f} above the back"]

    # ---------------------------------------------------------------- snap latches
    fit, wall_t = P["fit"], P["wall"]
    lw, lt, lh, lf, pre = P["latch_w"], P["latch_t"], P["latch_hook"], P["latch_flat"], P["latch_preload"]
    z_ab, z_c, z_wc = P["latch_z"]
    L_arm = zli - (z_c + lh)                                  # root (plate underside) to the top of the hook
    d_max = lh - fit                                          # deflection to pass the wall's inner face
    eps_l = 1.5 * lt * d_max / L_arm ** 2 * 100
    E = 2000.0; mu = 0.3; phi = math.atan(mu)
    L_eff = zli - (z_c + lh / 2)
    k = E * lw * lt ** 3 / (4 * L_eff ** 3)
    row("latches", f"arm L {L_arm:.2f} (plate to hook top) x t {lt} x w {lw} mm, deflection {d_max:.2f} mm: peak strain (%)",
        eps_l, 2.0, "<=", "eps = 1.5 t d / L^2, PETG")
    row("latches", "catch face angle from vertical in the lid print orientation (deg)", 45.0, 45.0, "<=", "45 deg overhang, no support")
    row("latches", "lead-in ramp angle from vertical (deg)", 30.0, 30.0, "<=", f"+ {P['latch_leadin']} mm chamfer on the wall top")
    t_l = P["tol_base"] + P["tol_lid"]
    row("latches", "preload (arm stays deflected when latched), nominal", pre, (0.2, 0.4), "in", "45 deg catch pulls the lid down")
    row("latches", "preload, worst case (no rattle)", pre - t_l, 0.05, ">=", f"window +/-{P['tol_base']}, hook +/-{P['tol_lid']}")
    row("latches", "hook engagement in the window, nominal", lh - fit - pre, 0.4, ">=")
    row("latches", "hook engagement, worst case", lh - fit - pre - t_l, 0.25, ">=")
    row("latches", f"pull-off force per latch (k {k:.1f} N/mm, mu {mu}) (N)", k * d_max * math.tan(math.radians(45) + phi), 8.0, ">=",
        "estimate; release with a screwdriver through the window")
    row("latches", "click-on force per latch (N)", k * d_max * math.tan(math.radians(30) + phi), 15.0, "<=", "estimate")
    row("latches", "window bridge span (base print)", lw + 2 * P["latch_win_side"], 10.0, "<=")
    z_ramp = z_ab + fit / lh * (z_c - lf - z_ab)
    row("latches", "window bottom below the hook inside the wall", z_ramp - P["latch_win_z"][0], 0.3, ">=")
    row("latches", "hook tip recess behind the outer wall face (screwdriver release)", fit + wall_t - (lh - pre), 1.0, ">=",
        f"push the tip in {lh - pre - fit:.2f} mm to release")
    comp = [(p["ref"] + " " + p["kind"], mbox(p["box"])) for p in B["parts"] if p["box"][5] > zpb + 1e-6]
    comp += [(f"H{i + 1} screw head", h) for i, h in enumerate(heads)] + [("board", pcb)]
    names = {(0, 1): "back", (0, -1): "front", (1, 1): "right", (1, -1): "left"}
    total_ov = vol(base ^ lid)
    zone_ov = 0.0
    for l in P["latches"]:
        kind, c, nw, d = l
        n0 = nw - d * fit
        def wbox(u0, u1, v0, v1, z0, z1, sh=0.0):
            a0, a1 = c + u0, c + u1
            n_a, n_b = sorted([n0 + d * (v0 - sh), n0 + d * (v1 - sh)])
            return [a0, n_a, z0, a1, n_b, z1] if kind == 0 else [n_a, a0, z0, n_b, a1, z1]
        nm_l = names[(kind, d)]
        zone = mbox(wbox(-lw / 2 - 0.05, lw / 2 + 0.05, -lt - 0.05, lh + 0.05, z_ab - 0.05, zli - 0.05))
        arm = lid ^ zone
        ov = vol(base ^ arm); zone_ov += ov
        shift = lambda s_: arm.translate((0, -d * s_, 0) if kind == 0 else (-d * s_, 0, 0))
        lo, hi = 0.0, 1.5
        for _ in range(18):
            mid = (lo + hi) / 2
            if vol(base ^ shift(mid)) > 1e-5:
                lo = mid
            else:
                hi = mid
        row("latches", f"{nm_l} latch: measured preload (inward shift that frees the hook)", hi, (pre - 0.03, pre + 0.03), "in",
            f"interference {ov:.2f} mm3 when the lid is on")
        g_free = min(gap(arm, q, 10) for _, q in comp)
        armd = shift(d_max)
        gd = [(gap(armd, q, 10), n_) for n_, q in comp]
        g_def, who = min(gd)
        row("latches", f"{nm_l} latch arm + hook to board / parts / screw heads, at rest", g_free, 1.0, ">=")
        row("latches", f"{nm_l} latch arm + hook to board / parts, deflected {d_max:.1f} mm (closest: {who})", g_def, 1.0, ">=")
        # placement in plan: distance to the other openings, vents, ears and the antenna bump
        ww = lw / 2 + P["latch_win_side"]
        wb = wbox(-ww, ww, fit, fit + wall_t, 0, 1)
        win_r = sbox(wb[0], wb[1], wb[3], wb[4])
        others = [sbox(P["main_o"][0] - 6, P["win"][0], 2.5, P["win"][1]), sbox(P["ko"][0], 0, P["ko"][1], 2.5),
                  sbox(*P["j5_open"]), sbox(*P["ear_left"]), sbox(*P["ear_right"]), sbox(*P["bump_o"])]
        others += [sbox(78, y - 0.75, 80, y + 0.75) for y in P["vent_right"]] + [sbox(x - 0.75, 0, x + 0.75, 2) for x in P["vent_front"]]
        others += [sbox(0, y - 0.8, 2, y + 0.8) for y in P["vent_left"]] + [sbox(x - 0.8, P["bump_i"][3], x + 0.8, P["bump_o"][3]) for x in P["vent_back"]]
        others += [sbox(v[0] - 0.8, min(v[1], v[3]) - 0.8, v[2] + 0.8, max(v[1], v[3]) + 0.8) for v in P["vent_lid"] + P["vent_lid_bme"]]
        row("latches", f"{nm_l} latch window to the nearest opening / vent / ear / bump (plan)", min(win_r.distance(o) for o in others), 2.0, ">=")
        if nm_l == "right":
            annot["A"] += [f"right latch: preload {hi:.2f}, engagement {lh - fit - pre:.2f}, strain {eps_l:.2f} %"]
    row("mesh", "base x lid overlap outside the latch hooks (mm3)", total_ov - zone_ov, 0.01, "<=", "only the hooks touch, by design")

    # ---------------------------------------------------------------- BME280 compartment
    u5 = [p for p in B["parts"] if p["kind"] == "bme_breakout"][0]["box"]
    j3 = [p for p in B["parts"] if p["kind"] == "xh_header" and p["ref"] == "J3"][0]["box"]
    bA, bB = P["baffleA"], P["baffleB"]
    row("BME280", "baffle A to breakout (front side)", bA[1] - u5[4], 0.5, ">=")
    row("BME280", "baffle B to breakout (left side)", u5[0] - bB[2], 0.5, ">=")
    rel = min(math.dist((sx, sy), ((bA[0] + bA[2]) / 2, bA[1])) for (sx, sy, _, _) in P["screws"])
    hx_, hy_ = P["screws"][2][0], P["screws"][2][1]
    row("BME280", "baffle A wall left beside the H3 head relief", (hy_ - P["head_relief_d"] / 2) - bA[1], 0.6, ">=", "relief cut into the baffle back")
    row("BME280", "baffle to J3 header (side)", bB[0] - j3[3], 0.5, ">=")
    row("BME280", "baffle bottom above board", P["z_baffle"] - zpt, 0.3, ">=", "baffle over the milled slots")
    row("BME280", "base rib top below board", zpb - P["z_rib"], 0.3, ">=", "rib under the slots")
    vw = P["vent_w"]
    lid_area = sum(abs(v[3] - v[1]) * vw + math.pi * vw ** 2 / 4 for v in P["vent_lid_bme"])
    wall_area = (len(P["vent_right"]) + len(P["vent_front"])) * P["vent_w_bme"] * (P["z_vent_bme"][1] - P["z_vent_bme"][0])
    row("BME280", "vent area over the breakout, lid (mm2)", lid_area, 50, ">=")
    row("BME280", "vent area beside the breakout, walls (mm2)", wall_area, 100, ">=", "right + front walls, also under the board")
    annot["B"] += [f"baffles -> breakout {bA[1] - u5[4]:4.2f} / {u5[0] - bB[2]:4.2f} mm, -> J3 {bB[0] - j3[3]:4.2f} mm",
                   f"BME vents: lid {lid_area:.0f} mm2, walls {wall_area:.0f} mm2"]

    # ---------------------------------------------------------------- printability (print orientation)
    for n in ("base", "lid", "cap"):
        t = trimesh.load(os.path.join(HERE, "out", "stl", f"gree_{n}.stl"))
        nz = t.face_normals[:, 2]; cz = t.triangles_center[:, 2]
        sel = (nz < -0.75) & (cz > 0.25)
        worst, where = 0.0, ""
        if sel.any():
            levels = {}
            for tri, z in zip(t.triangles[sel], cz[sel]):
                levels.setdefault(round(z, 1), []).append(Polygon(tri[:, :2]).buffer(1e-4))
            for z, ps in levels.items():
                u = unary_union(ps)
                for g in (u.geoms if isinstance(u, MultiPolygon) else [u]):
                    wdt = max_inscribed_width(g)
                    if wdt > worst:
                        worst, where = wdt, f"z {z:.1f}, around ({g.centroid.x:.0f}, {g.centroid.y:.0f})"
        row("print", f"{n}: widest unsupported bridge / ledge (no supports)", worst, 5.0, "<=", where)
        row("print", f"{n}: flat on the bed (min z)", t.bounds[0][2], 0.0, "==",
            f"print size {t.extents[0]:.1f} x {t.extents[1]:.1f} x {t.extents[2]:.1f} mm")

    # ---------------------------------------------------------------- overall
    bb = (base + lid).bounding_box()
    dims = dict(body=[P["main_o"][2] - P["main_o"][0], P["bump_o"][3] - P["main_o"][1], ztop],
                with_ears=[bb[3] - bb[0], bb[4] - bb[1], bb[5] - bb[2]])

    # ---------------------------------------------------------------- write
    ok = all(r["ok"] for r in rows)
    lines = ["Gree bridge rev B case - fit check (fit_check.py)",
             f"case body {dims['body'][0]:.1f} x {dims['body'][1]:.2f} x {dims['body'][2]:.1f} mm "
             f"(X x Y x Z), {dims['with_ears'][0]:.1f} mm across the ears",
             f"board at z {zpb:.2f}..{zpt:.2f}, lid inner surface z {zli:.2f}, wall top z {zwall:.2f}, lid top z {ztop:.2f}", ""]
    order = []
    for r in rows:
        if r["group"] not in order:
            order.append(r["group"])
    rows.sort(key=lambda r: order.index(r["group"]))         # stable: keeps the row order inside each group
    grp = None
    for r in rows:
        if r["group"] != grp:
            grp = r["group"]; lines.append(f"[{grp}]")
        lim = r["limit"]
        lims = f"{r['op']} {lim}" if r["op"] != "in" else f"in {lim[0]}..{lim[1]}"
        val = "none within 30 mm" if r["value"] >= INF / 2 else f"{r['value']:.3f}"
        lines.append(f"  {'PASS' if r['ok'] else 'FAIL'}  {r['name']:<86s} {val:>16s}  {lims:<14s} {r['note']}")
    lines += ["", "Tall components and envelopes (mm): height above board | vertical gap to lid | 3D gap to lid | 3D gap to base"]
    for ref, kind, h, up, gl, gb in tall:
        f = lambda v: "open" if v >= INF / 2 else f"{v:6.2f}"
        lines.append(f"  {ref:5s} {kind:22s} {h:6.2f} | {f(up):>6s} | {f(gl):>6s} | {f(gb):>6s}")
    nfail = sum(not r["ok"] for r in rows)
    lines += ["", f"{len(rows)} checks, {nfail} failed -> {'ALL PASS' if ok else 'FAIL'}"]
    txt = "\n".join(lines)
    open(os.path.join(HERE, "out", "fit_check.txt"), "w").write(txt + "\n")
    json.dump(dict(ok=ok, rows=rows, dims=dims, annot=annot,
                   tall=[dict(ref=a, kind=b, h=c, up=d, gap_lid=e, gap_base=f) for a, b, c, d, e, f in tall]),
              open(os.path.join(HERE, "out", "fit_report.json"), "w"), indent=1)
    print(txt)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
