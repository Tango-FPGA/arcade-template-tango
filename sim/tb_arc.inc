// SPDX-License-Identifier: MIT
// Copyright (c) 2026 the Tango authors
// tb_arc.inc -- the core-glue gate for sim/tb_menu.cpp (mode=arc), on rtl/tango_core_arcade_template.v
// (TANGO_IOCTL_UPLOAD): a DIP-index download reaches the core and its NVRAM value survives a simulated reboot
// (download in, upload out, download again after the reboot), against a core that drives the upload direction.
//
// Built like tb_ul.inc (mode=ul): the same minimal cold-boot handshake at step 0 (a plain SYS STATUS + IRQ_CTRL,
// results discarded), the same SDC IMAGE protocol (cmd 3,8; sub 1 SELECT/2 WRITE/3 READ/4 UL_SELECT/5 UL_STATUS),
// its ul_select()/ul_status()/ul_read() helpers (included just above this file); this file adds the plain-download
// helpers (dl_select/dl_write).
//
// What this script actually exercises (every expected value computed from the fixed rule stated in
// rtl/tango_core_arcade_template.v's own header, never read back from the simulation and treated as truth):
//   0   cold boot: SYS STATUS, IRQ_CTRL (discarded)
//   1-4 DIP: SELECT idx 254 size 8, WRITE the 8 bytes of ARC_DIP_VAL (little-endian), SELECT idx 254 size 0
//       (close); a settle transfer later, core_dip (hierarchical probe, tb_menu.v) must equal ARC_DIP_VAL
//   5-8 NVRAM: SELECT idx 4 size 8, WRITE ARC_NVRAM_SEED's 8 bytes, SELECT idx 4 size 0 (close); a settle
//       transfer later, core_nvram must equal ARC_NVRAM_SEED + 1 (the core's own documented +1-on-close rule)
//   9-11 UL_SELECT idx 4 size 8, poll UL_STATUS until ready, READ 8 bytes -- must equal ARC_NVRAM_SEED + 1,
//       byte for byte; captured as saved_bytes (what a real firmware save would have written to a .nvm file)
//   12  UL_SELECT idx 4 size 0: close the upload session. REQUIRED -- tango_io.v's download FIFO drain is
//       gated `!ioctl_upload` ("a download never starts while an upload is open"), and ioctl_upload has no
//       reset of its own; skipping this close silently blocks every later download in this script forever
//       (see this case's comment below)
//   13-15 simulate a reboot: pulse the top-level rst_pix (tb_menu.v's own input, wired straight to this
//       core's RESET port by sys/tango_sys.v's ".RESET(rst_pix)") high for >=200 ns (tens of clk_pix cycles:
//       far more than a synchronous-reset flop needs to see one posedge with RESET asserted), then low again
//   16  a settle SYS STATUS after the reset releases (the same recovery shape the normal boot script already
//       uses after a bl616_jtagsel link reset: a plain STATUS read before resuming); its callback checks
//       core_nvram == 0 and core_dip == 0 -- NOT the saved value: proof the reset actually cleared state,
//       not that this core happens to retain registers across a "reboot" that never really reset anything
//   17-20 re-download: SELECT idx 4 size 8, WRITE saved_bytes (the exact bytes the upload captured), SELECT
//       idx 4 size 0 (close); a settle transfer later, core_nvram must equal saved_bytes + 1 = ARC_NVRAM_SEED
//       + 2 (one more +1 from this close, the same fixed rule as every earlier close) -- the value that
//       survived step 13's reset is the one this redownload restored, not whatever was left sitting in the
//       register (which step 16 already proved was zero)
//   21  SYS READ_CFG -> the exact bytes must equal the RTL's own CONF_STR (BUILD_DATE=sim), the actual
//       check this gate's own run_tb_arc.sh header promises but, in an earlier draft, never ran
//   22  step = 25, past tb_menu.cpp's own ARC_DONE threshold, as tb_ul.inc's own step 22 does for UL_DONE
#include <cstdint>
static const uint8_t ARC_DIP_IDX = 254, ARC_NVRAM_IDX = 4;
static const uint64_t ARC_DIP_VAL    = 0xA5A5C3C3F00DFEEDULL;
static const uint64_t ARC_NVRAM_SEED = 0x1122334455667788ULL;
static std::vector<uint8_t> arc_le64(uint64_t v) {
    std::vector<uint8_t> b(8);
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (8 * i));
    return b;
}
static uint64_t arc_rx64(Xfer &x, unsigned off) {   // 8 little-endian bytes starting at x.rx[off]
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)x.rx[off + i] << (8 * i);
    return v;
}
static void arc_dl_select(uint8_t idx, uint32_t size, std::function<void(Xfer &)> f = nullptr) {
    std::vector<uint8_t> v = {3, 8, 1, idx, uint8_t(size >> 24), uint8_t(size >> 16), uint8_t(size >> 8), uint8_t(size)};
    xfer(v, f);
}
static void arc_dl_write(uint8_t idx, const std::vector<uint8_t> &bytes, std::function<void(Xfer &)> f = nullptr) {
    std::vector<uint8_t> v = {3, 8, 2, idx};
    for (auto b : bytes) v.push_back(b);
    xfer(v, f);
}
static std::vector<uint8_t> arc_saved_bytes;
static ps_t arc_reset_t0 = 0;
static int arc_ul_status_polls = 0;
static void script_arc() {
    switch (step) {
    case 0:
        if (now < 50000000) return;                 // 50 us after start, as every other mode's step 0
        xfer({0, 0, 0, 0, 0, 0, 0}, nullptr);        // SYS STATUS (discarded)
        xfer({0, 5, 0xFF, 0}, nullptr);              // SYS IRQ_CTRL 0xFF (discarded)
        step = 1; return;
    // ---- DIP: download index 254, 8 bytes, then check the core latched it
    case 1:
        if (!xq.empty()) return;
        arc_dl_select(ARC_DIP_IDX, 8, [](Xfer &) { printf("      SELECT idx 254 (DIP) size 8\n"); });
        step = 2; return;
    case 2:
        if (!xq.empty()) return;
        arc_dl_write(ARC_DIP_IDX, arc_le64(ARC_DIP_VAL));
        step = 3; return;
    case 3:
        if (!xq.empty()) return;
        arc_dl_select(ARC_DIP_IDX, 0, [](Xfer &) { printf("      SELECT idx 254 (DIP) size 0 (close)\n"); });
        step = 4; return;
    case 4:                                          // a settle transfer after the close, as tb_ul.inc's own
        // case 12 comment explains: "checked a couple of SPI transfers after SELECT/SELECT-0 ... so the
        // crossing has settled" (clk_pix/clk_sys here are the same clock for this core, but the wire protocol
        // itself still takes the rest of this SPI transfer's bytes to finish before the close is even sent)
        if (!xq.empty()) return;
#ifdef TANGO_IOCTL_UPLOAD
        xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &) {
            CHECK((uint64_t)t->core_dip == ARC_DIP_VAL, "DIP download (idx 254) reached the core: dip_reg = %016llx (want %016llx)",
                  (unsigned long long)t->core_dip, (unsigned long long)ARC_DIP_VAL);
        });
