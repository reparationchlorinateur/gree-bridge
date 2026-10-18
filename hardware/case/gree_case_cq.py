#!/usr/bin/env python3
"""
Gree bridge rev B case - CadQuery twin of gree_case.scad, for STEP output (Fusion 360).

Reads out/params.json + out/board_parts.json (written by layout_gree.py) and builds the same
base / lid / cap as gree_case.scad (rev 2: snap-fit lid, board screwed to the base), feature for
feature, in the assembled frame:
    out/step/gree_base.step, gree_lid.step, gree_cap.step   (assembled position, mm)
    out/step/gree_case_assembly.step                         (case + board + component placeholders, coloured)
    out/check/cq_{base,lid,cap}.stl                          (for the OpenSCAD <-> CadQuery cross-check)
usage: python3 gree_case_cq.py
"""
import json, os
import cadquery as cq

HERE = os.path.dirname(os.path.abspath(__file__))
P = json.load(open(os.path.join(HERE, "out", "params.json")))
B = json.load(open(os.path.join(HERE, "out", "board_parts.json")))
FONT = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
FONT_K = 1 / 0.72                     # OpenSCAD text(size) -> OCC font size
EPS = 0.01
g = lambda k: P[k]


# ------------------------------------------------------------------ primitives
def U(*objs):
    objs = [o for o in objs if o is not None]
    r = objs[0]
    for o in objs[1:]:
        r = r.union(o)
    return r

def box(x0, y0, z0, x1, y1, z1):
    return cq.Workplane().box(x1 - x0, y1 - y0, z1 - z0, centered=False).translate((x0, y0, z0))

def grow(r, d):
    return [r[0] - d, r[1] - d, r[2] + d, r[3] + d]

def rrbox(r, rad, z0, z1):
    s = box(r[0], r[1], z0, r[2], r[3], z1)
    return s.edges("|Z").fillet(rad) if rad > 0.001 else s

def cbox(r, rad, z0, z1, cb=0.0, ct=0.0):
    s = rrbox(r, rad, z0, z1)
    if cb > 0:
        s = s.faces("<Z").edges().chamfer(cb)
    if ct > 0:
        s = s.faces(">Z").edges().chamfer(ct)
    return s

def cyl(x, y, z0, z1, d):
    return cq.Workplane().circle(d / 2).extrude(z1 - z0).translate((x, y, z0))

def cone(x, y, z0, h, d1, d2):
    return cq.Workplane().add(cq.Solid.makeCone(d1 / 2, d2 / 2, h, cq.Vector(x, y, z0)))

def prism_xz(pts, y0, y1):            # polygon in (x, z), extruded along +Y from y0 to y1
    return cq.Workplane("XZ").polyline(pts).close().extrude(-(y1 - y0)).translate((0, y0, 0))

def prism_yz(pts, x0, x1):            # polygon in (y, z), extruded along +X from x0 to x1
    return cq.Workplane("YZ").polyline(pts).close().extrude(x1 - x0).translate((x0, 0, 0))

def vslot(p, w, z0, z1):              # slot along Y between centre points p = [x, y0, x, y1]
    L = abs(p[3] - p[1]) + w
    return cq.Workplane().slot2D(L, w, 90).extrude(z1 - z0).translate((p[0], (p[1] + p[3]) / 2, z0))

def text_solid(t, size, depth, x, y, z0, rot=0, halign="center"):
    s = cq.Workplane().text(t, size * FONT_K, depth, fontPath=FONT, halign=halign, valign="center", combine=False)
    if rot:
        s = s.rotate((0, 0, 0), (0, 0, 1), rot)
    return s.translate((x, y, z0))

def outer(z0, z1, cb, ct):
    return U(cbox(g("main_o"), g("r_out"), z0, z1, cb, ct), cbox(g("bump_o"), g("r_bump"), z0, z1, cb, ct))

def cavity(z0, z1, d=0.0):
    ri = g("r_in")
    return U(rrbox(grow(g("main_i"), -d), ri - d, z0, z1), rrbox(grow(g("bump_i"), -d), ri - d, z0, z1))

