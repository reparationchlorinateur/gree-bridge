#!/usr/bin/env python3
"""Analyze a Gree bridge capture (gree_capture.txt from the board's "Gree tools" page).

    python3 analyze_capture.py gree_capture.txt                 # full report
    python3 analyze_capture.py gree_capture.txt --section events
    python3 analyze_capture.py gree_capture.txt --json          # machine-readable

    python3 analyze_capture.py start-up.txt setpoint.txt modes.txt   # several, read as one

Sections: summary, frames, checksum, columns, events, timeline, gree (all by default).
"events": what changed after each IR command / note (bytes already drifting before it are listed
apart); "timeline": every change of every byte with its time, also the ones no event explains.
Only the Python 3 standard library is used.

Capture format (one event per line, '#' = comment):
    <ms since start> RX|TX <hex bytes>      raw chunk from a bus tap (split on silence)
    <ms> IR <json>                          Tasmota IrReceived (wall remote)
    <ms> IRHVAC <json>                      IR command sent by the board
    <ms> GREE <json>                        values decoded by gree_bus.be
    <ms> MARK <text>                        user note
"""
import argparse
import collections
import json
import math
import re
import sys

# --------------------------------------------------------------------------- parsing
def parse(path):
    cap = {"comments": [], "chunks": [], "events": [], "gree": [], "windows": [], "bus": None}
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line.strip():
                continue
            if line.startswith("#"):
                cap["comments"].append(line)
                m = re.match(r"# window (\d+)/(\d+) (starts|ends) at \+(\d+) s", line)
                if m:
                    cap["windows"].append((int(m.group(1)), m.group(3), int(m.group(4))))
                m = re.match(r"# bus: (\d+) (\w+), RX (\w+), TX (\w+)", line)
                if m:
                    cap["bus"] = {"baud": int(m.group(1)), "fmt": m.group(2), "rx": m.group(3), "tx": m.group(4)}
                continue
            parts = line.split(" ", 2)
            if len(parts) < 3 or not parts[0].lstrip("-").isdigit():
                continue
            t, src, data = int(parts[0]), parts[1], parts[2]
            if src in ("RX", "TX"):
                try:
                    b = bytes(int(x, 16) for x in data.split())
                except ValueError:
                    continue
                cap["chunks"].append((t, src, b))
            elif src in ("IR", "IRHVAC"):
                try:
                    j = json.loads(data)
                except ValueError:
                    j = {"raw": data}
                cap["events"].append((t, src, j))
            elif src == "GREE":
                try:
                    cap["gree"].append((t, json.loads(data)))
                except ValueError:
                    pass
            elif src == "MARK":
                cap["events"].append((t, "MARK", {"text": data}))
    return cap

# --------------------------------------------------------------------------- framing
def xor(bs):
    x = 0
    for v in bs:
        x ^= v
    return x

GREE_LAYOUTS = [(0x07, 9, 0x0D, "indoor"), (0x08, 11, 0x0F, "outdoor")]

def split_gree(chunk):
    """Valid Gree frames (head, length, tail, XOR of the bytes between head and checksum)."""
    out, i = [], 0
    while i < len(chunk):
        hit = None
        for head, n, tail, name in GREE_LAYOUTS:
            if i + n <= len(chunk) and chunk[i] == head and chunk[i + n - 1] == tail and \
               xor(chunk[i + 1:i + n - 2]) == chunk[i + n - 2]:
                hit = (name, chunk[i:i + n])
                break
        if hit:
            out.append(hit)
            i += len(hit[1])
        else:
            i += 1
    return out

