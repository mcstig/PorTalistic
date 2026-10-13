/* Steam's interface on the Mac's GPU (bottle steam-gpu on): keeps zink's own way of showing
 * frames (kopper) on for Steam's web views.
 *
 * Why: in this mode Steam's interface draws with OpenGL through Mesa's zink, on Venus, and zink
 * shows its frames through Vulkan (kopper), which the bottle present layer copies to the X
 * screen. Steam's client sets LIBGL_KOPPER_DISABLE=true for steamwebhelper ("to get store working
 * properly"). Without kopper, zink can only show frames through DRI3, which this X server (Xvnc)
 * doesn't have, so the web helper gets no OpenGL context ("CreateOutputWindow: failed to acquire
 * a gl context"), restarts every 10 s, and Big Picture stays black.
 *
 * Since Oct 9, 17:30 the mode's settings are no longer in Steam's environment at all: steam-arm64
 * sets only BOTTLE_STEAM_GPU=zink (and BOTTLE_STEAM_GPU_FAKE, the layer's stand-ins), and this
 * library, loaded by GLVND in Steam's web helper (2 below), sets MESA_LOADER_DRIVER_OVERRIDE=zink,
 * LIBGL_KOPPER_DRI2=1 and BOTTLE_FAKE_ZINK there, in that process only (0 below). Nothing Steam
 * starts (games, their launchers) gets them, whatever way Steam starts it. The earlier way
 * (Steam's environment, stripped from every program Steam started except its web helper) lost the
 * web helper too, which Steam starts through `sh`: Big Picture was on the CPU from 14:03 to 17:30.
 * Steam's own process doesn't get them either (it draws nothing that matters with OpenGL).
 *
 * How, three ways (only while the mode is on; steam-arm64 sets them up):
 *  1. (not used since 17:30) Preloaded into Steam (LD_PRELOAD): it watches the programs Steam starts (execve and the rest
 *     of the exec family, posix_spawn) and hands them LIBGL_KOPPER_DISABLE=0 whenever their
 *     environment asks for zink. This is what reaches the web helper: Steam starts it with its
 *     own library path, so (2) alone never got there (Oct 9: no shim in the web helper).
 *     The preload stays on for Steam and its web helper and is taken off everything else Steam
 *     starts (games, tools), so it never reaches Windows games or x86 programs. So are the
 *     settings of the mode itself (the variables named in BOTTLE_GPU_UI_VARS, which steam-arm64
 *     sets): a game's own OpenGL (a launcher's, say) stays on the CPU as before. With zink it
 *     would get OpenGL 2.1 on this GPU, and The Witcher 3's launcher quit at once (Oct 9).
 *  2. Linked as libGLX_mesa.so.0 and libEGL_mesa.so.0 into the folder on Steam's LD_LIBRARY_PATH:
 *     GLVND loads it in place of Mesa's vendor libraries; it hands everything to Mesa's real ones.
 *  3. Whenever it is loaded (either way), it sets the variable to 0 in its own process before
 *     Mesa reads it.
 * Without MESA_LOADER_DRIVER_OVERRIDE=zink it changes nothing.
 *
 * Log: ~/.cache/steamos-bottle/kopper.log (zink mode only): which programs loaded it, what it
 * changed for which started program. BOTTLE_PRESENT_DEBUG=1 also says it on stderr.
 * BOTTLE_MESA_LIBDIR=dir: where Mesa's real libGLX_mesa.so.0 / libEGL_mesa.so.0 are (else the usual
 * system folders, then LD_LIBRARY_PATH).
 *
 * The exec wrappers may run in a vfork()ed child (sharing Steam's memory while Steam's other
 * threads run): they use only the stack and plain system calls (no malloc, no stdio, no
 * dlsym; the real functions are looked up when the library loads).
 *
 * Build: gcc -O2 -fPIC -shared -Wall -Wl,-soname,libbottle_kopper.so -o libbottle_kopper.so \
 *            bottle_kopper.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

extern char **environ;

static const char KOPPER_VAR[] = "LIBGL_KOPPER_DISABLE=";
static const char ZINK_VAR[] = "MESA_LOADER_DRIVER_OVERRIDE=zink";
static const char PRELOAD_VAR[] = "LD_PRELOAD=";
static char kopper_on[] = "LIBGL_KOPPER_DISABLE=0";
static const char VARS_VAR[] = "BOTTLE_GPU_UI_VARS=";
static const char SHIM_NAME[] = "libbottle_kopper.so";

/* ---- small helpers that are safe anywhere (stack + system calls only) ---- */

