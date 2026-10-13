/*
 * bottle-screen: the VM side of the SteamOS Bottle window on the Mac.
 *
 * Streams the X desktop (DISPLAY :1, where Steam and the games run) to one client as JPEG
 * frames and feeds the client's keyboard and mouse back in through XTest. Relative mouse
 * motion goes in as XTest relative motion, so games doing mouse-look (raw input in Wine)
 * get real deltas, which VNC can't provide.
 *
 *   bottle-screen [-d :1] [-p 4720] [-q 80] [-f 60] [-b bands]
 *
 * Listens on 127.0.0.1 only; Lima forwards the port to the Mac's localhost.
 *
 * Protocol (little endian). Every message: u8 type, u8 0, u16 0, u32 payload length, payload.
 *  server -> client
 *    1 HELLO  "BTLS" u16 version(1) u16 0 u32 width u32 height
 *    2 FRAME  u32 seq, u16 x, u16 y, u16 w, u16 h, u16 screen_w, u16 screen_h, JPEG bytes
 *             (the JPEG is the w x h rectangle at x,y; a whole screen unless the client asked
 *             for partial frames, see SETTINGS)
 *    3 CURSOR u8 visible   (0 when the app hid the pointer, e.g. a game doing mouse-look: the
 *                          client then captures the mouse and sends relative motion)
 *    4 RUMBLE u8 pad, u8 0, u16 strong, u16 weak, u16 duration ms (0,0 = stop)
 *    5 PAD_STATUS u8 pad, u8 ok (0: the VM can't create controllers; see /dev/uinput)
 *    6 STATS  u16 fps x10, u16 capture ms x100, u16 encode ms x100, u16 send ms x100,
 *             u32 bytes per frame, u16 sharp frames in the last second   (once a second, to
 *             clients that asked for partial frames)
 *    7 NOTICE u8 kind (0 news, 1 a problem), u8 0, u16 seconds to show it, UTF-8 text: a title
 *             line, then the details (something for the player to read on the Mac: why a game
 *             closed at launch, say). From files in ~/.cache/steamos-bottle/notices/ (NAME.txt:
 *             first line "kind seconds", then the text), sent once and removed.
 *  HELLO's version is 2 since RESIZE, NOTICE and HOST_STATS (an older server ignores them).
 *  client -> server
 *    1 KEY        u32 X keysym, u8 down
 *    2 MOVE_REL   i16 dx, i16 dy
 *    3 MOVE_ABS   u16 x, u16 y            (screen pixels; sent on as a relative move from where
 *                                          the pointer is, so raw input only ever sees deltas)
 *    4 BUTTON     u8 X button (1 left, 2 middle, 3 right, 8 back, 9 forward), u8 down
 *    5 WHEEL      i16 dx, i16 dy          (notches; dy > 0 = up, dx > 0 = right)
 *    6 SETTINGS   u8 jpeg quality (1-100, 0 = keep), u8 max fps (0 = keep)[, u8 features]
 *                 features bit 0: partial frames (only the changed rectangle; the client keeps
 *                 the rest), a sharp frame (quality 95, full colour detail) once the screen
 *                 has been still for 150 ms, and STATS
 *    7 RELEASE    release every key and button this client holds down (and center the pads)
 *    8 PAD        u8 pad (0-3), u8 connected, u16 buttons, i16 lx, ly, rx, ry (y > 0 = down),
 *                 u8 left trigger, u8 right trigger, i8 dpad x, i8 dpad y (y > 0 = down)
 *                 buttons: A B X Y LB RB Back Start Guide LS RS = bits 0-10
 *    9 RESIZE     u16 width, u16 height[, u16 game width, u16 game height]: the screen size
 *                 the window wants (its shape and size), and the size while a game runs (default
 *                 1920x1080; 0x0 = the window's). Done with bottle-resolution (xrandr): the
 *                 window's size while no game runs, the game size as soon as a game starts
 *                 (before its window appears: games set to 1920x1080 then get exactly that, the
 *                 path every game was tested on), back when it ends. Never in the middle of a
 *                 game. A client that never sends it leaves the screen as it is.
 *   10 HOST_STATS u8 GPU load % (255 = unknown), u8 0, u16 GPU temperature C x10 (0 = unknown),
 *                 u32 GPU memory in use MB, u32 GPU memory MB, UTF-8 GPU name: the Mac's GPU,
 *                 once a second; written to /dev/shm/steamos-bottle-host-stats for Steam's
 *                 performance monitor (guest/nvml).
 *
 * Game controllers: each pad the client reports becomes a virtual Xbox 360 pad (uinput,
 * the same events and IDs as Linux's xpad driver), which SDL, Proton and games all know.
 * Its rumble goes back to the client. Needs rw access to /dev/uinput (bottle update).
 * Once plugged in, a pad stays plugged in until bottle-screen exits: when the Mac's controller
 * drops out or the app closes it's only centered (games freeze on mid-game unplugging).
 *
 * Capture: XDamage tells when and where the screen changed; the main thread grabs it with
 * MIT-SHM (a couple of ms) and hands it to an encoder thread, which JPEG-encodes the changed
 * rectangle and sends it. Two buffers: the next frame is captured while the last one is still
 * being encoded. The main thread never waits for the network, so input stays prompt. A big
 * rectangle is encoded in horizontal bands at once on several threads (each band its own FRAME
 * message, to clients that take partial frames): a whole 1080p screen in about a third of the
 * time, which bigger screens (the window's own size, RESIZE) need.
 *
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/XTest.h>
#include <X11/extensions/Xdamage.h>
#include <X11/extensions/Xfixes.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <dirent.h>
#include <spawn.h>
#include <time.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <sys/ioctl.h>
#include <turbojpeg.h>
#include <unistd.h>

#define MSG_HELLO 1
#define MSG_FRAME 2
#define MSG_STATS 6
#define MSG_CURSOR 3
#define MSG_RUMBLE 4
#define MSG_PAD_STATUS 5
#define MSG_NOTICE 7
#define IN_KEY 1
#define IN_MOVE_REL 2
#define IN_MOVE_ABS 3
#define IN_BUTTON 4
#define IN_WHEEL 5
#define IN_SETTINGS 6
#define IN_RELEASE 7
#define IN_PAD 8
#define IN_RESIZE 9
#define IN_HOST_STATS 10

static int g_verbose;
/* With the time of day, so events line up with the game's log and the Mac's. */
static void log_stamp(void) {
    time_t t = time(NULL);
    struct tm tm;
    char b[16];
    strftime(b, sizeof b, "%H:%M:%S", localtime_r(&t, &tm));
    fprintf(stderr, "%s bottle-screen: ", b);
}
#define LOG(...) do { log_stamp(); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#define VLOG(...) do { if (g_verbose) LOG(__VA_ARGS__); } while (0)

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static uint16_t get16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static int send_all(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t k = send(fd, p, n, MSG_NOSIGNAL);
        if (k < 0) { if (errno == EINTR) continue; return -1; }
        p += k; n -= (size_t)k;
    }
    return 0;
}

/* ---------------------------------------------------------------- encoder */

/* A captured screen and the part of it to send. */
typedef struct {
    uint8_t *pix;        /* the whole screen, BGRX, stride w*4 */
    int sw, sh;          /* screen size */
    int x, y, w, h;      /* rectangle to send */
    int quality, samp;   /* JPEG quality and chroma subsampling (TJSAMP_*) */
    int sharp;           /* the still-screen refresh */
    uint32_t seq;
} Job;

/* The encoder thread owns `job` while busy; the main thread may queue one more (`next`, in the
 * other buffer). A slow network makes us skip frames instead of queueing them. */
