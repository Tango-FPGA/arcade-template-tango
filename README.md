# arcade-template-tango -- the Tango Arcade Template core

**Version 2026-11-14** (date code `20261114`)

arcade-template-tango is the **Arcade Template core** of the Tango FPGA system for the **Sipeed Tang Console 138K**:
the starting point for writing an arcade core, as [console-template-tango](https://github.com/Tango-FPGA/console-template-tango)
is for a console core. It is launched from an **`.mra`** file the way MiSTer launches arcade cores, and it takes
what an arcade core takes -- a **ROM download**, the **DIP switches** of the `.mra`, a **save (NVRAM)** that goes
back to the SD card and comes back at the next launch -- and runs through the framework's **screen rotation** for
portrait games. It is not a game: it shows each of those on a test picture, so you can see that they work and copy
the mechanism into your own core.

Like every Tango core it is built on the framework [sys-tango](https://github.com/Tango-FPGA/sys-tango), which this
repository includes as a git submodule at `sys/`. The BL616 firmware that reads the `.mra`, loads the core and
draws its menu is [firmware-tango](https://github.com/Tango-FPGA/firmware-tango); the launcher is
[menu-tango](https://github.com/Tango-FPGA/menu-tango).

## Contents

- [What the core does](#what-the-core-does)
- [Trying it on the board](#trying-it-on-the-board)
- [Building from source](#building-from-source)
- [Making an arcade core from it](#making-an-arcade-core-from-it)
- [Layout](#layout)
- [Licence](#licence)

## What the core does

`rtl/tango_core_arcade_template.v` is a `tango_core` (the framework's core interface, `sys/tango_core_ports.vh`);
its header describes every signal and index. It uses the framework's two download directions
(`TANGO_IOCTL_UPLOAD`):

| Index | What | Direction |
|---|---|---|
| 0 | the ROM: the `.mra`'s `<rom index="0">` (here 16 bytes written inline, the ASCII text `TANGO-A5-ROM-OK!`) | download |
| 254 | the DIP switch word (8 bytes, little-endian): the `.mra`'s `<switches>`, set in the menu's DIP page | download |
| 4 | the NVRAM (8 bytes): the `.mra`'s `<nvram index="4" size="8"/>`; restored at launch, saved with System, Save settings | download and upload |

One clock after an NVRAM download closes, the core adds 1 to the value, so a value that went through a save and a
restore is visibly the core's own and not a copy of the downloaded bytes: each save, reboot and launch counts up by
one.

**The menu string (CONF_STR)** is `ArcadeTemplate;;-;DIP;-;` + the framework's Video entries (Aspect ratio, Scale,
Scanlines, Rotation; the card build only) + `-;T[0],Reset;R[0],Reset and close OSD;J1,Button 1,Button 2,Start,Coin;`
+ the version. `DIP` is the DIP switch page; `J1` names four buttons (System, Define buttons; with no saved map the
firmware gives Button 1 = A, Button 2 = B, Start = Start, Coin = R, the right shoulder).

**The test picture** (the card build): a native 288 x 224 frame at Galaga's video timing (384 x 264 total, 6.1875 MHz
pixels, 61.03 Hz), through the framework's scaler. Black background; from top to bottom, in the core's own
(unrotated) frame:

1. a **magenta 16 x 16 block** in the top-left corner (after a rotation it tells clockwise from counter-clockwise);
2. a **white arrow** pointing to the core's "up";
3. **DIP**: 64 cells, the 8-byte DIP word;
4. **NVRAM**: 64 cells, the 8 NVRAM bytes;
5. **ROM lo** and 6. **ROM hi**: 64 cells each, ROM bytes 0-7 and 8-15;
7. at the bottom left, the **frame counter**: 8 cells, counting;
8. at the bottom right, the **pads**: two rows of 8 cells, joystick 0 (USB-A2) on top and joystick 1 (USB-A1)
   below, in the order Up, Down, Left, Right, Button 1, Button 2, Start, Coin.

In every row **green = 1, red = 0**; byte 0 is the leftmost 8 cells and **bit 0 of each byte is its leftmost
cell**, so the byte 0xC5 reads green, red, green, red, red, red, green, green. A pad cell is green while that input
is held. Both pad rows read 0 (all red) while the menu is open.

## Trying it on the board

You need a Tang Console 138K with [firmware-tango](https://github.com/Tango-FPGA/firmware-tango) in its BL616 and
[menu-tango](https://github.com/Tango-FPGA/menu-tango)'s launcher on a FAT32 SD card (firmware-tango's README, "The SD
card"). The core is in this repository's **`releases/`** folder, one file per release named
`Arcade-arcadetemplate_<YYYYMMDD>.bin` (this version: `releases/Arcade-arcadetemplate_20261114.bin`). Take the
latest (the newest date).

| On the card | What |
|---|---|
| `/_Arcade/Arcade Template Test.mra` | `fixtures/Arcade Template Test.mra` from this repository: the name, the core (`<rbf>arcadetemplate</rbf>`), the ROM, the DIP switches, the NVRAM |
| `/_Arcade/cores/Arcade-arcadetemplate_<YYYYMMDD>.bin` | the newest **`releases/Arcade-arcadetemplate_<YYYYMMDD>.bin`** from this repository, the card build (`build/build_arcade_template_ascal.sh`); the firmware resolves `<rbf>arcadetemplate</rbf>` to `Arcade-arcadetemplate_<date>.bin` (or `arcadetemplate_<date>.bin`), the greatest name winning |
| `/config/nvram/Arcade Template Test.nvm` | written by System, Save settings (8 bytes) |

Its menu string ends `V,v<YYMMDD>`, the build date it was built with (System, About; this version: `V,v261114`). What to expect:

1. **Launch** "Arcade Template Test" from the launcher's Arcade list: the test picture, the frame counter running,
   ROM lo = `TANGO-A5` (54 41 4E 47 4F 2D 41 35) and ROM hi = `-ROM-OK!` (2D 52 4F 4D 2D 4F 4B 21).
2. **DIP:** the `.mra`'s default `C5` -- the first 8 DIP cells read green, red, green, red, red, red, green, green;
   the other 56 red. In the menu's DIP page, `Bit 1` On lights the second cell at once.
3. **NVRAM:** the first launch (no `.nvm`) shows all red. System, Save settings writes the `.nvm`; after a power
   cycle and a new launch the value is the saved one + 1 (`01 00 ...`: the leftmost cell green), and it counts up by
   one with every save, reboot and launch.
4. **Rotation:** the Video page's Rotation Normal / CW / CCW turns the whole picture; the magenta block shows which
   way.
5. **Pads:** each of Up, Down, Left, Right, A, B, Start and R lights exactly one cell of the row of the port the pad
   is in.

## Building from source

You need, on Linux (x86-64):

- **Gowin EDA** (the IDE with `gw_sh`), V1.9.11.03, with a licence for the GW5AST-138 and its DDR3 Memory Interface
  IP. The framework's `build_core.sh` runs it headless from `$GOWIN_HOME/IDE` (default `~/gowin`) and takes Gowin's
  `PLL_INIT` and the DDR3 IP from that installation (sys-tango README, "Building").
- **Python 3** (the build tools).
- **systemd** user scopes for `tango_capped.sh`, which runs the build in a memory-capped cgroup. A 138K build needs a
  few GB of memory; run one build at a time.

Get the sources with the framework:

    git clone https://github.com/Tango-FPGA/arcade-template-tango.git
    cd arcade-template-tango
    git submodule update --init          # sys/ = sys-tango, at the commit this release was built with

Build:

    build/build_arcade_template_ascal.sh  # the card build: the picture, scaler + DDR3, video and audio processing, rotation
    build/build_arcade_template.sh        # the bare build: no picture, the download / upload logic only

Each runs the framework's `sys/board/console138k/build_core.sh` (the Gowin project in `build/out/<name>/`), then the
STA gate (`sys/build_tools/sta_gate.py`: no setup or hold violation, every clock at or above its constraint, a worst
setup slack of at least +0.10 ns, logic and block RAM at most 98%; never use a build whose gate failed), and archives
the result in `$TANGO_ARCHIVE` (default `bitstreams/` in the checkout) as `<name>_<YYYYMMDD-HHMM>_g<commit>....{fs,bin,txt}`
(`..._STA-FAIL` when the gate failed; the `.txt` holds the gate's report and the resource use).

`TANGO_BUILD_DATE=<YYMMDD>` sets the build date in the menu string (the default is today); the release's `.bin` was
built with `TANGO_BUILD_DATE=261114`. The card build's timing depends on placement, which changes with the build
date: if its STA gate fails, build again with another `TANGO_BUILD_DATE`.

## Making an arcade core from it

1. **Copy this repository** to `<core>-tango` and start a fresh history; keep `sys/` as the sys-tango submodule.
2. **The core:** replace `rtl/tango_core_arcade_template.v` with your `module tango_core`. Take the ROM from the
   download at the indices your `.mra` gives, the DIP word at index 254 and the NVRAM at its `<nvram index>`, and
   answer the upload (`ioctl_upload`, `ioctl_rd`, `ioctl_din`) for the NVRAM. Name your buttons with a `J1` entry.
3. **The `.mra`:** MiSTer's format (`<rbf>`, `<rom>`, `<switches>`, `<nvram>`, `<buttons>`); a game's ROM data comes
   from the ROM zip its `<rom>` names, at run time -- never in the core or in your repository.
4. **The build:** copy `build/build_arcade_template_ascal.sh`, set `NAME` and your files, and add a core `.sdc` if
   your core has a clock of its own (sys-tango README, "Timing constraints"). A portrait game keeps
   `TANGO_VIDEO_ROTATE=1`.

## Layout

| Path | What |
|---|---|
| `rtl/tango_core_arcade_template.v` | the core (module `tango_core`) |
| `fixtures/Arcade Template Test.mra` | the `.mra` that launches it (no game ROM data: 16 inline bytes) |
| `build/` | the Gowin builds (above) |
| `releases/` | the core bitstreams, `Arcade-arcadetemplate_<YYYYMMDD>.bin`, one per release (copy the latest to the card's `/_Arcade/cores/`) |
| `sys/` | the framework, [sys-tango](https://github.com/Tango-FPGA/sys-tango) (git submodule) |

## Licence

**GPL-2.0-or-later** (`LICENSE`, the GNU General Public License version 2 text), `Copyright (c) 2026 the Tango
authors`: every Tango-written file says so in its `SPDX-License-Identifier: GPL-2.0-or-later` header. The core
contains a few MiSTer strings under that licence -- the menu entries `T[0],Reset;` and `R[0],Reset and close OSD;`
(as in Template_MiSTer's `Template.sv`), and quotes in comments of Arcade-Galaga_MiSTer's button lines and of a
Galaxian `.mra`'s `<buttons>` line; `NOTICE` lists each. The menu string format (CONF_STR), the `.mra` format and the
core interface are MiSTer's; the link to the BL616 follows [FPGA Companion](https://github.com/MiSTle-Dev/FPGA-Companion).
Release 20261028 of this repository was published under the MIT licence and keeps it.

The framework in `sys/` is sys-tango's, under its own `LICENSE` and `NOTICE`.

**The bitstream (`releases/Arcade-arcadetemplate_<YYYYMMDD>.bin`)** is a combined work distributed under the terms of
GPL-2.0-or-later: it contains the Arcade Template core, and the card build also includes sys-tango's
`tango_video_geo.v`, `tango_shmask.v` and `tango_audio_filter.v`, GPL-2.0-or-later (derived from MiSTer; sys-tango's
`NOTICE`). Its source is this repository with sys-tango at `sys/` (the commit the submodule points at). `PLL_INIT`
and the DDR3 Memory Interface IP, which the build takes from the Gowin installation, keep Gowin's terms.
