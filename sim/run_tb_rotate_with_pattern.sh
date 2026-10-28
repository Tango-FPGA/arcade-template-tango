#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
# run_tb_rotate_with_pattern.sh -- the rotation gate (sim/tb_rotate_with_pattern.v's header has the details): the
# framework's rotation RTL (sys/tango_video_rotate_ddr3.v) fed by this core's simulated picture, every write checked.
#   usage: sim/run_tb_rotate_with_pattern.sh
# Heavy jobs: when build/heavy_lock.sh exists (a local, optional queue that lets one heavy job at a time run on a
# shared machine) the build and the run go through it; without it they just run.
# Memory cap: TANGO_MEM_CAP (default 4G).
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OBJ=sim/obj_rotate_pattern
HL=(); [ -x "$ROOT/build/heavy_lock.sh" ] && HL=("$ROOT/build/heavy_lock.sh")   # optional heavy-job queue (header)
export TANGO_MEM_CAP="${TANGO_MEM_CAP:-4G}"
mkdir -p "$OBJ"
"${HL[@]}" "$ROOT/sys/build_tools/tango_capped.sh" verilator --binary --timing -O3 -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-SYMRSVDWORD -Wno-CASEINCOMPLETE -Wno-PINMISSING \
    +define+TANGO_VIDEO_ASCAL +define+TANGO_VIDEO_OPTS +define+TANGO_VIDEO_PROC +define+TANGO_IOCTL_UPLOAD \
    '-DBUILD_DATE="sim"' \
    -Mdir "$OBJ" --top-module tb_rotate_with_pattern -I"$ROOT/sys" -I"$ROOT/rtl" \
    "$ROOT/sim/tb_rotate_with_pattern.v" "$ROOT/rtl/tango_core_arcade_template.v" "$ROOT/sys/tango_conf_rom.v" \
    "$ROOT/sys/tango_video_rotate_ddr3.v" "$ROOT/sys/tango_cdc.v"
set +e
"${HL[@]}" "$ROOT/sys/build_tools/tango_capped.sh" "$OBJ/Vtb_rotate_with_pattern"
TB=$?
set -e
[ $TB -eq 0 ] && echo "TB_ROTATE_WITH_PATTERN SIM GATE: PASS" || \
    { echo "TB_ROTATE_WITH_PATTERN SIM GATE: FAIL (exit $TB)"; exit 1; }