typedef struct {
    pthread_mutex_t m;
    pthread_cond_t cv;
    int busy;            /* encoder owns job (and next, when has_next) */
    int has_next;
    Job job, next;
    uint8_t *bufs[2];
    int quit;
    int client;          /* socket, -1 = none (protected by m) */
    int quality;         /* for frames in motion (client setting) */
    int features;        /* client's SETTINGS features */
    double ms_capture, ms_encode, ms_send; /* stats */
    unsigned long frames, bytes, sharp;
} Encoder;

static Encoder g_enc = {.m = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER, .client = -1, .quality = 80};
/* Writes to the client socket (frames from the encoder, small messages from the main thread)
 * take turns on this lock, so messages never interleave. */
static pthread_mutex_t g_send_m = PTHREAD_MUTEX_INITIALIZER;

static void encoder_buffers(int w, int h) {   /* with m held and the encoder idle */
    for (int k = 0; k < 2; k++) {
        free(g_enc.bufs[k]);
        g_enc.bufs[k] = malloc((size_t)w * h * 4);
    }
    g_enc.has_next = 0;
}

static void send_stats(int fd, double secs) {
    uint8_t m[8 + 16] = {MSG_STATS, 0, 0, 0};
    unsigned long n = g_enc.frames ? g_enc.frames : 1;
    put32(m + 4, 16);
    put16(m + 8, (uint16_t)(g_enc.frames * 10.0 / secs));
    put16(m + 10, (uint16_t)(g_enc.ms_capture * 100 / n));
    put16(m + 12, (uint16_t)(g_enc.ms_encode * 100 / n));
    put16(m + 14, (uint16_t)(g_enc.ms_send * 100 / n));
    put32(m + 16, (uint32_t)(g_enc.bytes / n));
    put16(m + 20, (uint16_t)g_enc.sharp);
    put16(m + 22, 0);
    pthread_mutex_lock(&g_send_m);
    send_all(fd, m, sizeof m);
    pthread_mutex_unlock(&g_send_m);
}

/* Bands: a big rectangle is cut into horizontal strips (whole 16-row JPEG blocks) that are
 * encoded at once, band 0 on the encoder thread and the others on helper threads, then sent in
 * order, each as a FRAME of its own. Only for clients that take partial frames. */
#define MAX_BANDS 4
typedef struct {
    pthread_t th;
    tjhandle tj;
    unsigned char *jpeg;
    unsigned long cap, size;
    const uint8_t *src;
    int y, w, h, stride, samp, quality, rc;
    int go, done;
} Band;
static Band g_band[MAX_BANDS];
static int g_nbands = 1;           /* -b N; by default from the VM's processors */
static pthread_mutex_t g_band_m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_band_cv = PTHREAD_COND_INITIALIZER;

static void band_encode(Band *b) {
    unsigned long need = tjBufSize(b->w, b->h, TJSAMP_444);
    if (b->cap < need) {
        if (b->jpeg) tjFree(b->jpeg);
        b->jpeg = tjAlloc((int)need);
        b->cap = b->jpeg ? need : 0;
    }
    b->size = b->cap;
    b->rc = b->jpeg && b->tj ? tjCompress2(b->tj, b->src, b->w, b->stride, b->h, TJPF_BGRX, &b->jpeg, &b->size,
                                           b->samp, b->quality, TJFLAG_FASTDCT | TJFLAG_NOREALLOC) : -1;
}

static void *band_main(void *arg) {
    Band *b = arg;
    pthread_mutex_lock(&g_band_m);
    for (;;) {
        while (!b->go) pthread_cond_wait(&g_band_cv, &g_band_m);
        b->go = 0;
        pthread_mutex_unlock(&g_band_m);
        band_encode(b);
        pthread_mutex_lock(&g_band_m);
        b->done = 1;
        pthread_cond_broadcast(&g_band_cv);
    }
    return NULL;
}

static void bands_init(void) {
    for (int k = 0; k < g_nbands; k++) {
        g_band[k].tj = tjInitCompress();
        if (k > 0 && pthread_create(&g_band[k].th, NULL, band_main, &g_band[k]) != 0) { g_nbands = k; break; }
    }
}

static void *encoder_main(void *arg) {
    (void)arg;
    double t_stats = now_ms();
    pthread_mutex_lock(&g_enc.m);
    for (;;) {
        while (!g_enc.busy && !g_enc.quit) pthread_cond_wait(&g_enc.cv, &g_enc.m);
        if (g_enc.quit) break;
        Job j = g_enc.job;
        int fd = g_enc.client, features = g_enc.features;
        pthread_mutex_unlock(&g_enc.m);

        double t0 = now_ms();
        /* how many bands: one unless the client takes partial frames and the rectangle is big */
        int nb = 1;
        if ((features & 1) && g_nbands > 1 && (long)j.w * j.h >= 900000L && j.h >= 64 * g_nbands) nb = g_nbands;
        int rows = ((j.h + nb - 1) / nb + 15) & ~15;
        int used = 0;
        for (int k = 0; k < nb; k++) {
            int y0 = k * rows, hh = j.h - y0 < rows ? j.h - y0 : rows;
            if (hh <= 0) break;
            Band *b = &g_band[k];
            b->src = j.pix + ((size_t)(j.y + y0) * j.sw + j.x) * 4;
            b->y = j.y + y0; b->w = j.w; b->h = hh; b->stride = j.sw * 4;
            b->samp = j.samp; b->quality = j.quality;
            used++;
        }
        if (used > 1) {
            pthread_mutex_lock(&g_band_m);
            for (int k = 1; k < used; k++) { g_band[k].done = 0; g_band[k].go = 1; }
            pthread_cond_broadcast(&g_band_cv);
            pthread_mutex_unlock(&g_band_m);
        }
        band_encode(&g_band[0]);
        if (used > 1) {
            pthread_mutex_lock(&g_band_m);
            for (int k = 1; k < used; k++)
                while (!g_band[k].done) pthread_cond_wait(&g_band_cv, &g_band_m);
            pthread_mutex_unlock(&g_band_m);
        }
        double t1 = now_ms();
        int ok = fd >= 0;
        unsigned long jsize = 0;
        for (int k = 0; k < used; k++) {
            if (g_band[k].rc != 0) { ok = 0; LOG("jpeg: %s", g_band[k].tj ? tjGetErrorStr2(g_band[k].tj) : "no encoder"); }
            jsize += g_band[k].size;
        }
        if (ok) {
            pthread_mutex_lock(&g_send_m);
            for (int k = 0; k < used && ok; k++) {
                Band *b = &g_band[k];
                uint8_t hdr[8 + 16];
                hdr[0] = MSG_FRAME; hdr[1] = hdr[2] = hdr[3] = 0;
                put32(hdr + 4, 16 + (uint32_t)b->size);
                put32(hdr + 8, j.seq);
                put16(hdr + 12, (uint16_t)j.x); put16(hdr + 14, (uint16_t)b->y);
                put16(hdr + 16, (uint16_t)b->w); put16(hdr + 18, (uint16_t)b->h);
                put16(hdr + 20, (uint16_t)j.sw); put16(hdr + 22, (uint16_t)j.sh);
                if (send_all(fd, hdr, sizeof hdr) < 0 || send_all(fd, b->jpeg, b->size) < 0) {
                    VLOG("send failed: %s", strerror(errno));
                    shutdown(fd, SHUT_RDWR); /* main thread notices and cleans up */
                    ok = 0;
                }
            }
            pthread_mutex_unlock(&g_send_m);
        }
        double t2 = now_ms();

        pthread_mutex_lock(&g_enc.m);
        if (g_enc.has_next) {          /* the next frame is already captured: straight on */
            g_enc.job = g_enc.next;
            g_enc.has_next = 0;
        } else {
            g_enc.busy = 0;
        }
        if (ok) {
            g_enc.ms_encode += t1 - t0; g_enc.ms_send += t2 - t1;
            g_enc.frames++; g_enc.bytes += jsize;
            if (j.sharp) g_enc.sharp++;
        }
        if (t2 - t_stats >= 1000 && fd >= 0 && g_enc.frames) {
            if (features & 1) send_stats(fd, (t2 - t_stats) / 1000);
            if (g_verbose && t2 - t_stats >= 5000)
                LOG("%.1f fps, %.0f KB/frame, capture %.1f ms, encode %.1f ms, send %.1f ms",
                    g_enc.frames * 1000.0 / (t2 - t_stats), g_enc.bytes / 1024.0 / g_enc.frames,
                    g_enc.ms_capture / g_enc.frames, g_enc.ms_encode / g_enc.frames, g_enc.ms_send / g_enc.frames);
            g_enc.frames = g_enc.bytes = g_enc.sharp = 0;
            g_enc.ms_capture = g_enc.ms_encode = g_enc.ms_send = 0;
            t_stats = t2;
        }
        pthread_cond_broadcast(&g_enc.cv);
    }
    pthread_mutex_unlock(&g_enc.m);
    return NULL;
}

