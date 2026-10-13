/* bottle-gltest: an OpenGL window the way Steam's interface makes one, drawn and looked at.
 *
 *   bottle-gltest glx|egl [argb] [core]
 *
 * Steam's web helper composites Big Picture into an SDL window with an OpenGL context and
 * SDL_WINDOW_TRANSPARENT (a depth-32 ARGB visual). This opens such a window (through GLX or EGL,
 * ARGB or plain), clears it to orange for half a second, then reads the window back from the X
 * server: the frames have to have reached the screen (on the GPU path: zink, kopper, the bottle
 * present layer's copy). The window is override-redirect at the top left, above Steam.
 * "core" asks for an OpenGL 3.3 core profile context (a renderer that offers only OpenGL 2.1,
 * as zink does on a GPU without transform feedback, can't give one) and then draws the orange
 * with shaders and a texture (a triangle over a dark blue clear), as a compositor does: that
 * needs real pipelines on the GPU, which a clear alone doesn't.
 *
 * Prints "renderer: ..." and one RESULT line; exit 0 = shows, 1 = black, 2 = no OpenGL.
 * `bottle steam-gpu on` runs it with Steam's settings before switching Steam over.
 *
 * Build: gcc -O2 -Wall -o bottle-gltest bottle_gltest.c -lX11 -lXrender -lGL -lEGL
 */
#include <EGL/egl.h>
#include <GL/gl.h>
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xrender.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define W 160
#define H 120

typedef void (*clearcolor_fn)(GLfloat, GLfloat, GLfloat, GLfloat);
typedef void (*clear_fn)(GLbitfield);
typedef const GLubyte *(*getstring_fn)(GLenum);
typedef void (*finish_fn)(void);
typedef void *(*getproc_fn)(const char *);

/* The core-profile drawing: one triangle over the whole window, sampling an orange texture. */
static const char *k_vs =
    "#version 330 core\n"
    "out vec2 uv;\n"
    "void main() {\n"
    "    vec2 p = vec2(float(gl_VertexID & 1) * 2.0, float(gl_VertexID >> 1) * 2.0);\n"
    "    uv = p * 0.5;\n"
    "    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";
static const char *k_fs =
    "#version 330 core\n"
    "in vec2 uv;\n"
    "uniform sampler2D tex;\n"
    "out vec4 color;\n"
    "void main() { color = texture(tex, uv); }\n";

typedef GLuint (*create_shader_fn)(GLenum);
typedef void (*shader_source_fn)(GLuint, GLsizei, const char *const *, const GLint *);
typedef void (*compile_shader_fn)(GLuint);
typedef void (*get_shaderiv_fn)(GLuint, GLenum, GLint *);
typedef GLuint (*create_program_fn)(void);
typedef void (*attach_shader_fn)(GLuint, GLuint);
typedef void (*link_program_fn)(GLuint);
typedef void (*use_program_fn)(GLuint);
typedef void (*gen_fn)(GLsizei, GLuint *);
typedef void (*bind_vao_fn)(GLuint);
typedef void (*bind_texture_fn)(GLenum, GLuint);
typedef void (*tex_image_fn)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
typedef void (*tex_parameteri_fn)(GLenum, GLenum, GLint);
typedef void (*draw_arrays_fn)(GLenum, GLint, GLsizei);

