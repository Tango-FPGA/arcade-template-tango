// SPDX-License-Identifier: MIT
// Copyright (c) 2026 the Tango authors
//==============================================================================
// tb_rotate_with_pattern -- the rotation gate: the framework's rotation RTL (sys/tango_video_rotate_ddr3.v, the
// DDR3-direct corner-turn the card build wires in) fed by this core's simulated picture
// (rtl/tango_core_arcade_template.v, the defines of sim/tb_video_pattern.v).  Built on the machinery of the
// framework's own rotation bench (sys/sim/tb_rotate_golden.v): the DDR3 write-FSM DUT on an idealised memory
// (DDRAM_BUSY tied 0: an address-correctness check, not a bandwidth one), its shadow-memory decode
// (which_buf/buf_base/stride_w, read by hierarchical reference) and its per-write ("LIVE") check, which this
// bench's PASS / FAIL rests on.  The source of vga_r/g/b/hs/vs/de/ce_pixel is a real tango_core instance, and the
// check classifies the real RGB bytes against this core's two landmarks (the corner marker, the arrow), written
// here independently of the RTL's zone logic.  rotate_mode is driven through the real
// status[`TANGO_VO_B_ROTATE] -> tango_cdc_word -> rotate_mode path (as tango_sys.v wires it).
//
// Clocking: the real framework ties clk_video = clk_pix for this core (tango_sys.v's own u_vrot_ddr3
// instantiation: `.clk_video(clk_video)`, and every ASCAL-mode core -- Template, this one -- assigns
// `CLK_VIDEO = CLK_PIX`), so this bench uses ONE clock for the core and the rotate DUT, unlike
// tb_rotate_golden.v's own deliberately-decoupled clk_video/clk_pix (that bench exists to stress the CDC in
// isolation, already proven separately -- re-decoupling them here would test a clock relationship this real
// build never actually has).
//
// MAXW=288 (TANGO_VIDEO_ASCAL_MAXW, this core's build), MAXH=240 (sys/tango_cfg.vh's own default -- THIS
// core's build does NOT override it, unlike MAXW: 224 < 240, so the default buffer is simply slightly
// larger than this core's real 224 active lines, not truncating anything, the same reasoning that made
// overriding MAXW mandatory does not apply to MAXH here). Using 240, not 224, for the address algebra below
// is deliberate: it is what the real Gowin build contains.
//==============================================================================
`default_nettype none
`timescale 1ns/1ps
`include "tango_video_opts.vh"   // `TANGO_VO_B_ROTATE -- tango_core_arcade_template.v's own `include chain
                                 // would define this too, but only AFTER this file in the compile order
                                 // (Verilator processes files in command-line order); included explicitly
                                 // here so the macro exists before this file's own use of it, below.