/* ---------------------------------------------------------------- capture */

typedef struct {
    Display *dpy;
    Window root;
    int w, h;
    XImage *img;
    XShmSegmentInfo shm;
    int have_shm;
    int damage_event;
    Damage damage;
} Grab;

static void capture_free(Grab *s) {
    if (!s->img) return;
    if (s->have_shm) {
        XShmDetach(s->dpy, &s->shm);
        XSync(s->dpy, False);
        shmdt(s->shm.shmaddr);
    }
    s->img->data = s->have_shm ? NULL : s->img->data;
    XDestroyImage(s->img);
    s->img = NULL;
}

static int capture_setup(Grab *s) {
    XWindowAttributes a;
    XGetWindowAttributes(s->dpy, s->root, &a);
    s->w = a.width; s->h = a.height;
    s->have_shm = XShmQueryExtension(s->dpy);
    if (s->have_shm) {
        s->img = XShmCreateImage(s->dpy, a.visual, a.depth, ZPixmap, NULL, &s->shm, s->w, s->h);
        s->shm.shmid = shmget(IPC_PRIVATE, (size_t)s->img->bytes_per_line * s->h, IPC_CREAT | 0600);
        s->shm.shmaddr = s->img->data = shmat(s->shm.shmid, NULL, 0);
        s->shm.readOnly = False;
        XShmAttach(s->dpy, &s->shm);
        XSync(s->dpy, False);
        shmctl(s->shm.shmid, IPC_RMID, NULL); /* freed when both sides detach */
    } else {
        s->img = NULL; /* XGetImage per frame */
    }
    LOG("screen %dx%d depth %d, %s", s->w, s->h, a.depth, s->have_shm ? "MIT-SHM capture" : "XGetImage capture");
    return 0;
}

/* Grab the screen into pix (BGRX, stride w*4). */
static int capture(Grab *s, uint8_t *pix) {
    XImage *img = s->img;
    if (s->have_shm) {
        if (!XShmGetImage(s->dpy, s->root, img, 0, 0, AllPlanes)) return -1;
    } else {
        img = XGetImage(s->dpy, s->root, 0, 0, s->w, s->h, AllPlanes, ZPixmap);
        if (!img) return -1;
    }
    if (img->bits_per_pixel != 32) { LOG("unsupported screen format: %d bpp", img->bits_per_pixel); return -1; }
    for (int y = 0; y < s->h; y++)
        memcpy(pix + (size_t)y * s->w * 4, img->data + (size_t)y * img->bytes_per_line, (size_t)s->w * 4);
    if (!s->have_shm) XDestroyImage(img);
    return 0;
}

/* The bounds of what changed since the last call (and forget it); width 0 = nothing. */
static XRectangle damage_take(Grab *s) {
    XRectangle b = {0, 0, (unsigned short)s->w, (unsigned short)s->h};
    if (s->damage_event < 0) return b;
    XserverRegion parts = XFixesCreateRegion(s->dpy, NULL, 0);
    XDamageSubtract(s->dpy, s->damage, None, parts);
    int n = 0;
    XRectangle bounds = {0, 0, 0, 0};
    XRectangle *rects = XFixesFetchRegionAndBounds(s->dpy, parts, &n, &bounds);
    if (rects) XFree(rects);
    XFixesDestroyRegion(s->dpy, parts);
    if (n <= 0) { b.width = b.height = 0; return b; }
    return bounds;
}

/* Grow to 16-pixel steps (whole JPEG blocks, so the edges match the picture around them) and
 * keep it on the screen. */
static void align_rect(XRectangle *r, int sw, int sh) {
    int x0 = r->x < 0 ? 0 : r->x & ~15, y0 = r->y < 0 ? 0 : r->y & ~15;
    int x1 = (r->x + r->width + 15) & ~15, y1 = (r->y + r->height + 15) & ~15;
    if (x1 > sw) x1 = sw;
    if (y1 > sh) y1 = sh;
    r->x = (short)x0; r->y = (short)y0;
    r->width = (unsigned short)(x1 > x0 ? x1 - x0 : 0);
    r->height = (unsigned short)(y1 > y0 ? y1 - y0 : 0);
}

/* A small message from the main thread. The encoder thread may be sending a frame and the
 * client parses whole messages, so the two writers take turns (g_send_m). */
static void send_small(int fd, uint8_t type, const uint8_t *body, uint32_t len) {
    uint8_t m[8 + 32] = {type, 0, 0, 0};
    if (fd < 0 || len > 32) return;
    put32(m + 4, len);
    memcpy(m + 8, body, len);
    pthread_mutex_lock(&g_send_m);
    send_all(fd, m, 8 + len);
    pthread_mutex_unlock(&g_send_m);
}

/* A message of any length from the main thread (NOTICE). */
static void send_msg(int fd, uint8_t type, const uint8_t *body, uint32_t len) {
    uint8_t h[8] = {type, 0, 0, 0};
    if (fd < 0) return;
    put32(h + 4, len);
    pthread_mutex_lock(&g_send_m);
    if (send_all(fd, h, sizeof h) == 0) send_all(fd, body, len);
    pthread_mutex_unlock(&g_send_m);
}

/* ---------------------------------------------------------------- the Mac's GPU numbers */

/* HOST_STATS: what the Mac measures of its GPU, for Steam's performance monitor (guest/nvml reads
 * the file). Written whole and renamed, so a reader never sees half of it. */
static void host_stats(const uint8_t *p, uint32_t len) {
    if (len < 12) return;
    char name[128] = "";
    uint32_t n = len - 12 < sizeof name - 1 ? len - 12 : (uint32_t)sizeof name - 1;
    for (uint32_t i = 0; i < n; i++) name[i] = (p[12 + i] == '\n' || p[12 + i] == '\r') ? ' ' : (char)p[12 + i];
    name[n] = 0;
    const char *path = "/dev/shm/steamos-bottle-host-stats", *tmp = "/dev/shm/steamos-bottle-host-stats.tmp";
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "time %ld\n", (long)time(NULL));
    if (p[0] != 255) fprintf(f, "gpu_util %u\n", p[0]);
    if (get16(p + 2)) fprintf(f, "gpu_temp %.1f\n", get16(p + 2) / 10.0);
    if (get32(p + 8)) fprintf(f, "gpu_mem_used_mb %u\ngpu_mem_total_mb %u\n", get32(p + 4), get32(p + 8));
    if (name[0]) fprintf(f, "gpu_name %s\n", name);
    if (fclose(f) == 0) rename(tmp, path);
}

/* ---------------------------------------------------------------- the screen's size */

/* RESIZE: the size the Mac window wants and the size for games, done with bottle-resolution
 * (xrandr). The screen server notices the new size itself (the geometry check in main). */
