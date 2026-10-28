// SPDX-License-Identifier: MIT
// Copyright (c) 2026 the Tango authors
//==============================================================================
// tango_core (arcade-template-tango) -- the Arcade Template core: the minimal core for the arcade side of the
// Tango framework.  Launched from an .mra (fixtures/Arcade Template Test.mra), it takes the downloads an arcade
// core takes -- a ROM at index 0, the DIP switch word at index 254, a save (NVRAM) at index 4 -- gives the NVRAM
// back through the framework's upload direction (TANGO_IOCTL_UPLOAD), and shows all of it on a test picture.
// Not a game: no sound, no CPU.
//
// Two builds:
//   build/build_arcade_template_ascal.sh  the card build: a native 288 x 224 picture (Galaga's video timing:
//       384 x 264 total, as Arcade-Galaga_MiSTer's rtl/gen_video.vhd) through the framework's scaler, its frame
//       buffers in the DDR3, video and audio processing and screen rotation:
//         TANGO_VIDEO_ASCAL=1 TANGO_VIDEO_DDR3=1 TANGO_VIDEO_OPTS=1 TANGO_VIDEO_PROC=1 TANGO_VIDEO_ASCAL_MAXW=288
//         TANGO_IOCTL_UPLOAD=1 TANGO_VIDEO_ROTATE=1
//       (sys/board/console138k/build_core.sh derives TANGO_DDRAM from TANGO_VIDEO_ROTATE).  Rotation is the
//       framework's (sys/tango_video_rotate_ddr3.v, its Rotation entry in `TANGO_VIDEO_CONF): this core draws one
//       orientation, with a corner marker and an "up" arrow so the rotated picture shows which way it turned.
//       TANGO_VIDEO_PROC adds the port AUDIO_MIX (sys/tango_core_ports.vh), driven below.
//   build/build_arcade_template.sh  the bare build: no picture (VID_RGB black), the download / upload logic only.
//
// Signals (sys/tango_core_ports.vh):
//   ioctl_download, ioctl_index[15:0], ioctl_wr, ioctl_addr[26:0], ioctl_dout[7:0] (inputs): MiSTer's download.
//   ioctl_upload (input, mirrors ioctl_download), ioctl_din[7:0] (output: the core's byte at ioctl_addr),
//   ioctl_rd (input: "sample ioctl_din now, then advance ioctl_addr"): the upload direction (TANGO_IOCTL_UPLOAD).
//   ioctl_upload_req / ioctl_upload_index (outputs): a core-initiated save request; tied low here (the firmware
//   saves on its own schedule, System > Save settings, as MiSTer does).
//
// Indices:
//   0    ROM (16 bytes): the .mra's <rom index="0">, 16 inline bytes ("TANGO-A5-ROM-OK!"); latched into rom_reg
//        and drawn as 128 bit cells; never uploaded.
//   254  DIP word (8 bytes, little-endian): the firmware sends the .mra's <switches> there, as MiSTer does
//        (user_io_set_index(254)); download-only (the OSD keeps the authoritative copy, as in MiSTer).
//   4    NVRAM (8 bytes): the .mra's <nvram index="4" size="8"/>.  A download restores it; one clock after the
//        download closes the core adds 1 to it (so a value that went through a save and a restore is visibly
//        the core's own, not a pass-through of the downloaded bytes); an upload reports the current value.
//
// The simulation (sim/tb_arc.inc, mode=arc on sim/tb_menu.cpp) checks the exact rule: seed in -> seed; close ->
// seed+1; upload reports seed+1; reset -> 0; download the uploaded bytes again -> close -> seed+2.  Its "reboot"
// pulses RESET (rst_pix: this core and the link), not the framework's download FIFO, which has no reset; a real
// reboot reconfigures the whole FPGA.
//==============================================================================
`default_nettype none
module tango_core (
    `include "tango_core_ports.vh"
);
    localparam ROM_IDX   = 8'd0;     // the .mra fixture: 16 inline bytes at index 0 ("TANGO-A5-ROM-OK!")
    localparam DIP_IDX   = 8'd254;   // the DIP word, MiSTer's index for it
    localparam NVRAM_IDX = 8'd4;     // this core's choice; the .mra fixture's <nvram index="4">

    assign CLK_SYS = CLK_PIX;        // as rtl/tango_core_template.v: no clock of its own, no CDC to re-prove here
    wire clk = CLK_PIX;
    wire reset = RESET;              // RESET = tango_sys's rst_pix (sys/tango_sys.v: ".RESET(rst_pix)"); the sim's
                                      // "reboot" pulses this directly -- deliberately NOT status[0], which is the
                                      // OSD's own soft-reset trigger and no part of this core's own proof.

    // ---- CONF_STR.  The scaler build adds the framework's Video entries (`TANGO_VIDEO_CONF, sys/tango_video_opts.vh:
    // Aspect ratio, Scale, Scanlines and, with TANGO_VIDEO_ROTATE, Rotation); the core never names those entries or
    // their bits (status[127:118]) itself.  The bare build has no TANGO_VIDEO_OPTS, so it carries no Video entries.
    //
    // GAME CONTROLS: the `J1` entry is MiSTer's button declaration, the shape MiSTer's arcade cores use
    // (Arcade-Galaga_MiSTer Arcade-Galaga.sv:222 "J1,Fire,Start 1P,Start 2P,Coin,Pause;").  It is not a status bit.
    // The firmware's System > "Define ArcadeTemplate buttons" lists these names, and a pad with no saved map gets
    // the firmware's default guess, which follows MiSTer's joymapping.cpp map_joystick: "Button 1" -> A,
    // "Button 2" -> B, "Start" -> Start, "Coin" -> R (the right shoulder, as Arcade-Galaga.sv's
    // "jn,A,Start,Select,R,L;" also puts Coin on R).  No `jn` line: the guess already gives that map.  "J1" (not
    // "J") also puts the keyboard in joystick mode, MiSTer's meaning.
    // Bits in joystick_0/1 (MiSTer's order, Main_MiSTer input.h and joymapping.cpp "int idx = i+DPAD_COUNT;": the
    // i'th J name at bit 4+i):
    //   bit 0 Right, 1 Left, 2 Down, 3 Up, 4 Button 1, 5 Button 2, 6 Start, 7 Coin.
    // Both CONF_STR variants carry it, just before "V," (V stays the last entry).
