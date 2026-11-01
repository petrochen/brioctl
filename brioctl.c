// brioctl: read and change Logitech MX Brio settings without Logitech software.
//
// Sends UVC class requests to the camera's VideoControl interface through IOKit.
// Only the controls listed in CTRLS are ever written; everything else is read-only.
// Where each setting lives in the camera and how it behaves: docs/registers.md.
#include <dirent.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMediaIO/CMIOHardware.h>
#include <dispatch/dispatch.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/usb/IOUSBLib.h>

#define VID_LOGITECH 0x046d
#define PID_MXBRIO 0x0944
#define MIC_NAME "MX Brio"
#ifndef VERSION
#define VERSION "dev"  // the Makefile passes the real one
#endif

// Logitech extension units: the GUID comes from the camera's USB descriptor, the name is the one Logitech uses
#define GUID_VIDEOPIPE "49e40215-f434-47fe-b158-0e885023e51b"
#define GUID_PERIPHERAL "ffe52d21-8030-4e2c-82d9-f587d00540bd"
#define GUID_INFO "69678ee4-410f-40db-a850-7420d7d8240e"
#define GUID_STATS "5a6d654c-7e35-4d4e-810d-069d15e0f79b"  // Video Statistics
#define GUID_APP "29144c1f-658d-4f47-a40f-0ed339428bf0"    // App Settings: RightSight block
#define GUID_TESTDEBUG "1f5d4ca9-de11-4487-840d-50933c8ec8d1"
#define GUID_AIT "23e49ed0-1178-4f31-ae52-d2fb8a8d3b48"      // AIT custom: chip ISP commands, firmware update
#define GUID_UNKNOWN "2c49d16a-32b8-4485-3ea8-643a152362f2"  // no known purpose
#define INFO_FIRMWARE 0x01
#define INFO_SERIAL 0x07
#define INFO_COLOR 0x0b           // body colour code
#define INFO_FACTORY_RESET 0x0c   // writing 0xAA restarts the camera with factory settings
#define INFO_FLASH_LOCK 0x0d      // flash lock (a key locks or unlocks it); never written
#define FACTORY_RESET_VALUE 0xaa
#define INFO_SHOWMODE_ACTIVE 0x0e  // 1 while the camera is tilted to the desk and shows it
#define STATS_STREAM 0x01         // streaming flag, ?, width, height (16-bit)
#define PERIPHERAL_LED 0x09       // byte 1: LED is on; the camera ignores writes (locked on retail units)
#define PERIPHERAL_RIGHTSIGHT 0x18  // byte 0: Logitech's app drives framing; without video the camera then ignores zoom
#define APP_RIGHTSIGHT 0x01       // marker, enabled, speed, framing level, priority, application

static const struct { const char *guid, *name; } KNOWN_XU[] = {
    {GUID_VIDEOPIPE, "Videopipe Control"},
    {GUID_PERIPHERAL, "Peripheral Control"},
    {GUID_INFO, "device info"},
    {GUID_TESTDEBUG, "Test Debug"},
    {GUID_STATS, "Video Statistics"},
    {GUID_APP, "App Settings (RightSight)"},
    {GUID_AIT, "AIT custom (chip ISP commands, firmware update)"},
};

enum { SET_CUR = 0x01, GET_CUR = 0x81, GET_MIN, GET_MAX, GET_RES, GET_LEN, GET_INFO, GET_DEF };
enum { INFO_GET = 0x01, INFO_SET = 0x02, INFO_AUTO = 0x04 };  // GET_INFO bits; AUTO: driven by an auto mode now
enum { DESC_INTERFACE = 0x04, DESC_CS_INTERFACE = 0x24 };
enum { VC_INPUT_TERMINAL = 0x02, VC_PROCESSING_UNIT = 0x05, VC_EXTENSION_UNIT = 0x06, ITT_CAMERA = 0x0201 };
enum { U_CT, U_PU, U_VIDEOPIPE, U_PERIPHERAL, U_INFO, U_STATS, U_APP, U_COUNT };
enum { CT_AE_MODE = 0x02, CT_ZOOM = 0x0b, CT_PANTILT = 0x0d };

// Logitech models whose extension-unit controls brioctl knows. "full" is the camera brioctl was built on and tested
// with. "experimental" gets only what other projects confirm (cameractrls: field of view on all of them; OpenLogi issue
// 1222: Show Mode on the Brio 500). Any other camera, Logitech or not, gets the standard UVC controls and nothing else:
// extension units are never written there. F_HDR: Logi Tune calls the backlight compensation control HDR.
enum { S_STANDARD, S_EXPERIMENTAL, S_FULL };
static const char *const SUPPORT[] = {"standard", "experimental", "full"};
enum { F_FOV = 1, F_SHOW = 2, F_FULL = 4, F_HDR = 8, F_NOHDR = 16 };  // F_NOHDR is derived: the name is backlight
static const struct { int pid, feat; const char *name; } MODELS[] = {
    {0x0944, F_FULL | F_FOV | F_SHOW | F_HDR, "MX Brio"},
    {0x0943, F_FOV | F_SHOW | F_HDR, "Brio 500"},
    {0x085e, F_FOV | F_HDR, "Brio"},
    {0x0946, F_FOV, "Brio 501"},
    {0x0919, F_FOV, "Brio 505"},
    {0x086b, F_FOV | F_HDR, "Brio 4K Stream Edition"},
};

#define MAX_CAMS 16
typedef struct {  // a UVC camera on USB
    int vid, pid, index;       // index: 1-based, in location order
    unsigned loc;              // USB location id
    char name[64], serial[48]; // USB strings
    const char *model;         // name in MODELS, NULL if unknown
    int feat, support;         // F_* and S_*
    int slot;                  // fake: which BRIOCTL_FAKE file
    io_service_t svc;          // real: the USB device, held until dropCameras
} CamInfo;

typedef IOUSBDeviceInterface650 **Dev;

typedef struct {
    Dev dev;
    const uint8_t *cfg;  // configuration descriptor
    int cfgLen;
    int vcIf;            // VideoControl interface number
    int unit[U_COUNT];   // unit ids by U_*, 0 = absent
    uint32_t bm[2];      // bmControls of the camera terminal and the processing unit: the standard controls declared
    CamInfo info;
    int feat;            // info.feat, plus F_NOHDR
} Cam;

typedef struct { const char *name; long raw; } Map;  // what the user types and sees <-> register value

// Several names for one value are fine (the first is the one shown). A name can come twice with different values: the
// first one the camera accepts is used (auto exposure is 8 on Logitech cameras and 2 on most others).
static const Map ON_OFF[] = {{"on", 1}, {"off", 0}, {"1", 1}, {"0", 0}, {NULL, 0}};
static const Map FOV_MAP[] = {{"90", 0}, {"78", 1}, {"65", 2}, {NULL, 0}};
static const Map FLICKER_MAP[] = {{"50", 1}, {"60", 2}, {"off", 0}, {"auto", 3}, {NULL, 0}};
static const Map PRIORITY_MAP[] = {{"fps", 0}, {"exposure", 1}, {NULL, 0}};
static const Map AE_MAP[] = {{"auto", 8}, {"manual", 1}, {"auto", 2}, {"shutter", 4}, {NULL, 0}};

typedef struct {
    const char *name, *help;  // name NULL: a group heading (help is its title)
    int unit, sel, len;       // where the control lives and its size in bytes
    const Map *map;           // named values; NULL means a plain number
    int off, size;            // field inside the control (pan and tilt share one); size 0 = whole control
    int scale;                // register value = number * scale; 0 means 1
    int sgn;                  // field is signed
    int need;                 // F_* the camera's model must have: Logitech controls; F_NOHDR: the backlight name
    const char *group;        // headings: the name of the group in JSON
} Ctrl;

// What is written about a control: the names of its values are added after a colon (or where the help has "%s"), a
// numeric control's range comes from the camera. Order matters for save and apply: auto modes come before the values
// they gate. Standard controls are shown when the camera declares them, Logitech ones when the model gets them (MODELS).
static const Ctrl CTRLS[] = {
    {NULL, "Logitech (mapped from Logi Tune)", .group = "Logitech"},
    {"fov",        "field of view in degrees",                            U_VIDEOPIPE,  0x05, 1, FOV_MAP, .need = F_FOV},
    {"showmode",   "Show Mode (flip the picture when tilted to the desk)", U_VIDEOPIPE, 0x0d, 1, ON_OFF, .need = F_SHOW},
    {"hdr",        "HDR (UVC backlight compensation)",                    U_PU,         0x01, 2, ON_OFF, .need = F_HDR},
    {"warmth",     "white balance warmth, 50 = neutral",                  U_VIDEOPIPE,  0x15, 1, .need = F_FULL},
    {"tint",       "tint, 50 = neutral",                                  U_VIDEOPIPE,  0x12, 1, .need = F_FULL},
    {"vibrance",   "vibrance, 128 = neutral",                             U_VIDEOPIPE,  0x14, 1, .need = F_FULL},
    {"expcomp",    "exposure compensation, 128 = neutral",                U_VIDEOPIPE,  0x13, 1, .need = F_FULL},
    {"mic",        "camera microphone%s (camera restarts on change)",     U_PERIPHERAL, 0x10, 1, ON_OFF, .need = F_FULL},
    {NULL, "Framing", .group = "Framing"},
    {"zoom",       "zoom, 100 = 1x on Logitech cameras",                  U_CT, CT_ZOOM, 2},
    {"pan",        "move the zoomed frame, in degrees",                   U_CT, CT_PANTILT, 8, NULL, 0, 4, 3600, 1},
    {"tilt",       "move the zoomed frame, in degrees",                   U_CT, CT_PANTILT, 8, NULL, 4, 4, 3600, 1},
    {"roll",       "rotate the picture, in degrees",                      U_CT, 0x0f, 2, NULL, 0, 0, 0, 1},
    {NULL, "Exposure and image (standard UVC)", .group = "Exposure and image"},
    {"priority",   "in low light keep",                                   U_CT, 0x03, 1, PRIORITY_MAP},
    {"ae",         "auto exposure",                                       U_CT, CT_AE_MODE, 1, AE_MAP},
    {"exposure",   "exposure time in 100 us units (ae manual)",           U_CT, 0x04, 4},
    {"iris",       "iris, f-number x 100",                                U_CT, 0x09, 2},
    {"gain",       "gain",                                                U_PU, 0x04, 2},
    {"backlight",  "backlight compensation",                              U_PU, 0x01, 2, .need = F_NOHDR},
    {"flicker",    "anti-flicker, mains frequency in Hz",                 U_PU, 0x05, 1, FLICKER_MAP},
    {"brightness", "brightness",                                          U_PU, 0x02, 2, NULL, 0, 0, 0, 1},
    {"contrast",   "contrast",                                            U_PU, 0x03, 2},
    {"hueauto",    "automatic hue",                                       U_PU, 0x10, 1, ON_OFF},
    {"hue",        "hue (hueauto off)",                                   U_PU, 0x06, 2, NULL, 0, 0, 0, 1},
    {"saturation", "saturation",                                          U_PU, 0x07, 2},
    {"sharpness",  "sharpness",                                           U_PU, 0x08, 2},
    {"gamma",      "gamma",                                               U_PU, 0x09, 2},
    {"awb",        "auto white balance",                                  U_PU, 0x0b, 1, ON_OFF},
    {"wb",         "white balance in kelvin (awb off)",                   U_PU, 0x0a, 2},
    {"af",         "autofocus",                                           U_CT, 0x08, 1, ON_OFF},
    {"focus",      "focus (af off)",                                      U_CT, 0x06, 2},
    {"privacy",    "privacy shutter",                                     U_CT, 0x11, 1, ON_OFF},
    {NULL, "Found in the firmware, not used by Logitech's apps", .group = "Found in the firmware"},
    // Peripheral 3 also holds a speed (u16, 10-100); 10, 50 and 100 gave the same 3 s glide, so it is not offered.
    {"smooth",     "glide to new zoom and pan in about 3 s",              U_PERIPHERAL, 0x03, 3, ON_OFF, 0, 1, .need = F_FULL},
};
#define NCTRLS (int)(sizeof CTRLS / sizeof *CTRLS)

// The image and exposure presets of Logi Options+, as brioctl settings, and the firmware's hidden Color Boost.
// Color Boost (Videopipe 1) sends the image processor saturation x2, capped at 255, until the video restarts;
// saturation 255 is the same picture from the default 128 and the camera keeps it.
static const struct { const char *name, *settings; } PRESETS[] = {
    {"neutral", "warmth 50\nsaturation 128\n"},
    {"warmer", "warmth 60\n"},
    {"cooler", "warmth 40\n"},
    {"bw", "saturation 0\n"},
    {"standard", "priority exposure\n"},
    {"streaming", "priority fps\n"},
    {"colorboost", "saturation 255\n"},
};
#define NPRESETS (int)(sizeof PRESETS / sizeof *PRESETS)

// A register as a snapshot stores it: GET_INFO, GET_LEN (extension units only) and the raw bytes of each field.
enum { F_CUR, F_MIN, F_MAX, F_RES, F_DEF, F_COUNT };
static const struct { int req; const char *name; } FIELDS[F_COUNT] = {
    {GET_CUR, "cur"}, {GET_MIN, "min"}, {GET_MAX, "max"}, {GET_RES, "res"}, {GET_DEF, "def"}};
