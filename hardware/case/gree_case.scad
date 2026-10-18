// ============================================================================
//  Gree bridge rev B case, 2026-10-17
//  Board: gree_bridge.kicad_pcb rev B (75 x 54 mm, ESP32-S3-WROOM-1 antenna 6 mm over the back edge)
//  Inside the Gree GWH12KF indoor unit, powered from its 12 V logic supply through J1.
//
//  Printed parts (PETG, no supports):
//    BASE  tray, floor down. Board on 3 bosses (5 mm under it), J1 cable window + zip-tie block
//          (left wall), J3 knock-out (front wall), BME280 vents, 2 ears (screw + zip-tie slots)
//    LID   plate + 3 mm locating lip, printed top face down. 3 columns clamp the board at H1-H3,
//          BOOT flexure key, RESET pin hole, 2 light tubes, BME280 baffle, J5 opening, label
//    CAP   snap cap for the J5 opening, flange down
//  Closing: 3 x M3 x 20 pan head from the lid top, through the lid columns and the board's
//  M3 holes into the base bosses (self-tapping into 2.5 mm pilots, or M3 heat-set inserts).
//
//  Frame (gree_case_params.scad): X = kicad_x - X0, Y = Y0 - kicad_y, Z = 0 at the mounting face.
//  part = "base" | "lid" | "cap"            print orientation (STL)
//       | "base_inplace" | "lid_inplace" | "cap_inplace" | "board" | "assembled" | "exploded"
//  All positions come from layout_gree.py (python3 layout_gree.py), run ./build.sh for everything.
// ============================================================================
include <gree_case_params.scad>
part = "exploded";

$fn = 64;
eps = 0.01;
font = "Liberation Sans:style=Bold";

function grow(r, d) = [r[0] - d, r[1] - d, r[2] + d, r[3] + d];

// rounded rectangle r = [x0, y0, x1, y1]
module rr2d(r, rad) {
    if (rad <= 0.001) translate([r[0], r[1]]) square([r[2] - r[0], r[3] - r[1]]);
    else hull() for (x = [r[0] + rad, r[2] - rad], y = [r[1] + rad, r[3] - rad]) translate([x, y]) circle(r = rad);
}
// rounded box with 45 degree chamfers cb (bottom) / ct (top)
module cbox(r, rad, z0, z1, cb = 0, ct = 0) {
    hull() {
        translate([0, 0, z0]) linear_extrude(eps) rr2d(grow(r, -cb), rad - cb);
        translate([0, 0, z0 + cb]) linear_extrude(z1 - z0 - cb - ct) rr2d(r, rad);
        translate([0, 0, z1 - eps]) linear_extrude(eps) rr2d(grow(r, -ct), rad - ct);
    }
}
module box(x0, y0, z0, x1, y1, z1) translate([x0, y0, z0]) cube([x1 - x0, y1 - y0, z1 - z0]);
module slot2d(p, w) hull() { translate([p[0], p[1]]) circle(d = w); translate([p[2], p[3]]) circle(d = w); }

// outer shape = main box + antenna bump; cavity = same, inset by the wall; d = extra inset
module outer(z0, z1, cb, ct) union() { cbox(main_o, r_out, z0, z1, cb, ct); cbox(bump_o, r_bump, z0, z1, cb, ct); }
module cavity2d(d = 0) { rr2d(grow(main_i, -d), r_in - d); rr2d(grow(bump_i, -d), r_in - d); }
module cavity(z0, z1, d = 0) translate([0, 0, z0]) linear_extrude(z1 - z0) cavity2d(d);

