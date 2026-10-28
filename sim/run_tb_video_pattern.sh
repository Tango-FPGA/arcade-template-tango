#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
# run_tb_video_pattern.sh -- the test picture's gate (sim/tb_video_pattern.v's header has the details): a
# Verilator --binary unit bench of the core alone.
#   usage: sim/run_tb_video_pattern.sh
# Builds rtl/tango_core_arcade_template.v with TANGO_VIDEO_ASCAL + TANGO_VIDEO_OPTS + TANGO_VIDEO_PROC +
# TANGO_IOCTL_UPLOAD -- every one of this core's build-time defines that adds or changes a port
# (TANGO_VIDEO_PROC adds AUDIO_MIX). TANGO_VIDEO_DDR3/TANGO_VIDEO_ROTATE add no ports (sys/tango_core_ports.vh),
# so this sim does not need them.
# Heavy jobs: when build/heavy_lock.sh exists (a local, optional queue that lets one heavy job at a time run on a
# shared machine) the build and the run go through it; without it they just run.
# Memory cap: TANGO_MEM_CAP (default 4G).
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OBJ=sim/obj_video_pattern
HL=(); [ -x "$ROOT/build/heavy_lock.sh" ] && HL=("$ROOT/build/heavy_lock.sh")   # optional heavy-job queue (header)
export TANGO_MEM_CAP="${TANGO_MEM_CAP:-4G}"
mkdir -p "$OBJ"
"${HL[@]}" "$ROOT/sys/build_tools/tango_capped.sh" verilator --binary --timing -O3 -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-SYMRSVDWORD -Wno-CASEINCOMPLETE \
    +define+TANGO_VIDEO_ASCAL +define+TANGO_VIDEO_OPTS +define+TANGO_VIDEO_PROC +define+TANGO_IOCTL_UPLOAD \
    '-DBUILD_DATE="sim"' \
    -Mdir "$OBJ" --top-module tb_video_pattern -I"$ROOT/sys" -I"$ROOT/rtl" \
    "$ROOT/sim/tb_video_pattern.v" "$ROOT/rtl/tango_core_arcade_template.v" "$ROOT/sys/tango_conf_rom.v"
set +e
"${HL[@]}" "$ROOT/sys/build_tools/tango_capped.sh" "$OBJ/Vtb_video_pattern"
TB=$?
set -e
[ $TB -eq 0 ] && echo "TB_VIDEO_PATTERN SIM GATE: PASS" || \
    { echo "TB_VIDEO_PATTERN SIM GATE: FAIL (exit $TB)"; exit 1; }