#define REG_MAX 64  // longest register value a snapshot keeps

typedef struct {
    int unit, sel, info, len;                          // info and len -1: not in the snapshot
    struct { int n; uint8_t b[REG_MAX]; } f[F_COUNT];  // n 0: field not in the snapshot
} Reg;

static void hex(FILE *f, const uint8_t *b, int n) {
    for (int i = 0; i < n; i++) fprintf(f, "%02x", b[i]);
}

static void printReg(FILE *f, const Reg *r) {
    fprintf(f, "reg %d %d", r->unit, r->sel);
    if (r->info >= 0) fprintf(f, " info %02x", r->info);
    if (r->len >= 0) fprintf(f, " len %04x", r->len);
    for (int i = 0; i < F_COUNT; i++)
        if (r->f[i].n) {
            fprintf(f, " %s ", FIELDS[i].name);
            hex(f, r->f[i].b, r->f[i].n);
        }
    fprintf(f, "\n");
}

static void guidString(const uint8_t *g, char s[37]) {
    snprintf(s, 37, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", g[3], g[2], g[1], g[0],
             g[5], g[4], g[7], g[6], g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15]);
}

// Matching dictionary for a vendor and product id; the key names differ between USB and HID.
static CFMutableDictionaryRef vidPid(CFMutableDictionaryRef m, CFStringRef vidKey, CFStringRef pidKey, int vid, int pid) {
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberIntType, &vid), np = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, vidKey, nv);
    CFDictionarySetValue(m, pidKey, np);
    CFRelease(nv);
    CFRelease(np);
    return m;
}

// The descriptor at offset i of the configuration descriptor, NULL at the end or if it would run past it. Callers
// still check d[0] against the fields they read.
static const uint8_t *descAt(const Cam *c, int i) {
    return i + 2 <= c->cfgLen && c->cfg[i] >= 2 && i + c->cfg[i] <= c->cfgLen ? c->cfg + i : NULL;
}

// A bmControls bitmap of up to 4 bytes at d + at, bSize bytes long (0 if the descriptor is too short for it).
static uint32_t bitmap(const uint8_t *d, int at, int size) {
    uint32_t bm = 0;
    if (at + size > d[0]) return 0;
    for (int i = 0; i < size && i < 4; i++) bm |= (uint32_t)d[at + i] << (8 * i);
    return bm;
}

// Walk the configuration descriptor in c->cfg: the first VideoControl interface, its unit ids and the standard controls
// the camera terminal and the processing unit declare.
static int parseConfig(Cam *c) {
    c->vcIf = -1;
    memset(c->unit, 0, sizeof c->unit);
    memset(c->bm, 0, sizeof c->bm);
    int cls = 0, sub = 0, inVC = 0;
    const uint8_t *d;
    for (int i = 0; (d = descAt(c, i)); i += d[0]) {
        if (d[1] == DESC_INTERFACE && d[0] >= 7) {
            cls = d[5];
            sub = d[6];
            inVC = cls == 0x0e && sub == 1 && (c->vcIf < 0 || c->vcIf == d[2]);
            if (inVC) c->vcIf = d[2];
        } else if (d[1] == DESC_CS_INTERFACE && d[0] >= 4 && inVC) {
            if (d[2] == VC_INPUT_TERMINAL && d[0] >= 6 && (d[4] | d[5] << 8) == ITT_CAMERA && !c->unit[U_CT]) {
                c->unit[U_CT] = d[3];
                if (d[0] >= 15) c->bm[0] = bitmap(d, 15, d[14]);
            } else if (d[2] == VC_PROCESSING_UNIT && d[0] >= 8 && !c->unit[U_PU]) {
                c->unit[U_PU] = d[3];
                c->bm[1] = bitmap(d, 8, d[7]);
            } else if (d[2] == VC_EXTENSION_UNIT && d[0] >= 20) {
                char g[37];
                guidString(d + 4, g);
                if (!strcmp(g, GUID_VIDEOPIPE)) c->unit[U_VIDEOPIPE] = d[3];
                else if (!strcmp(g, GUID_PERIPHERAL)) c->unit[U_PERIPHERAL] = d[3];
                else if (!strcmp(g, GUID_INFO)) c->unit[U_INFO] = d[3];
                else if (!strcmp(g, GUID_STATS)) c->unit[U_STATS] = d[3];
                else if (!strcmp(g, GUID_APP)) c->unit[U_APP] = d[3];
            }
        }
    }
    if (c->vcIf < 0) { fprintf(stderr, "no VideoControl interface\n"); return -1; }
    return 0;
}

static CamInfo target;  // the camera every command talks to, chosen by selectCamera (watch: by itself)

static int usbNumber(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, NULL, 0);
    int n = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &n);
    if (v) CFRelease(v);
    return n;
}

static void usbString(io_service_t s, CFStringRef key, char *out, size_t n) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, NULL, 0);
    out[0] = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, out, n, kCFStringEncodingUTF8);
    if (v) CFRelease(v);
}

// Transport: request, scanCameras, attach, cameraPresent, closeCam and micGain are the only functions that touch
// hardware.
#ifdef BRIOCTL_FAKE
// A camera read from a snapshot file (brioctl snapshot) so the tests run without hardware. SET_CUR stores the value
// and closeCam writes the file back, so separate brioctl processes see each other's writes. BRIOCTL_FAKE may name
// several snapshots separated by ':': several cameras, at USB locations 0x100000, 0x200000, ...
#define FAKE_REGS 128

static struct {
    Reg reg[FAKE_REGS];
    int nreg, dirty, hasMic, hasDevice, vid, pid;
    Float32 mic;
    char path[PATH_MAX], head[256], name[64], serial[48];
    uint8_t *desc;
    int descLen;
} fk;

static int nibble(int ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    return ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : -1;
}

static int parseHex(const char *s, uint8_t *out, int max) {
    int n = 0;
    for (; s[0] && n < max; s += 2, n++) {
        int hi = nibble(s[0]), lo = s[1] ? nibble(s[1]) : -1;
        if (hi < 0 || lo < 0) return -1;
        out[n] = hi << 4 | lo;
    }
    return *s ? -1 : n;
}

// BRIOCTL_FAKE_TRACE=1 logs every SET_CUR (and the micgain write), 2 also every GET request.
static int traceLevel(void) {
    const char *t = getenv("BRIOCTL_FAKE_TRACE");
    return t && *t ? (atoi(t) > 1 ? 2 : 1) : 0;
}

// Parse one snapshot line (it is cut up on the way); -1 if it is not valid.
#define NEXT strtok_r(NULL, " \t\r\n", &save)
static int fakeLine(char *line) {
    if (line[0] == '#') {
        if (!fk.head[0]) snprintf(fk.head, sizeof fk.head, "%.*s", (int)strcspn(line, "\r\n"), line);
        return 0;
    }
    if (!strncmp(line, "name ", 5)) {  // the rest of the line, spaces included
        snprintf(fk.name, sizeof fk.name, "%.*s", (int)strcspn(line + 5, "\r\n"), line + 5);
        return 0;
    }
    char *save, *tok = strtok_r(line, " \t\r\n", &save), *a = tok ? NEXT : NULL;
    if (!tok) return 0;
    if (!strcmp(tok, "device") && a) {
        char *pid = NEXT, *e1, *e2;
        if (!pid) return -1;
        fk.vid = (int)strtol(a, &e1, 16);
        fk.pid = (int)strtol(pid, &e2, 16);
        if (*e1 || *e2) return -1;
        fk.hasDevice = 1;
    } else if (!strcmp(tok, "serial") && a) {
        snprintf(fk.serial, sizeof fk.serial, "%s", a);
    } else if (!strcmp(tok, "micgain") && a) {
        fk.hasMic = 1;
        fk.mic = strtof(a, NULL);
    } else if (!strcmp(tok, "descriptor") && a) {
        free(fk.desc);
        fk.desc = calloc(1, strlen(a) / 2 + 64);  // zero padding: the descriptor walk may read past the last unit
        if ((fk.descLen = parseHex(a, fk.desc, (int)strlen(a) / 2)) < 0) return -1;
    } else if (!strcmp(tok, "reg") && a && fk.nreg < FAKE_REGS) {
        char *sel = NEXT;
        Reg *r = &fk.reg[fk.nreg++];
        if (!sel) return -1;
        r->unit = atoi(a);
        r->sel = atoi(sel);
        r->info = r->len = -1;
        for (char *key, *val; (key = NEXT) && (val = NEXT);) {
            if (!strcmp(key, "info")) r->info = (int)strtol(val, NULL, 16);
            else if (!strcmp(key, "len")) r->len = (int)strtol(val, NULL, 16);
            for (int i = 0; i < F_COUNT; i++)
                if (!strcmp(key, FIELDS[i].name) && (r->f[i].n = parseHex(val, r->f[i].b, REG_MAX)) < 0)
                    return -1;
        }
    } else return -1;
    return 0;
}
#undef NEXT

static int fakeLoad(const char *path) {
    free(fk.desc);
    memset(&fk, 0, sizeof fk);
    snprintf(fk.path, sizeof fk.path, "%s", path);
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return -1; }
    char *line = NULL;
    size_t cap = 0;
    int rc = 0;
    while (!rc && getline(&line, &cap, f) > 0) {
        char *work = strdup(line);  // fakeLine cuts its copy up, the error message shows the whole line
        rc = work ? fakeLine(work) : -1;
        free(work);
        if (rc) fprintf(stderr, "%s: bad snapshot line: %.*s\n", path, (int)strcspn(line, "\r\n"), line);
    }
    free(line);
    fclose(f);
    if (!rc && !fk.hasDevice) {  // a snapshot from before 1.1 has no device line: it is an MX Brio
        fk.vid = VID_LOGITECH;
        fk.pid = PID_MXBRIO;
        if (!fk.name[0]) snprintf(fk.name, sizeof fk.name, "MX Brio");
    }
    return rc;
}

// The snapshot paths in BRIOCTL_FAKE; -1 if it is not set. Once a camera is chosen, BRIOCTL_FAKE_AFTER (if set) is the
// list instead: the cameras came back in another order, as after a reconnect.
static int fakePaths(char paths[][PATH_MAX], int max) {
    const char *env = target.vid && getenv("BRIOCTL_FAKE_AFTER") ? getenv("BRIOCTL_FAKE_AFTER") : getenv("BRIOCTL_FAKE");
    if (!env || !*env) { fprintf(stderr, "BRIOCTL_FAKE is not set (path of a brioctl snapshot)\n"); return -1; }
    int n = 0;
    while (*env && n < max) {
        size_t len = strcspn(env, ":");
        if (len) snprintf(paths[n++], PATH_MAX, "%.*s", (int)len, env);
        env += len + (env[len] ? 1 : 0);
    }
    return n;
}

static int scanCameras(CamInfo *l, int max) {
    static char paths[MAX_CAMS][PATH_MAX];
    int n = fakePaths(paths, max < MAX_CAMS ? max : MAX_CAMS);
    for (int i = 0; i < n; i++) {
        if (fakeLoad(paths[i])) return -1;
        memset(&l[i], 0, sizeof l[i]);
        l[i].vid = fk.vid;
        l[i].pid = fk.pid;
        l[i].loc = (unsigned)(i + 1) << 20;
        l[i].slot = i;
        snprintf(l[i].name, sizeof l[i].name, "%s", fk.name);
        snprintf(l[i].serial, sizeof l[i].serial, "%s", fk.serial);
    }
    return n;
}

static int fakeSave(void) {
    char tmp[PATH_MAX + 8];
    snprintf(tmp, sizeof tmp, "%s.tmp", fk.path);
    FILE *f = fopen(tmp, "w");
    if (!f) { perror(tmp); return -1; }
    fprintf(f, "%s\n", fk.head[0] ? fk.head : "# brioctl snapshot 1");
    if (fk.hasDevice) fprintf(f, "device %04x %04x\n", fk.vid, fk.pid);
    if (fk.name[0] && fk.hasDevice) fprintf(f, "name %s\n", fk.name);
    if (fk.serial[0]) fprintf(f, "serial %s\n", fk.serial);
    if (fk.descLen) {
        fprintf(f, "descriptor ");
        hex(f, fk.desc, fk.descLen);
        fprintf(f, "\n");
    }
    if (fk.hasMic) fprintf(f, "micgain %.4f\n", fk.mic);
    for (int i = 0; i < fk.nreg; i++) printReg(f, &fk.reg[i]);
    if (fclose(f) || rename(tmp, fk.path)) {
        perror(fk.path);
        remove(tmp);
        return -1;
    }
    return 0;
}

static const char *reqName(int req) {
    static const char *const names[] = {"GET_CUR", "GET_MIN", "GET_MAX", "GET_RES", "GET_LEN", "GET_INFO", "GET_DEF"};
    return req >= GET_CUR && req <= GET_DEF ? names[req - GET_CUR] : "GET_?";
}

