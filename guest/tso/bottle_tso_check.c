/* bottle-tso-check: does x86 code see x86 memory ordering? And how fast does it run?
 *
 * Built as a static x86_64 program (no libraries needed under FEX):
 *   gcc -O2 -static -pthread -o bottle-tso-check.x86_64 bottle_tso_check.c
 *
 *   bottle-tso-check litmus [ms per CPU pair]
 *       Message passing on every pair of CPUs: one thread stores A then B, the other loads
 *       B then A. x86 (total store order) guarantees A >= B; a weaker order can show A < B.
 *       Prints "violations N" (0 = x86 ordering held) and per-pair counts.
 *   bottle-tso-check bench [threads]
 *       A fixed amount of multithreaded memory work; prints "bench MS ms".
 *
 * Run it under FEX with FEX_TSOENABLED=0 (FEX's own ordering off) to see what the hardware
 * does: violations > 0 on a plain Arm CPU, 0 with Apple's TSO mode on (bottle_tso.ko).
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define barrier() __asm__ __volatile__("" ::: "memory") /* compiler only, no fence */

struct line { volatile uint64_t v; char pad[120]; } __attribute__((aligned(128)));
static struct line A, B, STOP;

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int pin(int cpu) {
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(cpu, &s);
    return sched_setaffinity(0, sizeof s, &s);
}

struct job { int cpu; uint64_t seen, bad; };

static void *writer(void *arg) {
    struct job *j = arg;
    pin(j->cpu);
    for (uint64_t i = 1; !STOP.v; i++) {
        A.v = i;
        barrier();
        B.v = i;
        barrier();
    }
    return NULL;
}

static void *reader(void *arg) {
    struct job *j = arg;
    pin(j->cpu);
    uint64_t seen = 0, bad = 0;
    while (!STOP.v) {
        uint64_t b = B.v;
        barrier();
        uint64_t a = A.v;
        barrier();
        bad += a < b;
        seen++;
    }
    j->seen = seen;
    j->bad = bad;
    return NULL;
}

static int litmus(int ms) {
    int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 2) { printf("only one CPU: nothing to test\n"); return 2; }
    uint64_t total_bad = 0, total_seen = 0;
    char per[2048] = "";
    size_t off = 0;
    /* every CPU writes once and reads once: pairs (0,1) (1,2) ... (n-1,0) */
    for (int w = 0; w < n; w++) {
        int r = (w + 1) % n;
        struct job jw = {.cpu = w}, jr = {.cpu = r};
        pthread_t tw, tr;
        A.v = B.v = 0;
        STOP.v = 0;
        pthread_create(&tr, NULL, reader, &jr);
        pthread_create(&tw, NULL, writer, &jw);
        usleep((useconds_t)ms * 1000);
        STOP.v = 1;
        pthread_join(tw, NULL);
        pthread_join(tr, NULL);
        total_bad += jr.bad;
        total_seen += jr.seen;
        if (off < sizeof per - 40)
            off += snprintf(per + off, sizeof per - off, " %d>%d:%llu", w, r, (unsigned long long)jr.bad);
    }
    printf("violations %llu in %llu reads on %d CPUs (%d ms per pair)\n", (unsigned long long)total_bad,
           (unsigned long long)total_seen, n, ms);
    printf("pairs%s\n", per);
    return total_seen == 0 ? 2 : 0;
}

/* ---- bench: per thread, random read-modify-write and streaming passes over 8 MB, plus a
 * shared counter now and then: the kind of memory traffic game threads make. */
#define WORDS (1u << 20) /* 8 MB of uint64_t per thread */
#define ROUNDS 24

static volatile uint64_t shared_counter;

static void *work(void *arg) {
    uint64_t *a = arg, x = (uint64_t)(uintptr_t)arg | 1, sum = 0;
    for (uint32_t i = 0; i < WORDS; i++) a[i] = i * 2654435761u;
    for (int r = 0; r < ROUNDS; r++) {
        for (uint32_t i = 0; i < WORDS; i++) { /* random read-modify-write */
            x = x * 6364136223846793005ull + 1442695040888963407ull;
            uint32_t k = (uint32_t)(x >> 40) & (WORDS - 1);
            a[k] += x;
            sum += a[(k + 64) & (WORDS - 1)];
        }
        for (uint32_t i = 1; i < WORDS; i++) a[i] += a[i - 1] >> 3; /* streaming */
        __atomic_fetch_add(&shared_counter, 1, __ATOMIC_SEQ_CST);
    }
    a[0] = sum;
    return NULL;
}

static int bench(int threads) {
    pthread_t t[64];
    uint64_t *mem[64];
    if (threads < 1) threads = 1;
    if (threads > 64) threads = 64;
    for (int i = 0; i < threads; i++) {
        mem[i] = aligned_alloc(4096, WORDS * sizeof(uint64_t));
        if (!mem[i]) { printf("out of memory\n"); return 2; }
    }
    double t0 = now_ms();
    for (int i = 0; i < threads; i++) pthread_create(&t[i], NULL, work, mem[i]);
    for (int i = 0; i < threads; i++) pthread_join(t[i], NULL);
    double t1 = now_ms();
    printf("bench %.0f ms (%d threads)\n", t1 - t0, threads);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "litmus")) return litmus(argc >= 3 ? atoi(argv[2]) : 300);
    if (argc >= 2 && !strcmp(argv[1], "bench")) return bench(argc >= 3 ? atoi(argv[2]) : 4);
    fprintf(stderr, "usage: %s litmus [ms per CPU pair] | bench [threads]\n", argv[0]);
    return 2;
}