static int starts(const char *s, const char *prefix) { return strncmp(s, prefix, strlen(prefix)) == 0; }

static const char *base_name(const char *p) {
    const char *b = p ? strrchr(p, '/') : NULL;
    return b ? b + 1 : (p ? p : "");
}

static int zink_in(char *const envp[]) {
    for (size_t i = 0; envp && envp[i]; i++)
        if (strcmp(envp[i], ZINK_VAR) == 0) return 1;
    return 0;
}

static size_t env_count(char *const envp[]) {
    size_t n = 0;
    while (envp && envp[n]) n++;
    return n;
}

/* One line to ~/.cache/steamos-bottle/kopper.log: "HH:MM:SSZ exe[pid] message". */
static void klog(const char *fmt, ...) {
    const char *home = getenv("HOME");
    if (!home) return;
    char path[PATH_MAX], line[1024], exe[PATH_MAX] = "?";
    if (snprintf(path, sizeof path, "%s/.cache/steamos-bottle/kopper.log", home) >= (int)sizeof path) return;
    ssize_t e = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (e > 0) exe[e] = 0;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long day = (long)(ts.tv_sec % 86400);   /* not gmtime_r: it takes a lock */
    int n = snprintf(line, sizeof line, "%02ld:%02ld:%02ldZ %s[%d] ", day / 3600, day / 60 % 60, day % 60,
                     base_name(exe), (int)getpid());
    va_list ap;
    va_start(ap, fmt);
    if (n > 0 && n < (int)sizeof line) n += vsnprintf(line + n, sizeof line - n, fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
    line[n++] = '\n';
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return;
    ssize_t w = write(fd, line, (size_t)n);
    (void)w;
    close(fd);
}

/* ---- 0: the mode's settings, in Steam's web helper only ---- */

static int is_webhelper(void) {
    char exe[PATH_MAX];
    ssize_t e = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (e <= 0) return 0;
    exe[e] = 0;
    return strcmp(base_name(exe), "steamwebhelper") == 0;
}

/* BOTTLE_STEAM_GPU=zink (steam-arm64, GPU mode) in a web helper process: zink for its OpenGL,
 * before Mesa reads the variables (when it sets up a display, after this library loaded). A
 * MESA_LOADER_DRIVER_OVERRIDE already there (set here before, or the user's) is left alone. */
static void gpu_mode_here(const char *how) {
    const char *m = getenv("BOTTLE_STEAM_GPU");
    if (!m || strcmp(m, "zink") != 0 || getenv("MESA_LOADER_DRIVER_OVERRIDE") || !is_webhelper()) return;
    const char *fake = getenv("BOTTLE_STEAM_GPU_FAKE");
    setenv("LIBGL_KOPPER_DRI2", "1", 1);
    setenv("BOTTLE_FAKE_ZINK", fake && *fake ? fake : "geometryShader", 1);
    setenv("BOTTLE_PRESENT_DEBUG", "1", 0);   /* the layer says what it does, in Steam's log */
    setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1);
    klog("%s: Steam's interface on the GPU here (zink; stand-ins %s)", how, getenv("BOTTLE_FAKE_ZINK"));
}

/* ---- 3: this process ---- */

/* Mesa reads LIBGL_KOPPER_DISABLE when it sets up a display (GLX) or an EGL display, which is
 * after this library loaded. setenv() replaces the variable's pointer in one store, so a thread
 * reading the environment meanwhile sees the old value or the new one, never a torn one. */
static void keep_kopper(const char *how) {
    const char *drv = getenv("MESA_LOADER_DRIVER_OVERRIDE");
    const char *off = getenv("LIBGL_KOPPER_DISABLE");
    if (!drv || strcmp(drv, "zink") != 0 || !off || strcmp(off, "0") == 0) return;
    char was[32];
    snprintf(was, sizeof was, "%s", off);
    setenv("LIBGL_KOPPER_DISABLE", "0", 1);
    klog("%s: LIBGL_KOPPER_DISABLE was %s, set to 0 here", how, was);
    if (getenv("BOTTLE_PRESENT_DEBUG"))
        fprintf(stderr, "[bottle-kopper] pid %d: LIBGL_KOPPER_DISABLE was %s, set to 0 "
                "(zink shows frames through Vulkan)\n", (int)getpid(), was);
}

/* ---- 1: programs this process starts ---- */

