#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 the Tango authors
# build_arcade_template_ascal.sh -- the card build of the Arcade Template core: the same RTL as
# build/build_arcade_template.sh (the picture is all `ifdef TANGO_VIDEO_ASCAL), with a real picture through the
# framework's scaler, its frame buffers in the DDR3, the video and audio processing and screen rotation:
#   TANGO_VIDEO_ASCAL=1 TANGO_VIDEO_DDR3=1 TANGO_VIDEO_OPTS=1 TANGO_VIDEO_PROC=1 TANGO_VIDEO_ASCAL_MAXW=288
#   TANGO_IOCTL_UPLOAD=1 TANGO_VIDEO_ROTATE=1
# TANGO_VIDEO_ASCAL_MAXW=288: this core's native active width (288x224, Galaga's geometry; the RTL's header); the
# framework's default (256, sys/tango_cfg.vh) is too narrow.
# TANGO_DDRAM is not passed: sys/board/console138k/build_core.sh derives it from TANGO_VIDEO_ROTATE.
# No core .sdc (the `-` argument below): this core has no clock of its own (CLK_SYS = CLK_PIX); build_core.sh adds
# the DDR3 SDC (tango_console138k_ddr3.sdc) and its clock groups for TANGO_VIDEO_DDR3 / _ROTATE.
# Timing: placement varies with the build date (it is in the CONF_STR, TANGO_BUILD_DATE); a build whose STA gate
# fails can be drawn again with another TANGO_BUILD_DATE.  This script runs one build.
#   build/build_arcade_template_ascal.sh
# Gate: sys/build_tools/sta_gate.py, STRICT (no --relax): this build has no clk_sdram clock at all
# (TANGO_VIDEO_DDR3, no tango_sdram).
# Archive: $TANGO_ARCHIVE (default <repo>/bitstreams/)/tango_arcade_template_ascal138_<YYYYMMDD-HHMM>_g<git>[-dirty]_ascal_rot.{fs,bin,txt}
#   (the _ascal_rot suffix tells it apart from the bare build's archive).
# Heavy jobs: when build/heavy_lock.sh exists (a local, optional queue that lets one heavy job at a time run on a
# shared machine) the build_core.sh call below goes through it; without it the
# build just runs.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HL=(); [ -x "$ROOT/build/heavy_lock.sh" ] && HL=("$ROOT/build/heavy_lock.sh")   # optional heavy-job queue (header)
NAME=tango_arcade_template_ascal138
FILES="$ROOT/rtl/tango_core_arcade_template.v"
OPTS="TANGO_VIDEO_ASCAL=1 TANGO_VIDEO_DDR3=1 TANGO_VIDEO_OPTS=1 TANGO_VIDEO_PROC=1 TANGO_VIDEO_ASCAL_MAXW=288 TANGO_IOCTL_UPLOAD=1 TANGO_VIDEO_ROTATE=1"
START=$(mktemp); trap 'rm -f "$START"' EXIT
set +e
"${HL[@]}" bash -c "env $OPTS TANGO_NO_ARCHIVE=1 TANGO_OUT=build/out '$ROOT/sys/board/console138k/build_core.sh' '$NAME' - $FILES"
BC=$?
set -e
IMPL="$ROOT/build/out/$NAME/impl/pnr"
FS="$IMPL/$NAME.fs"
[ $BC -eq 0 ] && [ -f "$FS" ] && [ "$FS" -nt "$START" ] || { echo "NO FRESH BITSTREAM (build_core.sh exit $BC)"; exit 1; }
# STRICT gate only (no --relax clk_sdram): this build has no clk_sdram clock at all.
set +e; GATE=$(python3 "$ROOT/sys/build_tools/sta_gate.py" "$IMPL"); SG=$?; set -e
echo "$GATE"
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
DTAG=""; [ -n "$(git status --porcelain --untracked-files=no -- rtl build sys 2>/dev/null)" ] && DTAG="-dirty"
FSHA=$(git -C sys rev-parse --short=12 HEAD); FDIRTY=$(git -C sys status --porcelain --untracked-files=no | wc -l)
MAINROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
ARCH="${TANGO_ARCHIVE:-${TANGO_ARCHIVE_DIR:-$MAINROOT/bitstreams}}"; mkdir -p "$ARCH"
STAMP="$ARCH/${NAME}_$(date +%Y%m%d-%H%M)_g${SHA}${DTAG}_ascal_rot"; [ $SG -ne 0 ] && STAMP="${STAMP}_STA-FAIL"
cp "$FS" "$STAMP.fs" && cmp "$FS" "$STAMP.fs" && chmod 444 "$STAMP.fs"
python3 "$ROOT/sys/build_tools/fs2bin.py" "$STAMP.fs" "$STAMP.bin" && chmod 444 "$STAMP.bin"
{ echo "arcade-template-tango ASCAL+DDR3+ROTATE $SHA$DTAG (scaler: $OPTS)"; echo "framework: sys/ = sys-tango $FSHA (uncommitted files in sys/: $FDIRTY)"
  echo "BUILD_DATE v${TANGO_BUILD_DATE:-$(date +%y%m%d)} (in the CONF_STR: a different date is a different netlist and placement)"
  echo; echo "$GATE"
  grep -E "^\s*(Logic|CLS|Register|BSRAM|DSP|PLL)\s*\|" "$IMPL/$NAME.rpt.txt" || true; } > "$STAMP.txt"
chmod 444 "$STAMP.txt"
ls -l "$STAMP".*
[ $SG -ne 0 ] && { echo "WARNING: STA GATE FAIL -- do NOT flash"; exit 1; }
exit 0
