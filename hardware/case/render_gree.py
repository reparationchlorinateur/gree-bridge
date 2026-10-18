#!/usr/bin/env python3
"""
Gree bridge rev B case - PNG renders (VTK offscreen + matplotlib sections).
Needs out/check/{base,lid,cap}_inplace.stl (OpenSCAD) and out/board_parts.json, out/params.json.
    out/png/gree_case_assembled.png      closed case, front-left and back-right
    out/png/gree_case_exploded.png       parts apart, from above and from below (lid underside)
    out/png/gree_lid_top.png             lid seen from above (label, legends, BOOT key, J5 cap)
    out/png/gree_base_top_board.png      base with the board in it, lid off
    out/png/gree_section.png             sections through J1 / RESET / BOOT / right latch and through the BME280 / antenna
    out/png/gree_latch.png               rev 2 snap latches: sections through the front and right latch + close-ups
usage: python3 render_gree.py
"""
import json, os
import numpy as np
import trimesh
import vtk
from vtk.util import numpy_support as ns
from shapely.geometry import Polygon, box as sbox
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon as MplPoly, Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "png")
P = json.load(open(os.path.join(HERE, "out", "params.json")))
B = json.load(open(os.path.join(HERE, "out", "board_parts.json")))
FIT = json.load(open(os.path.join(HERE, "out", "fit_report.json"))) if os.path.exists(os.path.join(HERE, "out", "fit_report.json")) else None

COL = {"base": (0.86, 0.89, 0.90), "lid": (0.62, 0.70, 0.74), "cap": (0.36, 0.40, 0.42), "pcb": (0.11, 0.45, 0.24),
       "smd": (0.79, 0.71, 0.54), "dark": (0.17, 0.17, 0.17), "metal": (0.75, 0.77, 0.80), "white": (0.96, 0.96, 0.96),
       "plug": (0.91, 0.86, 0.72), "gold": (0.85, 0.65, 0.12), "bme": (0.45, 0.15, 0.62), "wire": (0.80, 0.15, 0.15),
       "led_r": (1.0, 0.2, 0.2), "led_g": (0.2, 0.9, 0.35), "screw": (0.62, 0.64, 0.67)}


def load(name):
    return trimesh.load(os.path.join(HERE, "out", "check", f"{name}_inplace.stl"))


def board_meshes(below=False, plug=True, dupont=False):
    bd = B["board"]
    poly = Polygon(bd["outer"], [s for s in bd["slots"]])
    for (hx, hy) in bd["holes"]:
        poly = poly.difference(Polygon([(hx + 1.6 * np.cos(a), hy + 1.6 * np.sin(a)) for a in np.linspace(0, 2 * np.pi, 40, endpoint=False)]))
    pcb = trimesh.creation.extrude_polygon(poly, bd["z1"] - bd["z0"])
    pcb.apply_translation((0, 0, bd["z0"]))
    out = [(pcb, COL["pcb"])]
    for p in B["parts"]:
        k = p["kind"]
        if not below and p["box"][5] <= bd["z0"] + 1e-6:
            continue
        if not plug and k in ("xhp_plug", "wires_riser_bend", "wires_run"):
            continue
        if not dupont and k == "dupont_1x6":
            continue
        if k == "xhp_plug_optional":
            continue
        b = p["box"]
        m = trimesh.creation.box(bounds=[[b[0], b[1], b[2]], [b[3], b[4], b[5]]])
        out.append((m, COL.get(p["color"], (0.5, 0.5, 0.5))))
    for (sx, sy, zt, zh) in P["screws"]:                     # M3 x 6 pan head board screws
        hd = trimesh.creation.cylinder(radius=P["head_d"] / 2, height=zh - P["z_pt"], sections=40)
        hd.apply_translation((sx, sy, (zh + P["z_pt"]) / 2))
        out.append((hd, COL["screw"]))
        if below:
            sh = trimesh.creation.cylinder(radius=1.5, height=P["z_pt"] - zt, sections=24)
            sh.apply_translation((sx, sy, (P["z_pt"] + zt) / 2))
            out.append((sh, COL["screw"]))
    return out