def frames_generic(chunks):
    """Unknown protocol: learn header bytes and their typical length from the chunk starts, split
    chunks greedily at those headers; whatever is left over after a known frame (a reply glued to
    a request, say) is learned the same way in a second pass."""
    def split(heads):
        frames, rest = [], collections.defaultdict(collections.Counter)
        for t, src, b in chunks:
            i = 0
            while i < len(b):
                n = heads.get(b[i])
                if n and i + n <= len(b):
                    frames.append((t, src, "h%02X/%d" % (b[i], n), b[i:i + n]))
                    i += n
                else:
                    frames.append((t, src, "chunk/%d" % (len(b) - i), b[i:]))
                    if i > 0:
                        rest[b[i]][len(b) - i] += 1
                    break
        return frames, rest

    def learn(counters, total, heads):
        for h, lens in counters.items():
            if h not in heads and sum(lens.values()) / max(total, 1) >= 0.15:
                heads[h] = lens.most_common(1)[0][0]

    starts = collections.defaultdict(collections.Counter)
    for _, src, b in chunks:
        if b:
            starts[b[0]][len(b)] += 1
    heads = {}
    learn(starts, len(chunks), heads)
    frames, rest = split(heads)
    if rest:
        learn(rest, sum(sum(c.values()) for c in rest.values()), heads)
        frames, rest = split(heads)
    return frames

def all_frames(cap):
    """[(t, src, type, bytes)]; Gree layouts when they cover most of the data, else generic."""
    gree, covered, total = [], 0, 0
    for t, src, b in cap["chunks"]:
        total += len(b)
        for name, fr in split_gree(b):
            gree.append((t, src, name, fr))
            covered += len(fr)
    if total and covered / total >= 0.6:
        return gree, "gree"
    return frames_generic(cap["chunks"]), "generic"

# --------------------------------------------------------------------------- checksums
def crc8(data, poly, init=0, refin=False):
    c = init
    for v in data:
        if refin:
            c ^= v
            for _ in range(8):
                c = (c >> 1) ^ poly if c & 1 else c >> 1
        else:
            c ^= v
            for _ in range(8):
                c = ((c << 1) ^ poly) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c

CHECKS = {
    "xor": lambda d: xor(d),
    "sum": lambda d: sum(d) & 0xFF,
    "sum, two's complement": lambda d: (-sum(d)) & 0xFF,
    "sum, inverted": lambda d: (~sum(d)) & 0xFF,
    "crc8 0x07": lambda d: crc8(d, 0x07),
    "crc8 maxim (0x31 reflected)": lambda d: crc8(d, 0x8C, refin=True),
}

def find_checksums(frames):
    """For each frame type: checksum algorithm, position and covered byte range matching >= 95 %."""
    res = {}
    groups = collections.defaultdict(list)
    for _, _, typ, b in frames:
        groups[(typ, len(b))].append(b)
    for (typ, n), fs in groups.items():
        if len(fs) < 3 or n < 3:
            continue
        found = []
        for pos in (n - 1, n - 2, n - 3):
            if pos < 1:
                continue
            for start in (0, 1, 2):
                for end in (pos, pos - 1):
                    if end - start < 2:
                        continue
                    for name, fn in CHECKS.items():
                        ok = sum(1 for b in fs if fn(b[start:end]) == b[pos])
                        if ok / len(fs) >= 0.95:
                            found.append({"algo": name, "pos": pos, "from": start, "to": end - 1,
                                          "match": "%d/%d" % (ok, len(fs))})
        # constant bytes can match anything; keep the widest range per algorithm and position
        best = {}
        for f in found:
            k = (f["algo"], f["pos"])
            if k not in best or (f["to"] - f["from"]) > (best[k]["to"] - best[k]["from"]):
                best[k] = f
        res["%s (%d bytes, %d frames)" % (typ, n, len(fs))] = sorted(best.values(), key=lambda f: f["from"] - f["to"])[:4]
    return res

def checksum_positions(frames):
    """{(type, length): position} of the checksum byte found for each frame type"""
    out = {}
    for _, _, typ, b in frames:
        out.setdefault((typ, len(b)), None)
    res = find_checksums(frames)
    for key in list(out):
        label = "%s (%d bytes, " % key
        for k, v in res.items():
            if k.startswith(label) and v:
                out[key] = v[0]["pos"]
    return out

# --------------------------------------------------------------------------- columns
def ntc_c(raw, k=1.0, beta=3950.0):
    """20 kOhm NTC on a 20 kOhm divider read as 8 bits (Gree coil / outdoor sensors), k = Rpullup/R25."""
    if raw <= 0 or raw >= 255:
        return None
    return 1.0 / (1 / 298.15 + math.log(k * (256 - raw) / raw) / beta) - 273.15