# ------------------------------------------------------------------ base
def ear(e, side):
    wx = g("main_o")[0] if side < 0 else g("main_o")[2]
    s = box(e[0], e[1], 0, e[2], e[3], g("ear_t"))
    far = "<X" if side < 0 else ">X"
    s = s.edges("|Z").edges(far).fillet(3.0)
    eg = g("ear_gusset"); et = g("ear_t")
    gus = prism_xz([(wx, et - EPS), (wx + side * eg, et - EPS), (wx, et - EPS + eg)], e[1] + 1.5, e[3] - 1.5)
    return s.union(gus)

def ear_cuts(e, side):
    wx = g("main_o")[0] if side < 0 else g("main_o")[2]
    yc = (e[1] + e[3]) / 2
    sw, sl = g("ear_slot")
    cuts = [cyl(wx + side * g("ear_hole_off"), yc, -1, g("ear_t") + 1, g("ear_hole"))]
    for o in g("ear_slot_off"):
        x = wx + side * o
        cuts.append(box(x - sw / 2, yc - sl / 2, -1, x + sw / 2, yc + sl / 2, g("ear_t") + g("ear_gusset") + 1))
    return U(*cuts)

def tie_block():
    t = g("tie"); zt = t[4]
    return prism_xz([(t[0], zt), (t[2] + 0.5, zt), (t[2] + 0.5, zt - 9.3), (t[0], zt - 3.8)], t[1], t[3])

def base():
    zw, ft, zpb = g("z_wall"), g("floor_t"), g("z_pb")
    shell = U(outer(0, zw, g("cham_bot"), 0), ear(g("ear_left"), -1), ear(g("ear_right"), 1), tie_block())
    shell = shell.cut(cavity(ft, zw + 1))
    adds = []
    for (hx, hy) in g("holes"):
        adds += [cyl(hx, hy, ft - EPS, zpb, g("boss_d")), cone(hx, hy, ft - EPS, g("boss_flare_h"), g("boss_flare_d"), g("boss_d"))]
    for k, ztop in (("ribA", g("z_rib")), ("ribB", g("z_rib")), ("rest_j1", zpb), ("rest_j5", zpb)):
        r = g(k); adds.append(box(r[0], r[1], ft - EPS, r[2], r[3], ztop))
    s = U(shell, *adds)
    cuts = []
    for (hx, hy) in g("holes"):
        if g("use_inserts"):
            cuts.append(cyl(hx, hy, zpb - g("insert_depth"), zpb + 1, g("insert_d")))
        else:
            cuts.append(cyl(hx, hy, g("pilot_bottom"), zpb + 1, g("pilot_d")))
    w = g("win"); wall = g("wall"); mo = g("main_o"); ko = g("ko")
    # J1 window: profile in (y, z) along X through the left wall; J3 knock-out: profile in (x, z) along Y
    cuts.append(window_solid_yz(w[0], w[1], w[2], g("win_r"), zw + 3, mo[0] - 6, mo[0] - 6 + wall + 6.5))
    cuts.append(window_solid_xz(ko[0], ko[1], ko[2], g("win_r"), zw + 3, g("ko_membrane"), wall + 0.5))
    vb, vw = g("vent_w_bme"), g("vent_w")
    zb0, zb1 = g("z_vent_bme"); z0, z1 = g("z_vent"); zk0, zk1 = g("z_vent_back")
    for y in g("vent_right"):
        cuts.append(box(mo[2] - wall - 0.5, y - vb / 2, zb0, mo[2] + 0.5, y + vb / 2, zb1))
    for x in g("vent_front"):
        cuts.append(box(x - vb / 2, -0.5, zb0, x + vb / 2, wall + 0.5, zb1))
    for y in g("vent_left"):
        cuts.append(box(-0.5, y - vw / 2, z0, wall + 0.5, y + vw / 2, z1))
    for x in g("vent_back"):
        cuts.append(box(x - vw / 2, g("bump_i")[3] - 0.5, zk0, x + vw / 2, g("bump_o")[3] + 0.5, zk1))
    cuts += [ear_cuts(g("ear_left"), -1), ear_cuts(g("ear_right"), 1)]
    tt, t = g("tie_tunnel"), g("tie")
    cuts.append(box(tt[0], t[1] - 1, tt[2], tt[1], t[3] + 1, tt[3]))
    cuts += [latch_window(l) for l in g("latches")]
    # name on the outside of the front wall (0.5 deep)
    ft_ = cq.Workplane("XZ").text("GREE BRIDGE rev B", 2.8 * FONT_K, -0.5, fontPath=FONT, halign="center", valign="center", combine=False)
    cuts.append(ft_.translate((24, -EPS, 4.6)))
    return s.cut(U(*cuts))