/* ================================ BASE ================================ */
module ear2d(e, side) {     // side -1: left ear (wall at e[2] - 1), +1: right ear (wall at e[0] + 1)
    xn = side < 0 ? e[2] : e[0];  xf = side < 0 ? e[0] + 3 : e[2] - 3;
    hull() {
        translate([side < 0 ? xn - eps : xn, e[1]]) square([eps, e[3] - e[1]]);
        for (y = [e[1] + 3, e[3] - 3]) translate([xf, y]) circle(r = 3);
    }
}
module ear(e, side) {
    linear_extrude(ear_t) ear2d(e, side);
    wx = side < 0 ? main_o[0] : main_o[2];
    translate([wx, e[3] - 1.5, ear_t - eps]) rotate([90, 0, 0]) linear_extrude(e[3] - e[1] - 3)
        polygon([[0, 0], [side * ear_gusset, 0], [0, ear_gusset]]);
}
module ear_cuts(e, side) {
    wx = side < 0 ? main_o[0] : main_o[2];  yc = (e[1] + e[3]) / 2;
    translate([wx + side * ear_hole_off, yc, -1]) cylinder(d = ear_hole, h = ear_t + 2, $fn = 32);
    for (o = ear_slot_off) translate([wx + side * o - ear_slot[0] / 2, yc - ear_slot[1] / 2, -1]) cube([ear_slot[0], ear_slot[1], ear_t + ear_gusset + 2]);
}
// zip-tie block under the J1 window, outside the left wall (45 degree underside, tunnel along Y)
module tie_block() {
    zt = tie[4];
    translate([0, tie[3], 0]) rotate([90, 0, 0]) linear_extrude(tie[3] - tie[1])
        polygon([[tie[0], zt], [tie[2] + 0.5, zt], [tie[2] + 0.5, zt - 9.3], [tie[0], zt - 3.8]]);
}
module win2d(y0, y1, z0, r) hull() {
    translate([y0 + r, z0 + r]) circle(r = r); translate([y1 - r, z0 + r]) circle(r = r);
    translate([y0, z_wall]) square([y1 - y0, 3]);
}
module base_bosses() for (h = holes) translate([h[0], h[1], floor_t - eps]) {
    cylinder(d = boss_d, h = z_pb - floor_t + eps);
    cylinder(d1 = boss_flare_d, d2 = boss_d, h = boss_flare_h);
}
module base_ribs() {
    box(ribA[0], ribA[1], floor_t - eps, ribA[2], ribA[3], z_rib);         // under the BME280 slots
    box(ribB[0], ribB[1], floor_t - eps, ribB[2], ribB[3], z_rib);
    box(rest_j1[0], rest_j1[1], floor_t - eps, rest_j1[2], rest_j1[3], z_pb);   // board rests (plug-in forces)
    box(rest_j5[0], rest_j5[1], floor_t - eps, rest_j5[2], rest_j5[3], z_pb);
}
module pilot(h) {
    if (use_inserts) translate([h[0], h[1], z_pb - insert_depth]) cylinder(d = insert_d, h = insert_depth + 1, $fn = 32);
    else translate([h[0], h[1], pilot_bottom]) cylinder(d = pilot_d, h = z_pb - pilot_bottom + 1, $fn = 24);
}
module base_vents() {
    for (y = vent_right) box(main_o[2] - wall - 0.5, y - vent_w_bme / 2, z_vent_bme[0], main_o[2] + 0.5, y + vent_w_bme / 2, z_vent_bme[1]);
    for (x = vent_front) box(x - vent_w_bme / 2, -0.5, z_vent_bme[0], x + vent_w_bme / 2, wall + 0.5, z_vent_bme[1]);
    for (y = vent_left) box(-0.5, y - vent_w / 2, z_vent[0], wall + 0.5, y + vent_w / 2, z_vent[1]);
    for (x = vent_back) box(x - vent_w / 2, bump_i[3] - 0.5, z_vent_back[0], x + vent_w / 2, bump_o[3] + 0.5, z_vent_back[1]);
}
module base() {
    difference() {
        union() {
            difference() {
                union() {
                    outer(0, z_wall, cham_bot, 0);
                    ear(ear_left, -1); ear(ear_right, 1);
                    tie_block();
                }
                cavity(floor_t, z_wall + 1);
            }
            base_bosses();
            base_ribs();
        }
        for (h = holes) pilot(h);
        // J1 cable window through the left wall (open at the top, the lid closes it)
        translate([main_o[0] - 6, 0, 0]) rotate([90, 0, 90]) linear_extrude(wall + 6.5) win2d(win[0], win[1], win[2], win_r);
        // J3 knock-out: same window in the front wall, closed by a thin membrane on the outside
        translate([0, wall + 0.5, 0]) rotate([90, 0, 0]) linear_extrude(wall + 0.5 - ko_membrane) win2d(ko[0], ko[1], ko[2], win_r);
        base_vents();
        ear_cuts(ear_left, -1); ear_cuts(ear_right, 1);
        box(tie_tunnel[0], tie[1] - 1, tie_tunnel[2], tie_tunnel[1], tie[3] + 1, tie_tunnel[3]);
        // name on the outside of the front wall, under the J3 knock-out side
        translate([24, -eps, 4.6]) rotate([90, 0, 0]) mirror([0, 0, 1]) linear_extrude(0.5)
            text("GREE BRIDGE rev B", size = 2.8, halign = "center", valign = "center", font = font);
    }
}