static int g_want_w, g_want_h;      /* the window's; 0: nothing asked (the screen stays as it is) */
static int g_game_w = 1920, g_game_h = 1080;   /* while a game runs; 0: the window's */
static int g_was_game = -1;         /* a game was running at the last look (-1: not looked yet) */
static pid_t g_resize_pid;          /* bottle-resolution running */
extern char **environ;

/* A game is running: Steam's game launcher or Wine, as bottle-busy checks. */
static int game_running(void) {
    DIR *d = opendir("/proc");
    if (!d) return 0;
    struct dirent *e;
    int found = 0;
    while (!found && (e = readdir(d))) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        char path[300], buf[512];
        snprintf(path, sizeof path, "/proc/%s/cmdline", e->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        size_t n = fread(buf, 1, sizeof buf - 1, f);
        fclose(f);
        for (size_t i = 0; i < n; i++) if (!buf[i]) buf[i] = ' ';
        buf[n] = 0;
        if ((strstr(buf, "reaper") && strstr(buf, "SteamLaunch")) || strstr(buf, "wineserver")) found = 1;
    }
    closedir(d);
    return found;
}

static void resize_to(Grab *s, int w, int h, const char *why) {
    char ws[16], hs[16];
    snprintf(ws, sizeof ws, "%d", w);
    snprintf(hs, sizeof hs, "%d", h);
    char *argv[] = {"bottle-resolution", ws, hs, NULL};
    LOG("screen %dx%d -> %dx%d (%s)", s->w, s->h, w, h, why);
    if (posix_spawnp(&g_resize_pid, "bottle-resolution", NULL, NULL, argv, environ) != 0) {
        LOG("can't run bottle-resolution: %s", strerror(errno));
        g_resize_pid = 0;
    }
}

/* Once a second, while the window has asked for a size: a game that just started gets the game
 * size; with no game running the screen gets the window's size. Nothing changes mid-game. */
static void resize_check(Grab *s) {
    if (g_resize_pid > 0) {
        int st;
        pid_t r = waitpid(g_resize_pid, &st, WNOHANG);
        if (r == 0) return;   /* still at it */
        if (r == g_resize_pid && !(WIFEXITED(st) && WEXITSTATUS(st) == 0)) LOG("bottle-resolution failed (status %d)", st);
        g_resize_pid = 0;
    }
    if (!g_want_w) return;
    int game = game_running(), started = game && g_was_game == 0;
    g_was_game = game;
    if (started && g_game_w && (s->w != g_game_w || s->h != g_game_h)) {
        resize_to(s, g_game_w, g_game_h, "a game is starting");
    } else if (!game && (s->w != g_want_w || s->h != g_want_h)) {
        resize_to(s, g_want_w, g_want_h, "the window's size");
    }
}

/* ---------------------------------------------------------------- notices for the Mac */

/* Files in ~/.cache/steamos-bottle/notices/ (NAME.txt, written by bottle-whyquit, say): the first
 * line "kind seconds", then the text. Each goes to the window once and is removed; with no
 * window there, it waits up to 5 minutes. */
static void notices_check(int cfd) {
    const char *home = getenv("HOME");
    if (!home) return;
    char dir[512];
    snprintf(dir, sizeof dir, "%s/.cache/steamos-bottle/notices", home);
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t n = strlen(e->d_name);
        if (n < 5 || strcmp(e->d_name + n - 4, ".txt")) continue;
        char path[800];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        struct stat st;
        if (stat(path, &st) != 0) continue;
        if (cfd < 0) {
            if (time(NULL) - st.st_mtime > 300) unlink(path);
            continue;
        }
        FILE *f = fopen(path, "r");
        if (!f) continue;
        uint8_t body[4 + 1500];
        int kind = 0, secs = 12;
        char first[64] = "";
        if (fgets(first, sizeof first, f)) sscanf(first, "%d %d", &kind, &secs);
        size_t len = fread(body + 4, 1, sizeof body - 4, f);
        fclose(f);
        unlink(path);
        if (!len) continue;
        body[0] = (uint8_t)(kind ? 1 : 0); body[1] = 0;
        put16(body + 2, (uint16_t)(secs < 3 ? 3 : secs > 120 ? 120 : secs));
        send_msg(cfd, MSG_NOTICE, body, (uint32_t)(4 + len));
        char title[120];
        snprintf(title, sizeof title, "%.*s", (int)(strcspn((char *)body + 4, "\n") < 100 ? strcspn((char *)body + 4, "\n") : 100), (char *)body + 4);
        LOG("notice to the window: %s", title);
    }
    closedir(d);
}

/* ---------------------------------------------------------------- game controllers */

#define MAX_PADS 4
#define MAX_EFFECTS 16
static const int pad_keys[11] = {BTN_A, BTN_B, BTN_X, BTN_Y, BTN_TL, BTN_TR,
                                 BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR};
static const int pad_axes[8] = {ABS_X, ABS_Y, ABS_RX, ABS_RY, ABS_Z, ABS_RZ, ABS_HAT0X, ABS_HAT0Y};

typedef struct {
    int fd;                      /* uinput, -1 when the pad isn't there */
    uint16_t buttons;
    int axis[8];                 /* same order as pad_axes */
    struct { uint16_t strong, weak, ms; } fx[MAX_EFFECTS];
    int playing;                 /* effect id rumbling now, or -1 */
} Pad;

static Pad g_pads[MAX_PADS];
static int g_uinput_failed;      /* told the client once */

static void pads_init(void) {
    for (int i = 0; i < MAX_PADS; i++) { g_pads[i].fd = -1; g_pads[i].playing = -1; }
}

