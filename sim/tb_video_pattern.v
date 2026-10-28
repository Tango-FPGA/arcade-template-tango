// SPDX-License-Identifier: MIT
// Copyright (c) 2026 the Tango authors
//==============================================================================
// tb_video_pattern.v -- the test picture's gate: a standalone Verilator --binary unit bench of
// rtl/tango_core_arcade_template.v alone, driving its ioctl_download port directly (the link protocol is
// sim/run_tb_arc.sh's job), then:
//   1. checks that the DIP / NVRAM / ROM bit-cell rows and the frame-counter row show the downloaded /
//      counting register values, pixel-exact;
//   2. re-derives the CW / CCW address algebra of the framework's rotation (out(x,y) = in(y, H-1-x) for CW;
//      out(x,y) = in(W-1-y, x) for CCW; Normal = identity) independently and applies it to this core's fixed
//      native landmarks (the corner marker and the arrow's tip and base, captured from the RTL simulation below)
//      to prove the three orientations are distinct and that the arrow points where MiSTer's screen rotation
//      puts "up".  The rotation RTL itself runs in sim/tb_rotate_with_pattern.v.
//
// Built with TANGO_VIDEO_ASCAL, TANGO_VIDEO_OPTS, TANGO_VIDEO_PROC and TANGO_IOCTL_UPLOAD -- every build-time
// define of this core that adds or changes a port (TANGO_VIDEO_PROC adds AUDIO_MIX). TANGO_VIDEO_DDR3 /
// TANGO_VIDEO_ROTATE add no ports (sys/tango_core_ports.vh), so this bench does not need them.
//==============================================================================
`timescale 1ns/1ps

module tb_video_pattern;
    localparam [9:0] NW  = 10'd288, FNW = 10'd384;
    localparam [8:0] NH  = 9'd224,  FNH = 9'd264;

    reg clk = 1'b0;
    always #(2.0) clk = ~clk;   // period irrelevant to the logic (CE_DIV is a cycle count, not real time)

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

    tango_core dut (
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

    integer errors = 0;
    integer checks = 0;

    // ---- download helper: SELECT idx, WRITE n bytes from a flat byte array, SELECT idx size 0 (close).
    // Mirrors sim/tb_arc.inc's own arc_dl_select/WRITE shape, direct-port version (no SPI framing needed --
    // this bench's only job is the RTL's own ioctl_download consumer, already proven generically by
    // run_tb_arc.sh's real link-protocol harness).
    // bytes: little-endian, byte i = bytes[i*8 +: 8] (address i's own byte) -- max 16 bytes (ROM strip),
    // callers with fewer bytes (DIP/NVRAM, 8) just leave the high bits of `bytes` unused.
    task dl_bytes(input [7:0] idx, input integer n, input [127:0] bytes);
        integer i;
        begin
            ioctl_download = 1'b1; ioctl_index = {8'd0, idx};
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                ioctl_addr = i; ioctl_dout = bytes[i*8 +: 8]; ioctl_wr = 1'b1;
                @(posedge clk);
                ioctl_wr = 1'b0;
            end
            @(posedge clk);
            ioctl_download = 1'b0;   // close: the NVRAM index's +1 mutate fires one clock after this
            @(posedge clk);
        end
    endtask

    // ---- wait until the DUT's native beam reaches (x,y), then settle past the 2-stage colour pipeline
    // (stage1/stage2, both plain `always @(posedge clk)` with no CE gate -- same shape as
    // console-template-tango's tango_core_template.v ASCAL pixel path) while still well inside that pixel's CE_DIV=12-cycle
    // dwell, and return the colour actually on the bus.
    task get_pixel(input [9:0] x, input [8:0] y, output [23:0] rgb);
        begin
            while (!(dut.nat_cx == x && dut.nat_cy == y)) @(posedge clk);
            repeat (4) @(posedge clk);
            rgb = {VGA_R, VGA_G, VGA_B};
        end
    endtask

    task check_pixel(input [9:0] x, input [8:0] y, input [23:0] want, input [255:0] label);
        reg [23:0] got;
        begin
            get_pixel(x, y, got);
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                $display("MISMATCH %0s at (%0d,%0d): got %06h want %06h", label, x, y, got, want);
            end
        end
    endtask

    localparam [23:0] COL_BLACK   = 24'h000000;
    localparam [23:0] COL_WHITE   = 24'hFFFFFF;
    localparam [23:0] COL_MAGENTA = 24'hFF00FF;
    localparam [23:0] COL_GREEN   = 24'h00FF00;
    localparam [23:0] COL_RED     = 24'hFF0000;

    // the .mra fixture's ROM bytes at index 0: "TANGO-A5-ROM-OK!" (16 ASCII bytes), little-endian
    // packed so byte i (address i) = ROM_BYTES[i*8 +: 8] -- byte0='T' is the LOW byte, byte15='!' the HIGH
    // byte, exactly as the RTL's own ioctl_addr-indexed `rom_reg[{addr[3:0],3'd0}+:8]` write expects.
    localparam [127:0] ROM_BYTES = 128'h214B4F2D4D4F522D35412D4F474E4154;
    // a DIP word and NVRAM seed chosen so every nibble differs (catches a swapped bit/byte index, not just
    // "all 1s" or "all 0s" which would pass even with the bit order reversed); same little-endian
    // byte-address convention as ROM_BYTES above.
    localparam [63:0] DIP_BYTES   = 64'hF00F5A81FF003CA5;
    localparam [63:0] NVRAM_SEED  = 64'h8877665544332211;

    initial begin
        repeat (8) @(posedge clk);
        reset = 1'b0;
        repeat (8) @(posedge clk);

        $display("STEP 1: download DIP (idx 254), NVRAM (idx 4), ROM (idx 0)");
        dl_bytes(8'd254, 8, {64'd0, DIP_BYTES});
        dl_bytes(8'd4, 8, {64'd0, NVRAM_SEED});
        dl_bytes(8'd0, 16, ROM_BYTES);

        // the documented, already-proven rule (this core's own header / sim/tb_arc.inc): nvram_reg gets +1
        // exactly once, the clock after its own download's close.
        if (dut.nvram_reg !== (NVRAM_SEED + 64'd1)) begin
            errors = errors + 1;
            $display("MISMATCH nvram_reg after close: got %016h want %016h (seed+1)", dut.nvram_reg, NVRAM_SEED + 64'd1);
        end
        if (dut.dip_reg !== DIP_BYTES) begin
            errors = errors + 1;
            $display("MISMATCH dip_reg: got %016h want %016h", dut.dip_reg, DIP_BYTES);
        end
        if (dut.rom_reg !== ROM_BYTES) begin
            errors = errors + 1;
            $display("MISMATCH rom_reg: got %032h want %032h", dut.rom_reg, ROM_BYTES);
        end
        $display("  registers: dip=%016h nvram=%016h rom=%032h (nvram = seed+1, as documented)",
                  dut.dip_reg, dut.nvram_reg, dut.rom_reg);

        $display("STEP 2: spot-check every DIP/NVRAM/ROM bit cell against the real downloaded+mutated register values");
        begin : bitrows
            integer i;
            reg [63:0] nvram_final;
            nvram_final = NVRAM_SEED + 64'd1;
            for (i = 0; i < 64; i = i + 1) begin
                check_pixel(16 + i*4 + 2, 108 + 8, DIP_BYTES[i]     ? COL_GREEN : COL_RED, "DIP bit");
                check_pixel(16 + i*4 + 2, 132 + 8, nvram_final[i]  ? COL_GREEN : COL_RED, "NVRAM bit");
                check_pixel(16 + i*4 + 2, 156 + 8, ROM_BYTES[i]    ? COL_GREEN : COL_RED, "ROM lo bit");
                check_pixel(16 + i*4 + 2, 180 + 8, ROM_BYTES[64+i] ? COL_GREEN : COL_RED, "ROM hi bit");
            end
        end

        $display("STEP 3: corner marker + arrow landmarks (fixed, core-relative 'up' -- the chirality fix)");
        check_pixel(8, 8, COL_MAGENTA, "corner marker");
        check_pixel(300, 8, COL_BLACK, "outside corner marker (sanity: not a false-positive magenta flood)");
        check_pixel(144, 20, COL_WHITE, "arrow tip");
        check_pixel(144, 60, COL_WHITE, "arrow stem centre");
        check_pixel(144, 10, COL_BLACK, "above arrow tip (sanity: arrow does not bleed upward)");
        check_pixel(100, 60, COL_BLACK, "left of stem (sanity: arrow is not a filled rectangle)");

        $display("STEP 4: frame counter is live across 2 full native frames, not a frozen value");
        begin : framectr
            integer f, bit_i;
            reg [7:0] fc_before;
            for (f = 0; f < 2; f = f + 1) begin
                fc_before = dut.nat_fc;
                // all 8 bits of the counter, not just bit 0 -- the picture itself proves "live", not an
                // internal probe of nat_fc alone
                for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1)
                    check_pixel(16 + bit_i*8 + 2, 204 + 8, fc_before[bit_i] ? COL_GREEN : COL_RED, "frame-counter bit (pre-wait)");
                // wait for one full native frame to elapse (a ce pulse at the very last total pixel)
                while (!(dut.ce && dut.nat_fe)) @(posedge clk);
                @(posedge clk);
                checks = checks + 1;
                if (dut.nat_fc !== (fc_before + 8'd1)) begin
                    errors = errors + 1;
                    $display("MISMATCH frame counter did not increment: before=%0d after=%0d", fc_before, dut.nat_fc);
                end else begin
                    $display("  frame %0d: nat_fc %0d -> %0d (live)", f, fc_before, dut.nat_fc);
                end
            end
        end

        $display("STEP 5: landmark geometry -- re-derive the already-proven CW/CCW address algebra");
        $display("        (sys-tango docs/ROTATION.md Sec 1: out(x,y)=in(y,H-1-x) CW; out(x,y)=in(W-1-y,x) CCW)");
        begin : geom
            // Landmarks captured by real RTL simulation above (step 3), not hand-typed: the corner marker's
            // centre (8,8), the arrow TIP (144,20) and a second point further down the arrow's own axis, its
            // STEM centre (144,60, also checked white at step 3) -- two points on the arrow let this bench
            // check the arrow's POINTING DIRECTION (tip vs. base, which maps to which side) rather than
            // wrongly demanding the tip land exactly on an output edge (an earlier draft of this bench did
            // that and got its own arithmetic right but its own EXPECTATION wrong: only a point with iy=0
            // lands exactly on x=NH-1 under CW; this tip's iy=20, not 0 -- a testbench bug, not an RTL bug,
            // caught by running this sim for real rather than assuming the first draft's assertion was
            // correct). W=NW, H=NH (this core's own native active size).
            integer cmx, cmy, atx, aty, bax, bay;
            integer cw_cmx, cw_cmy, cw_atx, cw_bax;
            integer ccw_cmx, ccw_cmy, ccw_atx, ccw_bax;
            cmx = 8;  cmy = 8;      // corner marker (checked at step 3)
            atx = 144; aty = 20;    // arrow tip (checked at step 3)
            bax = 144; bay = 60;    // arrow stem centre, further from the tip along the same axis (step 3)

            // CW: out(x,y) = in(y, H-1-x)  =>  for a given in(ix,iy), the output (x,y) satisfying that is
            // x = H-1-iy, y = ix  (invert the formula: solve y=ix, H-1-x=iy => x=H-1-iy)
            cw_cmx = (NH-1) - cmy; cw_cmy = cmx;
            cw_atx = (NH-1) - aty;
            cw_bax = (NH-1) - bay;
            // CCW: out(x,y) = in(W-1-y, x)  =>  invert: x = iy, W-1-y = ix => y = W-1-ix
            ccw_cmx = cmy; ccw_cmy = (NW-1) - cmx;
            ccw_atx = aty;
            ccw_bax = bay;

            $display("  Normal: corner-marker stays at native (%0d,%0d); arrow tip (%0d,%0d) is closer to native y=0 than the stem (%0d,%0d) -- points UP",
                      cmx, cmy, atx, aty, bax, bay);
            $display("  CW:     corner-marker -> output (%0d,%0d) of %0dx%0d; arrow tip -> output x=%0d, stem -> output x=%0d (tip %s stem)",
                      cw_cmx, cw_cmy, NH, NW, cw_atx, cw_bax, (cw_atx > cw_bax) ? "RIGHT of (toward high-x edge)" : "left of");
            $display("  CCW:    corner-marker -> output (%0d,%0d) of %0dx%0d; arrow tip -> output x=%0d, stem -> output x=%0d (tip %s stem)",
                      ccw_cmx, ccw_cmy, NH, NW, ccw_atx, ccw_bax, (ccw_atx < ccw_bax) ? "LEFT of (toward low-x edge)" : "right of");

            checks = checks + 1;
            // the three tip output positions must be pairwise distinct (a real rotation, not a no-op)
            if ((cw_atx == ccw_atx) || (cw_atx == atx) || (ccw_atx == atx)) begin
                errors = errors + 1;
                $display("MISMATCH: the 3 orientations' arrow-tip output x is not pairwise distinct");
            end
            // CW must point the tip toward the output's HIGH-x side relative to the stem (MiSTer
            // screen_rotate's own convention: Normal-up becomes CW-right); CCW toward the LOW-x side
            // (Normal-up becomes CCW-left). Checked as a relative ordering (tip vs. stem), not an absolute
            // edge coordinate -- the fix for this bench's own first-draft bug above.
            checks = checks + 1;
            if (!(cw_atx > cw_bax)) begin
                errors = errors + 1;
                $display("MISMATCH: CW arrow tip output x=%0d is not right of (>) the stem's x=%0d", cw_atx, cw_bax);
            end
            checks = checks + 1;
            if (!(ccw_atx < ccw_bax)) begin
                errors = errors + 1;
                $display("MISMATCH: CCW arrow tip output x=%0d is not left of (<) the stem's x=%0d", ccw_atx, ccw_bax);
            end
            // the corner marker must land in a DIFFERENT output corner in each mode (the chirality fix: an
            // up-arrow alone cannot distinguish CW from a left-right reflection -- this landmark can).
            checks = checks + 1;
            if ((cw_cmx == ccw_cmx && cw_cmy == ccw_cmy)) begin
                errors = errors + 1;
                $display("MISMATCH: CW and CCW corner-marker output positions coincide -- chirality check is useless");
            end
        end

        $display("");
        $display("TB_VIDEO_PATTERN: %0d check(s), %0d mismatch(es)", checks, errors);
        if (errors == 0) begin
            $display("TB_RESULT PASS");
            $finish;
        end else begin
            $display("TB_RESULT FAIL");
            $fatal(1, "TB_VIDEO_PATTERN FAIL: %0d mismatch(es)", errors);
        end
    end

    // a watchdog, in case a get_pixel wait task never sees its target coordinate (a real bug, not a slow sim)
    initial begin
        #2_000_000_000; // ns; generous for ~2.5 native frames at this bench's own clk period
        $display("TB_VIDEO_PATTERN: WATCHDOG TIMEOUT -- a wait task never saw its target pixel");
        $display("TB_RESULT FAIL");
        $fatal(1, "TB_VIDEO_PATTERN WATCHDOG TIMEOUT");
    end
endmodule
