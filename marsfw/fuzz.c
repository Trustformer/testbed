/* Differential fuzz on the SoC: one seeded command stream goes to the MarsV2
   hardware over MMIO and to the firmware MARS (the TCG emulator, on this core), and
   the full public state is compared after every command.  Where the Profile departs
   from the emulator, a named rule supplies the expectation, as in the Trustformer
   repo's sim/fuzz/gen_mars_v2.c:
     EMU  the firmware's answer          N1  one _MARS_Init per reset; guarded
     N2   Sequence* answer COMMAND           commands answer VALUE before it
     N4   ctxlen/nlen != 32 answer BUFFER N5 unknown codes fire no action
   This SoC ties the fault input low and its IPs pass SelfTest, so failure mode stays
   unreachable here; the module-level fuzz covers it.
   Build parameters: SEED, COUNT, and PRE (commands before the first Init). */
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "mars.h"
#include "hw.h"
#ifdef MARS_GATE
#include "gate.h"
#define snapshot(out, rs, nonce) gate_test_snapshot(out, rs, nonce)
#else
void CryptSnapshot(void *out, uint32_t regSelect, const void *ctx, uint16_t ctxlen);
#define snapshot(out, rs, nonce) CryptSnapshot(out, rs, nonce, 32)
#endif

#ifndef SEED
#define SEED 1
#endif
#ifndef COUNT
#define COUNT 200
#endif
#ifndef PRE
#define PRE (20 + SEED % 6)
#endif

static uint64_t s;
static uint64_t rnd(void)
{
    uint64_t z = (s += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}
static unsigned below(unsigned n) { return (unsigned)(rnd() >> 33) % n; }
static unsigned pct(void) { return below(100); }
static void rbytes(uint8_t *b, int n) { for (int i = 0; i < n; i++) b[i] = (uint8_t)rnd(); }

static uint16_t draw_len(unsigned p32, unsigned p0)
{
    unsigned r = pct();
    if (r < p32) return 32;
    if (r < p32 + p0) return 0;
    static const uint16_t sp[] = {0, 1, 31, 33, 64, 0xFFFF};
    unsigned q = below(10);
    if (q < 6) return sp[q];
    if (q < 8) return (uint16_t)(32 + (1u << (6 + below(10))));
    return (uint16_t)rnd();
}
static uint16_t draw_idx(void)
{
    if (pct() < 80) return (uint16_t)below(2);
    unsigned k = 1 + below(15);
    switch (below(6)) {
    case 0: return 2;
    case 1: return 3;
    case 2: return 0xFFFF;
    case 3: return (uint16_t)(1u << k);
    case 4: return (uint16_t)(1 + (1u << k));
    default: return (uint16_t)rnd();
    }
}
static uint16_t draw_pt(void)
{
    unsigned r = pct();
    if (r < 85) return (uint16_t)below(14);
    if (r < 90) return 0xFFFF;
    if (r < 95) return (uint16_t)(below(12) | (1u << (4 + below(12))));
    return (uint16_t)rnd();
}
static uint32_t draw_regsel(void)
{
    if (pct() < 80) return below(4);
    switch (below(6)) {
    case 0: return 4;
    case 1: return 5;
    case 2: return 0x80000000u;
    case 3: return 0xFFFFFFFFu;
    case 4: return below(4) | (1u << (2 + below(30)));
    default: return (uint32_t)rnd();
    }
}
static uint16_t draw_code(void)
{
    unsigned r = below(1000);
    static const struct { unsigned upto; uint16_t code; } t[] = {
        {60, 0}, {140, 1}, {160, 2}, {180, 3}, {200, 4}, {350, 5}, {430, 6}, {520, 7},
        {600, 8}, {620, 9}, {740, 10}, {840, 11}, {945, 12}, {995, HW_INIT}};
    for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++)
        if (r < t[i].upto) return t[i].code;
    switch (below(4)) {
    case 0: return 13;
    case 1: return 14;
    case 2: return 0xFFFE;
    default: return (uint16_t)(13 + below(0xFFFE - 13));
    }
}

enum { R_EMU, R_N1, R_N2, R_N4, R_N5, R_COUNT };
static const char *rule_name[R_COUNT] = {"EMU", "N1", "N2", "N4", "N5"};
static unsigned long rules[R_COUNT], mismatches, compared;
static unsigned long cov[15][8];   /* command (13 = Init, 14 = unknown) x rc */