typedef int (*execve_fn)(const char *, char *const[], char *const[]);
typedef int (*fexecve_fn)(int, char *const[], char *const[]);
typedef int (*spawn_fn)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                        const posix_spawnattr_t *, char *const[], char *const[]);
static execve_fn real_execve, real_execvpe;
static fexecve_fn real_fexecve;
static spawn_fn real_spawn, real_spawnp;

/* The real functions, looked up when the library loads (or, if something starts a program
 * before that, then). */
static int resolved(void *fn) {
    if (fn) return 1;
    real_execve = (execve_fn)dlsym(RTLD_NEXT, "execve");
    real_execvpe = (execve_fn)dlsym(RTLD_NEXT, "execvpe");
    real_fexecve = (fexecve_fn)dlsym(RTLD_NEXT, "fexecve");
    real_spawn = (spawn_fn)dlsym(RTLD_NEXT, "posix_spawn");
    real_spawnp = (spawn_fn)dlsym(RTLD_NEXT, "posix_spawnp");
    return 0;
}
#define REAL(fn) ((resolved((void *)(fn)) || (fn)) ? (fn) : NULL)

/* The preload stays for Steam itself (it may start itself again, also as /proc/self/exe or
 * through steam.sh) and its web helper. Steam starts the web helper through a shell (sh, then
 * steamwebhelper.sh, then steamwebhelper): a shell whose arguments name the web helper keeps
 * it too. Without that, the GPU mode's settings were taken off at the shell, and Big Picture
 * fell back to the CPU (Oct 9, 14:03 until 17:10: the web helper on llvmpipe). */
static int is_shell(const char *b) {
    return strcmp(b, "sh") == 0 || strcmp(b, "bash") == 0 || strcmp(b, "dash") == 0;
}
static int keeps_preload(const char *target, char *const argv[]) {
    const char *b = base_name(target);
    if (strcmp(b, "steam") == 0 || strcmp(b, "steam.sh") == 0 || strcmp(b, "steamwebhelper") == 0 ||
        strcmp(b, "steamwebhelper.sh") == 0 || (target && strcmp(target, "/proc/self/exe") == 0))
        return 1;
    if (is_shell(b) && argv)
        for (size_t i = 0; argv[i] && i < 64; i++)
            if (strstr(argv[i], "steamwebhelper")) return 1;
    return 0;
}

/* LD_PRELOAD=... without this library, into buf; 0 if nothing is left. */
static int preload_without_shim(const char *entry, char *buf, size_t cap) {
    const char *v = entry + sizeof PRELOAD_VAR - 1;
    size_t o = (size_t)snprintf(buf, cap, "%s", PRELOAD_VAR), kept = 0;
    while (*v) {
        size_t len = strcspn(v, ": ");
        if (len && !(len >= sizeof SHIM_NAME - 1 &&
                     strncmp(v + len - (sizeof SHIM_NAME - 1), SHIM_NAME, sizeof SHIM_NAME - 1) == 0 &&
                     (len == sizeof SHIM_NAME - 1 || v[len - sizeof SHIM_NAME] == '/'))) {
            if (o + len + 2 > cap) return -1;   /* too long to rewrite: leave it */
            if (kept++) buf[o++] = ':';
            memcpy(buf + o, v, len);
            o += len;
            buf[o] = 0;
        }
        v += len;
        if (*v) v++;
    }
    return kept ? 1 : 0;
}

/* The value of NAME=... (NAME's length) among the names in list ("A:B C"), or the list's own
 * variable. */
static int listed(const char *entry, const char *list) {
    size_t len = strcspn(entry, "=");
    if (!entry[len]) return 0;
    if (strncmp(entry, VARS_VAR, sizeof VARS_VAR - 1) == 0) return 1;
    for (const char *p = list; p && *p;) {
        size_t l = strcspn(p, ": ");
        if (l == len && strncmp(p, entry, len) == 0) return 1;
        p += l;
        if (*p) p++;
    }
    return 0;
}

static const char *vars_in(char *const envp[], size_t n) {
    for (size_t i = 0; i < n && envp[i]; i++)
        if (starts(envp[i], VARS_VAR)) return envp[i] + sizeof VARS_VAR - 1;
    return NULL;
}

/* envp as the started program should get it, in out[] (n + 1 entries, n = env_count(envp)) and pbuf.
 * Returns envp itself when nothing changes. */
