// SPDX-License-Identifier: MIT
// Copyright (c) 2026 the Tango authors
//==============================================================================
// tb_pad_row.v -- the game controls gate: every joystick_0 / joystick_1 bit the CONF_STR's J1 entry defines
// lights EXACTLY its own cell of the test picture's pad rows, and nothing else in those rows.
// Same bench shape as sim/tb_video_pattern.v (Verilator --binary, the real rtl/tango_core_arcade_template.v
// with the same defines, joystick_0/1 driven directly on the core's ports -- the framework side, USB ->
// tango_ds4_joy -> tango_io's CDC into CLK_SYS, is sys-tango's own, already-proven job).
//
// The expected picture is stated independently here, NOT derived from the RTL's pad_cells function:
//   joystick bit (MiSTer Main_MiSTer input.h 37-41 + joymapping.cpp "idx = i+DPAD_COUNT"):
//     0 Right, 1 Left, 2 Down, 3 Up, 4 Button 1, 5 Button 2, 6 Start, 7 Coin
//   cell order, left to right (cell 0 leftmost):
//     Up, Down, Left, Right, Button 1, Button 2, Start, Coin
//   => CELL_OF_BIT below: bit 0 -> cell 3, bit 1 -> cell 2, bit 2 -> cell 1, bit 3 -> cell 0, bits 4..7 ->
//      cells 4..7.
//   Geometry (rtl header): cell c lit at native x 128+16c .. 128+16c+13, black at +14/+15; P1 (joystick_0)
//   rows y 204..210, P2 (joystick_1) rows y 213..219, rows 211/212 black between them.
// Per stimulus, ONE native frame is read in raster order: both rows' 8 cell centres, every cell's black
// gap, the row gap, both rows' outer edges (x 127 / 256), and row 220 (must stay black).
// Stimuli: idle; each bit 0..7 alone on P1 then on P2 (the other pad idle -- also proves no P1/P2
// crosstalk); bits 8..31 only (no J1 meaning: all cells red); all 8 bits on both pads.
// run_tb_pad_row.sh also builds a MUTANT copy of the RTL (Up/Down swapped in pad_cells) and requires this
// same bench to FAIL against it -- proof the bench can see a swapped bit, not just that it passes.
//==============================================================================
`timescale 1ns/1ps

module tb_pad_row;
    reg clk = 1'b0;
    always #(2.0) clk = ~clk;

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
    wire [1:0]  AUDIO_MIX;
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
        .AUDIO_L(AUDIO_L), .AUDIO_R(AUDIO_R), .AUDIO_MIX(AUDIO_MIX),
        .ioctl_upload(ioctl_upload), .ioctl_upload_req(ioctl_upload_req),
        .ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din), .ioctl_rd(ioctl_rd)
    );

    localparam [23:0] COL_BLACK = 24'h000000;
    localparam [23:0] COL_GREEN = 24'h00FF00;
    localparam [23:0] COL_RED   = 24'hFF0000;

    integer errors = 0, checks = 0, green_seen = 0;

    // bit -> cell, stated from the cell order and MiSTer's bit order (header), not from the RTL
    function integer cell_of_bit(input integer b);
        case (b)
            0: cell_of_bit = 3;   // Right
            1: cell_of_bit = 2;   // Left
            2: cell_of_bit = 1;   // Down
            3: cell_of_bit = 0;   // Up
            4: cell_of_bit = 4;   // Button 1
            5: cell_of_bit = 5;   // Button 2
            6: cell_of_bit = 6;   // Start
            7: cell_of_bit = 7;   // Coin
            default: cell_of_bit = -1;
        endcase
    endfunction
    // the 8 cells a joystick word should light (bit c = cell c)
    function [7:0] cells_of(input [31:0] j);
        integer b;
        begin
            cells_of = 8'd0;
            for (b = 0; b < 8; b = b + 1) if (j[b]) cells_of[cell_of_bit(b)] = 1'b1;
        end
    endfunction

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
            if (got === COL_GREEN) green_seen = green_seen + 1;
            if (got !== want) begin
                errors = errors + 1;
                $display("MISMATCH %0s at (%0d,%0d): got %06h want %06h  [j0=%08h j1=%08h]",
                         label, x, y, got, want, joystick_0, joystick_1);
            end
        end
    endtask

    // one native frame: both rows, raster order (y 207 = P1 mid-row, y 216 = P2 mid-row)
    task check_frame(input [31:0] j0, input [31:0] j1);
        reg [7:0] e0, e1;
        integer c;
        begin
            joystick_0 = j0; joystick_1 = j1;
            e0 = cells_of(j0); e1 = cells_of(j1);
            while (!(dut.nat_cy == 9'd0)) @(posedge clk);          // a fresh frame after the change
            check_pixel(128 + 6, 204, e0[0] ? COL_GREEN : COL_RED, "P1 top line, cell 0");
            check_pixel(127, 207, COL_BLACK, "P1 left of row");
            for (c = 0; c < 8; c = c + 1) begin
                check_pixel(128 + 16*c + 6,  207, e0[c] ? COL_GREEN : COL_RED, "P1 cell");
                check_pixel(128 + 16*c + 14, 207, COL_BLACK, "P1 cell gap");
            end
            check_pixel(256, 207, COL_BLACK, "P1 right of row");
            check_pixel(128 + 6, 210, e0[0] ? COL_GREEN : COL_RED, "P1 bottom line, cell 0");
            check_pixel(128 + 6, 211, COL_BLACK, "row gap 211");
            check_pixel(128 + 6, 212, COL_BLACK, "row gap 212");
            check_pixel(128 + 6, 213, e1[0] ? COL_GREEN : COL_RED, "P2 top line, cell 0");
            check_pixel(127, 216, COL_BLACK, "P2 left of row");
            for (c = 0; c < 8; c = c + 1) begin
                check_pixel(128 + 16*c + 6,  216, e1[c] ? COL_GREEN : COL_RED, "P2 cell");
                check_pixel(128 + 16*c + 14, 216, COL_BLACK, "P2 cell gap");
            end
            check_pixel(256, 216, COL_BLACK, "P2 right of row");
            check_pixel(128 + 16*7 + 6, 219, e1[7] ? COL_GREEN : COL_RED, "P2 bottom line, cell 7");
            check_pixel(128 + 16*7 + 6, 220, COL_BLACK, "row 220 stays black");
        end
    endtask

    initial begin : run
        integer b;
        repeat (8) @(posedge clk);
        reset = 1'b0;
        repeat (8) @(posedge clk);

        $display("STEP 1: idle pads -> every cell red");
        check_frame(32'd0, 32'd0);
        $display("STEP 2: each J1 bit alone on P1 (joystick_0), P2 idle");
        for (b = 0; b < 8; b = b + 1) check_frame(32'd1 << b, 32'd0);
        $display("STEP 3: each J1 bit alone on P2 (joystick_1), P1 idle");
        for (b = 0; b < 8; b = b + 1) check_frame(32'd0, 32'd1 << b);
        $display("STEP 4: bits 8..31 only (no J1 meaning, e.g. the fallback map's L/R/Select/Start) -> all red");
        check_frame(32'hFFFFFF00, 32'hFFFFFF00);
        $display("STEP 5: all 8 J1 bits on both pads -> all green");
        check_frame(32'h000000FF, 32'h000000FF);

        $display("");
        $display("TB_PAD_ROW: %0d check(s), %0d mismatch(es), %0d green pixel(s) seen", checks, errors, green_seen);
        // 16 single-bit frames + 2 all-green frames x 2 rows x 8 cells = 16 + 32 green centre reads + edge lines
        if (errors == 0 && green_seen > 0) begin
            $display("TB_RESULT PASS");
            $finish;
        end else begin
            $display("TB_RESULT FAIL");
            $fatal(1, "TB_PAD_ROW FAIL: %0d mismatch(es)", errors);
        end
    end

    initial begin
        #1_000_000_000;
        $display("TB_PAD_ROW: WATCHDOG TIMEOUT");
        $display("TB_RESULT FAIL");
        $fatal(1, "TB_PAD_ROW WATCHDOG TIMEOUT");
    end
endmodule