static bool same(const pub_t *a, const pub_t *b)
{
    return a->rc == b->rc && a->cap == b->cap && a->result == b->result && a->fail == b->fail &&
           a->st == b->st && !memcmp(a->dout, b->dout, 32) && !memcmp(a->snap, b->snap, 32) &&
           !memcmp(a->pcr0, b->pcr0, 32) && !memcmp(a->pcr1, b->pcr1, 32);
}

static void read_pcrs(pub_t *p, bool inited)
{
    memset(p->pcr0, 0, 32);
    memset(p->pcr1, 0, 32);
    if (inited) {
        MARS_RegRead(0, p->pcr0);
        MARS_RegRead(1, p->pcr1);
    }
}

/* Issue c to the hardware and compare its public state with exp. */
static void check(unsigned long i, const cmd_t *c, const pub_t *exp)
{
    pub_t hw;
    hw_write_args(c);
    hw_issue(c->code);
    hw_read(&hw);
    compared++;
    unsigned row = c->code == HW_INIT ? 13 : c->code > 12 ? 14 : c->code;
    cov[row][exp->rc < 8 ? exp->rc : 7]++;
    if (!same(exp, &hw) && ++mismatches <= 10)
        printf("MISMATCH %lu code %04x rc exp %u hw %u, cap %u/%u, result %d/%d, fail %d/%d, st %d/%d%s%s%s%s\n",
               i, c->code, exp->rc, hw.rc, exp->cap, hw.cap, exp->result, hw.result, exp->fail, hw.fail,
               exp->st, hw.st, memcmp(exp->dout, hw.dout, 32) ? " dout" : "",
               memcmp(exp->snap, hw.snap, 32) ? " snap" : "", memcmp(exp->pcr0, hw.pcr0, 32) ? " pcr0" : "",
               memcmp(exp->pcr1, hw.pcr1, 32) ? " pcr1" : "");
}