#endif
        step = 5; return;
    // ---- NVRAM: download a seed at index 4, close, the core mutates it +1 on the close edge
    case 5:
        if (!xq.empty()) return;
#ifdef TANGO_IOCTL_UPLOAD
        arc_dl_select(ARC_NVRAM_IDX, 8, [](Xfer &) {
            printf("      SELECT idx 4 (NVRAM) size 8 -- dbg: core_dl=%d dl_open=%d\n", (int)t->core_dl, (int)t->dbg_link_dl_open);
        });
#else
        arc_dl_select(ARC_NVRAM_IDX, 8, nullptr);
#endif
        step = 6; return;
    case 6:
        if (!xq.empty()) return;
#ifdef TANGO_IOCTL_UPLOAD
        arc_dl_write(ARC_NVRAM_IDX, arc_le64(ARC_NVRAM_SEED), [](Xfer &) {
            printf("      WRITE 8 bytes -- dbg: core_dl=%d dl_open=%d ioctl_addr=%u\n", (int)t->core_dl,
                   (int)t->dbg_link_dl_open, (unsigned)t->dbg_ioctl_addr);
        });
#else
        arc_dl_write(ARC_NVRAM_IDX, arc_le64(ARC_NVRAM_SEED), nullptr);
#endif
        step = 7; return;
    case 7:
        if (!xq.empty()) return;