static int pad_create(int i) {
    Pad *p = &g_pads[i];
    int fd = open("/dev/uinput", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    int ok = ioctl(fd, UI_SET_EVBIT, EV_KEY) == 0 && ioctl(fd, UI_SET_EVBIT, EV_ABS) == 0 &&
             ioctl(fd, UI_SET_EVBIT, EV_FF) == 0 && ioctl(fd, UI_SET_FFBIT, FF_RUMBLE) == 0;
    for (int k = 0; ok && k < 11; k++) ok = ioctl(fd, UI_SET_KEYBIT, pad_keys[k]) == 0;
    for (int a = 0; ok && a < 8; a++) ok = ioctl(fd, UI_SET_ABSBIT, pad_axes[a]) == 0;
    char phys[32];
    snprintf(phys, sizeof phys, "steamos-bottle/pad%d", i);   /* udev rule: games may open it */
    if (ok) ioctl(fd, UI_SET_PHYS, phys);
    struct uinput_setup us = {0};
    us.id.bustype = BUS_USB;
    us.id.vendor = 0x045e;    /* Microsoft Xbox 360 controller, as the xpad driver reports it */
    us.id.product = 0x028e;
    us.id.version = 0x0114;
    us.ff_effects_max = MAX_EFFECTS;
    snprintf(us.name, sizeof us.name, "Microsoft X-Box 360 pad %d", i);
    ok = ok && ioctl(fd, UI_DEV_SETUP, &us) == 0;
    for (int a = 0; ok && a < 8; a++) {
        struct uinput_abs_setup as = {.code = (uint16_t)pad_axes[a]};
        if (a < 4) { as.absinfo.minimum = -32768; as.absinfo.maximum = 32767; as.absinfo.fuzz = 16; as.absinfo.flat = 128; }
        else if (a < 6) { as.absinfo.minimum = 0; as.absinfo.maximum = 255; }
        else { as.absinfo.minimum = -1; as.absinfo.maximum = 1; }
        ok = ioctl(fd, UI_ABS_SETUP, &as) == 0;
    }
    if (!ok || ioctl(fd, UI_DEV_CREATE) != 0) {
        LOG("can't set up controller %d: %s", i, strerror(errno));
        close(fd);
        return -1;
    }
    memset(p, 0, sizeof *p);
    p->fd = fd;
    p->playing = -1;
    LOG("controller %d connected (virtual Xbox 360 pad)", i);
    return 0;
}

static void pad_set(int i, uint16_t buttons, const int *axis);

/* The Mac's controller went away (or the app closed): the VM's pad stays plugged in, centered
 * and still. Unplugging it mid-game makes Windows games re-scan their devices, and some (Devil
 * May Cry 5) stop drawing until the next controller change. The pad goes only with bottle-screen. */
static void pad_idle(int i, int cfd, const char *why) {
    static const int zero[8];
    Pad *p = &g_pads[i];
    if (p->fd < 0) return;
    pad_set(i, 0, zero);
    if (p->playing >= 0 && cfd >= 0) {   /* stop its rumble on the Mac */
        uint8_t b[8] = {(uint8_t)i};
        send_small(cfd, MSG_RUMBLE, b, sizeof b);
    }
    p->playing = -1;
    if (why) LOG("controller %d: %s; the VM's pad stays plugged in (centered)", i, why);
}

static void emit(struct input_event *ev, int *n, int type, int code, int value) {
    memset(&ev[*n], 0, sizeof ev[*n]);
    ev[*n].type = (uint16_t)type;
    ev[*n].code = (uint16_t)code;
    ev[*n].value = value;
    (*n)++;
}

/* Send what changed since the last state, then a report. */
static void pad_set(int i, uint16_t buttons, const int *axis) {
    Pad *p = &g_pads[i];
    struct input_event ev[24];
    int n = 0;
    for (int k = 0; k < 11; k++)
        if (((buttons ^ p->buttons) >> k) & 1) emit(ev, &n, EV_KEY, pad_keys[k], (buttons >> k) & 1);
    for (int a = 0; a < 8; a++)
        if (axis[a] != p->axis[a]) emit(ev, &n, EV_ABS, pad_axes[a], axis[a]);
    if (!n) return;
    emit(ev, &n, EV_SYN, SYN_REPORT, 0);
    if (write(p->fd, ev, sizeof ev[0] * (size_t)n) < 0) VLOG("controller %d: write: %s", i, strerror(errno));
    p->buttons = buttons;
    memcpy(p->axis, axis, sizeof p->axis);
}

static void pads_center(void) {
    static const int zero[8];
    for (int i = 0; i < MAX_PADS; i++)
        if (g_pads[i].fd >= 0) pad_set(i, 0, zero);
}

static void pad_message(const uint8_t *m, int cfd) {
    int i = m[0];
    if (i >= MAX_PADS) return;
    if (!m[1]) { pad_idle(i, cfd, "the Mac's controller disconnected"); return; }
    if (g_pads[i].fd < 0 && pad_create(i) < 0) {
        if (!g_uinput_failed) {
            LOG("no game controllers: can't use /dev/uinput (%s); run bottle update on the Mac", strerror(errno));
            uint8_t b[2] = {(uint8_t)i, 0};
            send_small(cfd, MSG_PAD_STATUS, b, sizeof b);
        }
        g_uinput_failed = 1;
        return;
    }
    if (g_uinput_failed) {   /* works again (after bottle update): say so */
        uint8_t b[2] = {(uint8_t)i, 1};
        send_small(cfd, MSG_PAD_STATUS, b, sizeof b);
        g_uinput_failed = 0;
    }
    int axis[8] = {(int16_t)get16(m + 4), (int16_t)get16(m + 6), (int16_t)get16(m + 8), (int16_t)get16(m + 10),
                   m[12], m[13], (int8_t)m[14], (int8_t)m[15]};
    for (int a = 6; a < 8; a++) axis[a] = axis[a] < 0 ? -1 : axis[a] > 0 ? 1 : 0;
    pad_set(i, get16(m + 2) & 0x7ff, axis);
}

/* The game's side of a pad: rumble effects are uploaded, erased and played through uinput.
 * Uploads and erases wait for our answer, so they're answered right away. */
static void pad_events(int i, int cfd) {
    Pad *p = &g_pads[i];
    struct input_event ev;
    while (p->fd >= 0 && read(p->fd, &ev, sizeof ev) == (ssize_t)sizeof ev) {
        if (ev.type == EV_UINPUT && ev.code == UI_FF_UPLOAD) {
            struct uinput_ff_upload up = {.request_id = (uint32_t)ev.value};
            if (ioctl(p->fd, UI_BEGIN_FF_UPLOAD, &up) != 0) continue;
            int id = up.effect.id;
            if (id >= 0 && id < MAX_EFFECTS) {
                if (up.effect.type == FF_RUMBLE) {
                    p->fx[id].strong = up.effect.u.rumble.strong_magnitude;
                    p->fx[id].weak = up.effect.u.rumble.weak_magnitude;
                } else {
                    p->fx[id].strong = p->fx[id].weak = 0;
                }
                p->fx[id].ms = up.effect.replay.length;
                up.retval = 0;
            } else {
                up.retval = -EINVAL;
            }
            ioctl(p->fd, UI_END_FF_UPLOAD, &up);
            if (id == p->playing) {   /* changed while playing (SDL updates rumble this way) */
                uint8_t b[8] = {(uint8_t)i, 0};
                put16(b + 2, p->fx[id].strong); put16(b + 4, p->fx[id].weak); put16(b + 6, p->fx[id].ms);
                send_small(cfd, MSG_RUMBLE, b, sizeof b);
            }
        } else if (ev.type == EV_UINPUT && ev.code == UI_FF_ERASE) {
            struct uinput_ff_erase er = {.request_id = (uint32_t)ev.value};
            if (ioctl(p->fd, UI_BEGIN_FF_ERASE, &er) != 0) continue;
            er.retval = 0;
            ioctl(p->fd, UI_END_FF_ERASE, &er);
            if ((int)er.effect_id == p->playing) {
                uint8_t b[8] = {(uint8_t)i};
                send_small(cfd, MSG_RUMBLE, b, sizeof b);
                p->playing = -1;
            }
        } else if (ev.type == EV_FF && ev.code < MAX_EFFECTS) {
            uint8_t b[8] = {(uint8_t)i, 0};
            if (ev.value > 0) {
                p->playing = ev.code;
                put16(b + 2, p->fx[ev.code].strong); put16(b + 4, p->fx[ev.code].weak);
                put16(b + 6, p->fx[ev.code].ms);
            } else if (ev.code == p->playing) {
                p->playing = -1;
            } else {
                continue;
            }
            send_small(cfd, MSG_RUMBLE, b, sizeof b);
        }
    }
}

/* ---------------------------------------------------------------- input */

static int g_client_fd = -1;     /* for messages back to the client from input handling */
static unsigned char g_keys_down[256];
static unsigned char g_buttons_down[32];

/* A press lasts at least MIN_HOLD_MS. Many games read the mouse buttons and keys once a frame
 * (their state, not the events): a click whose press and release reach the VM together, as
 * happens when input arrives in a burst (the VM busy with the game, the Mac app or the network
 * catching up), is over before the game looks, and the game never sees it. So a release that
 * comes sooner than that after its press waits until then (50 ms: one frame even at 20 fps). */
#define MIN_HOLD_MS 50.0
static double g_key_at[256], g_button_at[32];     /* when it went down */
static double g_key_due[256], g_button_due[32];   /* its release waits until then (0: none) */
static int g_pending;                             /* releases waiting */
static unsigned g_held_longer;                    /* how many waited (logged once a minute) */

static void press(Display *dpy, int button, unsigned code, int down) {
    double *at = button ? &g_button_at[code] : &g_key_at[code];
    double *due = button ? &g_button_due[code] : &g_key_due[code];
    unsigned char *is_down = button ? &g_buttons_down[code] : &g_keys_down[code];
    if (down) {
        if (*due > 0) {   /* pressed again while its release waited: release it first */
            if (button) XTestFakeButtonEvent(dpy, code, False, CurrentTime);
            else XTestFakeKeyEvent(dpy, code, False, CurrentTime);
            *due = 0;
            g_pending--;
        }
        if (button) XTestFakeButtonEvent(dpy, code, True, CurrentTime);
        else XTestFakeKeyEvent(dpy, code, True, CurrentTime);
        *is_down = 1;
        *at = now_ms();
        return;
    }
    if (!*is_down || *due > 0) return;   /* never pressed here, or its release is waiting */
    if (now_ms() - *at < MIN_HOLD_MS) {
        *due = *at + MIN_HOLD_MS;
        g_pending++;
        g_held_longer++;
        return;
    }
    if (button) XTestFakeButtonEvent(dpy, code, False, CurrentTime);
    else XTestFakeKeyEvent(dpy, code, False, CurrentTime);
    *is_down = 0;
}

/* Sends the releases whose time has come; returns the ms until the next one, or -1. */
static int releases_due(Display *dpy) {
    if (!g_pending) return -1;
    double t = now_ms(), next = 0;
    int sent = 0;
    for (int i = 0; i < 256 + 32; i++) {
        int button = i >= 256;
        unsigned code = button ? (unsigned)(i - 256) : (unsigned)i;
        double *due = button ? &g_button_due[code] : &g_key_due[code];
        if (*due <= 0) continue;
        if (*due <= t) {
            if (button) XTestFakeButtonEvent(dpy, code, False, CurrentTime);
            else XTestFakeKeyEvent(dpy, code, False, CurrentTime);
            if (button) g_buttons_down[code] = 0; else g_keys_down[code] = 0;
            *due = 0;
            g_pending--;
            sent = 1;
        } else if (next == 0 || *due < next) {
            next = *due;
        }
    }
    if (sent) XFlush(dpy);
    return next > 0 ? (int)(next - t) + 1 : -1;
}

static void release_all(Display *dpy) {
    for (int k = 0; k < 256; k++)
        if (g_keys_down[k]) { XTestFakeKeyEvent(dpy, (unsigned)k, False, CurrentTime); g_keys_down[k] = 0; }
    for (int b = 1; b < 32; b++)
        if (g_buttons_down[b]) { XTestFakeButtonEvent(dpy, (unsigned)b, False, CurrentTime); g_buttons_down[b] = 0; }
    memset(g_key_due, 0, sizeof g_key_due);
    memset(g_button_due, 0, sizeof g_button_due);
    g_pending = 0;
    XFlush(dpy);
}

static void wheel_clicks(Display *dpy, int n, unsigned pos, unsigned neg) {
    unsigned b = n > 0 ? pos : neg;
    for (int i = 0; i < abs(n) && i < 50; i++) {
        XTestFakeButtonEvent(dpy, b, True, CurrentTime);
        XTestFakeButtonEvent(dpy, b, False, CurrentTime);
    }
}

/* Handle one client message; returns 0, or -1 to drop the client. */
static int g_full_next = 1;       /* the next frame is a whole screen (new client, new settings) */

static int handle_input(Display *dpy, uint8_t type, const uint8_t *p, uint32_t len, Grab *s, int *max_fps) {
    switch (type) {
    case IN_KEY: {
        if (len < 5) return -1;
        KeySym ks = get32(p);
        int down = p[4] != 0;
        KeyCode kc = XKeysymToKeycode(dpy, ks);
        if (!kc) { VLOG("no keycode for keysym 0x%lx", (unsigned long)ks); break; }
        press(dpy, 0, kc, down);
        break;
    }
    case IN_MOVE_REL:
        if (len < 4) return -1;
        XTestFakeRelativeMotionEvent(dpy, (int16_t)get16(p), (int16_t)get16(p + 2), CurrentTime);
        break;
    case IN_MOVE_ABS: {
        /* An absolute XTest move shows up in XInput2 raw events as the position itself, which
         * Wine's raw input (mouse-look) takes for a huge delta. Move relatively instead. */
        if (len < 4) return -1;
        int x = get16(p), y = get16(p + 2);
        if (x >= s->w) x = s->w - 1;
        if (y >= s->h) y = s->h - 1;
        Window r, c;
        int rx, ry, wx, wy;
        unsigned mask;
        if (XQueryPointer(dpy, s->root, &r, &c, &rx, &ry, &wx, &wy, &mask)) {
            if (x != rx || y != ry) XTestFakeRelativeMotionEvent(dpy, x - rx, y - ry, CurrentTime);
        } else {
            XTestFakeMotionEvent(dpy, -1, x, y, CurrentTime);
        }
        break;
    }
    case IN_BUTTON: {
        if (len < 2) return -1;
        unsigned b = p[0];
        int down = p[1] != 0;
        if (b < 1 || b > 31) break;
        press(dpy, 1, b, down);
        break;
    }
    case IN_WHEEL:
        if (len < 4) return -1;
        wheel_clicks(dpy, (int16_t)get16(p + 2), 4, 5);  /* up / down */
        wheel_clicks(dpy, (int16_t)get16(p), 7, 6);      /* right / left */
        break;
    case IN_SETTINGS:
        if (len < 2) return -1;
        pthread_mutex_lock(&g_enc.m);
        if (p[0] >= 1 && p[0] <= 100) g_enc.quality = p[0];
        if (len >= 3) g_enc.features = p[2];
        int features = g_enc.features;
        pthread_mutex_unlock(&g_enc.m);
        if (p[1]) *max_fps = p[1];
        g_full_next = 1;
        LOG("client settings: quality %d, max %d fps%s", g_enc.quality, *max_fps,
            features & 1 ? ", partial frames + sharp stills" : "");
        break;
    case IN_RELEASE:
        release_all(dpy);
        pads_center();
        break;
    case IN_PAD:
        if (len < 16) return -1;
        pad_message(p, g_client_fd);
        break;
    case IN_RESIZE: {
        if (len < 4) return -1;
        int w = get16(p) & ~7, h = get16(p + 2) & ~7;   /* whole 8-pixel steps */
        if (w < 800) w = 800;
        if (h < 600) h = 600;
        if (w > 3840) w = 3840;
        if (h > 2400) h = 2400;
        if (w != g_want_w || h != g_want_h) VLOG("the window asks for %dx%d", w, h);
        g_want_w = w; g_want_h = h;
        if (len >= 8) {
            int gw = get16(p + 4) & ~7, gh = get16(p + 6) & ~7;
            if (!gw || !gh) { g_game_w = g_game_h = 0; }
            else {
                g_game_w = gw < 800 ? 800 : gw > 3840 ? 3840 : gw;
                g_game_h = gh < 600 ? 600 : gh > 2400 ? 2400 : gh;
            }
        }
        break;
    }
    case IN_HOST_STATS:
        host_stats(p, len);
        break;
    default:
        VLOG("unknown message %u", type);
    }
    return 0;
}

/* ---------------------------------------------------------------- cursor */

/* Is the pointer shown? Apps hide it with a fully transparent cursor (Wine does for a game
 * that called ShowCursor(FALSE)). */
static int cursor_visible(Display *dpy) {
    XFixesCursorImage *ci = XFixesGetCursorImage(dpy);
    if (!ci) return 1;
    int visible = 0;
    for (int i = 0; i < ci->width * ci->height; i++)
        if ((ci->pixels[i] >> 24) & 0xff) { visible = 1; break; }
    XFree(ci);
    return visible;
}

static void send_cursor(int fd, int visible) {
    uint8_t v = (uint8_t)visible;
    send_small(fd, MSG_CURSOR, &v, 1);
}

/* ---------------------------------------------------------------- main */

static int listen_on(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0), one = 1;   /* (not into bottle-resolution) */
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 2) < 0) {
        LOG("can't listen on 127.0.0.1:%d: %s", port, strerror(errno));
        exit(1);
    }
    return fd;
}

