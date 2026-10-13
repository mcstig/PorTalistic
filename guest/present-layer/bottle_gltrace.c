/*
 * bottle_gltrace: what Steam's overlay draws in an OpenGL program (diagnostics).
 *
 * In OpenGL programs (The Witcher 3's launcher, say) Steam's overlay renderer
 * (ubuntu12_64/gameoverlayrenderer.so) draws with old-style OpenGL calls it links directly:
 * glViewport and glOrtho set up the window's pixels, then glBegin/glTexCoord2d/glVertex2f/3f
 * draw each piece. Oct 11: in the launcher the performance monitor came out as a big rectangle
 * down the left side, as in the game the day before. This library, preloaded ahead of the
 * renderer (BOTTLE_OVERLAY_GL_TRACE=1: steam-arm64's user_settings.py puts it in LD_PRELOAD),
 * logs those calls to the game's log for the overlay's first 4 frames and one in 600 after,
 * at most 80 lines a frame, plus the GL state when the overlay starts drawing (matrices,
 * viewport, scissor, what the app left bound), and passes every call on unchanged.
 *
 *   gcc -O2 -fPIC -shared -Wall -o x86_64/libbottle_gltrace.so bottle_gltrace.c -ldl
 *
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <time.h>

#define EXPORT __attribute__((visibility("default")))

static unsigned g_frames, g_lines;
static int on(void) { return g_frames <= 4 || g_frames % 600 == 0; }
static void say(const char *fmt, double a, double b, double c, double d, double e, double f) {
    if (!on() || g_lines++ >= 80) return;
    time_t t = time(NULL);
    struct tm tm;
    char ts[16];
    strftime(ts, sizeof ts, "%H:%M:%S", localtime_r(&t, &tm));
    fprintf(stderr, "[bottle-gltrace %s] frame %u: ", ts, g_frames);
    fprintf(stderr, fmt, a, b, c, d, e, f);
    fputc('\n', stderr);
}
/* What the GL state is when the overlay starts drawing (first draw of a logged frame): its
 * matrices, the viewport and scissor, a GLSL program or vertex array the app left bound, the
 * clip conventions, the framebuffer. Asked before the draw starts (no glGet inside glBegin). */
static unsigned g_state_frame = ~0u;
static void state(const char *at) {
    if (!on() || g_state_frame == g_frames) return;
    g_state_frame = g_frames;
    static void (*gf)(unsigned, float *);
    static void (*gi)(unsigned, int *);
    static unsigned char (*ie)(unsigned);
    static const unsigned char *(*gs)(unsigned);
    static unsigned (*ge)(void);
    if (!gf) {
        gf = (void (*)(unsigned, float *))dlsym(RTLD_NEXT, "glGetFloatv");
        gi = (void (*)(unsigned, int *))dlsym(RTLD_NEXT, "glGetIntegerv");
        ie = (unsigned char (*)(unsigned))dlsym(RTLD_NEXT, "glIsEnabled");
        gs = (const unsigned char *(*)(unsigned))dlsym(RTLD_NEXT, "glGetString");
        ge = (unsigned (*)(void))dlsym(RTLD_NEXT, "glGetError");
    }
    if (!gf || !gi || !ie) return;
    static int told_renderer;
    if (!told_renderer && gs) {
        told_renderer = 1;
        const unsigned char *r = gs(0x1F01), *v = gs(0x1F02);
        fprintf(stderr, "[bottle-gltrace] renderer %s, version %s\n", r ? (const char *)r : "?", v ? (const char *)v : "?");
    }
    static const struct { unsigned e; const char *n; } mats[] = {
        {0x0BA7, "projection"}, {0x0BA6, "modelview"}, {0x0BA8, "texture"}};
    for (unsigned i = 0; i < 3; i++) {
        float m[16] = {0};
        gf(mats[i].e, m);
        fprintf(stderr, "[bottle-gltrace]   %s at %s: [%g %g %g %g | %g %g %g %g | %g %g %g %g | %g %g %g %g]\n",
                mats[i].n, at, m[0], m[4], m[8], m[12], m[1], m[5], m[9], m[13], m[2], m[6], m[10], m[14],
                m[3], m[7], m[11], m[15]);
    }
    int vp[4] = {0}, sc[4] = {0}, prog = -1, vao = -1, pipe = -1, fbo = -1, origin = 0, depthmode = 0, abuf = -1;
    float dr[2] = {0};
    gi(0x0BA2, vp);
    gi(0x0C10, sc);
    gi(0x8B8D, &prog);       /* GL_CURRENT_PROGRAM */
    gi(0x85B5, &vao);        /* GL_VERTEX_ARRAY_BINDING */
    gi(0x825A, &pipe);       /* GL_PROGRAM_PIPELINE_BINDING */
    gi(0x8CA6, &fbo);        /* GL_DRAW_FRAMEBUFFER_BINDING */
    gi(0x8894, &abuf);       /* GL_ARRAY_BUFFER_BINDING */
    gi(0x935C, &origin);     /* GL_CLIP_ORIGIN */
    gi(0x935D, &depthmode);  /* GL_CLIP_DEPTH_MODE */
    gf(0x0B70, dr);          /* GL_DEPTH_RANGE */
    fprintf(stderr, "[bottle-gltrace]   viewport %d %d %d %d, scissor %s %d %d %d %d, program %d, pipeline %d, "
            "vertex array %d, array buffer %d, draw framebuffer %d, clip origin %#x, depth mode %#x, depth range %g..%g, "
            "depth test %d, stencil test %d, cull %d, vertex program %d\n",
            vp[0], vp[1], vp[2], vp[3], ie(0x0C11) ? "on" : "off", sc[0], sc[1], sc[2], sc[3], prog, pipe, vao, abuf, fbo,
            origin, depthmode, dr[0], dr[1], ie(0x0B71), ie(0x0B90), ie(0x0B44), ie(0x8620));
    if (ge) while (ge()) {}   /* (the enums this context doesn't know) */
}