def window_solid_yz(a0, a1, z0, r, ztop, x0, x1):
    pts = profile_pts(a0, a1, z0, r, ztop)
    return cq.Workplane("YZ").polyline(pts).close().extrude(x1 - x0).translate((x0, 0, 0))

def window_solid_xz(a0, a1, z0, r, ztop, y0, y1):
    pts = profile_pts(a0, a1, z0, r, ztop)
    return cq.Workplane("XZ").polyline(pts).close().extrude(-(y1 - y0)).translate((0, y0, 0))

def profile_pts(a0, a1, z0, r, ztop, n=16):
    import math
    pts = [(a0, ztop)]
    for i in range(n + 1):                       # left bottom corner: centre (a0+r, z0+r), 180 -> 270 deg
        t = math.pi + (math.pi / 2) * i / n
        pts.append((a0 + r + r * math.cos(t), z0 + r + r * math.sin(t)))
    for i in range(n + 1):                       # right bottom corner: 270 -> 360 deg
        t = 1.5 * math.pi + (math.pi / 2) * i / n
        pts.append((a1 - r + r * math.cos(t), z0 + r + r * math.sin(t)))
    pts.append((a1, ztop))
    return pts


# ------------------------------------------------------------------ snap latches
def latch_solid(l, poly_vz, u0, u1):
    """polygon in the latch's local (v, z) frame (v outward from the arm's outer face), extruded over u0..u1"""
    kind, c, nw, d = l
    n0 = nw - d * g("fit")
    pts = [(n0 + d * v, z) for v, z in poly_vz]
    if kind == 0:
        return prism_yz(pts, c + u0, c + u1)      # back / front wall: (y, z) along X
    return prism_xz(pts, c + u0, c + u1)          # right wall: (x, z) along Y

def latch_arm(l):
    z_ab, z_c, _ = g("latch_z")
    w, t, h, f = g("latch_w"), g("latch_t"), g("latch_hook"), g("latch_flat")
    arm = latch_solid(l, [(-t, z_ab), (0, z_ab), (0, g("z_li") + EPS), (-t, g("z_li") + EPS)], -w / 2, w / 2)
    hook = latch_solid(l, [(-0.2, z_ab), (0, z_ab), (h, z_c - f), (h, z_c), (0, z_c + h), (-0.2, z_c + h)], -w / 2, w / 2)
    return arm.union(hook)

def latch_window(l):
    fit, wall, zw, c = g("fit"), g("wall"), g("z_wall"), g("latch_leadin")
    ww = g("latch_w") + 2 * g("latch_win_side")
    z0, z1 = g("latch_win_z")
    win = latch_solid(l, [(-0.5, z0), (fit + wall + 0.5, z0), (fit + wall + 0.5, z1), (-0.5, z1)], -ww / 2, ww / 2)
    lead = latch_solid(l, [(fit - 0.5, zw - c - 0.5), (fit + c + 1, zw + 1), (fit - 0.5, zw + 1)], -ww / 2 - 1, ww / 2 + 1)
    return win.union(lead)