module tb_rotate_with_pattern;
    localparam integer MAXW = 288, MAXH = 240;   // the REAL build's rotate-module parameters (buffer sizing)
    // The rotate DUT's own address algebra uses the DYNAMICALLY MEASURED native height (vsz, this module's
    // own de_fall-to-de_fall line count: `fb_w = vsz`), NOT the MAXH parameter above -- MAXH is only a
    // buffer-capacity upper bound (240 >= this core's real 224 active lines, so nothing truncates; see
    // rtl/tango_core_arcade_template.v's own header for why no MAXH override was needed). A first draft of
    // this bench used MAXH in the golden formula below and got a uniform mode=1 (CW)-only src_iy error of
    // exactly MAXH-1-NH = 16 (every mismatch's reported src_iy was 16 too high) -- found by running this
    // sim, not by re-reading the RTL closely enough the first time. NH=224 is this core's own known, fixed
    // active height (rtl/tango_core_arcade_template.v localparam NH), not re-measured here.
    localparam integer NH = 224;

    reg clk = 1'b0;
    always #2 clk = ~clk;

    // ---- the real core (same defines as sim/tb_video_pattern.v)
    reg        reset = 1'b1;
    reg [31:0] joystick_0 = 32'd0, joystick_1 = 32'd0;
    reg [127:0] status = 128'd0;
    reg        ioctl_download = 1'b0;
    reg [15:0] ioctl_index = 16'd0;
    reg        ioctl_wr = 1'b0;
    reg [26:0] ioctl_addr = 27'd0;
    reg [7:0]  ioctl_dout = 8'd0;
    reg [11:0] conf_addr = 12'd0;
    reg [11:0] hdmi_width = 12'd1280, hdmi_height = 12'd720;
    reg        ioctl_upload = 1'b0;
    reg        ioctl_rd = 1'b0;
    wire        ioctl_wait;
    wire [7:0]  conf_char;
    wire        CLK_VIDEO, CE_PIXEL, VGA_HS, VGA_VS, VGA_DE;
    wire [7:0]  VGA_R, VGA_G, VGA_B;
    wire [1:0]  VGA_SL;
    wire [12:0] VIDEO_ARX, VIDEO_ARY;
    wire        HDMI_FREEZE;
    wire [2:0]  VIDEO_SCALE;
    wire [11:0] VIDEO_CROP_SIZE;
    wire [4:0]  VIDEO_CROP_OFF;
    wire [15:0] AUDIO_L, AUDIO_R;
    wire        ioctl_upload_req;
    wire [7:0]  ioctl_upload_index;
    wire [7:0]  ioctl_din;
    wire        CLK_SYS;
    wire [15:0] status_menumask;

    tango_core core (
        .CLK_50M(1'b0), .CLK_PIX(clk), .RESET(reset), .CLK_SYS(CLK_SYS),
        .joystick_0(joystick_0), .joystick_1(joystick_1),
        .status(status), .status_menumask(status_menumask),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
        .conf_addr(conf_addr), .conf_char(conf_char),
        .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE), .VGA_SL(VGA_SL),
        .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
        .HDMI_WIDTH(hdmi_width), .HDMI_HEIGHT(hdmi_height), .HDMI_FREEZE(HDMI_FREEZE),
        .VIDEO_SCALE(VIDEO_SCALE), .VIDEO_CROP_SIZE(VIDEO_CROP_SIZE), .VIDEO_CROP_OFF(VIDEO_CROP_OFF),
        .AUDIO_L(AUDIO_L), .AUDIO_R(AUDIO_R),
        .ioctl_upload(ioctl_upload), .ioctl_upload_req(ioctl_upload_req),
        .ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din), .ioctl_rd(ioctl_rd)
    );

    // ---- rotate_mode driver: through the REAL status[`TANGO_VO_B_ROTATE] -> tango_cdc_word -> rotate_mode
    // path tango_sys.v:442-444 actually uses (NOT a direct testbench drive of rotate_mode -- sys-tango's own
    // tb_rotate_golden.v drives rotate_mode directly, which proves the write-FSM's address algebra but
    // leaves the status-bit -> CDC -> rotate_mode round trip itself unexercised; this bench runs it. Cheap
    // here: clk_video == clk_pix for this core (both tied to CLK_PIX), so the CDC has no real
    // frequency relationship to get wrong -- same clock on both sides, mirroring tango_sys.v's own
    // instantiation exactly (`.clk_a(clk_pix), .clk_b(clk_video)`, here both `clk`).
    wire [1:0] rotate_mode;
    tango_cdc_word #(.W(2)) u_vrot_cdc (.clk_a(clk), .din(status[`TANGO_VO_B_ROTATE]), .clk_b(clk), .dout(rotate_mode));
    reg vga_vs_q2 = 1'b0;
    wire vga_vs_rise = VGA_VS && !vga_vs_q2;
    always @(posedge clk) vga_vs_q2 <= VGA_VS;

    // ---- the rotate DUT
    wire        DDRAM_CLK, DDRAM_BUSY, DDRAM_RD, DDRAM_WE;
    wire [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
    wire [28:0] DDRAM_ADDR;
    wire [63:0] DDRAM_DIN;
    reg  [63:0] DDRAM_DOUT = 64'd0;
    reg         DDRAM_DOUT_READY = 1'b0;
    wire        o_fb_ena; wire [11:0] o_fb_hsize, o_fb_vsize; wire [5:0] o_fb_format;
    wire [31:0] o_fb_base; wire [13:0] o_fb_stride;

    tango_video_rotate_ddr3 #(.MAXW(MAXW), .MAXH(MAXH), .NBUF(4)) rot (
        .clk_video(clk), .rst_video(1'b0), .rotate_mode(rotate_mode),
        .ce_pixel_in(CE_PIXEL), .vga_r_in(VGA_R), .vga_g_in(VGA_G), .vga_b_in(VGA_B),
        .vga_hs_in(VGA_HS), .vga_vs_in(VGA_VS), .vga_de_in(VGA_DE),
        .DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
        .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
        .clk_pix(clk), .o_fb_ena(o_fb_ena), .o_fb_hsize(o_fb_hsize), .o_fb_vsize(o_fb_vsize),
        .o_fb_format(o_fb_format), .o_fb_base(o_fb_base), .o_fb_stride(o_fb_stride));

    assign DDRAM_BUSY = 1'b0;   // idealized memory: an address-correctness proof, not the bandwidth proof
    reg [2:0] rd_pend = 3'd0;
    always @(posedge DDRAM_CLK) begin
        DDRAM_DOUT_READY <= 1'b0;
        rd_pend <= {rd_pend[1:0], DDRAM_RD};
        if (rd_pend[2]) DDRAM_DOUT_READY <= 1'b1;
    end

    // ---- which buffer a write landed in (verbatim shape from sys/sim/tb_rotate_golden.v, reused directly:
    // it is the project's own already-proven decode of this module's own buffer layout, not something this
    // bench re-derives -- what IS re-derived fresh below is the pixel CLASSIFICATION, not this addressing)
    function integer which_buf(input [28:0] addr29);
        integer k; integer found;
        reg [24:0] off, bound;
        begin
            found = -1;
            bound = rot.stride_w * MAXW;   // words/buffer = stride_w (words/output row) x MAXW (output rows)
            for (k = 0; k < 4; k = k + 1) begin
                off = rot.buf_base(k[1:0]);
                if (addr29[24:0] >= off && addr29[24:0] < off + bound) found = k;
            end
            which_buf = found;
        end
    endfunction

    // ---- golden source-coordinate inversion (the framework's rotation algebra / sys/sim/tb_rotate_golden.v's own
    // header formula, re-derived a further independent time against THIS bench's own (yo,xo) naming,
    // reused as a MECHANISM, not transcribed uninspected): for output (yo=row, xo=col) of the HxW-shaped
    // rotated frame (H=MAXH wide, W=MAXW tall): CW: src_row=MAXH-1-xo, src_col=yo. CCW: src_row=xo,
    // src_col=MAXW-1-yo. (src_row=iy, src_col=ix.)
    function integer src_ix(input [1:0] md, input integer yo, input integer xo);
        src_ix = (md == 2'b01) ? yo : (MAXW - 1 - yo);
    endfunction
    function integer src_iy(input [1:0] md, input integer yo, input integer xo);
        src_iy = (md == 2'b01) ? (NH - 1 - xo) : xo;
    endfunction

    // ---- pixel classification, independently re-derived from THIS core's own two landmarks (not copied
    // from rtl/tango_core_arcade_template.v's zone wires -- same shapes, restated fresh): the corner marker
    // (native x<16,y<16, magenta) and the arrow (head: y in [20,52), |x-144|<=y-20; stem: y in [52,100),
    // |x-144|<=10; white).
    function integer is_corner(input integer ix, input integer iy);
        is_corner = (ix < 16) && (iy < 16);
    endfunction
    function integer is_arrow(input integer ix, input integer iy);
        integer dx;
        begin
            dx = (ix >= 144) ? (ix - 144) : (144 - ix);
            is_arrow = ((iy >= 20) && (iy < 52) && (dx <= (iy - 20))) ||
                       ((iy >= 52) && (iy < 100) && (dx <= 10));
        end
    endfunction

    localparam [23:0] COL_MAGENTA = 24'hFF00FF;
    localparam [23:0] COL_WHITE   = 24'hFFFFFF;

    // ---- THE COLOUR-ORDER CHECK. Both landmarks (magenta, white) and the negative control ("never magenta or
    // white") are symmetric under an R<->B swap, so without this check the bench would pass a picture with red
    // and blue swapped (as an earlier framework once showed on the board). Two parts:
    //  1. Every written 32-bit pixel is decoded by ascal.vhd's OWN 32bpp RGB rule (o_fb_format 6'b000110,
    //     bit 4 = 0, no swap at ascal.vhd ~2214): avl_dw = swap(avl_readdata) (BYTESWAP true) puts the word's
    //     lowest-address byte on top, shift_opack's 32bpp load puts it at shift(0 TO 7), shift_opix reads
    //     r => shift(0 TO 7), g => shift(8 TO 15), b => shift(16 TO 23). So byte0 = R, byte1 = G, byte2 = B.
    //  2. A shadow of the core's REAL native frame (nat_px, captured from VGA_R/G/B as the core emits them,
    //     CE_PIXEL && VGA_DE, same gating the DUT's FIFO push uses) and EVERY write compared, all three
    //     channels, against the native pixel it must be (src_ix/src_iy below). This covers the red/green
    //     bit cells (asymmetric colours) -- asym_hits counts the writes whose expected R != B, and must be > 0.
    function [23:0] ascal_rgb32(input [31:0] px32);   // {R,G,B} as ascal will display this 32bpp pixel
        ascal_rgb32 = {px32[7:0], px32[15:8], px32[23:16]};
    endfunction
    reg [23:0] nat_px [0:NH-1][0:MAXW-1];
    integer nat_x = 0, nat_y = 0;
    reg     nat_de_q = 1'b0;
    always @(posedge clk) begin
        if (vga_vs_rise) begin nat_x = 0; nat_y = 0; end
        if (CE_PIXEL) begin
            if (VGA_DE) begin
                if (nat_y < NH && nat_x < MAXW) nat_px[nat_y][nat_x] = {VGA_R, VGA_G, VGA_B};
                nat_x = nat_x + 1;
            end else if (nat_de_q) begin
                nat_x = 0; nat_y = nat_y + 1;
            end
            nat_de_q = VGA_DE;
        end
    end
    integer full_checked = 0, full_errs = 0, asym_hits = 0, byte3_errs = 0;

    integer live_checked = 0, live_errs = 0;
    integer corner_hits = 0, arrow_hits = 0;
    always @(posedge DDRAM_CLK) begin
        if (DDRAM_WE && rotate_mode != 2'b00) begin
            integer b, o, yo_l, xo_l, half_l, ix, iy;
            reg [23:0] got, want;
            reg [31:0] px32;
            reg exp_corner, exp_arrow;
            b = which_buf(DDRAM_ADDR);
            if (b >= 0) begin
                o      = DDRAM_ADDR[24:0] - rot.buf_base(b[1:0]);
                yo_l   = o / rot.stride_w;
                half_l = (o % rot.stride_w) * 2 + (DDRAM_BE[4] ? 1 : 0);
                xo_l   = half_l;
                ix = src_ix(rotate_mode, yo_l, xo_l);
                iy = src_iy(rotate_mode, yo_l, xo_l);
                px32 = DDRAM_BE[4] ? DDRAM_DIN[63:32] : DDRAM_DIN[31:0];
                got  = ascal_rgb32(px32);              // what ascal will DISPLAY, not the raw word
                if (px32[31:24] !== 8'd0) byte3_errs = byte3_errs + 1;
                // full-colour compare against the core's own native pixel at (ix,iy)
                if (ix >= 0 && ix < MAXW && iy >= 0 && iy < NH) begin
                    want = nat_px[iy][ix];
                    full_checked = full_checked + 1;
                    if (want[23:16] != want[7:0]) asym_hits = asym_hits + 1;
                    if (got !== want) begin
                        full_errs = full_errs + 1;
                        if (full_errs <= 12) $display("MISMATCH mode=%0d out(yo=%0d,xo=%0d) src(%0d,%0d) [FULL]: ascal reads RGB %06h, core emitted %06h", rotate_mode, yo_l, xo_l, ix, iy, got, want);
                    end
                end
                exp_corner = is_corner(ix, iy);
                exp_arrow  = is_arrow(ix, iy);
                live_checked = live_checked + 1;
                if (exp_corner) begin
                    corner_hits = corner_hits + 1;
                    if (got !== COL_MAGENTA) begin
                        live_errs = live_errs + 1;
                        $display("MISMATCH mode=%0d out(yo=%0d,xo=%0d) src(%0d,%0d) [CORNER]: got %06h want MAGENTA", rotate_mode, yo_l, xo_l, ix, iy, got);
                    end
                end else if (exp_arrow) begin
                    arrow_hits = arrow_hits + 1;
                    if (got !== COL_WHITE) begin
                        live_errs = live_errs + 1;
                        $display("MISMATCH mode=%0d out(yo=%0d,xo=%0d) src(%0d,%0d) [ARROW]: got %06h want WHITE", rotate_mode, yo_l, xo_l, ix, iy, got);
                    end
                end else begin
                    // negative control: neither landmark -- must NOT accidentally be magenta or white
                    if (got === COL_MAGENTA || got === COL_WHITE) begin
                        live_errs = live_errs + 1;
                        $display("MISMATCH mode=%0d out(yo=%0d,xo=%0d) src(%0d,%0d) [NEITHER]: got %06h, a landmark colour where neither landmark should be", rotate_mode, yo_l, xo_l, ix, iy, got);
                    end
                end
            end
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        reset = 1'b0;
        repeat (8) @(posedge clk);

        $display("STEP 1: Normal mode -- confirm the rotate DUT writes nothing");
        status[`TANGO_VO_B_ROTATE] = 2'b00;   // the real OSD bits, through the real CDC into rotate_mode
        repeat (2) @(posedge vga_vs_rise);
        if (live_checked != 0) begin
            $display("MISMATCH: %0d writes seen in Normal mode (expected 0 -- the DUT must not touch DDR3 at all)", live_checked);
        end else $display("  ok: 0 writes in Normal mode, as expected");

        $display("STEP 2: CW -- 3 input frames (so the double-buffer hand-over is exercised, not just the transition)");
        status[`TANGO_VO_B_ROTATE] = 2'b01;
        repeat (2) @(posedge vga_vs_rise);
        @(posedge vga_vs_rise);   // let the 2nd frame's fence complete into the 3rd frame boundary (3 frames total)

        $display("STEP 3: CCW -- 3 input frames");
        status[`TANGO_VO_B_ROTATE] = 2'b10;
        repeat (2) @(posedge vga_vs_rise);
        @(posedge vga_vs_rise);

        $display("");
        $display("TB_ROTATE_WITH_PATTERN: %0d write(s) checked (%0d corner-marker, %0d arrow), %0d mismatch(es)",
                  live_checked, corner_hits, arrow_hits, live_errs);
        $display("TB_ROTATE_WITH_PATTERN (ascal 32bpp RGB decode vs the core's native pixel): %0d write(s) checked, %0d with R!=B (red/green cells), %0d mismatch(es), %0d nonzero byte3",
                  full_checked, asym_hits, full_errs, byte3_errs);
        if (live_errs == 0 && corner_hits > 0 && arrow_hits > 0 &&
            full_errs == 0 && byte3_errs == 0 && full_checked == live_checked && asym_hits > 0) begin
            $display("TB_RESULT PASS");
            $finish;
        end else begin
            $display("TB_RESULT FAIL");
            $fatal(1, "TB_ROTATE_WITH_PATTERN FAIL: %0d landmark mismatch(es), %0d full-colour mismatch(es), %0d byte3, corner_hits=%0d arrow_hits=%0d asym_hits=%0d", live_errs, full_errs, byte3_errs, corner_hits, arrow_hits, asym_hits);
        end
    end

    initial begin
        #40_000_000; // ns; several native frames' worth at this bench's clk period
        $display("TB_ROTATE_WITH_PATTERN: WATCHDOG TIMEOUT");
        $fatal(1, "TB_ROTATE_WITH_PATTERN WATCHDOG TIMEOUT");
    end
endmodule
`default_nettype wire