/* Sets up the program, texture and vertex array; returns the draw call, or NULL (said why). */
static draw_arrays_fn setup_draw(getproc_fn gp) {
#define GP(type, name) type name = (type)gp(#name); if (!name) { printf("RESULT: no OpenGL (no %s)\n", #name); return NULL; }
    GP(create_shader_fn, glCreateShader) GP(shader_source_fn, glShaderSource) GP(compile_shader_fn, glCompileShader)
    GP(get_shaderiv_fn, glGetShaderiv) GP(create_program_fn, glCreateProgram) GP(attach_shader_fn, glAttachShader)
    GP(link_program_fn, glLinkProgram) GP(get_shaderiv_fn, glGetProgramiv) GP(use_program_fn, glUseProgram)
    GP(gen_fn, glGenVertexArrays) GP(bind_vao_fn, glBindVertexArray) GP(gen_fn, glGenTextures)
    GP(bind_texture_fn, glBindTexture) GP(tex_image_fn, glTexImage2D) GP(tex_parameteri_fn, glTexParameteri)
    GP(draw_arrays_fn, glDrawArrays)
#undef GP
    GLuint sh[2];
    const char *src[2] = { k_vs, k_fs };
    GLenum kind[2] = { 0x8B31 /* GL_VERTEX_SHADER */, 0x8B30 /* GL_FRAGMENT_SHADER */ };
    GLuint prog = glCreateProgram();
    for (int i = 0; i < 2; i++) {
        GLint ok = 0;
        sh[i] = glCreateShader(kind[i]);
        glShaderSource(sh[i], 1, &src[i], NULL);
        glCompileShader(sh[i]);
        glGetShaderiv(sh[i], 0x8B81 /* GL_COMPILE_STATUS */, &ok);
        if (!ok) { printf("RESULT: no drawing (a shader didn't compile)\n"); return NULL; }
        glAttachShader(prog, sh[i]);
    }
    GLint linked = 0;
    glLinkProgram(prog);
    glGetProgramiv(prog, 0x8B82 /* GL_LINK_STATUS */, &linked);
    if (!linked) { printf("RESULT: no drawing (the shaders didn't link)\n"); return NULL; }
    glUseProgram(prog);
    GLuint vao, tex;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    static const unsigned char orange[4 * 4] = { 255, 128, 0, 255, 255, 128, 0, 255, 255, 128, 0, 255, 255, 128, 0, 255 };
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, orange);
    return glDrawArrays;
}

static int is_argb(Display *d, Visual *v, int depth) {
    XRenderPictFormat *pf = XRenderFindVisualFormat(d, v);
    return depth == 32 && pf && pf->direct.alphaMask > 0;
}

static Window make_window(Display *d, XVisualInfo *vi) {
    XSetWindowAttributes swa;
    memset(&swa, 0, sizeof swa);
    swa.colormap = XCreateColormap(d, RootWindow(d, vi->screen), vi->visual, AllocNone);
    swa.override_redirect = True;   /* no window manager: shown at once, on top */
    Window w = XCreateWindow(d, RootWindow(d, vi->screen), 0, 0, W, H, 0, vi->depth, InputOutput,
                             vi->visual, CWColormap | CWBorderPixel | CWBackPixel | CWOverrideRedirect, &swa);
    XMapRaised(d, w);
    XSync(d, False);
    return w;
}

/* Share of the window's middle that is orange on the X server. */
static int orange_share(Display *d, Window w, XVisualInfo *vi) {
    XImage *im = XGetImage(d, w, W / 4, H / 4, W / 2, H / 2, AllPlanes, ZPixmap);
    if (!im) return 0;
    int rs = __builtin_ctzl(vi->red_mask), gs = __builtin_ctzl(vi->green_mask), bs = __builtin_ctzl(vi->blue_mask);
    int hit = 0, tot = 0;
    for (int y = 0; y < H / 2; y += 4)
        for (int x = 0; x < W / 2; x += 4) {
            unsigned long p = XGetPixel(im, x, y);
            int r = (int)((p & vi->red_mask) >> rs), g = (int)((p & vi->green_mask) >> gs), b = (int)((p & vi->blue_mask) >> bs);
            tot++;
            hit += r > 200 && g > 90 && g < 170 && b < 70;
        }
    XDestroyImage(im);
    return tot ? hit * 100 / tot : 0;
}