static int fuzz(void)
{
    s = SEED;
    printf("fuzz seed=%u count=%u pre=%u\n", (unsigned)SEED, (unsigned)COUNT, (unsigned)PRE);
    bool inited = false;
    pub_t cur;
    memset(&cur, 0, sizeof cur);

    for (unsigned long i = 0; i < COUNT; i++) {
        cmd_t c;
        uint8_t ctx[32], nonce[32];   /* on the stack: behind the gate it lies above the firmware */
        c.code = i == PRE ? HW_INIT : draw_code();
        c.pt = draw_pt();
        c.idx = draw_idx();
        c.regsel = draw_regsel();
        c.nlen = draw_len(85, 0);
        c.ctxlen = c.code == 8 ? draw_len(65, 20) : draw_len(85, 0);
        c.restricted = (int)(rnd() & 1);
        rbytes(c.dig, 32); rbytes(c.nonce, 32); rbytes(c.ctx, 32); rbytes(c.sig, 32);
        memcpy(ctx, c.ctx, 32);
        memcpy(nonce, c.nonce, 32);

        if (c.code == 12 && pct() < 55) {             /* a signature that verifies */
            if (rnd() & 1) {
                MARS_Sign(ctx, 32, c.dig, c.sig);
                c.restricted = 0;
            } else {
                uint32_t rs = below(4);
                uint8_t nn[32];
                rbytes(nn, 32);
                MARS_Quote(rs, nn, 32, ctx, 32, c.sig);
                snapshot(c.dig, rs, nn);
                c.restricted = 1;
            }
            if (pct() < 30) c.sig[below(32)] ^= (uint8_t)(1u << below(8));
        }

        pub_t nx = cur;
        nx.rc = 0; nx.cap = 0; nx.result = 0;
        memset(nx.dout, 0, 32);
        int rule = R_EMU;
        MARS_RC rc = 0;
        bool known = c.code <= 12 || c.code == HW_INIT;
        if (!known) {
            nx = cur; rule = R_N5;
        } else if (c.code == HW_INIT) {
            rule = R_N1;
            if (inited) rc = MARS_RC_VALUE;
            else inited = true;                       /* the firmware initialized at boot */
        } else if (c.code == 1) {
            uint16_t cap = 0;
            rc = MARS_CapabilityGet(c.pt, &cap, sizeof cap);
            if (!rc) nx.cap = cap;
        } else if (c.code >= 2 && c.code <= 4) {
            rc = MARS_RC_COMMAND; rule = R_N2;
        } else if (c.code == 9) {
            uint8_t pub[32];
            rc = MARS_PublicRead(c.restricted, ctx, c.ctxlen, pub);
        } else if (!inited) {
            rc = MARS_RC_VALUE; rule = R_N1;
        } else switch (c.code) {
        case 0: rc = MARS_SelfTest(true); break;
        case 5: rc = MARS_PcrExtend(c.idx, c.dig); break;
        case 6: { uint8_t o[32]; rc = MARS_RegRead(c.idx, o); if (!rc) memcpy(nx.dout, o, 32); } break;
        case 7:
            if (c.regsel > 3 || c.ctxlen == 32) {
                uint8_t o[32];
                rc = MARS_Derive(c.regsel, ctx, c.ctxlen, o);
                if (!rc) memcpy(nx.dout, o, 32);
            } else { rc = MARS_RC_BUFFER; rule = R_N4; }
            break;
        case 8:
            if (c.regsel > 3 || c.ctxlen == 0 || c.ctxlen == 32)
                rc = MARS_DpDerive(c.regsel, c.ctxlen ? ctx : NULL, c.ctxlen);
            else { rc = MARS_RC_BUFFER; rule = R_N4; }
            break;
        case 10:
            if (c.regsel > 3 || (c.nlen == 32 && c.ctxlen == 32)) {
                uint8_t o[32];
                rc = MARS_Quote(c.regsel, nonce, c.nlen, ctx, c.ctxlen, o);
                if (!rc) { memcpy(nx.dout, o, 32); snapshot(nx.snap, c.regsel, nonce); }
            } else { rc = MARS_RC_BUFFER; rule = R_N4; }
            break;
        case 11:
            if (c.ctxlen == 32) {
                uint8_t o[32];
                rc = MARS_Sign(ctx, 32, c.dig, o);
                if (!rc) memcpy(nx.dout, o, 32);
            } else { rc = MARS_RC_BUFFER; rule = R_N4; }
            break;
        case 12:
            if (c.ctxlen == 32) {
                bool r = false;
                rc = MARS_SignatureVerify(c.restricted, ctx, 32, c.dig, c.sig, &r);
                if (!rc) nx.result = r;
            } else { rc = MARS_RC_BUFFER; rule = R_N4; }
            break;
        }
        if (known) { nx.rc = rc; nx.fail = 0; nx.st = inited; read_pcrs(&nx, inited); }
        rules[rule]++;

        if (known && same(&nx, &cur)) {               /* a CapabilityGet that changes the state */
            static const uint16_t pts[] = {1, 3, 8, 10};
            for (int k = 0; k < 4; k++) {
                cmd_t g = c;
                pub_t gx = nx;
                uint16_t cap = 0;
                g.code = 1; g.pt = pts[k];
                gx.rc = MARS_CapabilityGet(g.pt, &cap, sizeof cap);
                gx.cap = cap; gx.result = 0;
                memset(gx.dout, 0, 32);
                if (!same(&gx, &nx)) {
                    rules[R_EMU]++;
                    check(i, &g, &gx);
                    cur = gx;
                    break;
                }
            }
        }
        check(i, &c, &nx);
        if (known) cur = nx;
    }

    unsigned pairs = 0;
    for (int r = 0; r < 15; r++)
        for (int k = 0; k < 8; k++)
            pairs += cov[r][k] != 0;
    printf("compared %lu, mismatches %lu, command x rc pairs %u; rules", compared, mismatches, pairs);
    for (int r = 0; r < R_COUNT; r++)
        printf(" %s=%lu", rule_name[r], rules[r]);
    printf("\n%s fuzz\n", mismatches ? "FAIL" : "PASS");
    return mismatches != 0;
}

#ifdef MARS_GATE
static int user_main(int argc, char **argv) { (void)argc; (void)argv; return fuzz(); }
int main(int argc, char **argv) { gate_run_user(user_main, argc, argv); }
#else
int main(void) { return fuzz(); }
#endif