static int g_quiet_x_errors;     /* reading another client's window, which may be gone */

static int x_error(Display *d, XErrorEvent *e) {
    if (g_quiet_x_errors) return 0;
    char msg[128];
    XGetErrorText(d, e->error_code, msg, sizeof msg);
    LOG("X error: %s (request %d.%d)", msg, e->request_code, e->minor_code);
    return 0;
}

/* The window that has the keyboard (and, for games, the mouse): logged when it changes, so a
 * window taking the focus from a game (a Steam notification, say) shows up in screen.log. */
static void log_active_window(Display *dpy, Window root, Atom active, Atom net_name, Atom utf8) {
    static Window last = (Window)-1;
    Atom type;
    int format;
    unsigned long n = 0, rest;
    unsigned char *data = NULL;
    Window w = None;
    g_quiet_x_errors = 1;
    if (XGetWindowProperty(dpy, root, active, 0, 1, False, XA_WINDOW, &type, &format, &n, &rest, &data) == Success
        && data && n == 1 && format == 32)
        w = *(Window *)data;
    if (data) XFree(data);
    if (w == last) { g_quiet_x_errors = 0; return; }
    last = w;
    char title[160] = "(none)";
    if (w != None) {
        data = NULL;
        if (XGetWindowProperty(dpy, w, net_name, 0, 64, False, utf8, &type, &format, &n, &rest, &data) == Success
            && data && n > 0) {
            snprintf(title, sizeof title, "%.*s", (int)n, (char *)data);
        } else {
            char *name = NULL;
            if (XFetchName(dpy, w, &name) && name) { snprintf(title, sizeof title, "%s", name); XFree(name); }
            else snprintf(title, sizeof title, "(untitled 0x%lx)", (unsigned long)w);
        }
        if (data) XFree(data);
    }
    XSync(dpy, False);
    g_quiet_x_errors = 0;
    LOG("active window: %s", title);
}