#ifdef TANGO_IOCTL_UPLOAD
        arc_dl_select(ARC_NVRAM_IDX, 0, [](Xfer &) {
            printf("      SELECT idx 4 (NVRAM) size 0 (close) -- dbg: core_dl=%d dl_open=%d\n", (int)t->core_dl, (int)t->dbg_link_dl_open);
        });
#else
        arc_dl_select(ARC_NVRAM_IDX, 0, nullptr);
#endif
        step = 8; return;
    case 8:
        if (!xq.empty()) return;
#ifdef TANGO_IOCTL_UPLOAD
        xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &) {
            uint64_t want = ARC_NVRAM_SEED + 1;
            CHECK((uint64_t)t->core_nvram == want, "NVRAM download (idx 4) + close mutate: nvram_reg = %016llx (want seed+1 = %016llx)",
                  (unsigned long long)t->core_nvram, (unsigned long long)want);
        });
#endif
        step = 9; return;
    // ---- upload the NVRAM value back (the core's own current value, seed+1)
    case 9:
        if (!xq.empty()) return;
        ul_select(ARC_NVRAM_IDX, 8, [](Xfer &) { printf("      UL_SELECT idx 4 (NVRAM) size 8\n"); });
        step = 10; return;
    case 10:
        if (!xq.empty()) return;
        waiting = true;
        ul_status(ARC_NVRAM_IDX, [](Xfer &x) {
            waiting = false; arc_ul_status_polls++;
            if ((x.rx[4] & 0x80) && x.rx[6] == 8) step = 11;
            else if (arc_ul_status_polls > 4000) { CHECK(false, "UL_STATUS (idx 4) never became ready"); step = 11; }
        });
        return;
    case 11:
        if (!xq.empty()) return;
        ul_read(ARC_NVRAM_IDX, 8, [](Xfer &x) {
            uint64_t want = ARC_NVRAM_SEED + 1;
            uint64_t got = arc_rx64(x, 4);
            CHECK(got == want, "UL READ (idx 4, 8 bytes) = %016llx (want seed+1 = %016llx)",
                  (unsigned long long)got, (unsigned long long)want);
            arc_saved_bytes.assign(x.rx.begin() + 4, x.rx.begin() + 12);
        });
        step = 12; return;
    // ---- close the upload session (UL_SELECT size 0): without this close, ioctl_upload (tango_io.v's output
    // reg) stays asserted (it has no reset of its own), and tango_io.v's download FIFO drain is gated
    // `!ioctl_upload` ("a download never starts while an upload is open") -- so every later download in this
    // script would never be popped off the FIFO: tango_link's dl_open goes 1 (the debug tap dut.u_link.dl_open
    // shows it), but ioctl_download never follows and ioctl_addr stays at the previous session's last value.
    // The real firmware closes every upload session it opens (a short write, a full transfer, a give-up), so it
    // never leaves ioctl_upload high; this script closes it as the firmware does.
    // (Every step below is numbered in sequence and stays under tb_menu.cpp's ARC_DONE (25), so the end-of-run
    // check `step >= ARC_DONE` cannot be met early by a scratch step number.)
    case 12:
        if (!xq.empty()) return;
        ul_select(ARC_NVRAM_IDX, 0, [](Xfer &) { printf("      UL_SELECT idx 4 (NVRAM) size 0 (close the upload session)\n"); });
        step = 13; return;
    // ---- simulate a reboot: pulse RESET (tb_menu.v's rst_pix), then recover the link
    case 13:
        if (!xq.empty()) return;
        printf("      reboot: asserting rst_pix\n");
        t->rst_pix = 1; arc_reset_t0 = now;
        step = 14; return;
    case 14:
        if (now - arc_reset_t0 < 200000) return;      // >= 200 ns: tens of clk_pix periods (13468 ps each)
        t->rst_pix = 0; arc_reset_t0 = now;
        printf("      reboot: releasing rst_pix\n");
        step = 15; return;
    case 15:
        if (now - arc_reset_t0 < 200000) return;      // let the framework re-settle before any SPI traffic
        step = 16; return;
    case 16:                                          // the recovery STATUS read, as the normal boot script
        // does after a bl616_jtagsel link reset -- its callback is this step's real check: the reset actually
        // cleared both registers, not merely "the simulation never looked"
        if (!xq.empty()) return;
