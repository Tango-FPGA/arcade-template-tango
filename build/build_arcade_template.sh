#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
# build_arcade_template.sh -- the bare build of the Arcade Template core (no picture: the download / upload logic
# only), STA-gated and archived; structured as console-template-tango's build/build_template.sh.
#   build/build_arcade_template.sh
# The framework is sys/, the sys-tango submodule (https://github.com/Tango-FPGA/sys-tango; its commit is the
# version): sys/board/console138k/build_core.sh builds the board top, the framework and rtl/ with the board
# SDC (this core has no clock of its own: CLK_SYS = CLK_PIX, so no core SDC).
# The Gowin output lands in build/out/<name>/ (ignored). The same build as
#   TANGO_IOCTL_UPLOAD=1 sys/board/console138k/build_core.sh tango_arcade_template138 - rtl/tango_core_arcade_template.v
# (TANGO_IOCTL_UPLOAD=1 is required: the core's ioctl_upload/ioctl_din/ioctl_upload_req/ioctl_upload_index ports
# only exist in tango_core_ports.vh when it is defined; without it synthesis stops with EX3872 "not declared".)
# Gate: sys/build_tools/sta_gate.py (every clock: no setup/hold violation, Fmax >= constraint, fill <= 98%).
# Archive: $TANGO_ARCHIVE (default <repo>/bitstreams/, git-ignored; TANGO_ARCHIVE_DIR is the older name)/
#   tango_arcade_template138_<YYYYMMDD-HHMM>_g<git>[-dirty].
#   {fs,bin,txt}; the .txt records this repo's and the framework's commits and the gate result. A failing
#   gate is archived as ..._STA-FAIL and printed as do-not-flash. Never flashes anything.
# On the card the .bin goes to /_Console/ArcadeTemplate_<YYYYMMDD>.bin.
# A heavy job (several GB of memory, run through sys/build_tools/tango_capped.sh): one at a time.
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
NAME=tango_arcade_template138
FILES="$ROOT/rtl/tango_core_arcade_template.v"
START=$(mktemp); trap 'rm -f "$START"' EXIT
set +e
bash -c "TANGO_NO_ARCHIVE=1 TANGO_IOCTL_UPLOAD=1 TANGO_OUT=build/out '$ROOT/sys/board/console138k/build_core.sh' '$NAME' - $FILES"
BC=$?
set -e
IMPL="$ROOT/build/out/$NAME/impl/pnr"
FS="$IMPL/$NAME.fs"
[ $BC -eq 0 ] && [ -f "$FS" ] && [ "$FS" -nt "$START" ] || { echo "NO FRESH BITSTREAM (build_core.sh exit $BC)"; exit 1; }
set +e; GATE=$(python3 "$ROOT/sys/build_tools/sta_gate.py" "$IMPL"); SG=$?; set -e
echo "$GATE"
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
DTAG=""; [ -n "$(git status --porcelain --untracked-files=no -- rtl build sys 2>/dev/null)" ] && DTAG="-dirty"
FSHA=$(git -C sys rev-parse --short=12 HEAD); FDIRTY=$(git -C sys status --porcelain --untracked-files=no | wc -l)
# archive: <repo>/bitstreams/ (git-ignored; the MAIN checkout's, also when run from a worktree), like every other *-tango repo
MAINROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
ARCH="${TANGO_ARCHIVE:-${TANGO_ARCHIVE_DIR:-$MAINROOT/bitstreams}}"; mkdir -p "$ARCH"
STAMP="$ARCH/${NAME}_$(date +%Y%m%d-%H%M)_g${SHA}${DTAG}"; [ $SG -ne 0 ] && STAMP="${STAMP}_STA-FAIL"
cp "$FS" "$STAMP.fs" && cmp "$FS" "$STAMP.fs" && chmod 444 "$STAMP.fs"
python3 "$ROOT/sys/build_tools/fs2bin.py" "$STAMP.fs" "$STAMP.bin" && chmod 444 "$STAMP.bin"
{ echo "arcade-template-tango $SHA$DTAG"; echo "framework: sys/ = sys-tango $FSHA (uncommitted files in sys/: $FDIRTY)"
  echo; echo "$GATE"
  grep -E "^\s*(Logic|CLS|Register|BSRAM|DSP|PLL)\s*\|" "$IMPL/$NAME.rpt.txt" || true; } > "$STAMP.txt"
chmod 444 "$STAMP.txt"
ls -l "$STAMP".*
[ $SG -ne 0 ] && { echo "WARNING: STA GATE FAIL -- do NOT flash"; exit 1; }
exit 0
