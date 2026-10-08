/* Per-command core cycles on the SoC: the firmware MARS against the MarsV2 hardware,
   warm.  Each shape runs once, then REPS times; min and median are reported.
   Firmware: the call itself (behind the gate, the ecall round trip included).
   Hardware: command write to idle over MMIO.  One CSV line per shape:
     PERF,<BUILD>,<shape>,<fw min>,<fw median>,<hw min>,<hw median> */
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "mars.h"
#include "hw.h"
#ifdef MARS_GATE
#include "gate.h"
#define fw_init() gate_test_reset()
#else
void _MARS_Init(void);
#define fw_init() _MARS_Init()
#endif

#ifndef BUILD
#define BUILD "unnamed"
#endif
#ifndef REPS
#define REPS 7
#endif

static cmd_t c;
static uint8_t out[32];
static MARS_RC fw_rc;   /* the firmware's last answer, checked against the hardware's */

static uint64_t fw_call(int shape);
static const struct { const char *name; uint16_t code; } shapes[] = {
    {"Init", HW_INIT}, {"SelfTest", 0}, {"CapabilityGet", 1}, {"PcrExtend", 5}, {"RegRead", 6},
    {"RegRead-REG", 6}, {"Derive", 7}, {"DpDerive", 8}, {"DpDerive-reset", 8}, {"Quote-rs0", 10},
    {"Quote-rs3", 10}, {"Sign", 11}, {"SignatureVerify", 12},
};
#define NSHAPES (int)(sizeof shapes / sizeof shapes[0])

static void args(int shape)
{
    memset(&c, 0, sizeof c);
    for (int i = 0; i < 32; i++) {
        c.dig[i] = (uint8_t)(0x41 + i);
        c.nonce[i] = (uint8_t)(0x01 + i);
        c.ctx[i] = (uint8_t)(0x21 + i);
    }
    c.code = shapes[shape].code;
    c.pt = 1;
    c.ctxlen = 32;
    c.nlen = 32;
    c.regsel = 3;
    if (!strcmp(shapes[shape].name, "RegRead-REG")) c.idx = 2;
    if (!strcmp(shapes[shape].name, "DpDerive-reset")) c.ctxlen = 0;
    if (!strcmp(shapes[shape].name, "Quote-rs0")) c.regsel = 0;
    if (c.code == 12) MARS_Sign(c.ctx, 32, c.dig, c.sig);
}

static uint64_t fw_call(int shape)
{
    bool r;
    uint64_t t0 = hw_rdcycle();
    switch (shapes[shape].code) {
    case HW_INIT: fw_init(); fw_rc = MARS_RC_SUCCESS; break;
    case 0:  fw_rc = MARS_SelfTest(true); break;
    case 1:  { uint16_t cap; fw_rc = MARS_CapabilityGet(c.pt, &cap, sizeof cap); } break;
    case 5:  fw_rc = MARS_PcrExtend(c.idx, c.dig); break;
    case 6:  fw_rc = MARS_RegRead(c.idx, out); break;
    case 7:  fw_rc = MARS_Derive(c.regsel, c.ctx, c.ctxlen, out); break;
    case 8:  fw_rc = MARS_DpDerive(c.regsel, c.ctxlen ? c.ctx : NULL, c.ctxlen); break;
    case 10: fw_rc = MARS_Quote(c.regsel, c.nonce, c.nlen, c.ctx, c.ctxlen, out); break;
    case 11: fw_rc = MARS_Sign(c.ctx, c.ctxlen, c.dig, out); break;
    case 12: fw_rc = MARS_SignatureVerify(false, c.ctx, c.ctxlen, c.dig, c.sig, &r); break;
    }
    return hw_rdcycle() - t0;
}

static void sort(uint64_t *v, int n)
{
    for (int i = 1; i < n; i++)
        for (int j = i; j > 0 && v[j - 1] > v[j]; j--) { uint64_t t = v[j]; v[j] = v[j - 1]; v[j - 1] = t; }
}

static int perf(void)
{
    int bad = 0;
    for (int k = 0; k < NSHAPES; k++) {
        uint64_t fw[REPS], hw[REPS];
        int hn = REPS;
        args(k);
        fw_call(k);
        for (int r = 0; r < REPS; r++) fw[r] = fw_call(k);
        hw_write_args(&c);
        if (c.code == HW_INIT) {                      /* the platform allows one per reset */
            hw[0] = hw_issue(c.code);
            hn = 1;
        } else {
            hw_issue(c.code);
            for (int r = 0; r < REPS; r++) hw[r] = hw_issue(c.code);
        }
        uint16_t hrc = (uint16_t)reg_read32(HW_OUT_RC);
        if (hrc != fw_rc) {
            printf("FAIL %s: rc firmware %u, hardware %u\n", shapes[k].name, fw_rc, hrc);
            bad++;
        }
        sort(fw, REPS);
        sort(hw, hn);
        printf("PERF,%s,%s,%lu,%lu,%lu,%lu\n", BUILD, shapes[k].name, (unsigned long)fw[0],
               (unsigned long)fw[REPS / 2], (unsigned long)hw[0], (unsigned long)hw[hn / 2]);
    }
    printf("%s perf\n", bad ? "FAIL" : "PASS");
    return bad != 0;
}

#ifdef MARS_GATE
static int user_main(int argc, char **argv) { (void)argc; (void)argv; return perf(); }
int main(int argc, char **argv) { gate_run_user(user_main, argc, argv); }
#else
int main(void) { return perf(); }
#endif