def columns(frames):
    groups = collections.defaultdict(list)
    for t, src, typ, b in frames:
        groups[(typ, len(b))].append((t, src, b))
    out = {}
    for (typ, n), fs in groups.items():
        cols = []
        for i in range(n):
            vals = [b[i] for _, _, b in fs]
            distinct = sorted(set(vals))
            changes = sum(1 for a, c in zip(vals, vals[1:]) if a != c)
            c = {"byte": i, "min": min(vals), "max": max(vals), "distinct": len(distinct), "changes": changes}
            if len(distinct) == 1:
                c["note"] = "constant 0x%02X" % distinct[0]
                v = distinct[0]
                if 20 <= v <= 235 and ntc_c(v) is not None:
                    c["if_temperature"] = "NTC %.1f C, or %d C (value - 40), or %.1f C (value / 2)" % (ntc_c(v), v - 40, v / 2)
            elif len(distinct) <= 6:
                c["values"] = ["0x%02X" % v for v in distinct]
            if len(distinct) > 1 and max(vals) - min(vals) > 2 and 20 <= min(vals) and max(vals) <= 235:
                lo, hi = ntc_c(min(vals)), ntc_c(max(vals))
                if lo is not None and hi is not None:
                    c["as_ntc_C"] = "%.1f .. %.1f" % (min(lo, hi), max(lo, hi))
                c["as_minus40_C"] = "%d .. %d" % (min(vals) - 40, max(vals) - 40)
            hi_bits = {v >> 4 for v in vals}
            lo_bits = {v & 15 for v in vals}
            if len(distinct) > 1 and (len(hi_bits) == 1 or len(lo_bits) == 1):
                c["nibbles"] = "high %s, low %s" % (sorted(hi_bits), sorted(lo_bits))
            cols.append(c)
        out["%s (%d bytes, %d frames)" % (typ, n, len(fs))] = cols
    return out

# --------------------------------------------------------------------------- events
def ir_state(j):
    h = j.get("IRHVAC", j) if isinstance(j, dict) else {}
    keys = ["Vendor", "Power", "Mode", "Temp", "FanSpeed", "SwingV", "Turbo", "Light"]
    return {k: h[k] for k in keys if k in h}

def events(cap, frames, settle_ms=3000, look_back_ms=15000, ck=None):
    """For each IR command / mark: which frame bytes changed between the last frame before it and
    the first frame settle_ms after it (the unit needs a moment to react), or the last frame of
    the same capture window when the window ends sooner. Bytes that were already changing in the
    look_back_ms before the event are listed apart ("drifting"): a temperature or a counter, not
    something the event caused."""
    groups = collections.defaultdict(list)
    for t, src, typ, b in frames:
        groups[(typ, len(b))].append((t, b))
    out = []
    for t, kind, j in sorted(cap["events"], key=lambda e: e[0]):
        e = {"t_ms": t, "kind": kind}
        if kind == "MARK":
            e["text"] = j.get("text")
        else:
            e["state"] = ir_state(j)
            if kind == "IR":
                e["protocol"] = j.get("Protocol")
        changes, drifting = {}, {}
        for (typ, n), fs in groups.items():
            before = [(ft, b) for ft, b in fs if t - look_back_ms <= ft < t]
            near = [(ft, b) for ft, b in fs if t < ft <= t + 15000]      # same capture window
            if not before or not near:
                continue
            settled = [b for ft, b in near if ft >= t + settle_ms]
            b0, b1 = before[-1][1], (settled[0] if settled else near[-1][1])
            moving = {i for i in range(n) if len({b[i] for _, b in before}) > 1}
            if ck and ck.get((typ, n)) is not None:
                moving.add(ck[(typ, n)])          # the checksum follows every other change
            d = ["b%d %02X->%02X" % (i, b0[i], b1[i]) for i in range(n) if b0[i] != b1[i] and i not in moving]
            m = ["b%d %02X->%02X" % (i, b0[i], b1[i]) for i in range(n) if b0[i] != b1[i] and i in moving]
            if d:
                changes["%s/%d" % (typ, n)] = d
            if m:
                drifting["%s/%d" % (typ, n)] = m
        e["changed"] = changes
        e["drifting"] = drifting
        out.append(e)
    return out