/* ================================ LID ================================ */
module lip() difference() {
    translate([0, 0, z_li - lip_h]) linear_extrude(lip_h + eps) cavity2d(fit);
    translate([0, 0, z_li - lip_h - 1]) linear_extrude(lip_h + 2) cavity2d(fit + lip_t);
    for (c = lip_cut) box(c[0], c[1], z_li - lip_h - 1, c[2], c[3], z_li);
}
module columns() for (h = holes) translate([h[0], h[1], 0]) {
    translate([0, 0, z_pt]) cylinder(d = col_d, h = z_li - col_boss_h - z_pt + eps);
    translate([0, 0, z_li - col_boss_h]) cylinder(d = col_boss_d, h = col_boss_h + eps);
}
module baffles() {
    box(baffleA[0], baffleA[1], z_baffle, baffleA[2], baffleA[3], z_li + eps);
    box(baffleB[0], baffleB[1], z_baffle, baffleB[2], baffleB[3], z_li + eps);
}
module tubes() {
    for (l = led) translate([l[0], l[1], z_led_tube]) cylinder(d = led_tube_od, h = z_li - z_led_tube + eps);
    translate([rst[0], rst[1], z_rst_tube]) cylinder(d = rst_tube_od, h = z_li - z_rst_tube + eps);
}
module legend(t, x, y, s, rot, ha) translate([x, y, z_top - legend_depth]) rotate(rot)
    linear_extrude(legend_depth + 1) text(t, size = s, halign = ha, valign = "center", font = font);
module lid_cuts() {
    for (h = holes) translate([h[0], h[1], 0]) {
        translate([0, 0, z_pt - 1]) cylinder(d = screw_clear, h = z_top - z_pt + 2, $fn = 32);
        translate([0, 0, z_top - cbore_depth]) cylinder(d = cbore_d, h = cbore_depth + 1);
    }
    for (l = led) translate([l[0], l[1], z_led_tube - 1]) cylinder(d = led_hole_d, h = (led_skin > 0 ? z_top - led_skin : z_top + 1) - z_led_tube + 1, $fn = 32);
    translate([rst[0], rst[1], z_rst_tube - 1]) cylinder(d = rst_hole_d, h = z_top - z_rst_tube + 2, $fn = 32);
    // BOOT flexure key: U slot through the plate + thinning pocket under the tongue
    bx0 = boot_x[0]; bx1 = boot_x[1]; by0 = boot_y[0]; by1 = boot_y[1]; s = boot_slot;
    box(bx0, by1, z_li - eps, bx1 + s, by1 + s, z_top + 1);
    box(bx0, by0 - s, z_li - eps, bx1 + s, by0, z_top + 1);
    box(bx1, by0 - s, z_li - eps, bx1 + s, by1 + s, z_top + 1);
    box(bx0, by0, z_li - eps, bx1, by1, z_top - boot_t);
    translate([boot[0], boot[1], z_top - 0.3]) cylinder(d = 3.2, h = 1);
    // J5 programming opening, recess for the cap flange, nail notch
    translate([0, 0, z_li - 1]) linear_extrude(lid_t + 2) rr2d(j5_open, 0.8);
    translate([0, 0, z_top - j5_recess_d]) linear_extrude(j5_recess_d + 1) {
        rr2d(grow(j5_open, j5_recess), 1.2);
        translate([(j5_open[0] + j5_open[2]) / 2, j5_open[3] + j5_recess]) circle(d = 4);
    }
    // vents
    translate([0, 0, z_li - eps]) linear_extrude(lid_t + 1) {
        for (v = vent_lid) slot2d(v, vent_w);
        for (v = vent_lid_bme) slot2d(v, vent_w);
    }
    // label pocket (letters added back, flush) + legends
    translate([0, 0, z_top - label_depth]) linear_extrude(label_depth + 1) rr2d(label_pocket, 1.2);
    for (g = legends) legend(g[0], g[1], g[2], g[3], g[4], g[5]);
}
module label_letters() intersection() {
    translate([0, 0, z_top - label_depth - eps]) linear_extrude(label_depth + eps) rr2d(label_pocket, 1.2);
    translate([label_xy[0], label_xy[1], z_top - label_depth - eps]) linear_extrude(label_depth + eps)
        text(label, size = label_size, halign = "center", valign = "center", font = font);
}
module lid() union() {
    difference() {
        union() {
            outer(z_li, z_top, 0, cham_top);
            intersection() {
                translate([0, 0, z_pt - 1]) linear_extrude(z_li - z_pt + 1 + eps) cavity2d(fit);
                union() { lip(); columns(); baffles(); tubes(); }
            }
        }
        lid_cuts();
    }
    translate([boot[0], boot[1], z_stem]) cylinder(d = stem_d, h = z_top - boot_t - z_stem + eps);   // BOOT stem
    label_letters();
}