static IOReturn request(Cam *c, int req, int unit, int sel, void *buf, int len, UInt32 *done) {
    (void)c;
    Reg *r = NULL;
    if (req != SET_CUR && traceLevel() > 1) fprintf(stderr, "fake %s unit %d sel %d\n", reqName(req), unit, sel);
    for (int i = 0; i < fk.nreg; i++)
        if (fk.reg[i].unit == unit && fk.reg[i].sel == sel) r = &fk.reg[i];
    if (done) *done = 0;
    if (!r) return kIOUSBPipeStalled;
    if (req == SET_CUR) {  // only what the register says it accepts: SET bit and the size it has
        if (r->info < 0 || !(r->info & INFO_SET) || len != r->f[F_CUR].n) return kIOUSBPipeStalled;
        memcpy(r->f[F_CUR].b, buf, len);
        fk.dirty = 1;
        if (traceLevel()) {
            fprintf(stderr, "fake SET_CUR unit %d sel %d ", unit, sel);
            hex(stderr, buf, len);
            fprintf(stderr, "\n");
        }
        return 0;
    }
    uint8_t one[2];
    const uint8_t *src = NULL;
    int n = 0;
    if (req == GET_INFO && r->info >= 0) { one[0] = r->info; src = one; n = 1; }
    else if (req == GET_LEN && r->len >= 0) { one[0] = r->len; one[1] = r->len >> 8; src = one; n = 2; }
    for (int i = 0; i < F_COUNT; i++)
        if (FIELDS[i].req == req && r->f[i].n) { src = r->f[i].b; n = r->f[i].n; }
    if (!src) return kIOUSBPipeStalled;
    if (n > len) n = len;
    memcpy(buf, src, n);
    if (done) *done = n;
    return 0;
}

static int cameraPresent(void) {  // BRIOCTL_FAKE_ABSENT: the camera is unplugged
    const char *absent = getenv("BRIOCTL_FAKE_ABSENT");
    return !(absent && *absent);
}

static int attach(Cam *c, const CamInfo *ci) {
    static char paths[MAX_CAMS][PATH_MAX];
    int n = fakePaths(paths, MAX_CAMS);
    if (n < 0 || ci->slot >= n || fakeLoad(paths[ci->slot])) return -1;
    c->cfg = fk.desc;
    c->cfgLen = fk.descLen;
    return 0;
}

// Returns -1 if the fake camera could not be written back.
static int closeCam(Cam *c) {
    (void)c;
    int rc = fk.dirty ? fakeSave() : 0;
    fk.dirty = 0;
    return rc;
}

static int micGain(Float32 *get, const Float32 *set) {
    if (!fk.hasMic) return -1;
    if (set) {
        fk.mic = *set;
        fk.dirty = 1;
        if (traceLevel()) fprintf(stderr, "fake SET_MICGAIN %.4f\n", *set);
    } else *get = fk.mic;
    return 0;
}
#else
static IOReturn request(Cam *c, int req, int unit, int sel, void *buf, int len, UInt32 *done) {
    IOUSBDevRequestTO r = {
        .bmRequestType = USBmakebmRequestType(req & 0x80 ? kUSBIn : kUSBOut, kUSBClass, kUSBInterface),
        .bRequest = req, .wValue = sel << 8, .wIndex = (unit << 8) | c->vcIf,
        .wLength = len, .pData = buf, .noDataTimeout = 500, .completionTimeout = 500,
    };
    IOReturn kr = (*c->dev)->DeviceRequestTO(c->dev, &r);
    if (done) *done = r.wLenDone;
    return kr;
}

static int closeCam(Cam *c) {
    if (c->dev) (*c->dev)->Release(c->dev);
    c->dev = NULL;
    return 0;
}

// Every USB device with a VideoControl interface (class 0x0e, subclass 1), one entry per device.
static int scanCameras(CamInfo *l, int max) {
    int n = 0, cls = 0x0e, sub = 1;
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostInterface");
    CFNumberRef nc = CFNumberCreate(NULL, kCFNumberIntType, &cls), ns = CFNumberCreate(NULL, kCFNumberIntType, &sub);
    CFDictionarySetValue(m, CFSTR("bInterfaceClass"), nc);
    CFDictionarySetValue(m, CFSTR("bInterfaceSubClass"), ns);
    CFRelease(nc);
    CFRelease(ns);
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it)) return 0;
    for (io_service_t ifc; (ifc = IOIteratorNext(it)); IOObjectRelease(ifc)) {
        io_service_t dev;
        if (IORegistryEntryGetParentEntry(ifc, kIOServicePlane, &dev)) continue;
        unsigned loc = (unsigned)usbNumber(dev, CFSTR("locationID"));
        int seen = 0;
        for (int i = 0; i < n; i++) seen |= l[i].loc == loc;
        if (seen || n == max || !IOObjectConformsTo(dev, "IOUSBHostDevice")) {
            IOObjectRelease(dev);
            continue;
        }
        memset(&l[n], 0, sizeof l[n]);
        l[n].vid = usbNumber(dev, CFSTR("idVendor"));
        l[n].pid = usbNumber(dev, CFSTR("idProduct"));
        l[n].loc = loc;
        usbString(dev, CFSTR("USB Product Name"), l[n].name, sizeof l[n].name);
        usbString(dev, CFSTR("USB Serial Number"), l[n].serial, sizeof l[n].serial);
        l[n++].svc = dev;
    }
    IOObjectRelease(it);
    return n;
}

static int attach(Cam *c, const CamInfo *ci) {
    IOCFPlugInInterface **plug;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(ci->svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                                         &plug, &score);
    if (kr) { fprintf(stderr, "cannot attach to the camera: 0x%x\n", kr); return -1; }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&c->dev);
    (*plug)->Release(plug);
    if (!c->dev) { fprintf(stderr, "no USB device interface\n"); return -1; }

    IOUSBConfigurationDescriptorPtr cfg;
    if ((*c->dev)->GetConfigurationDescriptorPtr(c->dev, 0, &cfg)) {
        fprintf(stderr, "no configuration descriptor\n");
        closeCam(c);
        return -1;
    }
    c->cfg = (const uint8_t *)cfg;
    c->cfgLen = USBToHostWord(cfg->wTotalLength);
    return 0;
}

// Input volume of the camera's microphone in macOS (what Logi Options+ calls microphone gain), 0..1.
static AudioObjectID findMic(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) || !size) return 0;
    AudioObjectID *ids = malloc(size), found = 0;
    if (!AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids)) {
        for (UInt32 i = 0; i < size / sizeof *ids && !found; i++) {
            AudioObjectPropertyAddress na = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain};
            AudioObjectPropertyAddress sa = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput,
                                             kAudioObjectPropertyElementMain};
            CFStringRef name = NULL;
            UInt32 n = sizeof name, streams = 0;
            if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &n, &name) || !name) continue;
            AudioObjectGetPropertyDataSize(ids[i], &sa, 0, NULL, &streams);
            if (streams && CFStringFind(name, CFSTR(MIC_NAME), 0).location != kCFNotFound) found = ids[i];
            CFRelease(name);
        }
    }
    free(ids);
    return found;
}

static int micGain(Float32 *get, const Float32 *set) {
    AudioObjectID mic = findMic();
    AudioObjectPropertyAddress a = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput,
                                    kAudioObjectPropertyElementMain};
    if (!mic || !AudioObjectHasProperty(mic, &a)) return -1;
    UInt32 n = sizeof(Float32);
    if (set) return AudioObjectSetPropertyData(mic, &a, 0, NULL, n, set) ? -1 : 0;
    return AudioObjectGetPropertyData(mic, &a, 0, NULL, &n, get) ? -1 : 0;
}
#endif

// --- cameras: the list, the choice and opening the one chosen -------------------------------------------------------

static void describe(CamInfo *ci) {
    ci->model = NULL;
    ci->feat = 0;
    for (size_t i = 0; i < sizeof MODELS / sizeof *MODELS; i++)
        if (ci->vid == VID_LOGITECH && ci->pid == MODELS[i].pid) {
            ci->model = MODELS[i].name;
            ci->feat = MODELS[i].feat;
        }
    ci->support = ci->feat & F_FULL ? S_FULL : ci->feat ? S_EXPERIMENTAL : S_STANDARD;
}

static int byLocation(const void *a, const void *b) {
    unsigned x = ((const CamInfo *)a)->loc, y = ((const CamInfo *)b)->loc;
    return x < y ? -1 : x > y;
}

// All cameras in location order, with their 1-based index and model; -1 if the list cannot be made (said on stderr).
static int listCameras(CamInfo *l, int max) {
    int n = scanCameras(l, max);
    if (n < 0) return -1;
    qsort(l, n, sizeof *l, byLocation);
    for (int i = 0; i < n; i++) {
        l[i].index = i + 1;
        describe(&l[i]);
    }
    return n;
}

static void dropCameras(CamInfo *l, int n) {
    for (int i = 0; i < n; i++)
        if (l[i].svc) IOObjectRelease(l[i].svc);
}

// The camera in l that is the target: same ids and serial, and the same location if there is a choice. -1 if it is gone.
static int findTarget(const CamInfo *l, int n) {
    int best = -1;
    for (int i = 0; i < n; i++) {
        if (l[i].vid != target.vid || l[i].pid != target.pid) continue;
        if (target.serial[0] && strcmp(l[i].serial, target.serial)) continue;
        if (l[i].loc == target.loc) return i;
        if (best < 0) best = i;
    }
    return best;
}

static const char *camName(const CamInfo *ci) {
    return ci->model ? ci->model : ci->name[0] ? ci->name : "UVC camera";
}

#ifndef BRIOCTL_FAKE
static int cameraPresent(void) {
    CamInfo l[MAX_CAMS];
    int n = listCameras(l, MAX_CAMS), found = n > 0 && findTarget(l, n) >= 0;
    dropCameras(l, n);
    return found;
}
#endif

static int openCam(Cam *c) {
    memset(c, 0, sizeof *c);
    CamInfo l[MAX_CAMS];
    int n = listCameras(l, MAX_CAMS), i = n > 0 ? findTarget(l, n) : -1, rc = -1;
    if (i >= 0) {
        if (!attach(c, &l[i])) {
            c->info = l[i];
            c->info.svc = 0;
            c->feat = l[i].feat | (l[i].feat & F_HDR ? 0 : F_NOHDR);
            if ((rc = parseConfig(c))) closeCam(c);
        }
    } else if (n >= 0) fprintf(stderr, "%s is not connected\n", camName(&target));
    dropCameras(l, n);
    return rc;
}

static void printCameras(FILE *f, const CamInfo *l, int n) {
    fprintf(f, "%-3s %-10s %-24s %-24s %-13s %-14s %s\n", "#", "id", "name", "model", "support", "serial", "location");
    for (int i = 0; i < n; i++)
        fprintf(f, "%-3d %04x:%04x  %-24s %-24s %-13s %-14s 0x%x\n", l[i].index, l[i].vid, l[i].pid, l[i].name,
                l[i].model ? l[i].model : "-", SUPPORT[l[i].support], l[i].serial[0] ? l[i].serial : "-", l[i].loc);
}

static int allDigits(const char *s) { return *s && strspn(s, "0123456789") == strlen(s); }

// Which camera does the user mean? ID is an index, a location (0x...) or a serial number; without ID: the only camera,
// or the only one brioctl knows (full or experimental support). Returns 0 and the position in *pick, or the exit code
// after saying why not.
static int chooseCamera(const CamInfo *l, int n, const char *id, int *pick) {
    *pick = -1;
    if (!n) {
        fprintf(stderr, "no UVC camera found\n");
        return 1;
    }
    if (id) {
        int found = 0;
        if (!strncmp(id, "0x", 2) || !strncmp(id, "0X", 2)) {
            char *end;
            unsigned long loc = strtoul(id, &end, 16);
            for (int i = 0; i < n; i++)
                if (!*end && end > id + 2 && l[i].loc == loc) *pick = i, found = 1;
        } else if (allDigits(id) && strlen(id) < 4 && atoi(id) >= 1 && atoi(id) <= n) {
            *pick = atoi(id) - 1;
            found = 1;
        } else
            for (int i = 0; i < n; i++)
                if (l[i].serial[0] && !strcasecmp(l[i].serial, id)) found++, *pick = i;
        if (found == 1) return 0;
        fprintf(stderr, found ? "serial %s matches several cameras: use the index or the location\n"
                              : "no camera matches %s (an index, a serial number or a location like 0x110000)\n", id);
        printCameras(stderr, l, n);
        return 2;
    }
    int known = 0;
    for (int i = 0; i < n; i++)
        if (l[i].support != S_STANDARD) known++, *pick = i;
    if (n == 1) *pick = 0;
    else if (known != 1) {
        fprintf(stderr, "several cameras: choose one with --camera\n");
        printCameras(stderr, l, n);
        return 2;
    }
    return 0;
}

// Choose the camera for this run and remember it in target; the exit code if there is none.
static int selectCamera(const char *id) {
    CamInfo l[MAX_CAMS];
    int n = listCameras(l, MAX_CAMS), pick, rc = 1;
    if (n >= 0 && !(rc = chooseCamera(l, n, id, &pick))) {
        target = l[pick];
        target.svc = 0;
    }
    dropCameras(l, n);
    return rc;
}

static long getLE(const uint8_t *b, int n, int sgn) {
    unsigned long v = 0;
    for (int i = n - 1; i >= 0; i--) v = v << 8 | b[i];
    if (sgn && n < 8 && (v >> (8 * n - 1) & 1)) v |= ~0UL << (8 * n);
    return (long)v;
}

static void putLE(uint8_t *b, int n, long v) {
    for (int i = 0; i < n; i++) b[i] = v >> (8 * i) & 0xff;
}

