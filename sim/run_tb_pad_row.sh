#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
# run_tb_pad_row.sh -- the game controls gate (sim/tb_pad_row.v's header has the details): every
# J1 joystick bit lights exactly its own pad-row cell, on both pads. Two runs:
#   1. MUTANT: a scratch copy of rtl/tango_core_arcade_template.v with Up/Down swapped in pad_cells
#      (j[2]/j[3] exchanged), built into its own sim/obj_pad_row_mutant -- tb_pad_row MUST FAIL against it
#      (proof the bench sees a swapped bit). The real rtl/ file is never edited; its sha256 is checked
#      unchanged afterwards.
#   2. REAL: the unmodified RTL, built fresh into sim/obj_pad_row -- tb_pad_row MUST PASS.
# Same defines as sim/run_tb_video_pattern.sh (every define of this core that adds or changes a port).
#   usage: sim/run_tb_pad_row.sh
# Heavy jobs: when build/heavy_lock.sh exists (a local, optional queue that lets one heavy job at a time run on a
# shared machine) the whole script runs under it (taken once for both runs);
# without it the script just runs.  Memory cap: TANGO_MEM_CAP.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export TANGO_MEM_CAP="${TANGO_MEM_CAP:-4G}"
if [ -z "${TB_PAD_ROW_LOCKED:-}" ] && [ -x "$ROOT/build/heavy_lock.sh" ]; then   # optional heavy-job queue (header)
    TB_PAD_ROW_LOCKED=1 exec "$ROOT/build/heavy_lock.sh" "$ROOT/sim/run_tb_pad_row.sh"
fi

RTL="$ROOT/rtl/tango_core_arcade_template.v"
SHA_BEFORE=$(sha256sum "$RTL" | cut -d' ' -f1)
build() {   # build <rtl file> <obj dir>
    rm -rf "$2"; mkdir -p "$2"
    "$ROOT/sys/build_tools/tango_capped.sh" verilator --binary --timing -O3 -Wall -Wno-fatal \
        -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
        -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-SYMRSVDWORD -Wno-CASEINCOMPLETE \
        +define+TANGO_VIDEO_ASCAL +define+TANGO_VIDEO_OPTS +define+TANGO_VIDEO_PROC +define+TANGO_IOCTL_UPLOAD \
        '-DBUILD_DATE="sim"' \
        -Mdir "$2" --top-module tb_pad_row -I"$ROOT/sys" -I"$ROOT/rtl" \
        "$ROOT/sim/tb_pad_row.v" "$1" "$ROOT/sys/tango_conf_rom.v"
}

# ---- 1. mutant (must FAIL)
MUT_DIR="$ROOT/sim/obj_pad_row_mutant"; mkdir -p "$MUT_DIR"
MUT="$MUT_DIR/tango_core_arcade_template_mutant.v"
ORIG='pad_cells = {j[7], j[6], j[5], j[4], j[0], j[1], j[2], j[3]};'
SWAP='pad_cells = {j[7], j[6], j[5], j[4], j[0], j[1], j[3], j[2]};'
[ "$(grep -cF "$ORIG" "$RTL")" = 1 ] || { echo "MUTANT: the pad_cells line was not found exactly once -- cannot mutate"; exit 1; }
python3 -c 'import sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(s.replace(sys.argv[3], sys.argv[4]))' \
    "$RTL" "$MUT" "$ORIG" "$SWAP"
[ "$(grep -cF "$SWAP" "$MUT")" = 1 ] || { echo "MUTANT: substitution did not take"; exit 1; }
build "$MUT" "$MUT_DIR/obj"
set +e
"$ROOT/sys/build_tools/tango_capped.sh" "$MUT_DIR/obj/Vtb_pad_row" > "$MUT_DIR/run.log" 2>&1
MT=$?
set -e
grep -E 'MISMATCH|TB_PAD_ROW:|TB_RESULT' "$MUT_DIR/run.log" | head -8
NMM=$(grep -c MISMATCH "$MUT_DIR/run.log" || true)
if [ $MT -ne 0 ] && grep -q 'TB_RESULT FAIL' "$MUT_DIR/run.log" && [ "$NMM" -gt 0 ]; then
    echo "MUTANT (Up/Down swapped): FAILS as required ($NMM mismatch line(s), exit $MT)"
else
    echo "MUTANT (Up/Down swapped): did NOT fail (exit $MT) -- the bench cannot see a swapped bit"
    echo "TB_PAD_ROW SIM GATE: FAIL"; exit 1
fi

# ---- 2. real RTL (must PASS)
[ "$(sha256sum "$RTL" | cut -d' ' -f1)" = "$SHA_BEFORE" ] || { echo "rtl/ changed during the mutant run"; exit 1; }
build "$RTL" "$ROOT/sim/obj_pad_row"
set +e
"$ROOT/sys/build_tools/tango_capped.sh" "$ROOT/sim/obj_pad_row/Vtb_pad_row"
TB=$?
set -e
[ $TB -eq 0 ] && echo "TB_PAD_ROW SIM GATE: PASS (real RTL passes, Up/Down mutant fails)" || \
    { echo "TB_PAD_ROW SIM GATE: FAIL (exit $TB)"; exit 1; }