int main(int argc, char **argv) {
    const char *display = getenv("DISPLAY") ? getenv("DISPLAY") : ":1";
    int port = 4720, max_fps = 60, opt;
    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    g_nbands = cpus >= 8 ? 4 : cpus >= 4 ? 2 : 1;
    while ((opt = getopt(argc, argv, "d:p:q:f:b:v")) != -1) {
        switch (opt) {
        case 'b': g_nbands = atoi(optarg) < 1 ? 1 : atoi(optarg) > MAX_BANDS ? MAX_BANDS : atoi(optarg); break;
        case 'd': display = optarg; break;
        case 'p': port = atoi(optarg); break;
        case 'q': g_enc.quality = atoi(optarg); break;
        case 'f': max_fps = atoi(optarg); break;
        case 'v': g_verbose = 1; break;
        default:
            fprintf(stderr, "usage: bottle-screen [-d :1] [-p 4720] [-q 80] [-f 60] [-b bands] [-v]\n");
            return 2;
        }
    }
    signal(SIGPIPE, SIG_IGN);
    setenv("DISPLAY", display, 1);   /* for bottle-resolution */
    pads_init();
    bands_init();

    Grab s = {0};
    s.dpy = XOpenDisplay(display);
    if (!s.dpy) { LOG("can't open display %s", display); return 1; }
    XSetErrorHandler(x_error);
    s.root = DefaultRootWindow(s.dpy);
    int ev, er, maj, min;
    if (!XTestQueryExtension(s.dpy, &ev, &er, &maj, &min)) { LOG("the X server has no XTest: no input"); }
    int dmg_err = 0;
    if (XDamageQueryExtension(s.dpy, &s.damage_event, &dmg_err)) {
        s.damage = XDamageCreate(s.dpy, s.root, XDamageReportNonEmpty);
    } else {
        s.damage_event = -1;
        LOG("no XDamage: capturing at the frame rate cap");
    }
    capture_setup(&s);
    int fixes_event = -1, fixes_err, cur_visible = 1;
    if (XFixesQueryExtension(s.dpy, &fixes_event, &fixes_err)) {
        XFixesSelectCursorInput(s.dpy, s.root, XFixesDisplayCursorNotifyMask);
        cur_visible = cursor_visible(s.dpy);
    } else {
        fixes_event = -1;
        LOG("no XFixes: can't tell when games hide the pointer");
    }

    Atom net_active = XInternAtom(s.dpy, "_NET_ACTIVE_WINDOW", False);
    Atom net_name = XInternAtom(s.dpy, "_NET_WM_NAME", False), utf8 = XInternAtom(s.dpy, "UTF8_STRING", False);
    XSelectInput(s.dpy, s.root, PropertyChangeMask | StructureNotifyMask);   /* + the root's new size */
    log_active_window(s.dpy, s.root, net_active, net_name, utf8);

    pthread_t enc;
    pthread_create(&enc, NULL, encoder_main, NULL);

    int lfd = listen_on(port), cfd = -1;
    LOG("listening on 127.0.0.1:%d (display %s)", port, display);

    uint8_t in[4096];
    size_t inlen = 0;
    int dirty = 1;
    double last_frame = 0, last_change = 0;
    int need_sharp = 0;              /* a frame in motion quality was sent since the last sharp one */
    XRectangle soft = {0, 0, 0, 0};  /* ...and the part of the screen it covered (their union) */
    uint32_t seq = 0;

    int geometry_due = 0;
    double last_turn = 0, last_stall_log = 0;
    int stalls = 0, worst_stall = 0;
    for (;;) {
        /* A turn of this loop that took long kept input waiting (the capture or the X server
         * busy): counted, and logged at most every 10 s. */
        double turn = now_ms();
        if (cfd >= 0 && last_turn > 0 && turn - last_turn > 250) {
            stalls++;
            if (turn - last_turn > worst_stall) worst_stall = (int)(turn - last_turn);
            if (turn - last_stall_log > 10000) {
                LOG("busy: input waited up to %d ms (%d time%s)", worst_stall, stalls, stalls == 1 ? "" : "s");
                last_stall_log = turn;
                stalls = 0;
                worst_stall = 0;
            }
        }
        last_turn = turn;

        /* X events: damage marks the screen dirty */
        while (XPending(s.dpy)) {
            XEvent e;
            XNextEvent(s.dpy, &e);
            if (e.type == PropertyNotify && e.xproperty.atom == net_active)
                log_active_window(s.dpy, s.root, net_active, net_name, utf8);
            if (e.type == ConfigureNotify && e.xconfigure.window == s.root &&
                (e.xconfigure.width != s.w || e.xconfigure.height != s.h))
                geometry_due = 1;   /* xrandr: the capture follows right away */
            if (s.damage_event >= 0 && e.type == s.damage_event + XDamageNotify) dirty = 1;
            if (fixes_event >= 0 && e.type == fixes_event + XFixesCursorNotify) {
                int v = cursor_visible(s.dpy);
                if (v != cur_visible) {
                    cur_visible = v;
                    VLOG("pointer %s", v ? "shown" : "hidden");
                    if (cfd >= 0) send_cursor(cfd, v);
                }
            }
        }
        if (s.damage_event < 0) dirty = 1;

        /* frame: when something changed (or a sharp still is due), a client is there, the
         * encoder can take one more, and the frame rate cap allows */
        double t = now_ms();
        int wait_ms = 100;
        pthread_mutex_lock(&g_enc.m);
        int room = !g_enc.busy || !g_enc.has_next;
        int features = g_enc.features, quality = g_enc.quality;
        uint8_t *buf = !g_enc.busy ? g_enc.bufs[0] : (g_enc.job.pix == g_enc.bufs[0] ? g_enc.bufs[1] : g_enc.bufs[0]);
        pthread_mutex_unlock(&g_enc.m);
        int sharp_due = (features & 1) && need_sharp && !dirty && t - last_change >= 150;
        if ((dirty || sharp_due) && cfd >= 0) {
            double due = last_frame + 1000.0 / (max_fps > 0 ? max_fps : 60);
            if (t < due) {
                wait_ms = (int)(due - t) + 1;
            } else if (!room) {
                wait_ms = 1;   /* the encoder has a frame queued already: look again shortly */
            } else {
                double c0 = now_ms();
                int sharp = !dirty;
                XRectangle r = damage_take(&s);   /* also forgets the damage this frame covers */
                if (sharp) r = soft;   /* the still: just what was sent in motion quality */
                int full = g_full_next || !(features & 1);
                if (full || (long)r.width * r.height * 10 > (long)s.w * s.h * 6) {
                    r = (XRectangle){0, 0, (unsigned short)s.w, (unsigned short)s.h};
                } else {
                    align_rect(&r, s.w, s.h);
                }
                dirty = 0;
                if (sharp && r.width == 0) need_sharp = 0;
                if (r.width > 0 && r.height > 0 && capture(&s, buf) == 0) {
                    Job jb = {buf, s.w, s.h, r.x, r.y, r.width, r.height,
                              sharp ? 95 : quality, sharp ? TJSAMP_444 : TJSAMP_420, sharp, ++seq};
                    pthread_mutex_lock(&g_enc.m);
                    g_enc.ms_capture += now_ms() - c0;
                    if (!g_enc.busy) {
                        g_enc.job = jb;
                        g_enc.busy = 1;
                    } else {
                        g_enc.next = jb;
                        g_enc.has_next = 1;
                    }
                    pthread_cond_broadcast(&g_enc.cv);
                    pthread_mutex_unlock(&g_enc.m);
                    last_frame = t;
                    g_full_next = 0;
                    if (sharp) {
                        need_sharp = 0;
                        soft = (XRectangle){0, 0, 0, 0};
                    } else {
                        if (!need_sharp || soft.width == 0) {
                            soft = r;
                        } else {             /* grow the union */
                            int x0 = soft.x < r.x ? soft.x : r.x, y0 = soft.y < r.y ? soft.y : r.y;
                            int x1 = soft.x + soft.width > r.x + r.width ? soft.x + soft.width : r.x + r.width;
                            int y1 = soft.y + soft.height > r.y + r.height ? soft.y + soft.height : r.y + r.height;
                            soft = (XRectangle){(short)x0, (short)y0, (unsigned short)(x1 - x0), (unsigned short)(y1 - y0)};
                        }
                        need_sharp = 1;
                        last_change = t;
                    }
                }
                wait_ms = 1;
            }
        } else if ((features & 1) && need_sharp && !dirty && cfd >= 0) {
            wait_ms = (int)(last_change + 150 - t) + 1;   /* wake up for the sharp still */
            if (wait_ms < 1) wait_ms = 1;
        }

        int due = releases_due(s.dpy);   /* presses held to their minimum length */
        if (due >= 0 && due < wait_ms) wait_ms = due;

        struct pollfd pf[3 + MAX_PADS] = {
            {.fd = ConnectionNumber(s.dpy), .events = POLLIN},
            {.fd = lfd, .events = POLLIN},
            {.fd = cfd, .events = POLLIN},
        };
        for (int i = 0; i < MAX_PADS; i++) pf[3 + i] = (struct pollfd){.fd = g_pads[i].fd, .events = POLLIN};
        int n = poll(pf, 3 + MAX_PADS, wait_ms);   /* fd -1 entries are skipped */
        if (n < 0 && errno != EINTR) { LOG("poll: %s", strerror(errno)); break; }
        for (int i = 0; i < MAX_PADS; i++)
            if (g_pads[i].fd >= 0 && (pf[3 + i].revents & POLLIN)) pad_events(i, cfd);

        if (pf[1].revents & POLLIN) {   /* new client replaces the old one */
            int fd = accept4(lfd, NULL, NULL, SOCK_CLOEXEC);
            if (fd >= 0) {
                int one = 1;
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                int sndbuf = 4 << 20;
                setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof sndbuf);
                pthread_mutex_lock(&g_enc.m);
                while (g_enc.busy) pthread_cond_wait(&g_enc.cv, &g_enc.m);
                if (cfd >= 0) { close(cfd); release_all(s.dpy); }
                cfd = fd;
                g_client_fd = fd;
                g_enc.client = fd;
                g_enc.features = 0;     /* until its SETTINGS say otherwise */
                encoder_buffers(s.w, s.h);
                pthread_mutex_unlock(&g_enc.m);
                g_full_next = 1;
                need_sharp = 0;
                soft = (XRectangle){0, 0, 0, 0};
                uint8_t hello[8 + 16] = {MSG_HELLO, 0, 0, 0};
                put32(hello + 4, 16);
                memcpy(hello + 8, "BTLS", 4);
                put16(hello + 12, 2); put16(hello + 14, 0);   /* 2: RESIZE, NOTICE, HOST_STATS */
                put32(hello + 16, (uint32_t)s.w); put32(hello + 20, (uint32_t)s.h);
                send_all(fd, hello, sizeof hello);
                send_cursor(fd, cur_visible);
                for (int i = 0; i < MAX_PADS; i++) pad_idle(i, -1, NULL);   /* the client sends its state */
                g_uinput_failed = 0;
                inlen = 0;
                dirty = 1;
                LOG("client connected");
            }
        }

        if (cfd >= 0 && (pf[2].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t k = recv(cfd, in + inlen, sizeof in - inlen, 0);
            if (k <= 0) {
                LOG("client disconnected");
                pthread_mutex_lock(&g_enc.m);
                while (g_enc.busy) pthread_cond_wait(&g_enc.cv, &g_enc.m);
                g_enc.client = -1;
                pthread_mutex_unlock(&g_enc.m);
                close(cfd);
                cfd = -1;
                g_client_fd = -1;
                release_all(s.dpy);
                for (int i = 0; i < MAX_PADS; i++) pad_idle(i, -1, "the Mac app closed");
                continue;
            }
            inlen += (size_t)k;
            size_t off = 0;
            int drop = 0;
            while (inlen - off >= 8) {
                uint32_t len = get32(in + off + 4);
                if (len > 1024) { drop = 1; break; }
                if (inlen - off < 8 + len) break;
                if (handle_input(s.dpy, in[off], in + off + 8, len, &s, &max_fps) < 0) { drop = 1; break; }
                off += 8 + len;
            }
            XFlush(s.dpy);
            memmove(in, in + off, inlen - off);
            inlen -= off;
            if (drop) { LOG("bad message from client; dropping it"); shutdown(cfd, SHUT_RDWR); }
        }

        /* once a minute: how many quick presses were held to their minimum length */
        static double last_held_log;
        if (t - last_held_log > 60000) {
            last_held_log = t;
            if (g_held_longer)
                LOG("input: %u quick press%s held to %.0f ms (press and release came together)",
                    g_held_longer, g_held_longer == 1 ? "" : "es", MIN_HOLD_MS);
            g_held_longer = 0;
        }

        /* screen size changed (xrandr): rebuild the capture buffers (at once when X said so) */
        static double last_geom;
        if (t - last_geom > 1000 || geometry_due) {
            last_geom = t;
            geometry_due = 0;
            notices_check(cfd);
            resize_check(&s);
            XWindowAttributes a;
            XGetWindowAttributes(s.dpy, s.root, &a);
            if (a.width != s.w || a.height != s.h) {
                pthread_mutex_lock(&g_enc.m);
                while (g_enc.busy) pthread_cond_wait(&g_enc.cv, &g_enc.m);
                capture_free(&s);
                capture_setup(&s);
                encoder_buffers(s.w, s.h);
                pthread_mutex_unlock(&g_enc.m);
                dirty = 1;
                g_full_next = 1;
            }
        }
    }
    return 0;
}