# ------------------------------------------------------------------ lid
def lid():
    zli, ztop, zpt = g("z_li"), g("z_top"), g("z_pt")
    fit, lip_t, lip_h = g("fit"), g("lip_t"), g("lip_h")
    plate = outer(zli, ztop, 0, g("cham_top"))
    lip = cavity(zli - lip_h, zli + EPS, fit).cut(cavity(zli - lip_h - 1, zli + 1, fit + lip_t))
    lip = lip.cut(U(*[box(c[0], c[1], zli - lip_h - 1, c[2], c[3], zli) for c in g("lip_cut")]))
    feats = [lip]
    for k in ("baffleA", "baffleB"):
        r = g(k); feats.append(box(r[0], r[1], g("z_baffle"), r[2], r[3], zli + EPS))
    for (lx, ly) in g("led"):
        feats.append(cyl(lx, ly, g("z_led_tube"), zli + EPS, g("led_tube_od")))
    rx, ry = g("rst")
    feats.append(cyl(rx, ry, g("z_rst_tube"), zli + EPS, g("rst_tube_od")))
    inner = U(*feats).intersect(cavity(zpt - 1, zli + EPS, fit))
    inner = inner.cut(U(*[cyl(hx, hy, zpt - 1, g("z_head_relief"), g("head_relief_d")) for (hx, hy) in g("holes")]))
    s = U(plate, inner, *[latch_arm(l) for l in g("latches")])

    cuts = []
    for (lx, ly) in g("led"):
        cuts.append(cyl(lx, ly, g("z_led_tube") - 1, (ztop - g("led_skin")) if g("led_skin") > 0 else ztop + 1, g("led_hole_d")))
    cuts.append(cyl(rx, ry, g("z_rst_tube") - 1, ztop + 1, g("rst_hole_d")))
    cuts += [box(r[0], r[1], zli - EPS, r[2], r[3], ztop + 1) for r in g("boot_slots")]
    tg = g("boot_tongue")
    cuts.append(box(tg[0], tg[1], zli - EPS, tg[2], tg[3], ztop - g("boot_t")))
    cuts.append(cyl(g("boot")[0], g("boot")[1], ztop - 0.3, ztop + 1, 3.2))
    jo = g("j5_open")
    cuts.append(rrbox(jo, 0.8, zli - 1, ztop + 1))
    cuts.append(rrbox(grow(jo, g("j5_recess")), 1.2, ztop - g("j5_recess_d"), ztop + 1))
    cuts.append(cyl((jo[0] + jo[2]) / 2, jo[3] + g("j5_recess"), ztop - g("j5_recess_d"), ztop + 1, 4))
    for v in g("vent_lid") + g("vent_lid_bme"):
        cuts.append(vslot(v, g("vent_w"), zli - EPS, ztop + 1))
    cuts.append(rrbox(g("label_pocket"), 1.2, ztop - g("label_depth"), ztop + 1))
    ld = g("legend_depth")
    for (t, x, y, sz, rot, ha) in g("legends"):
        cuts.append(text_solid(t, sz, ld + 1, x, y, ztop - ld, rot, ha))
    s = s.cut(U(*cuts))
    stem = cyl(g("boot")[0], g("boot")[1], g("z_stem"), ztop - g("boot_t") + EPS, g("stem_d"))
    lx, ly = g("label_xy")
    letters = text_solid(P.get("label", "GREE BRIDGE"), g("label_size"), g("label_depth") + EPS, lx, ly, ztop - g("label_depth") - EPS)
    letters = letters.intersect(rrbox(g("label_pocket"), 1.2, ztop - g("label_depth") - EPS, ztop))
    return U(s, stem, letters)


