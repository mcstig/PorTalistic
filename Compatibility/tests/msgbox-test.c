/*
 * msgbox-test: does a Wine build show message boxes the way PorTalistic's does?
 *
 * Built by Compatibility/test-dxmt-wine.sh, as a 64-bit and a 32-bit program, and run
 * against the Wine that build-dxmt-wine.sh produced.
 *
 *     msgbox-test.exe            the automatic checks, expecting native alerts
 *     msgbox-test.exe dialog     the same checks, expecting Wine's own dialog: for
 *                                UseNativeMessageBoxes=n, or any other Wine
 *     msgbox-test.exe gallery    one of each kind of message box, for a person to look at
 *
 * The automatic checks answer every message box themselves, the way programs and
 * automation do (WM_COMMAND, Return, EndDialog), so nobody has to be at the keyboard;
 * each alert is on screen for under a second. The exit code is the number that failed.
 */

#include <windows.h>

#define COUNT_OF(a) (sizeof(a) / sizeof((a)[0]))

enum mode { MODE_NATIVE, MODE_DIALOG, MODE_GALLERY };
enum modality { OWNERLESS, OWNED, TASK_MODAL };

struct check
{
    const char *name;
    UINT type;
    void (*act)(void);
    int expected;
    enum modality modality;
    BOOL long_text;
};

static HHOOK cbt_hook;
static HWND box;            /* the message box that is up */
static HWND watched;        /* a window that has to be disabled while it is up */
static BOOL box_visible, watched_disabled, acted;
static void (*action)(void);
static WCHAR long_text[8192];


static void print(const char *format, ...)
{
    char buffer[1024];
    va_list args;
    DWORD written;
    int len;

    va_start(args, format);
    len = wvsprintfA(buffer, format, args);
    va_end(args);
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), buffer, len, &written, NULL);
}

static const char *answer_name(int answer)
{
    switch (answer)
    {
    case IDOK:          return "OK";
    case IDCANCEL:      return "Cancel";
    case IDABORT:       return "Abort";
    case IDRETRY:       return "Retry";
    case IDIGNORE:      return "Ignore";
    case IDYES:         return "Yes";
    case IDNO:          return "No";
    case IDTRYAGAIN:    return "Try Again";
    case IDCONTINUE:    return "Continue";
    default:            return "?";
    }
}

/* A message box's dialog is the only dialog these programs create. */
static LRESULT CALLBACK cbt_proc(int code, WPARAM wparam, LPARAM lparam)
{
    WCHAR name[16];

    if (code == HCBT_CREATEWND && GetClassNameW((HWND)wparam, name, COUNT_OF(name)) &&
        !lstrcmpW(name, L"#32770"))
        box = (HWND)wparam;

    return CallNextHookEx(cbt_hook, code, wparam, lparam);
}

/* What a program, or a person's automation, does to a message box. Run from a thread
   timer, which the message box's own modal loop dispatches. */
static void answer_yes(void)   { PostMessageW(box, WM_COMMAND, IDYES, 0); }
static void answer_no(void)    { PostMessageW(box, WM_COMMAND, IDNO, 0); }
static void press_return(void) { PostMessageW(box, WM_KEYDOWN, VK_RETURN, 0); }
static void end_ok(void)       { EndDialog(box, IDOK); }

static void CALLBACK on_timer(HWND hwnd, UINT msg, UINT_PTR id, DWORD time)
{
    KillTimer(NULL, id);

    if (!box)
    {
        SetTimer(NULL, 0, 100, on_timer);
        return;
    }

    box_visible = IsWindowVisible(box);
    if (watched) watched_disabled = !IsWindowEnabled(watched);
    acted = TRUE;
    action();
}

static HWND create_other_window(void)
{
    return CreateWindowExW(0, L"STATIC", L"msgbox-test", WS_OVERLAPPEDWINDOW,
                           0, 0, 200, 100, NULL, NULL, NULL, NULL);
}

static int run_check(const struct check *check, enum mode mode)
{
    BOOL expect_visible = mode == MODE_DIALOG || (check->type & MB_HELP);
    const WCHAR *text = L"This box is answered by the test itself. There is nothing to click.";
    HWND owner = NULL, other = NULL;
    int ret, failures = 0;

    box = NULL;
    watched = NULL;
    box_visible = watched_disabled = acted = FALSE;
    action = check->act;
    if (check->long_text) text = long_text;

    if (check->modality == OWNED)
        watched = owner = create_other_window();
    else if (check->modality == TASK_MODAL)
        watched = other = create_other_window();

    SetTimer(NULL, 0, 800, on_timer);
    ret = MessageBoxW(owner, text, L"msgbox-test", check->type);

    if (!acted)
    {
        print("FAIL  %s: the box ended before the test could answer it (returned %d)\n", check->name, ret);
        failures++;
    }
    if (ret != check->expected)
    {
        print("FAIL  %s: returned %d (%s), expected %d (%s)\n", check->name,
              ret, answer_name(ret), check->expected, answer_name(check->expected));
        failures++;
    }
    if (acted && box_visible != expect_visible)
    {
        print("FAIL  %s: %s\n", check->name, box_visible ?
              "Wine's dialog was on screen, so no native alert was shown" :
              "Wine's dialog stayed hidden where it should have been shown");
        failures++;
    }
    if (watched && acted && !watched_disabled)
    {
        print("FAIL  %s: the other window stayed enabled while the box was up\n", check->name);
        failures++;
    }
    if (watched && !IsWindowEnabled(watched))
    {
        print("FAIL  %s: the other window was still disabled after the box closed\n", check->name);
        failures++;
    }
    if (!failures) print("PASS  %s\n", check->name);

    if (owner) DestroyWindow(owner);
    if (other) DestroyWindow(other);
    return failures;
}