`ifdef TANGO_VIDEO_ASCAL
    localparam CONF_STR = {
        "ArcadeTemplate;;",
        "-;",
        "DIP;",
        "-;",
        `TANGO_VIDEO_CONF,
        "-;",
        "T[0],Reset;",
        "R[0],Reset and close OSD;",
        "J1,Button 1,Button 2,Start,Coin;",
        "V,",`BUILD_DATE
    };
`else
    localparam CONF_STR = {
        "ArcadeTemplate;;",
        "-;",
        "DIP;",
        "-;",
        "T[0],Reset;",
        "R[0],Reset and close OSD;",
        "J1,Button 1,Button 2,Start,Coin;",
        "V,",`BUILD_DATE
    };
`endif
    tango_conf_rom #(.CONF_STR(CONF_STR)) u_conf (.clk(CLK_PIX), .addr(conf_addr), .q(conf_char));
    assign status_menumask = 16'd0;

    assign AUDIO_L = 16'd0;
    assign AUDIO_R = 16'd0;
`ifdef TANGO_CORE_AUDIO_MIX
    // TANGO_VIDEO_PROC/TANGO_AUDIO_FILTER pull in AUDIO_MIX (sys/tango_core_ports.vh); this core has no
    // audio at all (AUDIO_L/R tied 0 above), so the mix level is functionally inert either way, but an
    // undriven output still synthesizes as a floating net (Gowin EX0211: "assigning undriven bits to Z").
    // Tied to 0 (MiSTer's "none").
    assign AUDIO_MIX = 2'd0;
`endif

    // ---- DIP word (download-only; index 254, 8 bytes)
    wire dl_dip = ioctl_download && (ioctl_index[7:0] == DIP_IDX);
    reg [63:0] dip_reg = 64'd0;
    always @(posedge clk) begin
        if (reset) dip_reg <= 64'd0;
        else if (dl_dip && ioctl_wr && ioctl_addr < 27'd8)
            dip_reg[{ioctl_addr[2:0], 3'd0} +: 8] <= ioctl_dout;
    end

    // ---- ROM strip (download-only; index 0, 16 bytes, the .mra fixture's ROM).
    // Same treatment as DIP: latched, never uploaded, cleared on reset -- not a real ROM path, just 16 bytes
    // made visible on the test picture.
    wire dl_rom = ioctl_download && (ioctl_index[7:0] == ROM_IDX);
    reg [127:0] rom_reg = 128'd0;
    always @(posedge clk) begin
        if (reset) rom_reg <= 128'd0;
        else if (dl_rom && ioctl_wr && ioctl_addr < 27'd16)
            rom_reg[{ioctl_addr[3:0], 3'd0} +: 8] <= ioctl_dout;
    end

    // ---- NVRAM (download restores it; the core adds 1 exactly once, the clock after the download's close,
    // the rule the header gives -- "gameplay touched the save")
    wire dl_nvram = ioctl_download && (ioctl_index[7:0] == NVRAM_IDX);
    reg  dl_nvram_q = 1'b0;
    reg [63:0] nvram_reg = 64'd0;
    always @(posedge clk) begin
        dl_nvram_q <= dl_nvram;
        if (reset) begin
            nvram_reg <= 64'd0;                                      // the "reboot" clears it: proof the later
        end else if (dl_nvram && ioctl_wr && ioctl_addr < 27'd8) begin  // re-download is not a vacuous re-read
            nvram_reg[{ioctl_addr[2:0], 3'd0} +: 8] <= ioctl_dout;
        end else if (dl_nvram_q && !dl_nvram) begin                   // the download just closed (SELECT size 0)
            nvram_reg <= nvram_reg + 64'd1;                           // the core "owns" the value, not a pass-through
        end
    end

    // ---- upload: ioctl_din is the core's current byte at ioctl_addr, registered one clock after ioctl_addr
    // settles (as a real core's backing RAM would answer: registered, not combinational).
    // Only NVRAM (index 4) is ever uploadable -- the DIP word (254) and ROM strip (0) are download-only,
    // matching MiSTer's own arcade_sw_send (firmware never asks a core for either one back).
    wire ul_nvram = ioctl_upload && (ioctl_index[7:0] == NVRAM_IDX);
    reg [7:0] din_q = 8'd0;
    always @(posedge clk)
        din_q <= (ul_nvram && ioctl_addr < 27'd8) ? nvram_reg[{ioctl_addr[2:0], 3'd0} +: 8] : 8'h00;
    assign ioctl_din = din_q;

    // this core never requests its own save (the firmware saves on its own schedule)
    assign ioctl_upload_req   = 1'b0;
    assign ioctl_upload_index = 8'd0;

    assign ioctl_wait = 1'b0;   // 8/16-byte transfers: no backpressure needed

`ifdef TANGO_VIDEO_ASCAL
    // ======================================================================
    // The picture (scaler build). Native raster = Galaga's geometry: active 288x224, total 384x264 (as
    // Arcade-Galaga_MiSTer's rtl/gen_video.vhd: horizontal counter wraps
    // 128..511 = 384 states; vblank high at vcnt=240, low at vcnt=16, 224 active lines of 264 total).
    // ONE fixed size, no OSD-selectable table (console-template-tango's size_tab is more than a test core
    // with exactly one job): CE_DIV=12 gives 74.25 MHz / 12 = 6.1875 MHz pixels, / (384*264) = 61.03 Hz --
    // close enough to 60 Hz for the scaler's asynchronous input capture, as console-template-tango's 320x240 at
    // 59.04 Hz.
    // ======================================================================
    localparam [9:0] NW  = 10'd288, FNW = 10'd384;
    localparam [8:0] NH  = 9'd224,  FNH = 9'd264;
    localparam [4:0] CDIV = 5'd12;

    reg [4:0] ce_cnt = 5'd0;
    wire      ce = (ce_cnt == CDIV - 5'd1);
    always @(posedge clk) ce_cnt <= ce ? 5'd0 : ce_cnt + 5'd1;
    assign CLK_VIDEO       = CLK_PIX;
    assign CE_PIXEL        = ce;                          // RULE: keeps pulsing through blanking (ce_cnt free-runs)
    assign VGA_SL          = 2'd0;                         // the framework's Scanlines (TANGO_VIDEO_OPTS)
    assign VIDEO_ARX       = 13'd4;                        // the native shape, 4:3: the framework's Aspect ratio
    assign VIDEO_ARY       = 13'd3;                        // "Original" (TANGO_VIDEO_OPTS)
    assign HDMI_FREEZE     = 1'b0;
    assign VIDEO_SCALE     = 3'd0;                         // the framework's Scale (TANGO_VIDEO_OPTS)
    assign VIDEO_CROP_SIZE = 12'd0;
    assign VIDEO_CROP_OFF  = 5'd0;

    reg [9:0] nat_cx = 10'd0;  reg [8:0] nat_cy = 9'd0;
    wire nat_le = (nat_cx == FNW - 10'd1);
    wire nat_fe = nat_le && (nat_cy == FNH - 9'd1);
    always @(posedge clk) if (ce) begin
        if (nat_le) begin
            nat_cx <= 10'd0;
            nat_cy <= nat_fe ? 9'd0 : nat_cy + 9'd1;
        end else nat_cx <= nat_cx + 10'd1;
    end
    wire nat_de = (nat_cx < NW) && (nat_cy < NH);
    assign VGA_DE = nat_de;
    assign VGA_VS = (nat_cy >= NH) && (nat_cy < NH + 9'd3);
    assign VGA_HS = (nat_cx >= NW + 10'd10) && (nat_cx < NW + 10'd22);   // in blanking (ascal does not use HS)

    // ---- the live frame counter (proves the picture is live, not a frozen frame): plain binary, once per
    // native frame.
    reg [7:0] nat_fc = 8'd0;
    always @(posedge clk) if (ce && nat_fe) nat_fc <= nat_fc + 8'd1;

    // ---- the test pattern (header: fixed, core-relative "up"; the framework's rotation turns it downstream;
    // this core draws one orientation and never reads status[119:118] itself). Everything below is a pure
    // function of (nat_cx, nat_cy) plus the three downloaded registers and the frame counter -- no stored
    // bitmap, no font ROM.
    //
    // Layout inside the 288x224 active area (all zones are disjoint; y ranges chosen so a human reading a
    // still capture can tell, top to bottom, "corner marker, arrow, DIP, NVRAM, ROM lo, ROM hi, frame
    // counter" without any text):
    //   y   0..15   a fixed 16x16 magenta block at the native TOP-LEFT corner -- the chirality marker. An
    //               up-arrow alone is left-right symmetric (a transpose bug -> CW could look identical to a
    //               reflection -> looks like CCW); a marker fixed at one corner of the UNROTATED frame
    //               resolves that ambiguity by itself: which output corner it lands in after rotation tells
    //               you the real handedness, not just "something turned".
    //   y  20..99   a white up-arrow (triangular head y 20..51, half-width = y-20; rectangular stem y
    //               52..99, half-width 10), centered on x=144 (NW/2) -- core-relative "up" (toward y=0).
    //   y 108..123  DIP: dip_reg's 8 bytes as 64 one-bit cells, 4 px wide, x 16..271 (bit i = dip_reg[i],
    //               leftmost = bit 0); green = 1, red = 0 (header: "colored bars/blocks whose color encodes
    //               each bit's value").
    //   y 132..147  NVRAM: nvram_reg, same 64-cell/4px/green-red treatment.
    //   y 156..171  ROM lo: rom_reg[63:0] (the fixture's first 8 bytes), same treatment.
    //   y 180..195  ROM hi: rom_reg[127:64] (the fixture's last 8 bytes), same treatment -- together, ROM lo
    //               + ROM hi are all 16 downloaded bytes.
    //   y 204..219  frame counter: nat_fc's 8 bits, 8 px wide cells, x 16..79, same green/red treatment.
    //   y 204..210  PAD P1 (joystick_0, USB-A2) and
    //   y 213..219  PAD P2 (joystick_1, USB-A1): 8 cells each, 16 px pitch from x=128 (cell c lit at x
    //               128+16c .. 128+16c+13, the last 2 px of each pitch black so the 8 cells can be counted
    //               while all are red), x 128..253 in all; green while held, red while released. Cells in
    //               this named order, left to right: Up, Down, Left, Right, Button 1, Button 2, Start,
    //               Coin -- i.e. joystick bits 3, 2, 1, 0, 4, 5, 6, 7 (NOT the "bit 0 leftmost" rule of the
    //               rows above; see pad_cells below).
    //   everything else: black. Columns 272..287 and rows 220..223 stay black in every row (unchanged).
    wire corner_hit = (nat_cx < 10'd16) && (nat_cy < 9'd16);
    wire [9:0] arrow_dx = (nat_cx >= 10'd144) ? (nat_cx - 10'd144) : (10'd144 - nat_cx);
    wire head_hit = (nat_cy >= 9'd20) && (nat_cy < 9'd52) && ({1'b0,arrow_dx} <= (nat_cy - 9'd20));
    wire stem_hit = (nat_cy >= 9'd52) && (nat_cy < 9'd100) && (arrow_dx <= 10'd10);
    wire arrow_hit = head_hit || stem_hit;

    // generic "64 one-bit cells, 4 px wide, starting at x=16" row decode -- shared shape for DIP/NVRAM/ROM
    wire        row64_x_in = (nat_cx >= 10'd16) && (nat_cx < 10'd272);
    wire [5:0]  row64_bit  = nat_cx[7:2] - 6'd4;   // (nat_cx-16)>>2, nat_cx<272 so no wrap

    wire dip_row_hit   = row64_x_in && (nat_cy >= 9'd108) && (nat_cy < 9'd124);
    wire nvram_row_hit = row64_x_in && (nat_cy >= 9'd132) && (nat_cy < 9'd148);
    wire romlo_row_hit = row64_x_in && (nat_cy >= 9'd156) && (nat_cy < 9'd172);
    wire romhi_row_hit = row64_x_in && (nat_cy >= 9'd180) && (nat_cy < 9'd196);

    wire dip_bit   = dip_reg[row64_bit];
    wire nvram_bit = nvram_reg[row64_bit];
    wire romlo_bit = rom_reg[row64_bit];
    wire romhi_bit = rom_reg[{2'b01, row64_bit}];  // rom_reg[64 + row64_bit] = rom_reg[127:64]'s bit row64_bit

    // frame counter row: 8 cells, 8 px wide, x 16..79
    wire       fc_row_x_in = (nat_cx >= 10'd16) && (nat_cx < 10'd80);
    wire       fc_row_hit  = fc_row_x_in && (nat_cy >= 9'd204) && (nat_cy < 9'd220);
    wire [2:0] fc_bit_idx  = nat_cx[5:3] - 3'd2;   // (nat_cx-16)>>3
    wire       fc_bit      = nat_fc[fc_bit_idx];

    // ---- pad rows. Clock domain: joystick_0/1 are CLK_SYS signals (sys/tango_core_ports.vh:
    // "MiSTer hps_io equivalents (CLK_SYS)"); the framework has ALREADY crossed them from its clk_pix into
    // CLK_SYS with a full-word handshake (sys/tango_io.v:85, tango_cdc_word u_joy: `dout` is a register in
    // clk_b = clk_sys, updated only on a completed handshake, so all 32 bits change together). This core
    // sets CLK_SYS = CLK_PIX (above), so joystick_0/1 are already registers in `clk` -- no synchroniser is
    // needed or added here (a per-bit 2-flop sync on a word bus would be the wrong idiom anyway). The one
    // register below is a plain pipeline stage for clk_pix placement margin, not a CDC. A core whose CLK_SYS
    // is NOT its video clock would read joystick_0 in CLK_SYS (its game logic) and cross whatever it draws.
    // Both read 0 while the OSD is shown (sys/tango_io.v:80), so the rows are all red with the OSD open.
    // pad_cells: cell order Up, Down, Left, Right, Button 1, Button 2, Start, Coin (cell 0 = LSB = leftmost);
    // joystick bits per the CONF_STR comment above: 0 R, 1 L, 2 D, 3 U, 4 Button 1, 5 Button 2, 6 Start, 7 Coin.
    function [7:0] pad_cells(input [31:0] j);
        pad_cells = {j[7], j[6], j[5], j[4], j[0], j[1], j[2], j[3]};
    endfunction
    reg [7:0] pad0_q = 8'd0, pad1_q = 8'd0;
    always @(posedge clk) begin
        pad0_q <= pad_cells(joystick_0);
        pad1_q <= pad_cells(joystick_1);
    end
    wire       pad_x_in  = (nat_cx >= 10'd128) && (nat_cx < 10'd256) && (nat_cx[3:0] < 4'd14);
    wire [2:0] pad_cell  = nat_cx[6:4];             // (nat_cx-128)>>4, 128 <= nat_cx < 256
    wire       pad0_hit  = pad_x_in && (nat_cy >= 9'd204) && (nat_cy < 9'd211);
    wire       pad1_hit  = pad_x_in && (nat_cy >= 9'd213) && (nat_cy < 9'd220);

    localparam [23:0] COL_BLACK   = 24'h000000;
    localparam [23:0] COL_WHITE   = 24'hFFFFFF;
    localparam [23:0] COL_MAGENTA = 24'hFF00FF;
    localparam [23:0] COL_GREEN   = 24'h00FF00;
    localparam [23:0] COL_RED     = 24'hFF0000;

    // stage 1: resolve which zone (registered, as console-template-tango's stage 1 / stage 2 pixel pipeline)
    // 0 none/black, 1 corner, 2 arrow, 3 dip, 4 nvram, 5 romlo, 6 romhi, 7 fc, 8 pad P1, 9 pad P2
    reg [3:0] zone1 = 4'd0;
    reg       zbit1 = 1'b0;
    reg       de1   = 1'b0;
    always @(posedge clk) begin
        de1 <= nat_de;
        if (corner_hit)        begin zone1 <= 4'd1; zbit1 <= 1'b0;      end
        else if (arrow_hit)    begin zone1 <= 4'd2; zbit1 <= 1'b0;      end
        else if (dip_row_hit)  begin zone1 <= 4'd3; zbit1 <= dip_bit;   end
        else if (nvram_row_hit)begin zone1 <= 4'd4; zbit1 <= nvram_bit; end
        else if (romlo_row_hit)begin zone1 <= 4'd5; zbit1 <= romlo_bit; end
        else if (romhi_row_hit)begin zone1 <= 4'd6; zbit1 <= romhi_bit; end
        else if (fc_row_hit)   begin zone1 <= 4'd7; zbit1 <= fc_bit;    end
        else if (pad0_hit)     begin zone1 <= 4'd8; zbit1 <= pad0_q[pad_cell]; end
        else if (pad1_hit)     begin zone1 <= 4'd9; zbit1 <= pad1_q[pad_cell]; end
        else                   begin zone1 <= 4'd0; zbit1 <= 1'b0;      end
    end

    // stage 2: zone -> colour
    reg [23:0] nat_rgb = COL_BLACK;
    always @(posedge clk) begin
        if (!de1)              nat_rgb <= COL_BLACK;
        else case (zone1)
            4'd1:               nat_rgb <= COL_MAGENTA;
            4'd2:               nat_rgb <= COL_WHITE;
            4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8, 4'd9: nat_rgb <= zbit1 ? COL_GREEN : COL_RED;
            default:            nat_rgb <= COL_BLACK;
        endcase
    end
    assign VGA_R = nat_rgb[23:16];
    assign VGA_G = nat_rgb[15:8];
    assign VGA_B = nat_rgb[7:0];
`else
    // ---- the bare build (no TANGO_VIDEO_ASCAL): no picture, VID_RGB tied to black.
    assign VID_RGB = 24'd0;
`endif
endmodule
`default_nettype wire