static char *const *fixed_env(char *const envp[], size_t n, const char *target, char *const argv[], char **out,
                              char *pbuf, size_t pcap) {
    if (!envp) return envp;
    int zink = zink_in(envp), keep = keeps_preload(target, argv), changed = 0, preload_done = 0, dropped = 0;
    /* the mode's own settings stay with Steam and its web helper only */
    const char *vars = keep ? NULL : vars_in(envp, n);
    if (vars) zink = 0;
    size_t j = 0;
    const char *was = NULL;
    /* at most the n entries out[] was sized for: another thread's setenv() may grow environ */
    for (size_t i = 0; i < n && envp[i]; i++) {
        char *e = envp[i];
        if (vars && listed(e, vars)) {
            changed = 1;
            dropped++;
            continue;
        }
        if (zink && starts(e, KOPPER_VAR) && strcmp(e, kopper_on) != 0) {
            was = e + sizeof KOPPER_VAR - 1;
            out[j++] = kopper_on;
            changed = 1;
            continue;
        }
        if (!keep && !preload_done && starts(e, PRELOAD_VAR) && strstr(e, SHIM_NAME)) {
            preload_done = 1;   /* the first one (the one ld.so uses); pbuf holds one */
            int r = preload_without_shim(e, pbuf, pcap);
            if (r >= 0) {
                changed = 1;
                if (r) out[j++] = pbuf;
                continue;
            }
        }
        out[j++] = e;
    }
    out[j] = NULL;
    if (!changed) return envp;
    if (was) klog("starts %s with LIBGL_KOPPER_DISABLE=0 (Steam had set %s)", base_name(target), was);
    if (dropped) klog("starts %s without the GPU interface settings (%d)", base_name(target), dropped);
    return out;
}

#define PRELOAD_MAX 4096

EXPORT int execve(const char *path, char *const argv[], char *const envp[]) {
    execve_fn f = REAL(real_execve);
    if (!f) { errno = ENOSYS; return -1; }
    size_t n = env_count(envp);
    char *out[n + 1], pbuf[PRELOAD_MAX];
    return f(path, argv, fixed_env(envp, n, path, argv, out, pbuf, sizeof pbuf));
}

EXPORT int execvpe(const char *file, char *const argv[], char *const envp[]) {
    execve_fn f = REAL(real_execvpe);
    if (!f) { errno = ENOSYS; return -1; }
    size_t n = env_count(envp);
    char *out[n + 1], pbuf[PRELOAD_MAX];
    return f(file, argv, fixed_env(envp, n, file, argv, out, pbuf, sizeof pbuf));
}

EXPORT int execv(const char *path, char *const argv[]) { return execve(path, argv, environ); }

EXPORT int execvp(const char *file, char *const argv[]) { return execvpe(file, argv, environ); }

EXPORT int fexecve(int fd, char *const argv[], char *const envp[]) {
    fexecve_fn f = REAL(real_fexecve);
    if (!f) { errno = ENOSYS; return -1; }
    size_t n = env_count(envp);
    char *out[n + 1], pbuf[PRELOAD_MAX];
    /* the program is known by its first argument here (glibc lets argv be NULL) */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wnonnull-compare"
    const char *name = argv ? argv[0] : NULL;
#pragma GCC diagnostic pop
    return f(fd, argv, fixed_env(envp, n, name, argv, out, pbuf, sizeof pbuf));
}

/* execl, execlp, execle: the arguments into an array on the stack, then the above. */
#define LIST_ARGS(first, ap, args, n)                                   \
    size_t n = 1;                                                       \
    va_start(ap, first);                                                \
    while (va_arg(ap, char *)) n++;                                     \
    va_end(ap);                                                         \
    char *args[n + 1];                                                  \
    args[0] = (char *)(first);                                          \
    va_start(ap, first);                                                \
    for (size_t k_ = 1; k_ <= n; k_++) args[k_] = va_arg(ap, char *);

EXPORT int execl(const char *path, const char *arg, ...) {
    va_list ap;
    LIST_ARGS(arg, ap, args, n)
    va_end(ap);
    return execve(path, args, environ);
}

EXPORT int execlp(const char *file, const char *arg, ...) {
    va_list ap;
    LIST_ARGS(arg, ap, args, n)
    va_end(ap);
    return execvpe(file, args, environ);
}

EXPORT int execle(const char *path, const char *arg, ...) {
    va_list ap;
    LIST_ARGS(arg, ap, args, n)
    char *const *envp = va_arg(ap, char *const *);   /* after the terminating NULL */
    va_end(ap);
    return execve(path, args, envp);
}

EXPORT int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                       const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    spawn_fn f = REAL(real_spawn);
    if (!f) return ENOSYS;
    size_t n = env_count(envp);
    char *out[n + 1], pbuf[PRELOAD_MAX];
    return f(pid, path, fa, attr, argv, fixed_env(envp, n, path, argv, out, pbuf, sizeof pbuf));
}