static const struct check checks[] =
{
    { "A Yes/No box answered No returns No",
      MB_YESNO | MB_ICONQUESTION, answer_no, IDNO, OWNERLESS, FALSE },
    { "Return picks the default button, not the first one",
      MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2, press_return, IDCANCEL, OWNERLESS, FALSE },
    { "A box the program ends itself goes away",
      MB_OK | MB_ICONERROR, end_ok, IDOK, OWNERLESS, FALSE },
    { "An owned box disables its owner, and enables it again",
      MB_YESNO, answer_yes, IDYES, OWNED, FALSE },
    { "A task-modal box disables the thread's other windows, and enables them again",
      MB_OK | MB_TASKMODAL, end_ok, IDOK, TASK_MODAL, FALSE },
    { "A message too long for an alert's label still comes up",
      MB_OK | MB_ICONERROR, end_ok, IDOK, OWNERLESS, TRUE },
    { "A box with a Help button is Wine's own dialog",
      MB_OK | MB_HELP, end_ok, IDOK, OWNERLESS, FALSE },
};

static void gallery(void)
{
    static const struct
    {
        const WCHAR *caption;
        const WCHAR *text;
        UINT type;
    }
    boxes[] =
    {
        { L"Message",
          L"The video card in this computer does not meet the minimum video requirements for this "
          L"game. The minimum system requirements can be found in the game packaging and manual. "
          L"(Info=4095 0x106B 0x1A060209 )\n\nPlaying the game on this hardware is COMPLETELY "
          L"UNSUPPORTED, UNSTABLE, AND NOT RECOMMENDED. Do you wish to Continue anyway?",
          MB_YESNO },
        { L"Saved", L"Your progress has been saved.", MB_OK | MB_ICONINFORMATION },
        { L"Unsaved changes", L"Quit without saving?\n\nCancel is the default here, so Return picks it.",
          MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2 },
        { L"Save game", L"Save before quitting?", MB_YESNOCANCEL | MB_ICONQUESTION },
        { L"Fatal error", L"Couldn't read data\\textures.pak.", MB_ABORTRETRYIGNORE | MB_ICONERROR },
        { L"Connection lost", L"The server stopped responding.", MB_CANCELTRYCONTINUE | MB_ICONWARNING },
        { L"Crash report", long_text, MB_OK | MB_ICONERROR },
        { L"Help available",
          L"This one has a Help button, which only Wine's own dialog can offer, so it still looks the old way.",
          MB_OK | MB_HELP },
    };
    unsigned int i;

    for (i = 0; i < COUNT_OF(boxes); i++)
    {
        int ret = MessageBoxW(NULL, boxes[i].text, boxes[i].caption, boxes[i].type);
        print("      %d of %d answered %s\n", i + 1, (int)COUNT_OF(boxes), answer_name(ret));
    }
}

/* Is word one of the arguments? The program's own path, quoted or not, is skipped. */
static BOOL has_argument(const char *word)
{
    const char *p = GetCommandLineA();
    char token[64];
    BOOL first = TRUE;

    while (*p)
    {
        unsigned int len = 0;
        BOOL quoted = FALSE;

        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        while (*p && (quoted || (*p != ' ' && *p != '\t')))
        {
            if (*p == '"') quoted = !quoted;
            else if (len < sizeof(token) - 1) token[len++] = *p;
            p++;
        }
        token[len] = 0;
        if (!first && !lstrcmpiA(token, word)) return TRUE;
        first = FALSE;
    }
    return FALSE;
}

int main(void)
{
    enum mode mode = MODE_NATIVE;
    int failures = 0;
    unsigned int i, len = 0;

    if (has_argument("gallery")) mode = MODE_GALLERY;
    else if (has_argument("dialog")) mode = MODE_DIALOG;

    /* A crash report's worth of stack trace. */
    for (i = 0; i < 60; i++)
        len += wsprintfW(long_text + len, L"   at Game.Frame.Update(%d) in C:\\build\\game\\frame.cpp:line %d\r\n",
                         i, 100 + i * 7);

    if (mode == MODE_GALLERY)
    {
        gallery();
        return 0;
    }

    cbt_hook = SetWindowsHookExW(WH_CBT, cbt_proc, NULL, GetCurrentThreadId());
    for (i = 0; i < COUNT_OF(checks); i++)
        failures += run_check(&checks[i], mode) ? 1 : 0;
    UnhookWindowsHookEx(cbt_hook);

    print("%d of %d checks passed (%d-bit, expecting %s)\n", (int)COUNT_OF(checks) - failures,
          (int)COUNT_OF(checks), (int)sizeof(void *) * 8,
          mode == MODE_DIALOG ? "Wine's own dialog" : "native alerts");
    return failures;
}

#ifdef NO_CRT
/* Only for building without a C runtime, as the container that wrote this did. mingw's
   own startup code provides both of these. */
void __main(void)
{
}

void __cdecl mainCRTStartup(void)
{
    ExitProcess(main());
}
#endif