static int finish(Display *d, Window w, XVisualInfo *vi, const char *renderer,
                  clearcolor_fn cc, clear_fn cl, finish_fn fi, void (*swap)(void *), void *arg, getproc_fn gp) {
    printf("renderer: %s (window depth %d)\n", renderer ? renderer : "?", vi->depth);
    draw_arrays_fn draw = NULL;
    if (gp && !(draw = setup_draw(gp))) return 2;
    for (int f = 0; f < 30; f++) {
        if (draw) cc(0.0f, 0.0f, 0.4f, 1.0f);   /* dark blue, then the orange triangle over it */
        else cc(1.0f, 0.5f, 0.0f, 1.0f);
        cl(GL_COLOR_BUFFER_BIT);
        if (draw) draw(GL_TRIANGLES, 0, 3);
        swap(arg);
        usleep(16000);
    }
    fi();
    usleep(300000);   /* the present layer copies on its own thread */
    int share = orange_share(d, w, vi);
    if (share >= 90) {
        printf("RESULT: shows (%d%% of the window drawn%s)\n", share, draw ? ", with shaders and a texture" : "");
        return 0;
    }
    printf("RESULT: %s (%d%% of the window drawn)\n", draw ? "no drawing (the triangle didn't show)" : "black", share);
    return 1;
}

static void *glx_proc(const char *name) { return (void *)glXGetProcAddressARB((const GLubyte *)name); }
static void *egl_proc(const char *name) { return (void *)eglGetProcAddress(name); }

static Display *glx_dpy;
static Window glx_win;
static void glx_swap(void *unused) { (void)unused; glXSwapBuffers(glx_dpy, glx_win); }

typedef GLXContext (*create_attribs_fn)(Display *, GLXFBConfig, GLXContext, Bool, const int *);

/* An X error (GLXBadFBConfig when the context asked for can't be had) is an answer, not a crash. */
static int x_error;
static int on_x_error(Display *d, XErrorEvent *e) { (void)d; x_error = e->error_code ? e->error_code : 1; return 0; }

static int run_glx(Display *d, int argb, int core) {
    int attrs[] = { GLX_RENDER_TYPE, GLX_RGBA_BIT, GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT, GLX_DOUBLEBUFFER, True,
                    GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, GLX_ALPHA_SIZE, argb ? 8 : 0, None };
    int n = 0;
    GLXFBConfig *cfgs = glXChooseFBConfig(d, DefaultScreen(d), attrs, &n);
    if (!cfgs || !n) { printf("RESULT: no OpenGL (GLX gave no framebuffer configuration)\n"); return 2; }
    XVisualInfo *vi = NULL;
    GLXFBConfig cfg = cfgs[0];
    for (int i = 0; i < n && !vi; i++) {
        XVisualInfo *v = glXGetVisualFromFBConfig(d, cfgs[i]);
        if (!v) continue;
        if (!argb || is_argb(d, v->visual, v->depth)) { vi = v; cfg = cfgs[i]; }
        else XFree(v);
    }
    if (!vi) { printf("RESULT: no OpenGL (no %s visual through GLX)\n", argb ? "ARGB" : "RGB"); return 2; }
    Window w = make_window(d, vi);
    GLXContext ctx = NULL;
    if (core) {
        create_attribs_fn create = (create_attribs_fn)glXGetProcAddressARB((const GLubyte *)"glXCreateContextAttribsARB");
        int ca[] = { GLX_CONTEXT_MAJOR_VERSION_ARB, 3, GLX_CONTEXT_MINOR_VERSION_ARB, 3,
                     GLX_CONTEXT_PROFILE_MASK_ARB, GLX_CONTEXT_CORE_PROFILE_BIT_ARB, None };
        XErrorHandler prev = XSetErrorHandler(on_x_error);
        if (create) ctx = create(d, cfg, NULL, True, ca);
        XSync(d, False);
        XSetErrorHandler(prev);
        if (x_error) ctx = NULL;
    } else {
        ctx = glXCreateNewContext(d, cfg, GLX_RGBA_TYPE, NULL, True);
    }
    if (!ctx || !glXMakeCurrent(d, w, ctx)) {
        printf("RESULT: no OpenGL (no GLX %scontext)\n", core ? "OpenGL 3.3 core " : "");
        return 2;
    }
    glx_dpy = d; glx_win = w;
    return finish(d, w, vi, (const char *)glGetString(GL_RENDERER), glClearColor, glClear, glFinish, glx_swap, NULL,
                  core ? glx_proc : NULL);
}