// Unsigned little-endian value up to 4 bytes, for GET_LEN and the like.
static IOReturn getValue(Cam *c, int req, int unit, int sel, int len, long *out) {
    uint8_t b[4] = {0};
    IOReturn kr = request(c, req, unit, sel, b, len, NULL);
    *out = getLE(b, len, 0);
    return kr;
}

static int fieldSize(const Ctrl *k) { return k->size ? k->size : k->len; }
static long scaleOf(const Ctrl *k) { return k->scale ? k->scale : 1; }
static int isXUnit(int unit) { return unit != U_CT && unit != U_PU; }  // by U_*
static int isXU(const Ctrl *k) { return isXUnit(k->unit); }

// The standard controls a camera can declare, with the bit of each in the bmControls of its camera terminal (U_CT) or
// processing unit (U_PU): UVC 1.5 tables 3-6 and 3-8. The bit numbers do not follow the selectors.
static const struct { int unit, sel, bit; } STD_BITS[] = {
    {U_CT, 0x02, 1}, {U_CT, 0x03, 2}, {U_CT, 0x04, 3}, {U_CT, 0x06, 5}, {U_CT, 0x09, 7},
    {U_CT, 0x0b, 9}, {U_CT, 0x0d, 11}, {U_CT, 0x0f, 13}, {U_CT, 0x08, 17}, {U_CT, 0x11, 18},
    {U_PU, 0x02, 0}, {U_PU, 0x03, 1}, {U_PU, 0x06, 2}, {U_PU, 0x07, 3}, {U_PU, 0x08, 4}, {U_PU, 0x09, 5},
    {U_PU, 0x0a, 6}, {U_PU, 0x01, 8}, {U_PU, 0x04, 9}, {U_PU, 0x05, 10}, {U_PU, 0x10, 11}, {U_PU, 0x0b, 12},
};

// Does the camera have this control? A standard one if its camera terminal or processing unit declares it. A Logitech
// one if the model has it (MODELS) and the camera has the unit: nothing else is ever written to an extension unit.
static int avail(const Cam *c, const Ctrl *k) {
    if (!k->name || !c->unit[k->unit]) return 0;
    if (k->need && (c->feat & k->need) != k->need) return 0;
    if (isXU(k)) return 1;
    for (size_t i = 0; i < sizeof STD_BITS / sizeof *STD_BITS; i++)
        if (STD_BITS[i].unit == k->unit && STD_BITS[i].sel == k->sel) return c->bm[k->unit == U_PU] >> STD_BITS[i].bit & 1;
    return 0;
}

// One field of a control, read with GET_CUR, GET_MIN, GET_MAX or GET_DEF.
static IOReturn getField(Cam *c, const Ctrl *k, int req, long *out) {
    uint8_t b[8] = {0};
    IOReturn kr = request(c, req, c->unit[k->unit], k->sel, b, k->len, NULL);
    *out = getLE(b + k->off, fieldSize(k), k->sgn);
    return kr;
}

static int getInfo(Cam *c, const Ctrl *k) {
    uint8_t info = 0;
    return request(c, GET_INFO, c->unit[k->unit], k->sel, &info, 1, NULL) ? -1 : info;
}

// The microphone volume, -1 if there is no microphone or macOS reports something that is not a number.
static int micRead(Float32 *g) { return micGain(g, NULL) || !isfinite(*g) ? -1 : 0; }

static int quiet;    // watch: a setting that already has the value is not printed; real writes always are
static int written;  // settings really written so far (watch counts them for its log line)
static int videoOn;  // watch, video just started: mic is never changed (the camera restarts in the middle of a call)
static int deskOn;   // watch, the camera shows the desk: the firmware sets fov, zoom, pan and tilt itself

static int setMicGain(const char *arg) {
    char *end;
    Float32 v = strtof(arg, &end), cur = 0;
    // plain decimal only: strtof would also take nan, inf and hex floats
    if (!*arg || *end || strspn(arg, "0123456789.") != strlen(arg) || !(v >= 0 && v <= 1)) {
        fprintf(stderr, "micgain: bad value %s (microphone input volume: 0-1)\n", arg);
        return -1;
    }
    int same = !micRead(&cur) && (cur > v ? cur - v : v - cur) <= 0.0001f;  // the file keeps 4 decimals
    if (!same) {
        if (micGain(NULL, &v) || micRead(&cur)) {
            fprintf(stderr, "micgain: no %s microphone in macOS audio devices\n", MIC_NAME);
            return -1;
        }
        written++;
    }
    if (!same || !quiet) printf("micgain %.4f\n", cur);
    return 0;
}

// GET_MIN, GET_MAX and GET_RES of a control, in register units; has* says whether the camera answered.
typedef struct { int hasMin, hasMax, hasRes; long min, max, res; } Range;

static void getRange(Cam *c, const Ctrl *k, Range *r) {
    memset(r, 0, sizeof *r);
    r->hasMin = !getField(c, k, GET_MIN, &r->min);
    r->hasMax = !getField(c, k, GET_MAX, &r->max);
    r->hasRes = !getField(c, k, GET_RES, &r->res);
}

#define MAP_MAX 8
// The names of k's map that the camera accepts (all if c is NULL). A standard control must stay inside the camera's
// GET_MIN..GET_MAX, the exposure mode inside the modes of its GET_RES. A Logitech control takes exactly its table: the
// field of view says 255 for GET_MAX and only 0 to 2 do anything. A name is listed once; display also drops a second
// name for the same value ("1" for on).
static int choicesOf(Cam *c, const Ctrl *k, const Map **out, int display) {
    Range r = {0};
    uint8_t modes = 0;
    int std = c && !isXU(k), haveModes = 0, n = 0;
    if (std && k->unit == U_CT && k->sel == CT_AE_MODE)
        haveModes = !request(c, GET_RES, c->unit[k->unit], k->sel, &modes, 1, NULL);
    else if (std) getRange(c, k, &r);
    for (const Map *m = k->map; m->name; m++) {
        int ok = 1, dup = 0;
        if (haveModes) ok = (modes & m->raw) != 0;
        else if (std) ok = !(r.hasMin && m->raw < r.min) && !(r.hasMax && m->raw > r.max);
        for (int j = 0; j < n; j++) dup |= !strcmp(out[j]->name, m->name) || (display && out[j]->raw == m->raw);
        if (ok && !dup && n < MAP_MAX) out[n++] = m;
    }
    return n;
}

static int parseValue(Cam *c, const Ctrl *k, const char *arg, long *raw) {
    if (k->map) {
        const Map *ch[MAP_MAX];
        int n = choicesOf(c, k, ch, 0);
        for (int i = 0; i < n; i++)
            if (!strcmp(ch[i]->name, arg)) { *raw = ch[i]->raw; return 0; }
        return -1;
    }
    char *end;
    long v = strtol(arg, &end, 10);
    if (!*arg || *end) return -1;
    *raw = v * scaleOf(k);
    return 0;
}

static void formatValue(const Ctrl *k, long raw, char *s, size_t n) {
    if (k->map) {
        for (const Map *m = k->map; m->name; m++)
            if (m->raw == raw) { snprintf(s, n, "%s", m->name); return; }
        snprintf(s, n, "raw %ld", raw);
    } else if (raw % scaleOf(k)) {
        snprintf(s, n, "%.2f", (double)raw / scaleOf(k));
    } else {
        snprintf(s, n, "%ld", raw / scaleOf(k));
    }
}

// What a control does, with the names it takes after a colon ("field of view in degrees: 90, 78, 65"), or where its
// help has %s.
static void helpText(Cam *c, const Ctrl *k, char *out, size_t n) {
    char names[128] = "";
    const Map *ch[MAP_MAX];
    int cnt = k->map ? choicesOf(c, k, ch, 1) : 0;
    for (int i = 0; i < cnt; i++) {
        size_t len = strlen(names);
        snprintf(names + len, sizeof names - len, "%s%s", i ? ", " : ": ", ch[i]->name);
    }
    const char *at = strstr(k->help, "%s");
    if (at) snprintf(out, n, "%.*s%s%s", (int)(at - k->help), k->help, names, at + 2);
    else snprintf(out, n, "%s%s", k->help, names);
}

// The camera's range of a numeric control as the user sees it: "3-2047", or "-20..20" if it starts below zero.
static void rangeText(Cam *c, const Ctrl *k, char *out, size_t n) {
    Range r;
    char lo[16], hi[16];
    out[0] = 0;
    if (k->map) return;
    getRange(c, k, &r);
    if (!r.hasMin || !r.hasMax) return;
    formatValue(k, r.min, lo, sizeof lo);
    formatValue(k, r.max, hi, sizeof hi);
    snprintf(out, n, r.min < 0 ? "%s..%s" : "%s-%s", lo, hi);
}

static const char *const RS_SPEED[] = {"slower", "normal", "faster"};
static const char *const RS_LEVEL[] = {"closer", "normal", "further"};

// What the camera reports about itself, read-only. Layouts observed on a live camera, see docs/registers.md.
// Numbers are -1 where the camera did not answer.
typedef struct {
    char fw[16], sn[13];
    int colour, video, w, h, led, desk;  // video, led, desk: 1 on, 0 off
    int rs, rsOn, rsSpeed, rsLevel;      // rs: 1 settings stored, 0 nothing stored
} Status;

static int readFirmware(Cam *c, char fw[16]) {
    uint8_t b[4] = {0};
    if (!c->unit[U_INFO] || request(c, GET_CUR, c->unit[U_INFO], INFO_FIRMWARE, b, sizeof b, NULL)) return -1;
    snprintf(fw, 16, "%d.%d.%d", b[0], b[1], b[2] | b[3] << 8);
    return 0;
}

// 1 while the camera is tilted to the desk and shows it (Show Mode), 0 if not, -1 if it does not say.
static int readDesk(Cam *c) {
    uint8_t active = 0;
    if (!(c->feat & F_FULL) || !c->unit[U_INFO] || request(c, GET_CUR, c->unit[U_INFO], INFO_SHOWMODE_ACTIVE, &active, 1, NULL)) return -1;
    return active != 0;
}

static void readStatus(Cam *c, Status *s) {
    uint8_t st[6] = {0}, led[6] = {0}, rs[30] = {0}, color = 0;
    long len;
    memset(s, 0, sizeof *s);
    s->colour = s->video = s->led = s->desk = s->rs = -1;
    if (!(c->feat & F_FULL)) return;  // these registers are known on the MX Brio only
    if (c->unit[U_INFO]) {
        readFirmware(c, s->fw);
        if (request(c, GET_CUR, c->unit[U_INFO], INFO_SERIAL, s->sn, 12, NULL)) s->sn[0] = 0;
        if (!request(c, GET_CUR, c->unit[U_INFO], INFO_COLOR, &color, 1, NULL)) s->colour = color;
        s->desk = readDesk(c);
    }
    if (c->unit[U_STATS] && !request(c, GET_CUR, c->unit[U_STATS], STATS_STREAM, st, sizeof st, NULL)) {
        s->video = st[0] != 0;
        s->w = st[2] | st[3] << 8;
        s->h = st[4] | st[5] << 8;
    }
    if (c->unit[U_PERIPHERAL] && !getValue(c, GET_LEN, c->unit[U_PERIPHERAL], PERIPHERAL_LED, 2, &len) &&
        len == sizeof led && !request(c, GET_CUR, c->unit[U_PERIPHERAL], PERIPHERAL_LED, led, sizeof led, NULL))
        s->led = led[1] != 0;
    // RightSight runs in Logitech's Mac app; the camera only stores its settings (layout: docs/registers.md).
    if (c->unit[U_APP] && !getValue(c, GET_LEN, c->unit[U_APP], APP_RIGHTSIGHT, 2, &len) && len == sizeof rs &&
        !request(c, GET_CUR, c->unit[U_APP], APP_RIGHTSIGHT, rs, sizeof rs, NULL)) {
        s->rs = rs[0] == 1;
        s->rsOn = rs[1] != 0;
        s->rsSpeed = rs[2];
        s->rsLevel = rs[3];
    }
}

// Current and default value of a control as the user sees them; -1 if the current value cannot be read.
// def and autoNow may be NULL. def stays empty when the camera has no default.
static int readCtrl(Cam *c, const Ctrl *k, char cur[16], char def[16], int *autoNow) {
    long v;
    cur[0] = 0;
    if (def) def[0] = 0;
    if (autoNow) *autoNow = 0;
    if (!c->unit[k->unit] || getField(c, k, GET_CUR, &v)) return -1;
    formatValue(k, v, cur, 16);
    if (def && !getField(c, k, GET_DEF, &v)) formatValue(k, v, def, 16);
    if (autoNow) {
        int info = getInfo(c, k);
        *autoNow = info >= 0 && (info & INFO_AUTO);
    }
    return 0;
}

static void showStatus(const Status *s) {
    printf("\nStatus (read-only)\n");
    if (s->video > 0) printf("  %-11s on, %dx%d\n", "video", s->w, s->h);
    else if (s->video == 0 && s->w) printf("  %-11s off, last %dx%d\n", "video", s->w, s->h);
    else if (s->video == 0) printf("  %-11s off\n", "video");
    if (s->led >= 0) printf("  %-11s %s\n", "led", s->led ? "on" : "off");
    if (s->desk >= 0) printf("  %-11s %s\n", "desk view", s->desk ? "on (camera tilted, Show Mode)" : "off");
    if (s->rs == 0) printf("  %-11s nothing stored (cleared at power-on)\n", "rightsight");
    else if (s->rs > 0)
        printf("  %-11s %s, speed %s, framing %s (stored for Logitech's app)\n", "rightsight", s->rsOn ? "on" : "off",
               s->rsSpeed < 3 ? RS_SPEED[s->rsSpeed] : "?", s->rsLevel < 3 ? RS_LEVEL[s->rsLevel] : "?");
}

