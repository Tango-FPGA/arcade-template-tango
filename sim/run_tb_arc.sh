#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
# run_tb_arc.sh -- the core-glue gate: a DIP-index download reaches rtl/tango_core_arcade_template.v and its NVRAM
# value survives a simulated reboot (download in, upload out, download again after the reboot).  PASS needs the
# bench's checks (sim/tb_arc.inc: DIP latched, the NVRAM download and its close (+1), the upload, the reboot clearing
# both registers, the second download restoring the uploaded value, and SYS READ_CFG equal to the RTL's CONF_STR byte
# for byte) and a run with no MISO violation (tb_menu.cpp's end-of-run checks).  Built like menu-tango's upload
# bench (TANGO_IOCTL_UPLOAD in both +define and -CFLAGS), with this repository's file list (sim/tb_arc.files) and
# mode=arc.
#   usage: sim/run_tb_arc.sh
# Heavy jobs: when build/heavy_lock.sh exists (a local, optional queue that lets one heavy job at a time run on a
# shared machine) the build and the run go through it; without it they just run.
# Memory cap: TANGO_MEM_CAP (default 4G, via sys/build_tools/tango_capped.sh).
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OBJ=sim/obj_arc
HL=(); [ -x "$ROOT/build/heavy_lock.sh" ] && HL=("$ROOT/build/heavy_lock.sh")   # optional heavy-job queue (header)
export TANGO_MEM_CAP="${TANGO_MEM_CAP:-4G}"
mkdir -p "$OBJ"
"${HL[@]}" "$ROOT/sys/build_tools/tango_capped.sh" verilator --cc --exe --build -O3 -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-SYMRSVDWORD -DTANGO_SIM_RANDOM_RAM +define+TANGO_IOCTL_UPLOAD \
    '-DBUILD_DATE="sim"' -CFLAGS -DTANGO_IOCTL_UPLOAD \
    -Mdir "$OBJ" --top-module tb_menu -I"$ROOT/sys" -I"$ROOT/rtl" \
    $(grep '\.v$' sim/tb_arc.files | sed "s#^#$ROOT/#") \
    "$ROOT/sim/tb_menu.cpp" -o Vtb_menu
set +e
"${HL[@]}" "$ROOT/sys/build_tools/tango_capped.sh" "$OBJ/Vtb_menu" \
    sim/streams/empty.bin sim/streams/empty.bin "$OBJ" 37500 2000 din=2000 dout=8000 tsu=3000 th=1000 mode=arc
TB=$?
set -e
# human-readable reference only (the real READ_CFG check runs INSIDE the sim, tb_arc.inc's own step 21,
# against a hardcoded expected string -- this just prints the RTL's own CONF_STR for anyone reading the log)
verilator -E -P '-DBUILD_DATE="sim"' -I"$ROOT/sys" -I"$ROOT/rtl" rtl/tango_core_arcade_template.v > "$OBJ/tango_arc_pp.v" 2>/dev/null
python3 - "$OBJ/tango_arc_pp.v" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
body = src[src.index('localparam CONF_STR = {'):src.index('};', src.index('localparam CONF_STR = {'))]
conf = ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', body))
print('CONF_STR (from the RTL, macros expanded by verilator -E, for reference only):', repr(conf))
print('CONF_STR_LEN', len(conf))
PY
[ $TB -eq 0 ] && echo "ARCADE-TEMPLATE CORE-GLUE SIM GATE: PASS" || \
    { echo "ARCADE-TEMPLATE CORE-GLUE SIM GATE: FAIL (tb $TB)"; exit 1; }