EXPORT int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                        const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    spawn_fn f = REAL(real_spawnp);
    if (!f) return ENOSYS;
    size_t n = env_count(envp);
    char *out[n + 1], pbuf[PRELOAD_MAX];
    return f(pid, file, fa, attr, argv, fixed_env(envp, n, file, argv, out, pbuf, sizeof pbuf));
}

__attribute__((constructor)) static void on_load(void) {
    resolved(NULL);
    gpu_mode_here("at load");
    if (zink_in(environ)) {
        const char *pre = getenv("LD_PRELOAD");
        klog("loaded (%s; LIBGL_KOPPER_DISABLE=%s)", pre && strstr(pre, SHIM_NAME) ? "preloaded" : "as OpenGL library",
             getenv("LIBGL_KOPPER_DISABLE") ? getenv("LIBGL_KOPPER_DISABLE") : "unset");
    }
    keep_kopper("at load");
}

/* ---- 2: GLVND vendor library ---- */

/* dir/name loaded, unless it is this library (or missing). */
static void *try_dir(const char *dir, size_t len, const char *name, const char *self) {
    char cand[PATH_MAX], resolved[PATH_MAX];
    if (!len || len >= sizeof cand) return NULL;
    snprintf(cand, sizeof cand, "%.*s/%s", (int)len, dir, name);
    if (!realpath(cand, resolved) || (self[0] && strcmp(resolved, self) == 0)) return NULL;
    void *h = dlopen(resolved, RTLD_NOW | RTLD_LOCAL);
    if (!h) fprintf(stderr, "[bottle-kopper] couldn't load %s: %s\n", resolved, dlerror());
    return h;
}

/* Mesa's real vendor library: BOTTLE_MESA_LIBDIR, the usual system folders, then the folders on
 * LD_LIBRARY_PATH; the first one found that isn't this library. */
static void *real_library(const char *name) {
    static const char *const dirs[] = {
        "/usr/lib64", "/usr/lib/aarch64-linux-gnu", "/usr/lib/x86_64-linux-gnu",
        "/usr/lib", "/lib64", "/lib/aarch64-linux-gnu", "/lib/x86_64-linux-gnu",
    };
    char self[PATH_MAX] = "";
    Dl_info info;
    if (dladdr((void *)real_library, &info) && info.dli_fname) {
        if (!realpath(info.dli_fname, self)) self[0] = 0;
    }
    void *h;
    const char *env = getenv("BOTTLE_MESA_LIBDIR");
    if (env && (h = try_dir(env, strlen(env), name, self))) return h;
    for (size_t i = 0; i < sizeof dirs / sizeof dirs[0]; i++)
        if ((h = try_dir(dirs[i], strlen(dirs[i]), name, self))) return h;
    for (const char *p = getenv("LD_LIBRARY_PATH"); p && *p;) {
        const char *end = strchr(p, ':');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if ((h = try_dir(p, len, name, self))) return h;
        p = end ? end + 1 : p + len;
    }
    fprintf(stderr, "[bottle-kopper] Mesa's %s not found: OpenGL can't start\n", name);
    return NULL;
}

/* GLVND's vendor entry points: Bool __glx_Main(uint32_t version, const __GLXapiExports *,
 * __GLXvendorInfo *, __GLXapiImports *) and EGLBoolean __egl_Main(the same for EGL). The
 * arguments go to Mesa's own entry point untouched. */
typedef unsigned int (*vendor_main)(unsigned int, const void *, void *, void *);

static unsigned int forward(const char *lib, const char *sym, unsigned int version,
                            const void *exports, void *vendor, void *imports) {
    gpu_mode_here(sym);
    keep_kopper(sym);
    if (zink_in(environ)) klog("%s: OpenGL through the shim, on to Mesa's %s", sym, lib);
    void *h = real_library(lib);
    if (!h) return 0;
    vendor_main m = (vendor_main)dlsym(h, sym);
    if (!m) {
        fprintf(stderr, "[bottle-kopper] %s has no %s\n", lib, sym);
        return 0;
    }
    return m(version, exports, vendor, imports);
}

EXPORT unsigned int __glx_Main(unsigned int version, const void *exports, void *vendor, void *imports) {
    return forward("libGLX_mesa.so.0", "__glx_Main", version, exports, vendor, imports);
}

EXPORT unsigned int __egl_Main(unsigned int version, const void *exports, void *vendor, void *imports) {
    return forward("libEGL_mesa.so.0", "__egl_Main", version, exports, vendor, imports);
}