#ifdef TANGO_IOCTL_UPLOAD
        xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &) {
            CHECK((uint64_t)t->core_nvram == 0, "after the simulated reboot: nvram_reg = %016llx (want 0, i.e. actually cleared)",
                  (unsigned long long)t->core_nvram);
            CHECK((uint64_t)t->core_dip == 0, "after the simulated reboot: dip_reg = %016llx (want 0)",
                  (unsigned long long)t->core_dip);
            printf("      post-reboot STATUS -- dbg: dl_open=%d core_dl=%d\n", (int)t->dbg_link_dl_open, (int)t->core_dl);
        });
#else
        xfer({0, 0, 0, 0, 0, 0, 0}, nullptr);
#endif
        step = 17; return;
    // ---- re-download the exact bytes the upload captured: the restart's own "load the save back" step
    case 17:
        if (!xq.empty()) return;
        CHECK(arc_saved_bytes.size() == 8, "the upload (step 11) captured 8 bytes to redownload (%zu)", arc_saved_bytes.size());
#ifdef TANGO_IOCTL_UPLOAD
        arc_dl_select(ARC_NVRAM_IDX, 8, [](Xfer &) {
            printf("      SELECT idx 4 (NVRAM) size 8 (redownload after reboot) -- dbg: core_dl=%d dl_open=%d ioctl_wr=%d "
                   "ioctl_addr=%u ioctl_index=%u\n", (int)t->core_dl, (int)t->dbg_link_dl_open, (int)t->dbg_ioctl_wr,
                   (unsigned)t->dbg_ioctl_addr, (unsigned)t->dbg_ioctl_index);
        });
#else
        arc_dl_select(ARC_NVRAM_IDX, 8, nullptr);
#endif
        step = 18; return;
    case 18:
        if (!xq.empty()) return;
#ifdef TANGO_IOCTL_UPLOAD
        arc_dl_write(ARC_NVRAM_IDX, arc_saved_bytes, [](Xfer &) {
            printf("      WRITE 8 bytes -- dbg: core_dl=%d dl_open=%d ioctl_wr=%d ioctl_addr=%u ioctl_index=%u core_nvram=%016llx\n",
                   (int)t->core_dl, (int)t->dbg_link_dl_open, (int)t->dbg_ioctl_wr, (unsigned)t->dbg_ioctl_addr,
                   (unsigned)t->dbg_ioctl_index, (unsigned long long)t->core_nvram);
        });
#else
        arc_dl_write(ARC_NVRAM_IDX, arc_saved_bytes, nullptr);
#endif
        step = 19; return;
    case 19:
        if (!xq.empty()) return;
#ifdef TANGO_IOCTL_UPLOAD
        arc_dl_select(ARC_NVRAM_IDX, 0, [](Xfer &) {
            printf("      SELECT idx 4 (NVRAM) size 0 (close) -- dbg: core_dl=%d dl_open=%d core_nvram=%016llx\n",
                   (int)t->core_dl, (int)t->dbg_link_dl_open, (unsigned long long)t->core_nvram);
        });