def to_actor(mesh, color, opacity=1.0, offset=(0, 0, 0), edges=False):
    pts = vtk.vtkPoints()
    pts.SetData(ns.numpy_to_vtk(np.asarray(mesh.vertices + np.array(offset), dtype=np.float64), deep=True))
    f = np.asarray(mesh.faces, dtype=np.int64)
    cells = vtk.vtkCellArray()
    cells.SetData(ns.numpy_to_vtkIdTypeArray(np.arange(0, 3 * len(f) + 1, 3, dtype=np.int64), deep=True),
                  ns.numpy_to_vtkIdTypeArray(f.ravel(), deep=True))
    pd = vtk.vtkPolyData(); pd.SetPoints(pts); pd.SetPolys(cells)
    nm = vtk.vtkPolyDataNormals(); nm.SetInputData(pd); nm.SetFeatureAngle(35); nm.SplittingOn(); nm.Update()
    mp = vtk.vtkPolyDataMapper(); mp.SetInputConnection(nm.GetOutputPort())
    a = vtk.vtkActor(); a.SetMapper(mp)
    pr = a.GetProperty(); pr.SetColor(*color); pr.SetOpacity(opacity)
    pr.SetAmbient(0.25); pr.SetDiffuse(0.75); pr.SetSpecular(0.15); pr.SetSpecularPower(20)
    if edges:
        fe = vtk.vtkFeatureEdges(); fe.SetInputData(pd); fe.BoundaryEdgesOff(); fe.ManifoldEdgesOff(); fe.NonManifoldEdgesOff()
        fe.FeatureEdgesOn(); fe.SetFeatureAngle(40); fe.Update()
        em = vtk.vtkPolyDataMapper(); em.SetInputConnection(fe.GetOutputPort()); em.ScalarVisibilityOff()
        ea = vtk.vtkActor(); ea.SetMapper(em); ea.GetProperty().SetColor(0.25, 0.28, 0.30); ea.GetProperty().SetLineWidth(1.0)
        return [a, ea]
    return [a]


def render(viewports, path, size=(1800, 1000)):
    """viewports: list of dict(actors, cam=(pos, focal, up), ortho=scale|None, title, vp=(x0,y0,x1,y1))"""
    rw = vtk.vtkRenderWindow(); rw.SetOffScreenRendering(1); rw.SetSize(*size); rw.SetMultiSamples(8)
    for v in viewports:
        r = vtk.vtkRenderer(); r.SetViewport(*v["vp"])
        r.SetBackground(0.97, 0.97, 0.98); r.SetBackground2(0.86, 0.88, 0.91); r.GradientBackgroundOn()
        for a in v["actors"]:
            r.AddActor(a)
        lk = vtk.vtkLightKit(); lk.SetKeyLightIntensity(0.9); lk.AddLightsToRenderer(r)
        cam = r.GetActiveCamera()
        pos, foc, up = v["cam"]
        cam.SetPosition(*pos); cam.SetFocalPoint(*foc); cam.SetViewUp(*up)
        if v.get("ortho"):
            cam.ParallelProjectionOn(); cam.SetParallelScale(v["ortho"])
        else:
            cam.SetViewAngle(v.get("angle", 24))
        r.ResetCameraClippingRange()
        if v.get("title"):
            t = vtk.vtkTextActor(); t.SetInput(v["title"]); tp = t.GetTextProperty()
            tp.SetFontSize(v.get("fs", 22)); tp.SetColor(0.15, 0.17, 0.2); tp.SetBold(1)
            t.SetPosition(14, 12); r.AddViewProp(t)
        rw.AddRenderer(r)
    rw.Render()
    w2i = vtk.vtkWindowToImageFilter(); w2i.SetInput(rw); w2i.ReadFrontBufferOff(); w2i.Update()
    wr = vtk.vtkPNGWriter(); wr.SetFileName(path); wr.SetInputConnection(w2i.GetOutputPort()); wr.Write()
    print("wrote", os.path.relpath(path, HERE))