static EGLDisplay egl_dpy;
static EGLSurface egl_surf;
static void egl_swap(void *unused) { (void)unused; eglSwapBuffers(egl_dpy, egl_surf); }

static int run_egl(Display *d, int argb, int core) {
    EGLDisplay ed = eglGetDisplay((EGLNativeDisplayType)d);
    if (ed == EGL_NO_DISPLAY || !eglInitialize(ed, NULL, NULL)) {
        printf("RESULT: no OpenGL (eglInitialize failed)\n");
        return 2;
    }
    eglBindAPI(EGL_OPENGL_API);
    EGLint attrs[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
                       EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, argb ? 8 : 0, EGL_NONE };
    EGLConfig cfgs[64];
    EGLint n = 0;
    if (!eglChooseConfig(ed, attrs, cfgs, 64, &n) || !n) { printf("RESULT: no OpenGL (EGL gave no configuration)\n"); return 2; }
    XVisualInfo *vi = NULL;
    EGLConfig cfg = cfgs[0];
    for (int i = 0; i < n && !vi; i++) {
        EGLint vid = 0;
        if (!eglGetConfigAttrib(ed, cfgs[i], EGL_NATIVE_VISUAL_ID, &vid) || !vid) continue;
        XVisualInfo tmpl;
        memset(&tmpl, 0, sizeof tmpl);
        tmpl.visualid = (VisualID)vid;
        int m = 0;
        XVisualInfo *v = XGetVisualInfo(d, VisualIDMask, &tmpl, &m);
        if (!v || !m) continue;
        if (!argb || is_argb(d, v->visual, v->depth)) { vi = v; cfg = cfgs[i]; }
        else XFree(v);
    }
    if (!vi) { printf("RESULT: no OpenGL (no %s visual through EGL)\n", argb ? "ARGB" : "RGB"); return 2; }
    Window w = make_window(d, vi);
    EGLSurface s = eglCreateWindowSurface(ed, cfg, (EGLNativeWindowType)w, NULL);
    EGLint ca[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
                    EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE };
    EGLContext c = eglCreateContext(ed, cfg, EGL_NO_CONTEXT, core ? ca : NULL);
    if (s == EGL_NO_SURFACE || c == EGL_NO_CONTEXT || !eglMakeCurrent(ed, s, s, c)) {
        printf("RESULT: no OpenGL (no EGL %scontext or window surface)\n", core ? "OpenGL 3.3 core " : "");
        return 2;
    }
    egl_dpy = ed; egl_surf = s;
    getstring_fn gs = (getstring_fn)eglGetProcAddress("glGetString");
    return finish(d, w, vi, gs ? (const char *)gs(GL_RENDERER) : NULL,
                  (clearcolor_fn)eglGetProcAddress("glClearColor"), (clear_fn)eglGetProcAddress("glClear"),
                  (finish_fn)eglGetProcAddress("glFinish"), egl_swap, NULL, core ? egl_proc : NULL);
}

int main(int argc, char **argv) {
    int egl = argc > 1 && strcmp(argv[1], "egl") == 0;
    int argb = 0, core = 0;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "argb") == 0) argb = 1;
        if (strcmp(argv[i], "core") == 0) core = 1;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    Display *d = XOpenDisplay(NULL);
    if (!d) { printf("RESULT: no OpenGL (no X display)\n"); return 2; }
    return egl ? run_egl(d, argb, core) : run_glx(d, argb, core);
}