/* ================================ CAP (J5) ================================ */
cap_fl = grow(grow(j5_open, j5_recess), -fit);
cap_pl = grow(j5_open, -cap_plug_fit);
module cap_bump(s) {
    x = s < 0 ? cap_pl[0] : cap_pl[2];
    translate([x, cap_pl[3] - 2, 0]) rotate([90, 0, 0]) linear_extrude(cap_pl[3] - cap_pl[1] - 4)
        polygon([[-s * 0.2, z_li - 1.1], [0, z_li - 1.1], [s * cap_bump, z_li - 0.65], [0, z_li - 0.2], [-s * 0.2, z_li - 0.2]]);
}
module cap() difference() {
    union() {
        translate([0, 0, z_top - j5_recess_d]) linear_extrude(j5_recess_d) rr2d(cap_fl, 0.9);
        translate([0, 0, z_li - cap_plug_below]) linear_extrude(z_top - j5_recess_d - z_li + cap_plug_below + eps) rr2d(cap_pl, 0.65);
        cap_bump(-1); cap_bump(1);
    }
    translate([0, 0, z_li - cap_plug_below - 1]) linear_extrude(z_top - j5_recess_d - z_li + cap_plug_below + 1) rr2d(grow(cap_pl, -cap_wall), 0.1);
}

/* ================================ board dummy ================================ */
function pcol(c) = c == "smd" ? "#c9b48a" : c == "dark" ? "#2b2b2b" : c == "metal" ? "#b8bcc2" : c == "white" ? "#f2f2f2"
    : c == "plug" ? "#e9dfc4" : c == "gold" ? "#d4a017" : c == "bme" ? "#6a1b9a" : c == "wire" ? "#c62828"
    : c == "led_r" ? "#ff3030" : c == "led_g" ? "#30ff60" : "#888888";
module board() {
    color("#1d6b3a") translate([0, 0, z_pb]) linear_extrude(t_pcb) difference() {
        polygon(board_outer);
        for (s = board_slots) polygon(s);
        for (h = holes) translate(h) circle(d = 3.2);
    }
    for (p = parts) color(pcol(p[1])) box(p[0][0], p[0][1], p[0][2], p[0][3], p[0][4], p[0][5]);
}

/* ================================ output ================================ */
if (part == "base") base();
else if (part == "lid") translate([0, bump_o[3], z_top]) rotate([180, 0, 0]) lid();                 // top face down
else if (part == "cap") translate([-cap_fl[0] + 2, cap_fl[3] + 2, z_top]) rotate([180, 0, 0]) cap(); // flange down
else if (part == "base_inplace") base();
else if (part == "lid_inplace") lid();
else if (part == "cap_inplace") cap();
else if (part == "board") board();
else if (part == "assembled") { color("#dfe6e9") base(); color("#b2bec3", 0.6) lid(); color("#636e72") cap(); board(); }
else { color("#dfe6e9") base(); board(); color("#b2bec3") translate([0, 0, 30]) lid(); color("#636e72") translate([0, 0, 45]) cap(); }