def timeline(cap, frames, events_list, near_ms=4000, ck=None):
    """Every change of every byte, with its time, marked when it follows an event within near_ms.
    Bytes that change on (almost) every frame are summarised (steady drift, counter...)."""
    ev_times = [(e["t_ms"], e["kind"]) for e in events_list]
    groups = collections.defaultdict(list)
    for t, src, typ, b in frames:
        groups[(typ, len(b), src)].append((t, b))
    out = {}
    for (typ, n, src), fs in groups.items():
        if len(fs) < 2:
            continue
        rows = []
        for i in range(n):
            if ck and ck.get((typ, n)) == i:
                continue                          # checksum byte: changes with everything else
            ch = [(fs[k][0], fs[k - 1][1][i], fs[k][1][i]) for k in range(1, len(fs)) if fs[k][1][i] != fs[k - 1][1][i]]
            if not ch:
                continue
            if len(ch) > 8 or len(ch) >= 0.7 * (len(fs) - 1):
                steps = [((c[2] - c[1] + 128) % 256) - 128 for c in ch]
                kind = "steady +%d" % steps[0] if len(set(steps)) == 1 and steps[0] > 0 else \
                       "steady %d" % steps[0] if len(set(steps)) == 1 else "varies"
                rows.append("b%d: %d changes (%s), %02X .. %02X" % (i, len(ch), kind, ch[0][1], ch[-1][2]))
                continue
            for ct, a, b in ch:
                cause = [k for et, k in ev_times if 0 <= ct - et <= near_ms]
                rows.append("b%d: %02X->%02X at %d ms%s" % (i, a, b, ct, (" (after " + cause[-1] + ")") if cause else
                                                               " (no event just before)"))
        if rows:
            out["%s/%d on %s" % (typ, n, src)] = rows
    return out

# --------------------------------------------------------------------------- Gree decoding
MODES = {0: "auto", 1: "cool", 2: "dry", 3: "fan", 4: "heat"}

def gree_decode(name, b):
    if name == "indoor":
        return {"room_C": b[1] + (0.5 if b[5] & 0x80 else 0), "coil_C": round(ntc_c(b[2]) or 0, 1),
                "power": bool(b[3] & 8), "mode": MODES.get(b[3] & 7, b[3] & 7),
                "fan_actual": (b[6] >> 4) & 3, "setpoint_C": (b[6] & 15) + 16}
    if name == "outdoor":
        o = b[1:9]
        return {"comp_Hz": o[0], "running": o[1], "o3": o[2], "out_coil_C": round(ntc_c(o[3]) or 0, 1),
                "discharge_raw": o[4], "discharge_C": round(ntc_c(o[4], 0.3229) or 0, 1),
                "out_air_C": round(ntc_c(o[5]) or 0, 1), "comp_A": round(o[6] * 0.05, 2),
                "mode": {0: "off", 1: "cool", 4: "heat"}.get(o[7], o[7])}
    return None

