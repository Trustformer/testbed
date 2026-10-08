/* MarsV2 over MMIO (register map: chipyard-trustformer-module
   src/main/resources/regmap/Example_MarsV2.json).  256-bit values travel as the
   emulator's 32-byte big-endian arrays: byte j is bits [255-8j : 248-8j]. */
#ifndef MARSFW_HW_H
#define MARSFW_HW_H
#include <stdint.h>
#include <string.h>
#include "mmio.h"

#define HW_BASE          0x4000UL
#define HW_STATUS        (HW_BASE + 0x00)
#define HW_CMD           (HW_BASE + 0x04)
#define HW_IN_CTX        (HW_BASE + 0x08)
#define HW_IN_CTXLEN     (HW_BASE + 0x28)
#define HW_IN_DIG        (HW_BASE + 0x2C)
#define HW_IN_IDX        (HW_BASE + 0x4C)
#define HW_IN_NLEN       (HW_BASE + 0x50)
#define HW_IN_NONCE      (HW_BASE + 0x54)
#define HW_IN_PT         (HW_BASE + 0x74)
#define HW_IN_REGSEL     (HW_BASE + 0x78)
#define HW_IN_RESTRICTED (HW_BASE + 0x7C)
#define HW_IN_SIG        (HW_BASE + 0x80)
#define HW_OUT_CAP       (HW_BASE + 0xA0)
#define HW_OUT_DOUT      (HW_BASE + 0xA4)
#define HW_OUT_FAILURE   (HW_BASE + 0xC4)
#define HW_OUT_PCR0      (HW_BASE + 0xC8)
#define HW_OUT_PCR1      (HW_BASE + 0xE8)
#define HW_OUT_RC        (HW_BASE + 0x108)
#define HW_OUT_RESULT    (HW_BASE + 0x10C)
#define HW_OUT_SNAP      (HW_BASE + 0x110)
#define HW_OUT_ST        (HW_BASE + 0x130)

#define HW_INIT 0xFFFF

/* The full public state after a command. */
typedef struct {
    uint16_t rc, cap;
    int result;
    uint8_t dout[32], snap[32], pcr0[32], pcr1[32];
    int fail, st;
} pub_t;

/* One command's arguments, as the host writes them. */
typedef struct {
    uint16_t code, pt, idx, nlen, ctxlen;
    uint32_t regsel;
    int restricted;
    uint8_t dig[32], nonce[32], ctx[32], sig[32];
} cmd_t;

static inline void hw_put256(uintptr_t addr, const uint8_t *b)
{
    for (int k = 0; k < 8; k++) {
        const uint8_t *w = b + 4 * (7 - k);
        reg_write32(addr + 4 * k, (uint32_t)w[0] << 24 | (uint32_t)w[1] << 16 | (uint32_t)w[2] << 8 | w[3]);
    }
}

static inline void hw_get256(uintptr_t addr, uint8_t *b)
{
    for (int k = 0; k < 8; k++) {
        uint32_t v = reg_read32(addr + 4 * k);
        uint8_t *w = b + 4 * (7 - k);
        w[0] = v >> 24; w[1] = v >> 16; w[2] = v >> 8; w[3] = v;
    }
}

static inline uint64_t hw_rdcycle(void)
{
#if __riscv_xlen == 32
    uint32_t hi, lo, hi2;
    do {
        asm volatile ("rdcycleh %0" : "=r"(hi));
        asm volatile ("rdcycle %0" : "=r"(lo));
        asm volatile ("rdcycleh %0" : "=r"(hi2));
    } while (hi != hi2);
    return (uint64_t)hi << 32 | lo;
#else
    uint64_t c;
    asm volatile ("rdcycle %0" : "=r"(c));
    return c;
#endif
}

static inline void hw_wait_idle(void)
{
    while (reg_read32(HW_STATUS) & 1)
        ;
}

static inline void hw_write_args(const cmd_t *c)
{
    reg_write32(HW_IN_PT, c->pt);
    reg_write32(HW_IN_IDX, c->idx);
    reg_write32(HW_IN_REGSEL, c->regsel);
    reg_write32(HW_IN_NLEN, c->nlen);
    reg_write32(HW_IN_CTXLEN, c->ctxlen);
    reg_write32(HW_IN_RESTRICTED, (uint32_t)c->restricted);
    hw_put256(HW_IN_DIG, c->dig);
    hw_put256(HW_IN_NONCE, c->nonce);
    hw_put256(HW_IN_CTX, c->ctx);
    hw_put256(HW_IN_SIG, c->sig);
}

/* Cycles from the command write until the device is idle again. */
static inline uint64_t hw_issue(uint16_t code)
{
    hw_wait_idle();
    uint64_t t0 = hw_rdcycle();
    reg_write32(HW_CMD, code);
    hw_wait_idle();
    return hw_rdcycle() - t0;
}

static inline void hw_read(pub_t *p)
{
    p->rc = (uint16_t)reg_read32(HW_OUT_RC);
    p->cap = (uint16_t)reg_read32(HW_OUT_CAP);
    p->result = (int)reg_read32(HW_OUT_RESULT);
    hw_get256(HW_OUT_DOUT, p->dout);
    hw_get256(HW_OUT_SNAP, p->snap);
    hw_get256(HW_OUT_PCR0, p->pcr0);
    hw_get256(HW_OUT_PCR1, p->pcr1);
    p->fail = (int)reg_read32(HW_OUT_FAILURE);
    p->st = (int)reg_read32(HW_OUT_ST);
}
#endif
