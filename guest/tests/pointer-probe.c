/* pointer-probe: every 300 ms, the active window's name, whether the X cursor is visible (XFixes),
 * whether some client holds a pointer grab (XGrabPointer answers AlreadyGrabbed), and the pointer's
 * position + the window under it. For the overlay "Exit game" bug (Oct 26). Stops after N seconds. */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/Xfixes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static int visible(Display *d) {
    XFixesCursorImage *ci = XFixesGetCursorImage(d); if (!ci) return 1;
    int v = 0; for (int i = 0; i < ci->width * ci->height; i++) if ((ci->pixels[i] >> 24) & 0xff) { v = 1; break; }
    XFree(ci); return v;
}
static char *name(Display *d, Window w) {
    static char buf[128]; buf[0] = 0; if (!w) return buf;
    Atom a = XInternAtom(d, "_NET_WM_NAME", True), t; int f; unsigned long n, b; unsigned char *p = NULL;
    if (a && XGetWindowProperty(d, w, a, 0, 64, False, AnyPropertyType, &t, &f, &n, &b, &p) == Success && p) { snprintf(buf, sizeof buf, "%s", (char *)p); XFree(p); }
    if (!buf[0]) { char *s = NULL; if (XFetchName(d, w, &s) && s) { snprintf(buf, sizeof buf, "%s", s); XFree(s); } }
    return buf;
}
int main(int argc, char **argv) {
    int secs = argc > 1 ? atoi(argv[1]) : 120;
    Display *d = XOpenDisplay(NULL); if (!d) return 1;
    Window root = DefaultRootWindow(d);
    Atom active = XInternAtom(d, "_NET_ACTIVE_WINDOW", True);
    char last[256] = "";
    for (int i = 0; i < secs * 10 / 3; i++) {
        Window aw = 0; Atom t; int f; unsigned long n, b; unsigned char *p = NULL;
        if (XGetWindowProperty(d, root, active, 0, 1, False, XA_WINDOW, &t, &f, &n, &b, &p) == Success && p) { aw = *(Window *)p; XFree(p); }
        int vis = visible(d);
        int g = XGrabPointer(d, root, False, 0, GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
        const char *grab = g == GrabSuccess ? "free" : g == AlreadyGrabbed ? "GRABBED by another client" : g == GrabFrozen ? "frozen" : "other";
        if (g == GrabSuccess) XUngrabPointer(d, CurrentTime);
        Window rr, cw; int rx, ry, wx, wy; unsigned m;
        XQueryPointer(d, root, &rr, &cw, &rx, &ry, &wx, &wy, &m);
        char an[128]; snprintf(an, sizeof an, "%s", name(d, aw));
        char line[256]; snprintf(line, sizeof line, "active=\"%s\" cursor=%s pointer=%s under=\"%s\"", an, vis ? "visible" : "HIDDEN", grab, name(d, cw));
        if (strcmp(line, last)) { time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm); printf("%02d:%02d:%02d %s at %d,%d\n", tm.tm_hour, tm.tm_min, tm.tm_sec, line, rx, ry); fflush(stdout); strcpy(last, line); }
        usleep(300000);
    }
    return 0;
}