def acts(items, **kw):
    out = []
    for m, c in items:
        out += to_actor(m, c, **kw)
    return out


def sec_polys(mesh, origin, normal, to2d_cols):
    """section of mesh by plane -> list of shapely polygons in plane coords (u, v)"""
    s = mesh.section(plane_origin=origin, plane_normal=normal)
    if s is None:
        return []
    M = np.eye(4); M[:3, 0], M[:3, 1], M[:3, 2] = to2d_cols; M[:3, 3] = origin
    p2, _ = s.to_planar(to_2D=np.linalg.inv(M), check=False)
    return list(p2.polygons_full)


def main():
    os.makedirs(OUT, exist_ok=True)
    base, lid, cap = load("base"), load("lid"), load("cap")
    cx = (P["main_o"][0] + P["main_o"][2]) / 2; cy = (P["main_o"][1] + P["bump_o"][3]) / 2; cz = P["z_top"] / 2
    c = np.array([cx, cy, cz])

    # 1. assembled
    case = [(base, COL["base"]), (lid, COL["lid"]), (cap, COL["cap"])]
    d1 = np.array([-1.0, -1.25, 0.95]); d1 /= np.linalg.norm(d1)
    d2 = np.array([1.1, 1.0, 0.9]); d2 /= np.linalg.norm(d2)
    render([dict(actors=acts(case, edges=True), cam=(tuple(c + 330 * d1), tuple(c), (0, 0, 1)), vp=(0, 0, 0.5, 1), angle=26,
                 title="front-left: front latch window, J1 cable window, J3 knock-out"),
            dict(actors=acts(case, edges=True), cam=(tuple(c + 330 * d2), tuple(c), (0, 0, 1)), vp=(0.5, 0, 1, 1), angle=26,
                 title="back-right: back + right latch windows, antenna bump")],
           os.path.join(OUT, "gree_case_assembled.png"))

    # 2. exploded: from above, and from below (lid underside)
    bm = board_meshes(below=False)
    dz_l, dz_c = 34.0, 50.0
    ex = acts([(base, COL["base"])], edges=True) + acts(bm) + acts([(lid, COL["lid"])], offset=(0, 0, dz_l), edges=True) \
        + acts([(cap, COL["cap"])], offset=(0, 0, dz_c), edges=True)
    ce = c + np.array([0, 0, 20])
    d3 = np.array([-0.9, -1.3, 1.1]); d3 /= np.linalg.norm(d3)
    d4 = np.array([-0.7, -1.2, -0.75]); d4 /= np.linalg.norm(d4)
    ex2 = acts([(lid, COL["lid"])], offset=(0, 0, dz_l), edges=True) + acts([(cap, COL["cap"])], offset=(0, 0, dz_l), edges=True)
    render([dict(actors=ex, cam=(tuple(ce + 400 * d3), tuple(ce), (0, 0, 1)), vp=(0, 0, 0.56, 1), angle=27,
                 title="exploded: base + board screwed down (M3 x 6), lid, J5 cap"),
            dict(actors=ex2, cam=(tuple(c + np.array([0, 0, dz_l]) + 300 * d4), tuple(c + np.array([0, 0, dz_l])), (0, 0, 1)),
                 vp=(0.56, 0, 1, 1), angle=26,
                 title="lid underside: 3 snap latches, BME baffle, light tubes, BOOT stem")],
           os.path.join(OUT, "gree_case_exploded.png"))

    # 3. lid top (ortho)
    top = (cx, cy, 300); foc = (cx, cy, 0)
    render([dict(actors=acts([(lid, COL["lid"]), (cap, COL["cap"])], edges=True) + acts([(base, COL["base"])]),
                 cam=(top, foc, (0, 1, 0)), ortho=44, vp=(0, 0, 1, 1),
                 title="lid from above (antenna at the top edge, J1 left, BME280 front right)")],
           os.path.join(OUT, "gree_lid_top.png"), size=(1500, 1000))

    # 4. base with the board (ortho top + iso)
    bm2 = board_meshes(below=False, plug=True)
    d5 = np.array([-0.55, -1.0, 1.6]); d5 /= np.linalg.norm(d5)
    render([dict(actors=acts([(base, COL["base"])], edges=True) + acts(bm2), cam=(top, foc, (0, 1, 0)), ortho=58,
                 vp=(0, 0, 0.5, 1), title="base + board, from above"),
            dict(actors=acts([(base, COL["base"])], edges=True) + acts(bm2), cam=(tuple(c + 260 * d5), tuple(c), (0, 0, 1)),
                 vp=(0.5, 0, 1, 1), angle=28, title="base + board, J1 plug and 5 wires to the window")],
           os.path.join(OUT, "gree_base_top_board.png"), size=(1900, 950))

    # 5. sections (matplotlib)
    section_png(base, lid, cap)
    latch_png(base, lid, cap)