#define REAL(ret, name, args) \
    static ret (*real) args; \
    if (!real) real = (ret (*) args)dlsym(RTLD_NEXT, #name); \
    if (!real) return

EXPORT void glOrtho(double l, double r, double b, double t, double n, double f) {
    g_frames++;
    g_lines = 0;
    say("glOrtho(%g, %g, %g, %g, %g, %g)", l, r, b, t, n, f);
    REAL(void, glOrtho, (double, double, double, double, double, double));
    real(l, r, b, t, n, f);
}
EXPORT void glViewport(int x, int y, int w, int h) {
    say("glViewport(%g, %g, %g, %g)", x, y, w, h, 0, 0);
    REAL(void, glViewport, (int, int, int, int));
    real(x, y, w, h);
}
EXPORT void glScalef(float x, float y, float z) {
    say("glScalef(%g, %g, %g)", x, y, z, 0, 0, 0);
    REAL(void, glScalef, (float, float, float));
    real(x, y, z);
}
EXPORT void glTranslatef(float x, float y, float z) {
    say("glTranslatef(%g, %g, %g)", x, y, z, 0, 0, 0);
    REAL(void, glTranslatef, (float, float, float));
    real(x, y, z);
}
EXPORT void glLoadMatrixf(const float *m) {
    if (m) say("glLoadMatrixf(diag %g %g %g, translate %g %g)", m[0], m[5], m[10], m[12], m[13], 0);
    REAL(void, glLoadMatrixf, (const float *));
    real(m);
}
EXPORT void glBegin(unsigned mode) {
    state("glBegin");
    say("glBegin(%g)", mode, 0, 0, 0, 0, 0);
    REAL(void, glBegin, (unsigned));
    real(mode);
}
EXPORT void glTexCoord2d(double s, double t) {
    say("  uv %g %g", s, t, 0, 0, 0, 0);
    REAL(void, glTexCoord2d, (double, double));
    real(s, t);
}
EXPORT void glVertex2f(float x, float y) {
    say("  xy %g %g", x, y, 0, 0, 0, 0);
    REAL(void, glVertex2f, (float, float));
    real(x, y);
}
EXPORT void glVertex3f(float x, float y, float z) {
    say("  xyz %g %g %g", x, y, z, 0, 0, 0);
    REAL(void, glVertex3f, (float, float, float));
    real(x, y, z);
}
EXPORT void glTexCoord2i(int s, int t) {
    say("  uv(i) %g %g", s, t, 0, 0, 0, 0);
    REAL(void, glTexCoord2i, (int, int));
    real(s, t);
}
EXPORT void glDrawArrays(unsigned mode, int first, int count) {
    state("glDrawArrays");
    say("glDrawArrays(mode %g, first %g, count %g)", mode, first, count, 0, 0, 0);
    REAL(void, glDrawArrays, (unsigned, int, int));
    real(mode, first, count);
}
EXPORT void glDrawElements(unsigned mode, int count, unsigned type, const void *idx) {
    state("glDrawElements");
    say("glDrawElements(mode %g, count %g, type %g)", mode, count, type, 0, 0, 0);
    REAL(void, glDrawElements, (unsigned, int, unsigned, const void *));
    real(mode, count, type, idx);
}
EXPORT void glDepthRange(double n, double f) {
    say("glDepthRange(%g, %g)", n, f, 0, 0, 0, 0);
    REAL(void, glDepthRange, (double, double));
    real(n, f);
}
EXPORT void glPolygonMode(unsigned face, unsigned mode) {
    say("glPolygonMode(%g, %g)", face, mode, 0, 0, 0, 0);
    REAL(void, glPolygonMode, (unsigned, unsigned));
    real(face, mode);
}
EXPORT void glPixelZoom(float x, float y) {
    say("glPixelZoom(%g, %g)", x, y, 0, 0, 0, 0);
    REAL(void, glPixelZoom, (float, float));
    real(x, y);
}
