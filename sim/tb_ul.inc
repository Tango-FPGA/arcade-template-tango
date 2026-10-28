// SPDX-License-Identifier: MIT
// Copyright (c) 2026 the Tango authors
// tb_ul.inc -- the upload gate of menu-tango's bench (mode=ul, on its sim-only core tb_ulcore.v; not built here)
// (TANGO_IOCTL_UPLOAD): proves the reverse direction (core -> firmware)
// SDC_IMAGE sub-commands against tb_ulcore.v's known pattern (ioctl_din = ioctl_addr[7:0] + 0x11):
//   0  a READ while nothing is open returns all-zero bytes (sub 3 is gated on an open, ready session: a_ulr)
//   1  UL_SELECT (sub 4) opens index 7, size 37; UL_STATUS (sub 5) polled until ready, size reported
//      correctly throughout
//   2  a single READ transfer reads all 37 bytes in one SPI transfer: every byte checked against the pattern
//   3  re-SELECT the same index/size (step 2 already consumed the session's own read cursor, ul_off) and
//      wait ready again, then read it a second time, split across three separate READ transfers (10 + 10 +
//      17 bytes, no re-SELECT in between), PLUS 5 more bytes read past the session's own end (must be 00,
//      not stale buffer bytes from a previous, larger session -- this is what a_ulr's own bound, not just
//      an_rx, against ul_off + local position actually proves, since ul_off is nonzero here)
//   4  an oversized UL_SELECT (idx 7, size 3000, above the 2048-byte buffer): UL_STATUS must report the
//      RTL's own clamp (2048), never the asked-for 3000, then closed
//   5  a UL_SELECT (idx 5, size 1500) immediately followed by a UL_SELECT close, before the fill engine can
//      possibly finish (1500 bytes takes ~94 us to prefetch; the two SPI transfers are ~2 us apart): proves
//      a close arriving mid-fill is honoured, not silently lost behind the in-flight fetch -- core_ul
//      (tango_io's ioctl_upload) must fall, and a later, ordinary open at the same index must still work
//   6  a plain SELECT/WRITE/SELECT(0) DOWNLOAD (sub 1/2), to prove the new sub-commands (3/4/5) sharing SDC
//      IMAGE's cmd=8 with the unmodified download path (sub 0/1/2) cause no cross-talk -- core_dl (tango_io's
//      ioctl_download) toggles exactly as it always did
//   7  a second upload session at a different index/size (idx 2, size 9), to prove the state machine returns
//      cleanly to idle and re-opens correctly after everything above
//   8  a UL_SELECT (idx 5, size 9) sent WHILE a plain download (idx 6) is still open: must be deferred
//      (tango_io.v's ul_pend), not lost -- tango_link already latched the new ul_idx/ul_size_l the moment
//      this UL_SELECT's own bytes land, well before the download closes and the upload is finally honoured
#include <cstdint>
static uint8_t ul_pat(unsigned r) { return (uint8_t)((r + 0x11) & 0xFF); }
static void ul_select(uint8_t idx, uint32_t size, std::function<void(Xfer &)> f = nullptr) {
    std::vector<uint8_t> v = {3, 8, 4, idx, uint8_t(size >> 24), uint8_t(size >> 16), uint8_t(size >> 8), uint8_t(size)};
    xfer(v, f);
}
static void ul_status(uint8_t idx, std::function<void(Xfer &)> f) {
    xfer({3, 8, 5, idx, 0, 0, 0}, f);
}
static void ul_read(uint8_t idx, unsigned n, std::function<void(Xfer &)> f) {
    std::vector<uint8_t> v = {3, 8, 3, idx}; v.resize(4 + n, 0);
    xfer(v, f);
}
static int ul_status_polls = 0;
static void script_ul() {
    switch (step) {
    case 0:
        if (now < 50000000) return;
        xfer({0, 0, 0, 0, 0, 0, 0}, nullptr);
        xfer({0, 5, 0xFF, 0}, nullptr);
        ul_read(7, 4, [](Xfer &x) {
            bool z = x.rx[4] == 0 && x.rx[5] == 0 && x.rx[6] == 0 && x.rx[7] == 0;
            CHECK(z, "READ while nothing is open -> all zero (%s)", hex(x.rx, 4, 4).c_str());
        });
        ul_status(7, [](Xfer &x) {
            CHECK((x.rx[4] & 0x80) == 0 && x.rx[5] == 0 && x.rx[6] == 0,
                  "UL_STATUS before any UL_SELECT: not ready, size 0 (%s)", hex(x.rx, 4, 3).c_str());
        });
        step = 1; return;
    case 1:
        if (!xq.empty()) return;
        ul_select(7, 37, [](Xfer &) { printf("      UL_SELECT idx 7 size 37 (frame %d)\n", frame); });
        step = 2; return;
    case 2:                                         // poll UL_STATUS until ready
        if (!xq.empty()) return;
        waiting = true;
        ul_status(7, [](Xfer &x) {
            waiting = false; ul_status_polls++;
            CHECK(x.rx[5] == 0 && x.rx[6] == 37, "UL_STATUS size reported as 37 throughout (%s)", hex(x.rx, 5, 2).c_str());
            if (x.rx[4] & 0x80) {
                printf("ok:   UL_STATUS ready after %d poll(s)\n", ul_status_polls);
                step = 3;
            } else if (ul_status_polls > 2000) { CHECK(false, "UL_STATUS never became ready"); step = 3; }
        });
        return;
    case 3:
        if (!xq.empty()) return;
        ul_read(7, 37, [](Xfer &x) {
            int bad = 0, first = -1;
            for (unsigned i = 0; i < 37; i++) if (x.rx[4 + i] != ul_pat(i)) { if (first < 0) first = i; bad++; }
            CHECK(bad == 0, "READ (one transfer, 37 bytes) matches the pattern (%d differ, first byte %d: got %02X want %02X)",
                  bad, first, first >= 0 ? x.rx[4 + first] : 0, first >= 0 ? ul_pat(first) : 0);
        });
        step = 4; return;
    case 4:                                          // re-SELECT the same session (step 3 already consumed
        // it; ul_off is the session's own running cursor, so reading it again now needs a fresh open --
        // this is also real, additional coverage: re-opening the same index right after a full read)
        if (!xq.empty()) return;
        ul_select(7, 37, nullptr);
        step = 5; return;
    case 5:
        if (!xq.empty()) return;
        waiting = true;
        ul_status(7, [](Xfer &x) {
            waiting = false; ul_status_polls++;
            if (x.rx[4] & 0x80) step = 6;
            else if (ul_status_polls > 6000) { CHECK(false, "re-opened session never became ready"); step = 6; }
        });
        return;
    case 6:                                           // the same 37 bytes, split across 3 READ transfers,
        // plus a read past the session's own end
        if (!xq.empty()) return;
        ul_read(7, 10, [](Xfer &x) {
            int bad = 0; for (unsigned i = 0; i < 10; i++) if (x.rx[4 + i] != ul_pat(i)) bad++;
            CHECK(bad == 0, "split READ chunk 1/3 (bytes 0..9) matches (%d differ)", bad);
        });
        ul_read(7, 10, [](Xfer &x) {
            int bad = 0, first = -1; for (unsigned i = 0; i < 10; i++) if (x.rx[4 + i] != ul_pat(10 + i)) { if (first<0) first=i; bad++; }
            CHECK(bad == 0, "split READ chunk 2/3 (bytes 10..19) matches (%d differ, first local i=%d got %02X want %02X) -- a transfer boundary that "
                            "a destructive 2-ahead FIFO pop would have skipped 2 bytes at", bad, first, first>=0?x.rx[4+first]:0, first>=0?ul_pat(10+first):0);
        });
        ul_read(7, 17, [](Xfer &x) {
            int bad = 0, first = -1; for (unsigned i = 0; i < 17; i++) if (x.rx[4 + i] != ul_pat(20 + i)) { if (first<0) first=i; bad++; }
            CHECK(bad == 0, "split READ chunk 3/3 (bytes 20..36) matches (%d differ, first local i=%d got %02X want %02X)", bad, first, first>=0?x.rx[4+first]:0, first>=0?ul_pat(20+first):0);
        });
        ul_read(7, 5, [](Xfer &x) {
            int bad = 0; for (unsigned i = 0; i < 5; i++) if (x.rx[4 + i] != 0) bad++;
            CHECK(bad == 0, "READ past the session's own end (bytes 37..41) -> all zero, not stale buffer bytes (%d differ, %s)",
                  bad, hex(x.rx, 4, 5).c_str());
        });
        step = 7; return;
    case 7:                                          // an oversized UL_SELECT: the RTL clamps to 2048
        if (!xq.empty()) return;
        ul_select(7, 3000, [](Xfer &) { printf("      UL_SELECT idx 7 size 3000 (above the 2048-byte buffer)\n"); });
        step = 8; return;
    case 8:
        if (!xq.empty()) return;
        waiting = true;
        ul_status(7, [](Xfer &x) {
            waiting = false; ul_status_polls++;
            if (x.rx[4] & 0x80) {
                CHECK(x.rx[5] == 0x08 && x.rx[6] == 0x00, "UL_STATUS clamps an oversized open (asked 3000) to 2048 (%s)",
                      hex(x.rx, 5, 2).c_str());
                step = 9;
            } else if (ul_status_polls > 20000) { CHECK(false, "oversized session never became ready"); step = 9; }
        });
        return;
    case 9:
        if (!xq.empty()) return;
        ul_select(7, 0, [](Xfer &) { printf("      UL_SELECT idx 7 size 0 (close the oversized session)\n"); });
        step = 10; return;
    case 10:                                          // a close that lands while the fill engine is still
        // mid-fetch (1500 bytes at ~3 clk_sys clocks/byte, clk_sys ~48 MHz, is ~94 us; the two SPI
        // transfers below are only ~2 us apart, so the close is issued long before the fetch could finish)
        if (!xq.empty()) return;
        ul_select(5, 1500, [](Xfer &) { printf("      UL_SELECT idx 5 size 1500 (frame %d)\n", frame); });
        ul_select(5, 0, [](Xfer &) { printf("      UL_SELECT idx 5 size 0 (close, issued mid-fill)\n"); });
        step = 11; return;
    case 11:
        if (!xq.empty()) return;
        waiting = true;
        ul_status(5, [](Xfer &x) {
            waiting = false;
            CHECK((x.rx[4] & 0x80) == 0 && x.rx[6] == 0, "UL_STATUS after a mid-fill close: not ready, size 0 (%s)", hex(x.rx, 4, 3).c_str());
#ifdef TANGO_IOCTL_UPLOAD                 // core_ul only exists on Vtb_menu when the Verilog side was also
            CHECK(t->core_ul == 0, "ioctl_upload fell after the mid-fill close");   // built with the define
#endif
        });
        step = 12; return;
    case 12: {                                        // a plain download, interleaved: no cross-talk with sub 3/4/5
        // core_dl (tango_io's ioctl_download) crosses the download FIFO (clk_pix -> clk_sys): checked a
        // couple of SPI transfers after SELECT/SELECT-0, not inside their own callback, so the crossing has
        // settled (a dummy SYS STATUS xfer's own ~44 clk_pix-cycle gap is orders of magnitude more).
        if (!xq.empty()) return;
        static const uint8_t dl_bytes[5] = {0x10, 0x20, 0x30, 0x40, 0x50};
        waiting = true;
        xfer({3, 8, 1, 9, 0, 0, 0, 5});
        xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &) { CHECK(t->core_dl == 1, "SELECT (download) -> ioctl_download 1"); });
        { std::vector<uint8_t> v = {3, 8, 2, 9}; for (int i = 0; i < 5; i++) v.push_back(dl_bytes[i]); xfer(v); }
        xfer({3, 8, 1, 9, 0, 0, 0, 0});
        xfer({0, 0, 0, 0, 0, 0, 0}, [](Xfer &x) { waiting = false;
            CHECK(t->core_dl == 0, "SELECT 0 (download close) -> ioctl_download 0"); });
        step = 13; return; }
    case 13:                                          // a session re-opened at idx 5 (just mid-fill-closed
        // above), to prove it recovers cleanly, same index, different (small) size
        if (!xq.empty()) return;
        ul_select(5, 9, nullptr);
        step = 14; return;
    case 14:
        if (!xq.empty()) return;
        waiting = true;
        ul_status(5, [](Xfer &x) {
            waiting = false; ul_status_polls++;
            if ((x.rx[4] & 0x80) && x.rx[6] == 9) step = 15;
            else if (ul_status_polls > 24000) { CHECK(false, "idx 5 never became ready after the mid-fill close"); step = 15; }
        });
        return;
    case 15:
        if (!xq.empty()) return;
        ul_read(5, 9, [](Xfer &x) {
            int bad = 0; for (unsigned i = 0; i < 9; i++) if (x.rx[4 + i] != ul_pat(i)) bad++;
            CHECK(bad == 0, "idx 5 (re-opened after a mid-fill close) READ matches the pattern (%d differ)", bad);
        });
        step = 16; return;
    case 16:                                          // a second, independent session at a different index
        if (!xq.empty()) return;
        ul_select(2, 9, nullptr);
        step = 17; return;
    case 17:                                          // poll UL_STATUS until the second session is ready
        if (!xq.empty()) return;
        waiting = true;
        ul_status(2, [](Xfer &x) {
            waiting = false; ul_status_polls++;
            if ((x.rx[4] & 0x80) && x.rx[6] == 9) step = 18;
            else if (ul_status_polls > 8000) { CHECK(false, "second session (idx 2) never became ready"); step = 18; }
        });
        return;
    case 18:
        if (!xq.empty()) return;
        ul_read(2, 9, [](Xfer &x) {
            int bad = 0; for (unsigned i = 0; i < 9; i++) if (x.rx[4 + i] != ul_pat(i)) bad++;
            CHECK(bad == 0, "second session (idx 2, size 9) READ matches the pattern (%d differ)", bad);
        });
        step = 19; return;
    case 19: {                                        // UL_SELECT arriving while a download is open: must
        // be deferred (ul_pend, tango_io.v), not lost -- tango_link already latched the new ul_idx/
        // ul_size_l the moment this UL_SELECT's own bytes land, well before the download below closes.
        if (!xq.empty()) return;
        static const uint8_t dl_bytes[9] = {1, 2, 3, 4, 5, 6, 7, 8, 9};
        xfer({3, 8, 1, 6, 0, 0, 0, 5});                 // SELECT (download) idx 6, size 5: opens, stays open
        ul_select(5, 9, [](Xfer &) { printf("      UL_SELECT idx 5 size 9 sent while a download is open\n"); });
        { std::vector<uint8_t> v = {3, 8, 2, 6}; for (int i = 0; i < 5; i++) v.push_back(dl_bytes[i]); xfer(v); }
        xfer({3, 8, 1, 6, 0, 0, 0, 0});                 // SELECT 0: closes the download
        step = 20; return; }
    case 20:                                          // poll UL_STATUS until the deferred session is ready
        if (!xq.empty()) return;
        waiting = true;
        ul_status(5, [](Xfer &x) {
            waiting = false; ul_status_polls++;
            if ((x.rx[4] & 0x80) && x.rx[6] == 9) step = 21;
            else if (ul_status_polls > 24000) { CHECK(false, "deferred UL_SELECT (idx 5) never became ready"); step = 21; }
        });
        return;
    case 21:
        if (!xq.empty()) return;
        ul_read(5, 9, [](Xfer &x) {
            int bad = 0; for (unsigned i = 0; i < 9; i++) if (x.rx[4 + i] != ul_pat(i)) bad++;
            CHECK(bad == 0, "deferred UL_SELECT (idx 5, size 9) READ matches the pattern once honoured (%d differ)", bad);
        });
        step = 22; return;
    case 22:
        step = 25; return;    // >= 14 is tb_menu.cpp's own "script completed" threshold for this mode group;
                               // 25 is just past this script's own last real step number (22), so it never
                               // collides with one of the step numbers above still doing real work
    default: return;
    }
}