def section_png(base, lid, cap):
    X0, Y0 = P["X0"], P["Y0"]
    ky_s = 129.0                     # through J1 pin 5, the window, the tie block, RESET (SW1) and BOOT (SW2)
    kx_s = 165.0                     # through the antenna, the module, BOOT tongue, BME280 breakout, baffle, vents
    planes = [
        dict(name=f"A-A: XZ plane at kicad y = {ky_s:g} (J1 plug + wires -> left window / tie block, RESET pin hole, BOOT key)",
             origin=(0, Y0 - ky_s, 0), normal=(0, 1, 0), cols=((1, 0, 0), (0, 0, 1), (0, -1, 0)), axis="x", at=Y0 - ky_s,
             xlabel="X (case) [mm]   (kicad x = X + %g)" % X0),
        dict(name=f"B-B: YZ plane at kicad x = {kx_s:g} (BME280 front right ... antenna back left)",
             origin=(kx_s - X0, 0, 0), normal=(1, 0, 0), cols=((0, 1, 0), (0, 0, 1), (1, 0, 0)), axis="y", at=kx_s - X0,
             xlabel="Y (case) [mm]   (kicad y = %g - Y)" % Y0),
    ]
    fig, axs = plt.subplots(2, 1, figsize=(19, 12.5))
    for ax, pl in zip(axs, planes):
        for mesh, col, lab in ((base, COL["base"], "base"), (lid, COL["lid"], "lid"), (cap, COL["cap"], "J5 cap")):
            for i, poly in enumerate(sec_polys(mesh, pl["origin"], pl["normal"], pl["cols"])):
                ext = np.array(poly.exterior.coords)
                ax.add_patch(MplPoly(ext, closed=True, fc=col, ec="#37474f", lw=0.6, label=lab if i == 0 else None))
                for h in poly.interiors:
                    ax.add_patch(MplPoly(np.array(h.coords), closed=True, fc="white", ec="#37474f", lw=0.6))
        # board + components cut by the plane
        bd = B["board"]
        bpoly = Polygon(bd["outer"], bd["slots"])
        if pl["axis"] == "x":
            line = sbox(-50, pl["at"] - 1e-3, 150, pl["at"] + 1e-3)
            for seg in getattr(bpoly.intersection(line), "geoms", [bpoly.intersection(line)]):
                if seg.is_empty: continue
                x0, _, x1, _ = seg.bounds
                ax.add_patch(Rectangle((x0, bd["z0"]), x1 - x0, bd["z1"] - bd["z0"], fc=COL["pcb"], ec="k", lw=0.4))
        else:
            line = sbox(pl["at"] - 1e-3, -50, pl["at"] + 1e-3, 150)
            for seg in getattr(bpoly.intersection(line), "geoms", [bpoly.intersection(line)]):
                if seg.is_empty: continue
                _, y0, _, y1 = seg.bounds
                ax.add_patch(Rectangle((y0, bd["z0"]), y1 - y0, bd["z1"] - bd["z0"], fc=COL["pcb"], ec="k", lw=0.4))
        seen = set()
        for p in B["parts"]:
            b = p["box"]
            if pl["axis"] == "x" and not (b[1] <= pl["at"] <= b[4]): continue
            if pl["axis"] == "y" and not (b[0] <= pl["at"] <= b[3]): continue
            u0, u1 = (b[0], b[3]) if pl["axis"] == "x" else (b[1], b[4])
            ax.add_patch(Rectangle((u0, b[2]), u1 - u0, b[5] - b[2], fc=COL.get(p["color"], (0.5, 0.5, 0.5)), ec="k", lw=0.4, alpha=0.9))
            tag = p["ref"] if p["kind"] not in ("wires_riser_bend", "wires_run") else "J1 wires"
            if tag not in seen and p["kind"] not in ("xh_tail", "j5_tail", "u5_tail_untrimmed", "centre_pad_solder", "switch_body", "bme_header", "header_body"):
                seen.add(tag)
                ax.text((u0 + u1) / 2, b[5] + 0.3, tag, ha="center", va="bottom", fontsize=7, color="#263238")
        # the antenna band for B-B
        if pl["axis"] == "y":
            a = P["antenna"]
            ax.add_patch(Rectangle((a[1], P["z_pt"]), a[3] - a[1], 3.25, fc="none", ec="#d81b60", lw=1.4, ls="--"))
            ax.text((a[1] + a[3]) / 2, P["z_pt"] + 3.6, "antenna (6 mm overhang)", color="#d81b60", ha="center", fontsize=8)
        ax.set_aspect("equal"); ax.set_title(pl["name"], fontsize=11, loc="left")
        ax.set_xlabel(pl["xlabel"]); ax.set_ylabel("Z [mm]")
        lo = -19 if pl["axis"] == "x" else -2
        hi = 142 if pl["axis"] == "x" else 118
        ax.set_xlim(lo, hi); ax.set_ylim(-1.5, 28); ax.grid(alpha=0.25)
        h, l = ax.get_legend_handles_labels()
        ax.legend(h, l, loc="upper right", fontsize=8)
        if FIT and pl["axis"] == "x":
            ann = FIT.get("annot", {})
            txt = "\n".join(ann.get("A", []))
            ax.text(0.665, 0.80, txt, transform=ax.transAxes, fontsize=8.5, va="top", family="monospace",
                    bbox=dict(fc="white", ec="#90a4ae", alpha=0.9))
        if FIT and pl["axis"] == "y":
            txt = "\n".join(FIT.get("annot", {}).get("B", []))
            ax.text(0.62, 0.80, txt, transform=ax.transAxes, fontsize=8, va="top", family="monospace",
                    bbox=dict(fc="white", ec="#90a4ae", alpha=0.9))
    fig.tight_layout()
    path = os.path.join(OUT, "gree_section.png")
    fig.savefig(path, dpi=130); plt.close(fig)
    print("wrote", os.path.relpath(path, HERE))