static int show(Cam *c) {
    Status s;
    readStatus(c, &s);
    printf("%s", camName(&c->info));
    if (c->feat & F_FULL) {
        if (s.fw[0]) printf("  firmware %s", s.fw);
        if (s.sn[0]) printf("  serial %s", s.sn);
        if (s.colour >= 0) printf("  colour code %d", s.colour);
    } else {
        printf("  %04x:%04x", c->info.vid, c->info.pid);
        if (c->info.serial[0]) printf("  serial %s", c->info.serial);
    }
    printf("\n");
    if (c->info.support == S_EXPERIMENTAL)
        printf("experimental support: reported by other projects, not tested with brioctl; "
               "please report with 'brioctl snapshot'\n");
    else if (c->info.support == S_STANDARD) printf("standard UVC controls only\n");
    if (c->feat & F_FULL) showStatus(&s);

    int rc = 0;
    const char *head = NULL;
    for (int i = 0; i < NCTRLS; i++) {
        const Ctrl *k = &CTRLS[i];
        if (!k->name) { head = k->help; continue; }
        if (!avail(c, k)) continue;
        if (head) printf("\n%s\n", head);
        head = NULL;
        char cs[16], ds[16], rg[32], help[192];
        int autoNow;
        if (readCtrl(c, k, cs, ds, &autoNow)) {
            printf("  %-11s ?\n", k->name);
            rc = 1;
            continue;
        }
        if (!ds[0]) snprintf(ds, sizeof ds, "?");
        if (autoNow) strncat(cs, "*", sizeof cs - strlen(cs) - 1);
        rangeText(c, k, rg, sizeof rg);
        helpText(c, k, help, sizeof help);
        printf("  %-11s %-9s default %-9s %-11s %s\n", k->name, cs, ds, rg, help);
    }

    if (c->feat & F_FULL) {
        Float32 g;
        printf("\nMicrophone (macOS)\n");
        if (!micRead(&g)) printf("  %-11s %-9.4f default %-9s %-11s %s\n", "micgain", g, "-", "0-1", "input volume");
        else printf("  %-11s ?\n", "micgain");
    }
    printf("\n* set automatically right now\n");
    return rc;
}

// JSON helpers: a missing value (NULL string, negative number) is null.
static void jstr(const char *s) {
    if (!s) { printf("null"); return; }
    putchar('"');
    while (*s) {
        unsigned char ch = *s;
        int len = ch >= 0xf0 ? 4 : ch >= 0xe0 ? 3 : ch >= 0xc0 ? 2 : 1;
        if (ch == '"' || ch == '\\') printf("\\%c", ch), s++;
        else if (ch < 0x20 || ch == 0x7f) printf("\\u%04x", ch), s++;
        else if (ch < 0x80) putchar(ch), s++;
        else {  // UTF-8 (USB strings): a valid sequence becomes \uXXXX, anything else U+FFFD
            unsigned cp = len == 4 ? ch & 7 : len == 3 ? ch & 15 : len == 2 ? ch & 31 : 0xfffd;
            int ok = len > 1;
            for (int i = 1; i < len && ok; i++) {
                ok = (s[i] & 0xc0) == 0x80;
                cp = cp << 6 | (s[i] & 63);
            }
            if (!ok || cp > 0x10ffff || (cp >= 0xd800 && cp < 0xe000)) cp = 0xfffd, len = ok ? len : 1;
            if (cp > 0xffff) printf("\\u%04x\\u%04x", 0xd800 + ((cp - 0x10000) >> 10), 0xdc00 + ((cp - 0x10000) & 0x3ff));
            else printf("\\u%04x", cp);
            s += len;
        }
    }
    putchar('"');
}

static void jint(int v) {
    if (v < 0) printf("null");
    else printf("%d", v);
}

static void jbool(int v) { printf(v < 0 ? "null" : v ? "true" : "false"); }

// list: the cameras brioctl can talk to, as a table or as JSON.
static int listCmd(int json) {
    CamInfo l[MAX_CAMS];
    int n = listCameras(l, MAX_CAMS);
    if (n < 0) return 1;
    if (!json) {
        if (n) printCameras(stdout, l, n);
        else printf("no UVC camera found\n");
    } else {
        printf("{\"cameras\":[");
        for (int i = 0; i < n; i++) {
            printf("%s{\"index\":%d,\"vid\":\"%04x\",\"pid\":\"%04x\",\"name\":", i ? "," : "", l[i].index, l[i].vid,
                   l[i].pid);
            jstr(l[i].name[0] ? l[i].name : NULL);
            printf(",\"model\":");
            jstr(l[i].model);
            printf(",\"support\":\"%s\",\"serial\":", SUPPORT[l[i].support]);
            jstr(l[i].serial[0] ? l[i].serial : NULL);
            printf(",\"location\":\"0x%x\"}", l[i].loc);
        }
        printf("]}\n");
    }
    dropCameras(l, n);
    return 0;
}

// A control's value as JSON: named values are strings, plain numbers stay numbers.
static void jvalue(const Ctrl *k, const char *s) {
    if (!*s) printf("null");
    else if (k->map) jstr(s);
    else printf("%s", s);
}

// A register value of a numeric control, scaled as the user sees it; null if the camera did not say.
static void jscaled(const Ctrl *k, int has, long raw) {
    char s[16];
    if (!has) { printf("null"); return; }
    formatValue(k, raw, s, sizeof s);
    printf("%s", s);
}

// The same information as show, as one JSON object on one line.
static int showJson(Cam *c) {
    Status s;
    readStatus(c, &s);
    const CamInfo *ci = &c->info;
    printf("{\"device\":{\"model\":");
    jstr(ci->model);
    printf(",\"firmware\":");
    jstr(s.fw[0] ? s.fw : NULL);
    printf(",\"serial\":");
    jstr(s.sn[0] ? s.sn : ci->serial[0] ? ci->serial : NULL);
    printf(",\"colour\":");
    jint(s.colour);
    printf(",\"name\":");
    jstr(ci->name[0] ? ci->name : NULL);
    printf(",\"vid\":\"%04x\",\"pid\":\"%04x\",\"support\":\"%s\",\"index\":%d,\"location\":\"0x%x\"},", ci->vid,
           ci->pid, SUPPORT[ci->support], ci->index, ci->loc);
    printf("\"status\":{\"video\":");
    if (s.video < 0) printf("null");
    else {
        printf("{\"on\":");
        jbool(s.video);
        printf(",\"width\":%d,\"height\":%d}", s.w, s.h);
    }
    printf(",\"led\":");
    jbool(s.led);
    printf(",\"desk_view\":");
    jbool(s.desk);
    printf(",\"rightsight\":");
    if (s.rs < 0) printf("null");
    else if (!s.rs) printf("{\"stored\":false}");
    else {
        printf("{\"stored\":true,\"enabled\":");
        jbool(s.rsOn);
        printf(",\"speed\":");
        jstr(s.rsSpeed < 3 ? RS_SPEED[s.rsSpeed] : NULL);
        printf(",\"framing\":");
        jstr(s.rsLevel < 3 ? RS_LEVEL[s.rsLevel] : NULL);
        printf("}");
    }
    printf("},\"settings\":{");

    int rc = 0, first = 1;
    const char *group = NULL;
    for (int i = 0; i < NCTRLS; i++) {
        const Ctrl *k = &CTRLS[i];
        char cs[16], ds[16], help[192];
        int autoNow;
        if (!k->name) { group = k->group; continue; }
        if (!avail(c, k)) continue;
        if (readCtrl(c, k, cs, ds, &autoNow)) rc = 1;
        int info = getInfo(c, k);
        printf("%s\"%s\":{\"value\":", first ? "" : ",", k->name);
        first = 0;
        jvalue(k, cs);
        printf(",\"default\":");
        jvalue(k, ds);
        printf(",\"auto\":%s,\"group\":", autoNow ? "true" : "false");
        jstr(group);
        printf(",\"writable\":%s,\"kind\":\"%s\"", info >= 0 && (info & INFO_SET) && !(info & INFO_AUTO) ? "true" : "false",
               !k->map ? "number" : k->map == ON_OFF ? "bool" : "choice");
        if (!k->map) {
            Range r;
            getRange(c, k, &r);
            printf(",\"min\":");
            jscaled(k, r.hasMin, r.min);
            printf(",\"max\":");
            jscaled(k, r.hasMax, r.max);
            printf(",\"step\":");
            jscaled(k, r.hasRes, r.res);
        } else if (k->map != ON_OFF) {
            const Map *ch[MAP_MAX];
            int n = choicesOf(c, k, ch, 1);
            printf(",\"choices\":[");
            for (int j = 0; j < n; j++) {
                if (j) putchar(',');
                jstr(ch[j]->name);
            }
            printf("]");
        }
        helpText(c, k, help, sizeof help);
        printf(",\"help\":");
        jstr(help);
        printf("}");
    }
    Float32 g;
    printf("},\"micgain\":");
    if ((c->feat & F_FULL) && !micRead(&g)) printf("%.4f", g);
    else printf("null");
    printf("}\n");
    return rc;
}

// The control of that name, the one this camera has if the table has several. hdr and backlight are one control (the
// backlight compensation) under two names; either is accepted on every camera. NULL if there is no such control; the
// caller checks avail for the camera.
static const Ctrl *findCtrl(const Cam *c, const char *name) {
    const Ctrl *any = NULL;
    int backlight = !strcmp(name, "hdr") || !strcmp(name, "backlight");
    for (int i = 0; i < NCTRLS; i++) {
        const Ctrl *k = &CTRLS[i];
        int same = k->name && (!strcmp(k->name, name) || (backlight && k->unit == U_PU && k->sel == 0x01));
        if (same && avail(c, k)) return k;
        if (same && !any) any = k;
    }
    return any;
}

// Print one value the way show does, without anything else (for scripts).
static int get(Cam *c, const char *name) {
    char cs[16];
    if (!strcmp(name, "micgain") && (c->feat & F_FULL)) {
        Float32 g;
        if (micRead(&g)) {
            fprintf(stderr, "micgain: no readable %s microphone in macOS audio devices\n", MIC_NAME);
            return 1;
        }
        printf("%.4f\n", g);
        return 0;
    }
    const Ctrl *k = findCtrl(c, name);
    if (!k || !strcmp(name, "micgain")) { fprintf(stderr, "unknown setting: %s\n", name); return 1; }
    if (!avail(c, k)) { fprintf(stderr, "%s: control not found on this camera\n", name); return 1; }
    if (readCtrl(c, k, cs, NULL, NULL)) { fprintf(stderr, "%s: cannot read the value\n", name); return 1; }
    printf("%s\n", cs);
    return 0;
}

// Logitech's app can take over framing (RightSight Ctl); without video the camera then drops zoom and pan writes.
static int rightsightHolds(Cam *c) {
    uint8_t b[4] = {0};
    long len;
    int unit = (c->feat & F_FULL) ? c->unit[U_PERIPHERAL] : 0;
    return unit && !getValue(c, GET_LEN, unit, PERIPHERAL_RIGHTSIGHT, 2, &len) && len == sizeof b &&
           !request(c, GET_CUR, unit, PERIPHERAL_RIGHTSIGHT, b, sizeof b, NULL) && b[0];
}

static int set(Cam *c, const char *name, const char *arg) {
    if (!strcmp(name, "micgain") && (c->feat & F_FULL)) return setMicGain(arg);
    const Ctrl *k = findCtrl(c, name);
    if (!k || !strcmp(name, "micgain")) { fprintf(stderr, "unknown setting: %s\n", name); return -1; }
    int unit = c->unit[k->unit];
    if (!avail(c, k)) { fprintf(stderr, "%s: control not found on this camera\n", name); return -1; }

    char help[192];
    long raw, len, cur;
    if (parseValue(c, k, arg, &raw)) {
        helpText(c, k, help, sizeof help);
        fprintf(stderr, "%s: bad value %s (%s)\n", name, arg, help);
        return -1;
    }
    // Extension units report their size; refuse to write if firmware changed the layout.
    if (isXU(k) && (getValue(c, GET_LEN, unit, k->sel, 2, &len) || len != k->len)) {
        fprintf(stderr, "%s: unexpected control size, not writing\n", name);
        return -1;
    }
    int info = getInfo(c, k);
    if (info >= 0 ? !(info & INFO_SET) : isXU(k)) {  // an extension unit must say it can be set
        fprintf(stderr, "%s: the camera does not allow writing it\n", name);
        return -1;
    }
    if (info >= 0 && (info & INFO_AUTO)) {
        helpText(c, k, help, sizeof help);
        fprintf(stderr, "%s: set automatically right now (%s)\n", name, help);
        return -1;
    }
    Range r;
    getRange(c, k, &r);
    if (!k->map && ((r.hasMin && raw < r.min) || (r.hasMax && raw > r.max))) {
        char rg[32];
        rangeText(c, k, rg, sizeof rg);
        fprintf(stderr, "%s: %s is out of range (%s)\n", name, arg, rg);
        return -1;
    }
    // A field shares the control with others: keep their current values.
    uint8_t b[8] = {0};
    int haveCur = !request(c, GET_CUR, unit, k->sel, b, k->len, NULL);
    if (!haveCur && fieldSize(k) < k->len) {
        fprintf(stderr, "%s: cannot read the current value\n", name);
        return -1;
    }
    char s[16];
    formatValue(k, raw, s, sizeof s);
    if (haveCur && getLE(b + k->off, fieldSize(k), k->sgn) == raw) {  // already set: no write, no flash wear or restart
        if (!quiet) printf("%s %s\n", k->name, s);
        return 0;
    }
    putLE(b + k->off, fieldSize(k), raw);
    IOReturn kr = request(c, SET_CUR, unit, k->sel, b, k->len, NULL);
    if (kr) {
        helpText(c, k, help, sizeof help);
        fprintf(stderr, "%s: write failed: 0x%x (%s)\n", name, kr, help);
        return -1;
    }
    if (getField(c, k, GET_CUR, &cur) || cur != raw) {
        if (k->unit == U_CT && (k->sel == CT_ZOOM || k->sel == CT_PANTILT) && rightsightHolds(c))
            fprintf(stderr, "%s: ignored, Logitech's RightSight holds the framing while there is no video\n", name);
        else fprintf(stderr, "%s: camera did not keep the value\n", name);
        return -1;
    }
    written++;
    printf("%s %s\n", k->name, s);
    return 0;
}

