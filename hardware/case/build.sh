#!/bin/bash
# Gree bridge rev B case: layout -> STL (OpenSCAD) -> STEP (CadQuery) -> fit check -> PNG renders
# usage: ./build.sh [path/to/gree_bridge.kicad_pcb]
set -e
cd "$(dirname "$0")"
mkdir -p out/stl out/check out/step out/png
python3 layout_gree.py "$@"
for p in base lid cap; do
  openscad -q -o out/check/${p}_inplace.stl -D "part=\"${p}_inplace\"" gree_case.scad &
  openscad -q -o out/stl/gree_${p}.stl -D "part=\"${p}\"" gree_case.scad &
done
wait
python3 gree_case_cq.py
set +e
python3 fit_check.py > /dev/null; fit=$?
set -e
tail -1 out/fit_check.txt
python3 render_gree.py 2>&1 | grep -v -i -E "bad X server|deprecat|to_planar"
echo "done: out/stl (print), out/step (Fusion), out/png, out/fit_check.txt"
exit $fit