# --------------------------------------------------------------------------- report
def report(cap, sections, as_json):
    frames, framing = all_frames(cap)
    res = {}
    if "summary" in sections:
        src = collections.Counter(s for _, s, _ in cap["chunks"])
        types = collections.Counter((typ, src) for _, src, typ, _ in frames)
        dur = (max([c[0] for c in cap["chunks"]] + [0]) / 1000.0)
        res["summary"] = {
            "bus": cap["bus"], "duration_s": dur, "chunks": dict(src), "framing": framing,
            "frame_types": {"%s on %s" % k: v for k, v in types.items()},
            "ir_events": sum(1 for e in cap["events"] if e[1] == "IR"),
            "commands_sent": sum(1 for e in cap["events"] if e[1] == "IRHVAC"),
            "marks": [e[2]["text"] for e in cap["events"] if e[1] == "MARK"],
            "windows": len({w[0] for w in cap["windows"]}),
            "header": [c for c in cap["comments"] if c.startswith(("# detected", "# ir:", "# bus:"))],
        }
    if "frames" in sections:
        uniq = collections.OrderedDict()
        for t, src, typ, b in frames:
            k = (src, typ, b.hex(" ").upper())
            uniq.setdefault(k, [t, 0])[1] += 1
        res["frames"] = ["%7d ms  %s  %-12s x%-3d %s" % (v[0], k[0], k[1], v[1], k[2]) for k, v in list(uniq.items())[:60]]
    if "checksum" in sections:
        res["checksum"] = find_checksums(frames)
    if "columns" in sections:
        res["columns"] = columns(frames)
    if "events" in sections or "timeline" in sections:
        ck = checksum_positions(frames)
        ev = events(cap, frames, ck=ck)
        if "events" in sections:
            res["events"] = ev
        if "timeline" in sections:
            res["timeline"] = timeline(cap, frames, ev, ck=ck)
    if "gree" in sections and framing == "gree":
        last = {}
        for t, src, typ, b in frames:
            last[typ] = (t, gree_decode(typ, b))
        res["gree"] = {k: {"t_ms": v[0], **v[1]} for k, v in last.items()}
    if as_json:
        print(json.dumps(res, indent=1))
        return
    for sec, val in res.items():
        print("=" * 78)
        print(sec.upper())
        print("=" * 78)
        if sec == "frames":
            print("\n".join(val))
        elif sec == "columns":
            for g, cols in val.items():
                print(g)
                for c in cols:
                    extra = {k: v for k, v in c.items() if k not in ("byte", "min", "max", "distinct", "changes")}
                    print("  b%-2d min %3d max %3d distinct %3d changes %3d  %s" % (
                        c["byte"], c["min"], c["max"], c["distinct"], c["changes"],
                        "; ".join("%s %s" % (k, v) for k, v in extra.items())))
        elif sec == "timeline":
            for g, rows in val.items():
                print(g)
                for r in rows:
                    print("  " + r)
        elif sec == "events":
            for e in val:
                what = e.get("text") or json.dumps(e.get("state"))
                print("%7d ms %-6s %s" % (e["t_ms"], e["kind"], what))
                for g, d in e["changed"].items():
                    print("            changed  %s: %s" % (g, ", ".join(d)))
                for g, d in e.get("drifting", {}).items():
                    print("            drifting %s: %s  (already changing before, or the checksum: not caused by this)" % (g, ", ".join(d)))
                if not e["changed"] and not e.get("drifting"):
                    print("            (no frame change seen, or no frames around it)")
        else:
            print(json.dumps(val, indent=1))
        print()

def merge(caps):
    """Several captures one after the other: times of each one are shifted to follow the previous."""
    if len(caps) == 1:
        return caps[0]
    out = {"comments": [], "chunks": [], "events": [], "gree": [], "windows": [], "bus": caps[0]["bus"]}
    offset = 0
    for k, c in enumerate(caps):
        out["comments"] += c["comments"]
        out["chunks"] += [(t + offset, s, b) for t, s, b in c["chunks"]]
        out["events"] += [(t + offset, s, j) for t, s, j in c["events"]]
        out["events"].append((offset, "MARK", {"text": "start of capture file %d" % (k + 1)}))
        out["gree"] += [(t + offset, j) for t, j in c["gree"]]
        out["windows"] += [(w[0] + 100 * k, w[1], w[2]) for w in c["windows"]]
        last = max([t for t, _, _ in c["chunks"]] + [t for t, _, _ in c["events"]] + [0])
        offset += last + 60000          # a minute apart, so events never mix across files
    return out

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", nargs="+", help="one or more capture files, analysed as one, in this order")
    ap.add_argument("--section", action="append",
                    choices=["summary", "frames", "checksum", "columns", "events", "timeline", "gree"])
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    sections = a.section or ["summary", "frames", "checksum", "columns", "events", "timeline", "gree"]
    report(merge([parse(p) for p in a.capture]), sections, a.json)

if __name__ == "__main__":
    sys.exit(main())