// Settings files: "name value" per line, # starts a comment. A name without a slash is a file in ~/.config/brioctl.
static void configPath(const char *name, char *out, size_t n) {
    const char *home = getenv("HOME");
    if (strchr(name, '/')) snprintf(out, n, "%s", name);
    else snprintf(out, n, "%s/.config/brioctl/%s", home ? home : ".", name);
}

static void makeConfigDir(void) {
    char p[PATH_MAX];
    configPath("", p, sizeof p);
    p[strlen(p) - 1] = 0;  // drop the trailing slash
    char *slash = strrchr(p, '/');
    *slash = 0;
    mkdir(p, 0755);  // ~/.config
    *slash = '/';
    mkdir(p, 0755);  // ~/.config/brioctl
}

static const char *presetSettings(const char *name) {
    for (int i = 0; i < NPRESETS; i++)
        if (!strcmp(PRESETS[i].name, name)) return PRESETS[i].settings;
    return NULL;
}

static int save(Cam *c, const char *name) {
    char path[PATH_MAX];
    if (presetSettings(name)) { fprintf(stderr, "%s is a built-in preset, choose another name\n", name); return 1; }
    configPath(name, path, sizeof path);
    makeConfigDir();
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    char ts[32];
    time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M", localtime(&t));
    fprintf(f, "# brioctl settings, saved %s\n", ts);
    fprintf(f, "# camera %04x:%04x%s%s\n", c->info.vid, c->info.pid, c->info.serial[0] ? " " : "", c->info.serial);

    int n = 0;
    for (int i = 0; i < NCTRLS; i++) {
        const Ctrl *k = &CTRLS[i];
        long cur, min, max;
        char s[16];
        int info = avail(c, k) ? getInfo(c, k) : -1;
        // Skip what cannot be set now: values driven by an auto mode are saved as that mode.
        if (info < 0 || !(info & INFO_SET) || (info & INFO_AUTO) || getField(c, k, GET_CUR, &cur)) continue;
        // and values outside the camera's own range, which apply would refuse
        if (!getField(c, k, GET_MIN, &min) && !getField(c, k, GET_MAX, &max) && (cur < min || cur > max)) continue;
        formatValue(k, cur, s, sizeof s);
        fprintf(f, "%s %s\n", k->name, s);
        n++;
    }
    Float32 g;
    if ((c->feat & F_FULL) && !micRead(&g)) { fprintf(f, "micgain %.4f\n", g); n++; }
    fclose(f);
    printf("saved %d settings to %s\n", n, path);
    return 0;
}

// Changing mic restarts the camera about 2 s after the write, which would lose the settings after it: mic goes last.
static int setLast(const char *name) { return !strcmp(name, "mic"); }

// Timestamp that starts a log line of watch.
static void stamp(void) {
    char ts[32];
    time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    printf("%s ", ts);
}

// Settings the firmware sets itself while the camera is tilted to the desk (Show Mode).
static int isFraming(const char *name) {
    return !strcmp(name, "fov") || !strcmp(name, "zoom") || !strcmp(name, "pan") || !strcmp(name, "tilt");
}

// Does the camera's mic differ from what the file asks for (or can it not tell)?
static int micDiffers(Cam *c, const char *arg) {
    const Ctrl *k = findCtrl(c, "mic");
    long raw, cur;
    return !k || !avail(c, k) || parseValue(c, k, arg, &raw) || getField(c, k, GET_CUR, &cur) || cur != raw;
}

// The "# camera VID:PID SERIAL" line of a settings file: say so if it was saved from another model (not an error: the
// settings that fit are still applied).
static void checkCamera(const Cam *c, const char *line) {
    unsigned vid, pid;
    if (sscanf(line, "# camera %x:%x", &vid, &pid) == 2 && ((int)vid != c->info.vid || (int)pid != c->info.pid))
        fprintf(stderr, "warning: these settings were saved from camera %04x:%04x, this is %04x:%04x (%s)\n", vid, pid,
                c->info.vid, c->info.pid, camName(&c->info));
}

static int applyStream(Cam *c, FILE *f) {
    char line[256], name[64], value[64], mic[64] = "", skipped[64] = "";
    int rc = 0;
    while (fgets(line, sizeof line, f)) {
        if (!strncmp(line, "# camera ", 9)) checkCamera(c, line);
        char *hash = strchr(line, '#');
        if (hash) *hash = 0;
        if (sscanf(line, "%63s %63s", name, value) != 2) continue;
        if (setLast(name)) snprintf(mic, sizeof mic, "%s", value);
        else if (deskOn && isFraming(name)) {
            size_t n = strlen(skipped);
            snprintf(skipped + n, sizeof skipped - n, " %s", name);
        } else if (set(c, name, value)) rc = 1;
    }
    if (*skipped) {
        stamp();
        printf("camera shows the desk, left to the firmware:%s\n", skipped);
    }
    if (*mic && !videoOn) {
        if (set(c, "mic", mic)) rc = 1;
    } else if (*mic && micDiffers(c, mic)) {
        stamp();
        printf("mic: not changed while video is on\n");
    }
    return rc;
}

static int apply(Cam *c, const char *name) {
    char path[PATH_MAX];
    configPath(name, path, sizeof path);
    FILE *f = fopen(path, "r");
    const char *preset = presetSettings(name);
    if (!f && preset) f = fmemopen((void *)preset, strlen(preset), "r");
    if (!f) { fprintf(stderr, "no settings file %s and no preset %s\n", path, name); return 1; }
    int rc = applyStream(c, f);
    fclose(f);
    return rc;
}

static int byName(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

// The files in the settings directory (not the dot files), sorted. Returns the count; free each name.
static int savedFiles(const char *dir, char **names, int max) {
    int n = 0;
    DIR *d = opendir(dir);
    for (struct dirent *e; d && n < max && (e = readdir(d));)
        if (e->d_name[0] != '.' && (names[n] = strdup(e->d_name))) n++;
    if (d) closedir(d);
    qsort(names, n, sizeof *names, byName);
    return n;
}

static int profiles(int json) {
    char dir[PATH_MAX], *names[512];
    configPath("", dir, sizeof dir);
    int n = savedFiles(dir, names, 512);
    if (json) {
        dir[strlen(dir) - 1] = 0;  // no trailing slash
        printf("{\"presets\":[");
        for (int i = 0; i < NPRESETS; i++) {
            printf("%s{\"name\":\"%s\",\"settings\":{", i ? "," : "", PRESETS[i].name);
            char nm[64], val[64];
            int off = 0, used = 0, first = 1;
            while (sscanf(PRESETS[i].settings + off, "%63s %63s%n", nm, val, &used) == 2) {
                printf("%s\"%s\":\"%s\"", first ? "" : ",", nm, val);
                first = 0;
                off += used;
            }
            printf("}}");
        }
        printf("],\"saved\":[");
        for (int i = 0; i < n; i++) {
            if (i) putchar(',');
            jstr(names[i]);
        }
        printf("],\"dir\":");
        jstr(dir);
        printf("}\n");
    } else {
        printf("built-in presets (from Logi Options+; colorboost is the firmware's Color Boost):\n");
        for (int i = 0; i < NPRESETS; i++) {
            printf("  %-10s ", PRESETS[i].name);
            for (const char *p = PRESETS[i].settings; *p; p++)
                if (*p != '\n') putchar(*p);
                else printf(p[1] ? ", " : "\n");
        }
        printf("\nsaved in %s:\n", dir);
        for (int i = 0; i < n; i++) printf("  %s\n", names[i]);
    }
    for (int i = 0; i < n; i++) free(names[i]);
    return 0;
}

// Camera's own defaults (GET_DEF) for every control the camera has except mic and showmode: for those two GET_DEF
// says off, but a real factory reset leaves them on. Nothing restarts and Logitech's hidden state is left alone.
static int defaults(Cam *c) {
    int rc = 0;
    for (int i = 0; i < NCTRLS; i++) {
        const Ctrl *k = &CTRLS[i];
        long def;
        char s[16];
        if (!avail(c, k) || !strcmp(k->name, "mic") || !strcmp(k->name, "showmode")) continue;
        int info = getInfo(c, k);
        if (info < 0 || !(info & INFO_SET) || (info & INFO_AUTO) || getField(c, k, GET_DEF, &def)) continue;
        formatValue(k, def, s, sizeof s);
        if (strncmp(s, "raw ", 4) && set(c, k->name, s)) rc = 1;
    }
    return rc;
}

static char watchPath[PATH_MAX];

// Apply the watch file quietly and end with one log line. A starting camera may not answer yet: retry.
// video: video has just started, so mic is left alone. While the camera shows the desk, framing is left alone too.
static void reapply(int attempts, int waitFirst, int video) {
    quiet = 1;
    videoOn = video;
    written = 0;
    for (int attempt = 1; attempt <= attempts; attempt++) {
        if (attempt > 1 || waitFirst) sleep(2);  // give the camera time to start
        Cam c;
        if (openCam(&c)) continue;
        deskOn = readDesk(&c) > 0;
        int rc = apply(&c, watchPath);
        closeCam(&c);
        if (!rc) { stamp(); printf("applied (%d changed)\n", written); return; }
    }
    stamp();
    printf("could not apply all settings (%d changed)\n", written);
}

// USB devices with the target's vendor and product id; the target's serial number is checked when one arrives.
static CFMutableDictionaryRef cameraMatching(void) {
    return vidPid(IOServiceMatching("IOUSBHostDevice"), CFSTR("idVendor"), CFSTR("idProduct"), target.vid, target.pid);
}

static void cameraArrived(void *refcon, io_iterator_t it) {
    (void)refcon;
    int arrived = 0;
    for (io_service_t s; (s = IOIteratorNext(it)); IOObjectRelease(s)) {
        char serial[48];
        usbString(s, CFSTR("USB Serial Number"), serial, sizeof serial);
        if (target.serial[0] && strcmp(serial, target.serial)) continue;
        target.loc = (unsigned)usbNumber(s, CFSTR("locationID"));  // it may be on another port now
        arrived = 1;
    }
    if (!arrived) return;
    stamp();
    printf("%s connected, applying %s\n", camName(&target), watchPath);
    reapply(5, 1, 0);
}

// The camera sends HID input report 0x40 when video starts: 0x10, then 0x02 about 160 ms later (and 0x14 about 3 s
// after it stops). The image settings can be lost with the stream, so apply the file again once it has settled.
#define HID_STREAM_REPORT 0x40
#define VIDEO_SETTLE_SECONDS 2.0
static CFRunLoopTimerRef videoTimer;
static CFAbsoluteTime lastVideoApply;  // when the last apply for a video start ended

static void videoSettled(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;
    if (!cameraPresent()) return;  // unplugged during the wait
    stamp();
    printf("video started\n");
    reapply(2, 0, 1);
    lastVideoApply = CFAbsoluteTimeGetCurrent();
}

static void armVideoTimer(void) {  // every report restarts the wait, so one start gives one apply
    if (videoTimer) {
        CFRunLoopTimerInvalidate(videoTimer);
        CFRelease(videoTimer);
    }
    CFAbsoluteTime when = CFAbsoluteTimeGetCurrent() + VIDEO_SETTLE_SECONDS;
    videoTimer = CFRunLoopTimerCreate(NULL, when, 0, 0, 0, videoSettled, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), videoTimer, kCFRunLoopDefaultMode);
}

static void hidReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t id, uint8_t *report,
                      CFIndex len) {
    (void)ctx;
    (void)sender;
    if (result || type != kIOHIDReportTypeInput || id != HID_STREAM_REPORT || len < 1) return;
    uint8_t code = len > 1 && report[0] == id ? report[1] : report[0];  // the buffer may start with the report ID
    if (code == 0x10 || code == 0x02) armVideoTimer();
}

static int hidDevices;  // HID devices of the camera that are present now