#else
        arc_dl_select(ARC_NVRAM_IDX, 0, nullptr);
#endif
        step = 20; return;
    case 20:
        if (!xq.empty()) return;
#ifdef TANGO_IOCTL_UPLOAD
        xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &) {
            uint64_t want = ARC_NVRAM_SEED + 2;        // saved_bytes (seed+1) redownloaded, then +1 again on this close
            CHECK((uint64_t)t->core_nvram == want, "NVRAM survived the simulated reboot: redownload + close -> nvram_reg = "
                  "%016llx (want (seed+1)+1 = %016llx)", (unsigned long long)t->core_nvram, (unsigned long long)want);
        });
#endif
        step = 21; return;
    // ---- SYS READ_CFG: the byte-for-byte check run_tb_arc.sh's header promises (its python block only
    // PRINTS the RTL's CONF_STR; this step compares it with what the sim read back). Command/offset
    // confirmed directly from this file's own default boot script (case 0 above: tgt=0 SYS, cmd=8
    // READ_CFG, then as many zero bytes as the reply needs; the string starts at x.rx[3], same as that
    // case's own READ_CFG check for "MENU;;..."). The expected string is hardcoded, the same house style
    // that existing check already uses (not derived at run time either) -- confirmed once, by hand, against
    // this core's own CONF_STR (rtl/tango_core_arcade_template.v, with `BUILD_DATE expanded to "sim" the
    // same way run_tb_arc.sh's build does): "ArcadeTemplate;;-;DIP;-;T[0],Reset;R[0],Reset and close
    // OSD;J1,Button 1,Button 2,Start,Coin;V,sim" (97 bytes; 65 before arcade-pads added the 32-byte J1
    // entry) -- independently re-derived from the RTL's own quoted parts, not copied from a previous run's
    // printed output. The reply buffer below was 100 bytes, which a 97-byte string only just fits; raised
    // to 160 so a later entry cannot silently truncate the comparison.
    case 21:
        if (!xq.empty()) return;
        {
            std::vector<uint8_t> c = {0, 8, 0}; c.resize(3 + 160, 0);   // 97-byte CONF_STR + NUL, with room to spare
            xfer(c, [](Xfer &x) {
                std::string s; for (size_t i = 3; i < x.rx.size() && x.rx[i]; i++) s += char(x.rx[i]);
                CHECK(s == "ArcadeTemplate;;-;DIP;-;T[0],Reset;R[0],Reset and close OSD;J1,Button 1,Button 2,Start,Coin;V,sim",
                      "SYS READ_CFG -> \"%s\" (want the RTL's own CONF_STR, BUILD_DATE=sim)", s.c_str());
            });
        }
        step = 22; return;
    case 22:
        // REAL BUG FOUND HERE, first draft of this step: without this xq.empty() gate (every OTHER step in
        // this file has one before touching `step` again), the final jump to 25 happened on the very next
        // tick after case 21 merely QUEUED the READ_CFG transfer -- before it had actually run. Since 25
        // trips tb_menu.cpp's own `step >= ARC_DONE` end-of-run countdown (an extra 20 us grace period,
        // "let the DUT see the last CSN rise"), the 103-byte READ_CFG transfer (needing ~62 us at this
        // master's SCK rate) was still in flight when that grace period ran out: the sim ended with the
        // transfer PARTIALLY sent (confirmed by the byte count: +16 bytes, not +103) and its callback never
        // fired, so the whole new check silently never ran -- no FAIL printed, because CHECK() never got
        // called at all, not because anything passed.
        if (!xq.empty()) return;
        step = 25; return;    // past tb_menu.cpp's own ARC_DONE threshold, as tb_ul.inc's step 22 -> 25 does for UL_DONE
    default: return;
    }
}