# ------------------------------------------------------------------ cap
def cap():
    zli, ztop = g("z_li"), g("z_top")
    jo = g("j5_open")
    fl = grow(grow(jo, g("j5_recess")), -g("fit"))
    pl = grow(jo, -g("cap_plug_fit"))
    zb = zli - g("cap_plug_below"); zf = ztop - g("j5_recess_d")
    s = U(rrbox(fl, 0.9, zf, ztop), rrbox(pl, 0.65, zb, zf + EPS))
    cb = g("cap_bump")
    for side in (-1, 1):
        x = pl[0] if side < 0 else pl[2]
        pts = [(x - side * 0.2, zli - 1.1), (x, zli - 1.1), (x + side * cb, zli - 0.65), (x, zli - 0.2), (x - side * 0.2, zli - 0.2)]
        s = s.union(prism_xz(pts, pl[1] + 2, pl[3] - 2))
    return s.cut(rrbox(grow(pl, -g("cap_wall")), 0.1, zb - 1, zf))


# ------------------------------------------------------------------ board placeholder
def board():
    bd = B["board"]
    s = cq.Workplane().polyline([tuple(p) for p in bd["outer"]]).close().extrude(bd["z1"] - bd["z0"]).translate((0, 0, bd["z0"]))
    for sl in bd["slots"]:
        s = s.cut(cq.Workplane().polyline([tuple(p) for p in sl]).close().extrude(5).translate((0, 0, bd["z0"] - 1)))
    for (hx, hy) in bd["holes"]:
        s = s.cut(cyl(hx, hy, bd["z0"] - 1, bd["z1"] + 1, bd["hole_d"]))
    return s

COLORS = {"smd": (0.79, 0.71, 0.54), "dark": (0.17, 0.17, 0.17), "metal": (0.72, 0.74, 0.76), "white": (0.95, 0.95, 0.95),
          "plug": (0.91, 0.87, 0.77), "gold": (0.83, 0.63, 0.09), "bme": (0.42, 0.11, 0.6), "wire": (0.78, 0.16, 0.16),
          "led_r": (1, 0.19, 0.19), "led_g": (0.19, 1, 0.38)}


def main():
    os.makedirs(os.path.join(HERE, "out", "step"), exist_ok=True)
    os.makedirs(os.path.join(HERE, "out", "check"), exist_ok=True)
    parts = {"base": base(), "lid": lid(), "cap": cap()}
    for name, wp in parts.items():
        solid = wp.val()
        print(f"{name}: valid {solid.isValid()}, volume {solid.Volume():.1f} mm3, solids {len(wp.solids().vals())}")
        cq.exporters.export(wp, os.path.join(HERE, "out", "step", f"gree_{name}.step"))
        cq.exporters.export(wp, os.path.join(HERE, "out", "check", f"cq_{name}.stl"), tolerance=0.01, angularTolerance=0.1)
    assy = cq.Assembly(name="gree_bridge_case")
    assy.add(parts["base"], name="base", color=cq.Color(0.87, 0.90, 0.91))
    assy.add(parts["lid"], name="lid", color=cq.Color(0.70, 0.75, 0.76, 0.6))
    assy.add(parts["cap"], name="j5_cap", color=cq.Color(0.39, 0.43, 0.45))
    assy.add(board(), name="pcb", color=cq.Color(0.11, 0.42, 0.23))
    for i, (sx, sy, ztip, zhead) in enumerate(g("screws")):
        sc = cyl(sx, sy, ztip, g("z_pt"), 3.0).union(cyl(sx, sy, g("z_pt"), zhead, g("head_d")))
        assy.add(sc, name=f"M3x{g('screw_len'):g}_H{i + 1}", color=cq.Color(0.6, 0.62, 0.65))
    seen = {}
    for p in B["parts"]:
        if p["kind"] in ("xhp_plug_optional", "dupont_1x6"):      # fit-check only (J3 cable if fitted, programming plug)
            continue
        b = p["box"]
        n = f'{p["ref"].replace("/", "_")}_{p["kind"]}'
        seen[n] = seen.get(n, 0) + 1
        if seen[n] > 1:
            n += f"_{seen[n]}"
        assy.add(box(*b), name=n, color=cq.Color(*COLORS.get(p["color"], (0.5, 0.5, 0.5))))
    assy.export(os.path.join(HERE, "out", "step", "gree_case_assembly.step"))
    print("STEP written to out/step/")


if __name__ == "__main__":
    main()