def latch_png(base, lid, cap):
    """rev 2 snap latches: two zoomed sections (front latch, right latch) + two 3D close-ups"""
    fig = plt.figure(figsize=(19, 8.2))
    lat = {(0, -1): "front", (1, 1): "right"}
    panels = []
    for l in P["latches"]:
        key = (l[0], l[3])
        if key not in lat:
            continue
        if l[0] == 0:   # front: YZ plane at X = c
            panels.append(dict(name=f"front latch: YZ section at X {l[1]:g} (kicad x {l[1] + P['X0']:g})", origin=(l[1], 0, 0),
                               normal=(1, 0, 0), cols=((0, 1, 0), (0, 0, 1), (1, 0, 0)), axis="y", at=l[1], lim=(-1.5, 9.5)))
        else:           # right: XZ plane at Y = c
            panels.append(dict(name=f"right latch: XZ section at Y {l[1]:g} (kicad y {P['Y0'] - l[1]:g}), SW2 beside it",
                               origin=(0, l[1], 0), normal=(0, 1, 0), cols=((1, 0, 0), (0, 0, 1), (0, -1, 0)), axis="x", at=l[1],
                               lim=(68.5, 81.5)))
    fit_rows = {r["name"]: r for r in (FIT or {}).get("rows", [])}
    def fr(prefix):
        for k, r in fit_rows.items():
            if k.startswith(prefix):
                return r["value"]
        return float("nan")
    for i, pl in enumerate(panels):
        ax = fig.add_subplot(1, 3, i + 1)
        for mesh, col, lab in ((base, COL["base"], "base"), (lid, COL["lid"], "lid")):
            for j, poly in enumerate(sec_polys(mesh, pl["origin"], pl["normal"], pl["cols"])):
                ax.add_patch(MplPoly(np.array(poly.exterior.coords), closed=True, fc=col, ec="#37474f", lw=0.6, label=lab if j == 0 else None))
                for h in poly.interiors:
                    ax.add_patch(MplPoly(np.array(h.coords), closed=True, fc="white", ec="#37474f", lw=0.6))
        bd = B["board"]
        bpoly = Polygon(bd["outer"], bd["slots"])
        if pl["axis"] == "y":
            line = sbox(pl["at"] - 1e-3, -50, pl["at"] + 1e-3, 150)
        else:
            line = sbox(-50, pl["at"] - 1e-3, 150, pl["at"] + 1e-3)
        cutb = bpoly.intersection(line)
        for seg in getattr(cutb, "geoms", [cutb]):
            if seg.is_empty:
                continue
            u0, u1 = (seg.bounds[1], seg.bounds[3]) if pl["axis"] == "y" else (seg.bounds[0], seg.bounds[2])
            ax.add_patch(Rectangle((u0, bd["z0"]), u1 - u0, bd["z1"] - bd["z0"], fc=COL["pcb"], ec="k", lw=0.4, label="PCB"))
        for p in B["parts"]:
            b = p["box"]
            if p["kind"] in ("xhp_plug_optional", "dupont_1x6"):
                continue
            inside = (b[0] <= pl["at"] <= b[3]) if pl["axis"] == "y" else (b[1] <= pl["at"] <= b[4])
            if not inside:
                continue
            u0, u1 = (b[1], b[4]) if pl["axis"] == "y" else (b[0], b[3])
            ax.add_patch(Rectangle((u0, b[2]), u1 - u0, b[5] - b[2], fc=COL.get(p["color"], (0.5, 0.5, 0.5)), ec="k", lw=0.4))
            if pl["lim"][0] < (u0 + u1) / 2 < pl["lim"][1] and p["kind"] in ("switch_body", "switch_legs"):
                ax.text((u0 + u1) / 2, b[5] + 0.15, p["ref"] + " " + p["kind"].split("_")[1], ha="center", fontsize=7)
        z_ab, z_c, z_w = P["latch_z"]
        ax.axhline(P["z_wall"], color="#90a4ae", lw=0.6, ls=":")
        ax.set_aspect("equal"); ax.set_xlim(*pl["lim"]); ax.set_ylim(6.0, 26.0); ax.grid(alpha=0.25)
        ax.set_title(pl["name"], fontsize=10, loc="left")
        ax.set_xlabel(("Y" if pl["axis"] == "y" else "X") + " (case) [mm]"); ax.set_ylabel("Z [mm]")
        h, lb = ax.get_legend_handles_labels()
        uniq = dict(zip(lb, h)); ax.legend(uniq.values(), uniq.keys(), loc="lower right", fontsize=8)
    # text block with the latch numbers
    ax = fig.add_subplot(1, 3, 3); ax.axis("off")
    z_ab, z_c, z_w = P["latch_z"]
    L_arm = P["z_li"] - (z_c + P["latch_hook"])
    lines = [
        "Snap latch (3x: back, front, right wall)",
        f"arm      L {L_arm:.2f} mm (plate to hook top), t {P['latch_t']} mm, w {P['latch_w']} mm",
        f"hook     {P['latch_hook']} mm proud of the arm, 45 deg catch face, 30 deg lead-in ramp",
        f"window   {P['latch_w'] + 2 * P['latch_win_side']:.1f} x {z_w - P['latch_win_z'][0]:.1f} mm through the wall, ceiling z {z_w:.2f}",
        f"deflect  {P['latch_hook'] - P['fit']:.2f} mm to pass the wall -> peak strain {fr('arm L'):.2f} %",
        f"preload  {P['latch_preload']} mm nominal (measured {fr('back latch: measured'):.2f}), worst case {fr('preload, worst'):.2f} mm",
        f"engage   {fr('hook engagement in'):.2f} mm nominal, {fr('hook engagement, worst'):.2f} mm worst case",
        f"forces   ~{fr('click-on'):.0f} N to click on, ~{fr('pull-off'):.0f} N to pull off (per latch, estimate)",
        f"clear    arm/hook to board + parts >= {min(fr('back latch arm'), fr('front latch arm'), fr('right latch arm')):.2f} mm at rest,",
        f"         >= {min(fr('back latch arm + hook to board / parts, deflected'), fr('front latch arm + hook to board / parts, deflected'), fr('right latch arm + hook to board / parts, deflected')):.2f} mm deflected",
        "open     push each hook in ~0.5 mm through its window with a",
        "         small screwdriver and lift that side of the lid",
    ]
    ax.text(-0.05, 0.92, "\n".join(lines), va="top", family="monospace", fontsize=9.5)
    fig.tight_layout()
    path = os.path.join(OUT, "gree_latch.png")
    fig.savefig(path, dpi=120); plt.close(fig)
    # 3D close-ups: lid underside at the front latch, and the right latch window from outside (closed case)
    fl = [l for l in P["latches"] if (l[0], l[3]) == (0, -1)][0]
    rl = [l for l in P["latches"] if l[0] == 1][0]
    zc = sum(P["latch_z"][:2]) / 2
    lid_ex = acts([(lid, COL["lid"])], edges=True)
    f1 = np.array([fl[1], fl[2] + 3, zc + 4])
    d1 = np.array([0.55, 0.9, -0.55]); d1 /= np.linalg.norm(d1)
    f2 = np.array([P["main_o"][2], rl[1], zc + 1])
    d2 = np.array([1.0, -0.35, 0.3]); d2 /= np.linalg.norm(d2)
    case = acts([(base, COL["base"]), (lid, COL["lid"]), (cap, COL["cap"])], edges=True)
    render([dict(actors=lid_ex, cam=(tuple(f1 + 70 * d1), tuple(f1), (0, 0, 1)), vp=(0, 0, 0.5, 1), angle=30,
                 title="lid underside: front latch arm + hook (lip slits either side)"),
            dict(actors=case, cam=(tuple(f2 + 75 * d2), tuple(f2), (0, 0, 1)), vp=(0.5, 0, 1, 1), angle=30,
                 title="closed: hook in the right wall window (push in here to open)")],
           os.path.join(OUT, "gree_latch_closeup.png"), size=(1800, 900))
    print("wrote", os.path.relpath(path, HERE))


if __name__ == "__main__":
    main()