// The log shows whether video-start detection is armed after the camera has restarted: one line per camera, not per
// HID device.
static void hidAdded(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)ctx;
    (void)result;
    (void)sender;
    (void)dev;
    if (hidDevices++) return;
    stamp();
    printf("HID listening\n");
}

static void hidRemoved(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)ctx;
    (void)result;
    (void)sender;
    (void)dev;
    if (hidDevices <= 0 || --hidDevices) return;
    stamp();
    printf("HID device removed\n");
}

// Video start for every camera, through CoreMediaIO. macOS lists each camera there. For a USB UVC camera the device UID
// is "0x" + the USB location id + vendor id + product id, the ids as 4 hex digits ("0x110000046d0944" for the MX Brio at
// location 0x110000), the model UID is "UVC Camera VendorID_1133 ProductID_2372" (decimal) and the transport is 'usb '
// (found on macOS 26 with an MX Brio). kCMIODevicePropertyDeviceIsRunningSomewhere is true while any app streams from
// the camera. Reading it and listening to it does not open the camera and needs no camera permission.
static CMIOObjectID cmioDev;  // the CoreMediaIO device being listened to, 0 if none
static int cmioRunning;       // its DeviceIsRunningSomewhere the last time we looked

static CMIOObjectPropertyAddress cmioAddress(UInt32 selector) {
    return (CMIOObjectPropertyAddress){selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
}

static int cmioString(CMIOObjectID id, UInt32 selector, char *out, size_t n) {
    CMIOObjectPropertyAddress a = cmioAddress(selector);
    CFStringRef str = NULL;
    UInt32 used = 0;
    out[0] = 0;
    if (CMIOObjectGetPropertyData(id, &a, 0, NULL, sizeof str, &used, &str) || !str) return -1;
    int rc = CFStringGetCString(str, out, n, kCFStringEncodingUTF8) ? 0 : -1;
    CFRelease(str);
    return rc;
}

static int cmioRunningNow(CMIOObjectID id) {
    CMIOObjectPropertyAddress a = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere);
    UInt32 running = 0, used = 0;
    return !CMIOObjectGetPropertyData(id, &a, 0, NULL, sizeof running, &used, &running) && running;
}

// The device UID CoreMediaIO gives the target camera.
static void cmioUid(char *out, size_t n) { snprintf(out, n, "0x%x%04x%04x", target.loc, target.vid, target.pid); }

// The CoreMediaIO device of the target camera: the one with its UID or, if the camera is on another port than we
// think, the only USB device with its ids at the end of the UID. 0 if there is none.
static CMIOObjectID cmioFind(char *uid, size_t n) {
    CMIOObjectPropertyAddress a = cmioAddress(kCMIOHardwarePropertyDevices);
    UInt32 size = 0, used = 0;
    if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &a, 0, NULL, &size) || !size) return 0;
    CMIOObjectID *ids = malloc(size), found = 0, only = 0;
    char want[64], suffix[16], u[64];
    int matches = 0;
    cmioUid(want, sizeof want);
    snprintf(suffix, sizeof suffix, "%04x%04x", target.vid, target.pid);
    if (ids && !CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &a, 0, NULL, size, &used, ids)) {
        for (UInt32 i = 0; i < used / sizeof *ids; i++) {
            size_t len;
            if (cmioString(ids[i], kCMIODevicePropertyDeviceUID, u, sizeof u)) continue;
            len = strlen(u);
            if (!strcmp(u, want)) found = ids[i];
            if (!strncmp(u, "0x", 2) && len >= 8 && !strcmp(u + len - 8, suffix)) only = ids[i], matches++;
        }
    }
    free(ids);
    if (!found && matches == 1) found = only;
    if (found) cmioString(found, kCMIODevicePropertyDeviceUID, uid, n);
    return found;
}

static void cmioChanged(CMIOObjectID id) {
    if (id != cmioDev) return;
    int now = cmioRunningNow(id);
    // the HID report of the MX Brio comes with the same start: one apply for both
    if (now && !cmioRunning && CFAbsoluteTimeGetCurrent() - lastVideoApply > 3.0) armVideoTimer();
    cmioRunning = now;
}

// Listen to the target camera in CoreMediaIO if it is there and we do not already; called when devices come and go.
static void cmioSync(void) {
    char uid[64] = "";
    CMIOObjectID id = cmioFind(uid, sizeof uid);
    if (id == cmioDev) return;
    cmioDev = id;
    stamp();
    if (!id) { printf("CoreMediaIO device removed\n"); return; }
    cmioRunning = cmioRunningNow(id);
    CMIOObjectPropertyAddress a = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere);
    OSStatus st = CMIOObjectAddPropertyListenerBlock(id, &a, dispatch_get_main_queue(),
                                                     ^(UInt32 n, const CMIOObjectPropertyAddress *changed) {
                                                         (void)n;
                                                         (void)changed;
                                                         cmioChanged(id);
                                                     });
    if (st) printf("warning: cannot listen to CoreMediaIO (%d)\n", (int)st);
    else printf("CoreMediaIO listening (%s)\n", uid);
}

static void cmioWatch(void) {
    CMIOObjectPropertyAddress a = cmioAddress(kCMIOHardwarePropertyDevices);
    OSStatus st = CMIOObjectAddPropertyListenerBlock(kCMIOObjectSystemObject, &a, dispatch_get_main_queue(),
                                                     ^(UInt32 n, const CMIOObjectPropertyAddress *changed) {
                                                         (void)n;
                                                         (void)changed;
                                                         cmioSync();
                                                     });
    if (st) {
        stamp();
        printf("warning: cannot watch CoreMediaIO devices (%d)\n", (int)st);
    }
    cmioSync();
}

// Listen to the camera's HID interface without seizing it; never sends or requests a report.
static void watchVideo(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef m =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(
        mgr, vidPid(m, CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey), target.vid, target.pid));
    CFRelease(m);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, hidAdded, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(mgr, hidRemoved, NULL);
    IOHIDManagerRegisterInputReportCallback(mgr, hidReport, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn kr = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (!kr) return;
    stamp();
    printf("warning: cannot listen for video start (HID open failed 0x%x), applying on connect only\n", kr);
    IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(mgr);
}

// Which camera watch follows. Like the other commands, but without --camera it never settles for a camera brioctl does
// not know: a LaunchAgent started with the MX Brio unplugged must not apply its settings to a FaceTime camera. With no
// Logitech camera connected it waits for the MX Brio, as 1.0 did.
static int watchTarget(const char *camId) {
    CamInfo l[MAX_CAMS];
    int n = listCameras(l, MAX_CAMS), pick = -1, known = 0, rc = 0;
    if (n < 0) return 1;
    for (int i = 0; i < n; i++)
        if (l[i].support != S_STANDARD) known++, pick = i;
    if (!camId && !known) {
        memset(&target, 0, sizeof target);
        target.vid = VID_LOGITECH;
        target.pid = PID_MXBRIO;
        describe(&target);
        if (n) {
            stamp();
            printf("no camera known to brioctl is connected, waiting for the MX Brio (--camera ID watches another)\n");
        }
    } else if (!(rc = chooseCamera(l, n, camId, &pick))) {
        target = l[pick];
        target.svc = 0;
    }
    dropCameras(l, n);
    return rc;
}

// Apply a settings file now, every time the camera is connected again and whenever video starts (run it from a
// LaunchAgent).
static int watch(const char *name, const char *camId) {
    configPath(name, watchPath, sizeof watchPath);
    setvbuf(stdout, NULL, _IOLBF, 0);
    int rc = watchTarget(camId);
    if (rc) return rc;
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);
    io_iterator_t it;
    if (IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, cameraMatching(), cameraArrived, NULL, &it)) {
        fprintf(stderr, "cannot watch for the camera\n");
        return 1;
    }
    stamp();
    printf("watching for %s, settings %s\n", camName(&target), watchPath);
    if (target.vid == VID_LOGITECH && target.pid == PID_MXBRIO) watchVideo();  // only it sends the HID report
    cmioWatch();                                                                // every camera tells CoreMediaIO
    cameraArrived(NULL, it);  // the camera may already be connected; this also arms the notification
    CFRunLoopRun();
    return 0;
}

static int factoryReset(Cam *c, int yes) {
    if (!(c->feat & F_FULL)) {
        fprintf(stderr, "factory-reset is only for the MX Brio\n");
        return 1;
    }
    if (!yes) {
        fprintf(stderr, "factory-reset restores the camera's own defaults and restarts it.\n"
                        "Current settings are saved to ~/.config/brioctl/before-reset and applied again afterwards.\n"
                        "Run: brioctl factory-reset --yes\n");
        return 2;
    }
    int unit = c->unit[U_INFO];
    uint8_t info = 0, magic = FACTORY_RESET_VALUE;
    long len;
    if (!unit || getValue(c, GET_LEN, unit, INFO_FACTORY_RESET, 2, &len) || len != 1 ||
        request(c, GET_INFO, unit, INFO_FACTORY_RESET, &info, 1, NULL) || !(info & INFO_SET)) {
        fprintf(stderr, "the reset control does not look as expected, not resetting\n");
        return 1;
    }
    if (save(c, "before-reset")) return 1;
    IOReturn kr = request(c, SET_CUR, unit, INFO_FACTORY_RESET, &magic, 1, NULL);
    closeCam(c);
    printf("reset sent (0x%x), waiting for the camera to restart\n", kr);  // an error is normal: it drops off USB
    sleep(3);
    for (int i = 0; i < 20 && !cameraPresent(); i++) sleep(1);
    if (!cameraPresent()) {
        fprintf(stderr, "the camera did not come back; settings are in ~/.config/brioctl/before-reset\n");
        return 1;
    }
    sleep(2);
    Cam d;
    if (openCam(&d)) return 1;
    int rc = apply(&d, "before-reset");
    if (closeCam(&d)) rc = 1;
    return rc;
}

// Selectors the firmware answers although the descriptor leaves them out (docs/registers.md). Only these two have plain
// getters; info 3 and 9 and Test Debug 3 and 4 have their own and are not probed.
static const struct { const char *guid; int sel; } HIDDEN[] = {
    {GUID_VIDEOPIPE, 1},  // Color Boost
    {GUID_VIDEOPIPE, 3},  // no effect in this firmware
};

// Service registers: chip debug and update units, the factory reset, the flash lock, the lens EEPROM / focus motor
// debug command (Peripheral 7), the restart (Peripheral 17) and factory optics calibration (Videopipe 2). So is every
// register of an extension unit brioctl does not know (another vendor's, or Logitech's unit 2): what reading it does
// is not known. dump asks them only for GET_INFO and GET_LEN.
static int knownXU(const char *guid) {
    for (size_t i = 0; i < sizeof KNOWN_XU / sizeof *KNOWN_XU; i++)
        if (!strcmp(guid, KNOWN_XU[i].guid)) return 1;
    return 0;
}

static int serviceReg(const char *guid, int sel) {
    return !knownXU(guid) || !strcmp(guid, GUID_TESTDEBUG) || !strcmp(guid, GUID_AIT) || !strcmp(guid, GUID_UNKNOWN) ||
           (!strcmp(guid, GUID_INFO) && (sel == INFO_FACTORY_RESET || sel == INFO_FLASH_LOCK)) ||
           (!strcmp(guid, GUID_PERIPHERAL) && (sel == 7 || sel == 17)) || (!strcmp(guid, GUID_VIDEOPIPE) && sel == 2);
}

static void probe(Cam *c, int unit, int sel, int service) {
    uint8_t info = 0;
    long len = 0;
    if (request(c, GET_INFO, unit, sel, &info, 1, NULL)) { printf("  sel %2d  no response\n", sel); return; }
    getValue(c, GET_LEN, unit, sel, 2, &len);
    printf("  sel %2d  %-7s len %-3ld", sel, info & 2 ? (info & 1 ? "get set" : "set") : "get", len);
    if (service) printf("  (service register, value not read)");
    else if ((info & 1) && len > 0 && len <= 1024) {
        static const struct { int req; const char *name; } rs[] = {
            {GET_CUR, "cur"}, {GET_MIN, "min"}, {GET_MAX, "max"}, {GET_DEF, "def"}};
        uint8_t *b = calloc(1, len);
        for (int i = 0; i < 4 && (i == 0 || len <= 8); i++) {  // ranges only for short scalar controls
            UInt32 done;
            if (request(c, rs[i].req, unit, sel, b, (int)len, &done)) continue;
            printf("  %s=", rs[i].name);
            hex(stdout, b, done > 32 ? 32 : done);
            if (done > 32) printf("...");
        }
        free(b);
    }
    printf("\n");
}

// bmControls of an extension unit descriptor and its size; NULL if the descriptor is too short for its own fields.
static const uint8_t *xuControls(const uint8_t *d, int *size) {
    if (d[0] < 23 || d[0] < 23 + d[21]) return NULL;
    *size = d[22 + d[21]];
    return d[0] >= 23 + d[21] + *size ? d + 23 + d[21] : NULL;
}

static int dump(Cam *c) {
    int cls = 0, sub = 0;
    const uint8_t *d;
    for (int i = 0; (d = descAt(c, i)); i += d[0]) {
        if (d[1] == DESC_INTERFACE) {
            if (d[0] >= 7) {
                cls = d[5];
                sub = d[6];
            }
            continue;
        }
        if (d[1] != DESC_CS_INTERFACE || d[0] < 4 || cls != 0x0e || sub != 1) continue;
        if (d[2] == VC_INPUT_TERMINAL && d[0] >= 6 && (d[4] | d[5] << 8) == ITT_CAMERA) {
            printf("camera terminal %d  controls ", d[3]);
            if (d[0] >= 15 && d[0] >= 15 + d[14]) hex(stdout, d + 15, d[14]);
            else printf("(descriptor cut off)");
            printf("\n");
        } else if (d[2] == VC_PROCESSING_UNIT) {
            printf("processing unit %d  controls ", d[3]);
            if (d[0] >= 8 && d[0] >= 8 + d[7]) hex(stdout, d + 8, d[7]);
            else printf("(descriptor cut off)");
            printf("\n");
        } else if (d[2] == VC_EXTENSION_UNIT && d[0] >= 20) {
            int size = 0;
            const uint8_t *bm = xuControls(d, &size);
            char g[37];
            const char *known = "unknown";
            guidString(d + 4, g);
            for (size_t x = 0; x < sizeof KNOWN_XU / sizeof *KNOWN_XU; x++)
                if (!strcmp(g, KNOWN_XU[x].guid)) known = KNOWN_XU[x].name;
            printf("extension unit %d  %s  %s\n", d[3], g, known);
            if (!bm) { printf("  (descriptor cut off, no control list)\n"); continue; }
            for (int bit = 0; bit < size * 8; bit++)
                if (bm[bit / 8] >> (bit % 8) & 1) probe(c, d[3], bit + 1, serviceReg(g, bit + 1));
            int shown = 0;
            for (size_t h = 0; h < sizeof HIDDEN / sizeof *HIDDEN; h++) {
                int bit = HIDDEN[h].sel - 1;
                if (strcmp(g, HIDDEN[h].guid) || (bit / 8 < size && bm[bit / 8] >> (bit % 8) & 1)) continue;
                if (!shown++) printf("  not in the descriptor, answered by the firmware:\n");
                probe(c, d[3], HIDDEN[h].sel, serviceReg(g, HIDDEN[h].sel));
            }
        }
    }
    return 0;
}

// A register for a snapshot: how many of cur, min, max, res, def to read; len is used if GET_LEN does not answer.
typedef struct { int unit, sel, len, fields; } SnapReg;

// Registers the code reads besides CTRLS.
static const SnapReg EXTRA[] = {
    {U_INFO, INFO_FIRMWARE, 4, F_COUNT},
    {U_INFO, INFO_SERIAL, 12, 1},  // the value is masked in the output
    {U_INFO, INFO_COLOR, 1, F_COUNT},
    {U_INFO, INFO_SHOWMODE_ACTIVE, 1, F_COUNT},
    {U_INFO, INFO_FACTORY_RESET, 1, 0},  // INFO and LEN only: GET_CUR is never sent to the factory reset
    {U_STATS, STATS_STREAM, 6, 1},
    {U_PERIPHERAL, PERIPHERAL_LED, 6, 1},
    {U_PERIPHERAL, PERIPHERAL_RIGHTSIGHT, 4, F_COUNT},
    {U_APP, APP_RIGHTSIGHT, 30, 1},
    {U_VIDEOPIPE, 1, 1, F_COUNT},  // the two HIDDEN selectors: Color Boost and one without effect
    {U_VIDEOPIPE, 3, 1, F_COUNT},
};
#define NEXTRA (int)(sizeof EXTRA / sizeof *EXTRA)

// Read one register: GET_INFO, GET_LEN (extension units) and the first nf of cur, min, max, res, def. Read-only by
// construction: only GET_* requests are sent here. Returns 1 if the camera answered anything.
static int readReg(Cam *c, Reg *r, int u, int sel, int len, int nf) {
    long xlen;
    uint8_t info = 0;
    int any = 0;
    memset(r, 0, sizeof *r);
    r->unit = c->unit[u];
    r->sel = sel;
    r->info = r->len = -1;
    if (!r->unit) return 0;
    // Whatever the table says: GET_CUR on the factory reset or the flash lock must never be sent.
    if (u == U_INFO && (sel == INFO_FACTORY_RESET || sel == INFO_FLASH_LOCK)) nf = 0;
    if (!request(c, GET_INFO, r->unit, sel, &info, 1, NULL)) { r->info = info; any = 1; }
    if (isXUnit(u) && !getValue(c, GET_LEN, r->unit, sel, 2, &xlen) && xlen > 0 && xlen <= REG_MAX) {
        r->len = len = (int)xlen;
        any = 1;
    }
    for (int i = 0; i < nf; i++) {
        UInt32 done = 0;
        if (!request(c, FIELDS[i].req, r->unit, sel, r->f[i].b, len > REG_MAX ? REG_MAX : len, &done) && done) {
            r->f[i].n = done;
            any = 1;
        }
    }
    return any;
}

// Everything brioctl reads from the camera, in the format the offline tests load (see tests/). Strictly read-only.
// The serial number is replaced by zeros so a snapshot can be shared.
static int snapshot(Cam *c, const char *path) {
    FILE *f = path ? fopen(path, "w") : stdout;
    if (!f) { perror(path); return 1; }
    char fw[16] = "unknown", ts[32];
    time_t t = time(NULL);
    if (c->info.vid == VID_LOGITECH) readFirmware(c, fw);  // one read of Logitech's device info unit, if it has one
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M", localtime(&t));
    fprintf(f, "# brioctl snapshot 1, firmware %s, %s\ndevice %04x %04x\n", fw, ts, c->info.vid, c->info.pid);
    if (c->info.name[0]) fprintf(f, "name %s\n", c->info.name);
    if (c->info.serial[0]) {  // masked like the serial register
        fprintf(f, "serial ");
        for (const char *p = c->info.serial; *p; p++) fputc('0', f);
        fprintf(f, "\n");
    }
    fprintf(f, "descriptor ");
    hex(f, c->cfg, c->cfgLen);
    fprintf(f, "\n");
    Float32 g;
    if ((c->feat & F_FULL) && !micRead(&g)) fprintf(f, "micgain %.4f\n", g);

    SnapReg todo[NCTRLS + NEXTRA];
    int nt = 0, n = 0;
    for (int i = 0; i < NCTRLS; i++)  // what brioctl would read from this camera
        if (avail(c, &CTRLS[i])) todo[nt++] = (SnapReg){CTRLS[i].unit, CTRLS[i].sel, CTRLS[i].len, F_COUNT};
    for (int i = 0; i < NEXTRA && (c->feat & F_FULL); i++) todo[nt++] = EXTRA[i];
    for (int i = 0; i < nt; i++) {
        int dup = 0;
        for (int j = 0; j < i; j++) dup |= todo[j].unit == todo[i].unit && todo[j].sel == todo[i].sel;  // pan, tilt
        Reg r;
        if (dup || !readReg(c, &r, todo[i].unit, todo[i].sel, todo[i].len, todo[i].fields)) continue;
        if (todo[i].unit == U_INFO && todo[i].sel == INFO_SERIAL) memset(r.f[F_CUR].b, '0', r.f[F_CUR].n);
        printReg(f, &r);
        n++;
    }
    if (path) fclose(f);
    if (!n) {
        fprintf(stderr, "snapshot: the camera answered no register\n");
        if (path) remove(path);  // only a header: not a snapshot
        return 1;
    }
    if (path) printf("snapshot of %d registers written to %s\n", n, path);
    return 0;
}

static void usage(FILE *f) {
    fprintf(f, "usage: brioctl [--camera ID] COMMAND   ID: index or serial number from 'brioctl list', or location 0x...\n"
               "       brioctl                     show settings\n"
               "       brioctl list [--json]       list the UVC cameras\n"
               "       brioctl --json              the same as one JSON object, for scripts\n"
               "       brioctl get NAME            print one value only (settings and micgain), exit 1 if unreadable\n"
               "       brioctl NAME VALUE ...      change settings, e.g. brioctl fov 78 flicker 50 hdr on\n"
               "       brioctl save [FILE]         save current settings (default ~/.config/brioctl/settings)\n"
               "       brioctl apply [FILE|PRESET] apply saved settings or a built-in preset\n"
               "       brioctl profiles [--json]   list presets and saved files\n"
               "       brioctl defaults            camera defaults for the settings below except mic and showmode\n"
               "       brioctl watch [FILE]        apply FILE now, when the camera is connected and when video starts\n"
               "       brioctl factory-reset --yes restart the MX Brio with factory settings, then restore yours\n"
               "       brioctl dump                list all UVC units and extension controls (read-only)\n"
               "       brioctl snapshot [FILE]     write every register brioctl reads, serial masked (read-only)\n"
               "       brioctl --version           print the version\n");
    fprintf(f, "\nWhat a camera has depends on the camera: 'brioctl' shows its settings and their ranges. Setting names:\n");
    for (int i = 0; i < NCTRLS; i++) {
        char help[192];
        helpText(NULL, &CTRLS[i], help, sizeof help);
        if (!CTRLS[i].name) fprintf(f, "\n%s:\n", CTRLS[i].help);
        else fprintf(f, "  %-11s %s\n", CTRLS[i].name, help);
    }
    fprintf(f, "\nMicrophone (macOS, MX Brio only):\n  %-11s %s\n", "micgain", "input volume, 0-1");
}

int main(int argc, char **argv) {
    const char *camId = NULL;  // --camera ID may stand anywhere; take it out
    int n = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--camera")) {
            if (++i == argc) { usage(stderr); return 2; }
            camId = argv[i];
        } else if (!strncmp(argv[i], "--camera=", 9)) camId = argv[i] + 9;
        else argv[n++] = argv[i];
    }
    argv[argc = n] = NULL;

    const char *cmd = argc > 1 ? argv[1] : "show";
    const char *arg = argc > 2 ? argv[2] : NULL;
    if (!strcmp(cmd, "-h") || !strcmp(cmd, "--help") || !strcmp(cmd, "help")) {
        usage(stdout);
        return 0;
    }
    if (!strcmp(cmd, "--version") || !strcmp(cmd, "version")) {
        printf("brioctl %s\n", VERSION);
        return 0;
    }
    if (!strcmp(cmd, "list") || !strcmp(cmd, "profiles")) {
        if (argc > 3 || (arg && strcmp(arg, "--json"))) { usage(stderr); return 2; }
        return !strcmp(cmd, "list") ? listCmd(arg != NULL) : profiles(arg != NULL);
    }
    if (!strcmp(cmd, "watch")) return watch(arg ? arg : "settings", camId);
    int rc = 0;
#ifdef BRIOCTL_FAKE
    if (!strcmp(cmd, "--test-watch-target")) {  // test hook: which camera would watch follow
        char uid[64];
        if ((rc = watchTarget(camId))) return rc;
        cmioUid(uid, sizeof uid);
        printf("%04x:%04x serial=%s uid=%s\n", target.vid, target.pid, target.serial, uid);
        return 0;
    }
    if (!strcmp(cmd, "--test-cmio")) {  // test hook: the CoreMediaIO device of the chosen camera (reads only)
        char uid[64] = "";
        if ((rc = selectCamera(camId))) return rc;
        CMIOObjectID id = cmioFind(uid, sizeof uid);
        if (id) printf("cmio uid=%s running=%d\n", uid, cmioRunningNow(id));
        else printf("cmio none\n");
        return 0;
    }
    if (!strcmp(cmd, "--test-reapply") && arg && argc <= 4) {  // test hook: what watch does, without the run loop
        if ((rc = selectCamera(camId))) return rc;
        snprintf(watchPath, sizeof watchPath, "%s", arg);
        if (argc == 4 && !strcmp(argv[3], "video")) videoSettled(NULL, NULL);  // the timer callback of a video start
        else reapply(1, 0, 0);                                                 // the camera connected
        return 0;
    }
#endif
    if (!strcmp(cmd, "get") && argc != 3) { usage(stderr); return 2; }

    static const char *const COMMANDS[] = {"show", "dump", "save", "apply", "defaults", "factory-reset", "--json",
                                           "snapshot", "get"};
    int isCommand = 0;
    for (size_t i = 0; i < sizeof COMMANDS / sizeof *COMMANDS; i++)
        if (!strcmp(cmd, COMMANDS[i])) isCommand = 1;
    if (isCommand ? argc > 3 : argc % 2 == 0) { usage(stderr); return 2; }

    if ((rc = selectCamera(camId))) return rc;
    Cam c;
    if (openCam(&c)) return 1;
    if (!strcmp(cmd, "show")) rc = show(&c);
    else if (!strcmp(cmd, "--json")) rc = showJson(&c);
    else if (!strcmp(cmd, "get")) rc = get(&c, arg);
    else if (!strcmp(cmd, "snapshot")) rc = snapshot(&c, arg);
    else if (!strcmp(cmd, "dump")) rc = dump(&c);
    else if (!strcmp(cmd, "save")) rc = save(&c, arg ? arg : "settings");
    else if (!strcmp(cmd, "apply")) rc = apply(&c, arg ? arg : "settings");
    else if (!strcmp(cmd, "defaults")) rc = defaults(&c);
    else if (!strcmp(cmd, "factory-reset")) rc = factoryReset(&c, arg && !strcmp(arg, "--yes"));
    else
        for (int last = 0; last < 2; last++)
            for (int i = 1; i + 1 < argc; i += 2)
                if (setLast(argv[i]) == last && set(&c, argv[i], argv[i + 1])) rc = 1;
    if (closeCam(&c)) rc = 1;
    return rc;
}
