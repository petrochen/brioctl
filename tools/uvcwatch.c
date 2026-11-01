// uvcwatch: poll UVC controls of the Logitech MX Brio and print a line whenever a value changes.
//
// Uses the same IOKit path as brioctl (DeviceRequestTO on the VideoControl interface, without opening the device),
// but only ever sends GET_CUR and GET_LEN. There is no code path that writes to the camera.
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define VID 0x046d
#define PID 0x0944  // MX Brio

// Logitech extension units, names as in brioctl
static const struct { const char *name, *guid, *title; } XU_NAMES[] = {
    {"videopipe", "49e40215-f434-47fe-b158-0e885023e51b", "Videopipe Control"},
    {"peripheral", "ffe52d21-8030-4e2c-82d9-f587d00540bd", "Peripheral Control"},
    {"info", "69678ee4-410f-40db-a850-7420d7d8240e", "device info"},
    {"stats", "5a6d654c-7e35-4d4e-810d-069d15e0f79b", "Video Statistics"},
    {"appsettings", "29144c1f-658d-4f47-a40f-0ed339428bf0", "App Settings (RightSight)"},
    {NULL, "1f5d4ca9-de11-4487-840d-50933c8ec8d1", "Test Debug"},
    {NULL, "23e49ed0-1178-4f31-ae52-d2fb8a8d3b48", "AIT custom"},
};
#define NXU_NAMES (int)(sizeof XU_NAMES / sizeof *XU_NAMES)

static const char *DEFAULTS[] = {
    "stats:1",      "peripheral:9", "peripheral:15", "peripheral:12", "peripheral:18",
    "peripheral:24", "videopipe:2", "videopipe:4",   "videopipe:8",   "videopipe:9",
    "videopipe:10", "videopipe:11", "videopipe:12",  "appsettings:1",
};

// Sizes of the standard controls (UVC 1.5), by selector; they do not answer GET_LEN reliably.
static const int CT_LEN[] = {0, 1, 1, 1, 4, 1, 2, 2, 1, 2, 1, 2, 3, 8, 4, 2, 2, 1, 1, 12, 10};
static const int PU_LEN[] = {0, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 1, 4, 1, 2, 2, 1, 1, 1, 1};

enum { GET_CUR = 0x81, GET_LEN = 0x85 };  // the only requests this tool sends
enum { DESC_INTERFACE = 0x04, DESC_CS_INTERFACE = 0x24 };
enum { VC_INPUT_TERMINAL = 0x02, VC_PROCESSING_UNIT = 0x05, VC_EXTENSION_UNIT = 0x06, ITT_CAMERA = 0x0201 };

typedef IOUSBDeviceInterface650 **Dev;

#define MAXXU 32
typedef struct {
    Dev dev;
    int vcIf;  // VideoControl interface number
    int ct, pu;
    int nxu;
    struct { int id; char guid[37]; } xu[MAXXU];
} Cam;

typedef struct {
    char label[40];  // name:sel as printed
    const char *title;
    int unit, sel, len;
    int seen;        // a value or an error has been printed
    IOReturn err;
    UInt32 done;
    uint8_t *cur, *buf;
} Watch;

static volatile sig_atomic_t stop;

static void onSignal(int sig) {
    (void)sig;
    stop = 1;
}

// Device-to-host class request: GET_CUR or GET_LEN only.
static IOReturn get(Cam *c, int req, int unit, int sel, void *buf, int len, UInt32 *done) {
    if (req != GET_CUR && req != GET_LEN) abort();
    IOUSBDevRequestTO r = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface),
        .bRequest = req, .wValue = sel << 8, .wIndex = (unit << 8) | c->vcIf,
        .wLength = len, .pData = buf, .noDataTimeout = 500, .completionTimeout = 500,
    };
    IOReturn kr = (*c->dev)->DeviceRequestTO(c->dev, &r);
    if (done) *done = r.wLenDone;
    return kr;
}

static void guidString(const uint8_t *g, char s[37]) {
    snprintf(s, 37, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", g[3], g[2], g[1], g[0],
             g[5], g[4], g[7], g[6], g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15]);
}

static int openCam(Cam *c) {
    memset(c, 0, sizeof *c);
    c->vcIf = -1;

    int vid = VID, pid = PID;
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberIntType, &vid), np = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv);
    CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv);
    CFRelease(np);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) { fprintf(stderr, "MX Brio is not connected\n"); return -1; }

    IOCFPlugInInterface **plug;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                                         &plug, &score);
    IOObjectRelease(svc);
    if (kr) { fprintf(stderr, "cannot attach to the camera: 0x%x\n", kr); return -1; }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&c->dev);
    (*plug)->Release(plug);
    if (!c->dev) { fprintf(stderr, "no USB device interface\n"); return -1; }

    IOUSBConfigurationDescriptorPtr cfgp;
    if ((*c->dev)->GetConfigurationDescriptorPtr(c->dev, 0, &cfgp)) {
        fprintf(stderr, "no configuration descriptor\n");
        return -1;
    }
    const uint8_t *cfg = (const uint8_t *)cfgp;
    int cfgLen = USBToHostWord(cfgp->wTotalLength);

    int cls = 0, sub = 0;
    for (int i = 0; i + 2 <= cfgLen && cfg[i]; i += cfg[i]) {
        const uint8_t *d = cfg + i;
        if (d[1] == DESC_INTERFACE) {
            cls = d[5];
            sub = d[6];
            if (cls == 0x0e && sub == 1) c->vcIf = d[2];
        } else if (d[1] == DESC_CS_INTERFACE && cls == 0x0e && sub == 1) {
            if (d[2] == VC_INPUT_TERMINAL && (d[4] | d[5] << 8) == ITT_CAMERA) c->ct = d[3];
            else if (d[2] == VC_PROCESSING_UNIT) c->pu = d[3];
            else if (d[2] == VC_EXTENSION_UNIT && c->nxu < MAXXU) {
                c->xu[c->nxu].id = d[3];
                guidString(d + 4, c->xu[c->nxu].guid);
                c->nxu++;
            }
        }
    }
    if (c->vcIf < 0) { fprintf(stderr, "no VideoControl interface\n"); return -1; }
    return 0;
}

static const char *guidOf(Cam *c, int unit) {
    for (int i = 0; i < c->nxu; i++)
        if (c->xu[i].id == unit) return c->xu[i].guid;
    return NULL;
}

// Short name and title for a unit id: ct, pu, a known extension name, or the first 8 digits of its GUID.
static void unitName(Cam *c, int unit, char *name, size_t n, const char **title) {
    *title = "unknown extension";
    if (unit == c->ct) { snprintf(name, n, "ct"); *title = "Camera Terminal"; return; }
    if (unit == c->pu) { snprintf(name, n, "pu"); *title = "Processing Unit"; return; }
    const char *g = guidOf(c, unit);
    snprintf(name, n, "%.8s", g ? g : "?");
    for (int i = 0; g && i < NXU_NAMES; i++)
        if (!strcmp(g, XU_NAMES[i].guid)) {
            if (XU_NAMES[i].name) snprintf(name, n, "%s", XU_NAMES[i].name);
            *title = XU_NAMES[i].title;
        }
}

static int resolveUnit(Cam *c, const char *s) {
    if (!strcasecmp(s, "ct")) return c->ct ? c->ct : -1;
    if (!strcasecmp(s, "pu")) return c->pu ? c->pu : -1;
    const char *guid = NULL;
    for (int i = 0; i < NXU_NAMES; i++)
        if (XU_NAMES[i].name && !strcasecmp(s, XU_NAMES[i].name)) guid = XU_NAMES[i].guid;
    if (guid) {
        for (int i = 0; i < c->nxu; i++)
            if (!strcmp(c->xu[i].guid, guid)) return c->xu[i].id;
        return -1;
    }
    char *end;
    long id = strtol(s, &end, 10);
    if (*s && !*end && id >= 1 && id <= 255)  // a unit id, as printed by brioctl dump
        return (id == c->ct || id == c->pu || guidOf(c, (int)id)) ? (int)id : -1;
    int found = -1, matches = 0;  // otherwise a GUID prefix
    for (int i = 0; i < c->nxu; i++)
        if (!strncasecmp(c->xu[i].guid, s, strlen(s))) {
            found = c->xu[i].id;
            matches++;
        }
    if (matches > 1) return -2;
    return found;
}

static int parseWatch(Cam *c, const char *arg, Watch *w) {
    char unit[64];
    int sel = 0, len = 0;
    const char *colon = strchr(arg, ':');
    char *end;
    memset(w, 0, sizeof *w);
    if (!colon || colon == arg || (size_t)(colon - arg) >= sizeof unit) goto bad;
    snprintf(unit, sizeof unit, "%.*s", (int)(colon - arg), arg);
    sel = (int)strtol(colon + 1, &end, 0);
    if (end == colon + 1 || sel < 1 || sel > 255) goto bad;
    if (*end == ':') {
        const char *l = end + 1;
        len = (int)strtol(l, &end, 0);
        if (end == l || len < 1 || len > 1024) goto bad;
    }
    if (*end) goto bad;

    w->unit = resolveUnit(c, unit);
    if (w->unit == -2) { fprintf(stderr, "%s: more than one extension unit matches %s\n", arg, unit); return -1; }
    if (w->unit < 0) { fprintf(stderr, "%s: no unit %s on this camera\n", arg, unit); return -1; }
    w->sel = sel;

    if (!len) {
        int std = w->unit == c->ct || w->unit == c->pu;
        const int *tab = w->unit == c->ct ? CT_LEN : PU_LEN;
        int ntab = w->unit == c->ct ? (int)(sizeof CT_LEN / sizeof *CT_LEN) : (int)(sizeof PU_LEN / sizeof *PU_LEN);
        if (std && sel < ntab) len = tab[sel];
        uint8_t b[2] = {0};
        if (!len && !get(c, GET_LEN, w->unit, sel, b, 2, NULL)) len = b[0] | b[1] << 8;
        if (len < 1 || len > 1024) {
            fprintf(stderr, "%s: GET_LEN failed, give the size as %s:%d:LEN\n", arg, unit, sel);
            return -1;
        }
    }
    w->len = len;
    char name[24];
    unitName(c, w->unit, name, sizeof name, &w->title);
    snprintf(w->label, sizeof w->label, "%s:%d", name, sel);
    w->cur = calloc(1, len);
    w->buf = calloc(1, len);
    return 0;
bad:
    fprintf(stderr, "bad control %s, expected UNIT:SEL[:LEN]\n", arg);
    return -1;
}

static void stamp(void) {
    struct timeval tv;
    struct tm tm;
    gettimeofday(&tv, NULL);
    localtime_r(&tv.tv_sec, &tm);
    printf("%02d:%02d:%02d.%03d", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
}

static void printValue(IOReturn err, const uint8_t *b, UInt32 done, int len) {
    if (err) { printf("error 0x%08x", err); return; }
    for (UInt32 i = 0; i < done; i++) printf("%02x", b[i]);
    if ((int)done != len) printf(" (%u of %d bytes)", (unsigned)done, len);
}

static void poll(Cam *c, Watch *w, int width) {
    UInt32 done = 0;
    memset(w->buf, 0, w->len);
    IOReturn err = get(c, GET_CUR, w->unit, w->sel, w->buf, w->len, &done);
    if (err) done = 0;
    if (w->seen && err == w->err && done == w->done && !memcmp(w->buf, w->cur, done)) return;

    stamp();
    printf("  %-*s  ", width, w->label);
    printValue(err, w->buf, done, w->len);
    if (w->seen) {
        printf("  was ");
        printValue(w->err, w->cur, w->done, w->len);
        if (!err && !w->err) {  // which bytes changed
            const char *sep = "  bytes ";
            for (UInt32 i = 0; i < done && i < w->done; i++)
                if (w->buf[i] != w->cur[i]) { printf("%s%u", sep, (unsigned)i); sep = ","; }
        }
    }
    printf("\n");
    fflush(stdout);
    w->seen = 1;
    w->err = err;
    w->done = done;
    memcpy(w->cur, w->buf, w->len);
}

static void usage(FILE *f) {
    fprintf(f, "usage: uvcwatch [-i MS] [-t SECONDS] [UNIT:SEL[:LEN] ...]\n"
               "  poll GET_CUR of each control every MS milliseconds (default 500) and print a line when\n"
               "  a value changes; run until Ctrl-C or for SECONDS. Read-only: sends only GET_CUR and GET_LEN.\n"
               "  UNIT: unit id (see brioctl dump), GUID prefix, or ct, pu, videopipe, peripheral, info,\n"
               "  stats, appsettings. LEN: control size in bytes, GET_LEN by default.\n"
               "  without controls watches:");
    for (size_t i = 0; i < sizeof DEFAULTS / sizeof *DEFAULTS; i++) fprintf(f, " %s", DEFAULTS[i]);
    fprintf(f, "\n");
}

int main(int argc, char **argv) {
    int ms = 500;
    double secs = 0;
    int opt;
    while ((opt = getopt(argc, argv, "i:t:h")) != -1) {
        if (opt == 'i' && (ms = atoi(optarg)) >= 10) continue;
        if (opt == 't' && (secs = atof(optarg)) > 0) continue;
        usage(opt == 'h' ? stdout : stderr);
        return opt == 'h' ? 0 : 2;
    }

    Cam c;
    if (openCam(&c)) return 1;

    const char **args = (const char **)argv + optind;
    int n = argc - optind;
    if (!n) {
        args = DEFAULTS;
        n = sizeof DEFAULTS / sizeof *DEFAULTS;
    }
    Watch *ws = calloc(n, sizeof *ws);
    int nw = 0, width = 0, rc = 0;
    for (int i = 0; i < n; i++) {
        if (parseWatch(&c, args[i], &ws[nw])) { rc = 1; continue; }
        int l = (int)strlen(ws[nw].label);
        if (l > width) width = l;
        nw++;
    }
    if (!nw) return 1;

    printf("MX Brio: polling %d controls every %d ms", nw, ms);
    if (secs > 0) printf(" for %g s", secs);
    printf(", Ctrl-C to stop\n");
    for (int i = 0; i < nw; i++)
        printf("  %-*s  unit %-2d sel %-2d %3d bytes  %s\n", width, ws[i].label, ws[i].unit, ws[i].sel, ws[i].len,
               ws[i].title);

    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);
    struct timeval t0, t;
    gettimeofday(&t0, NULL);
    while (!stop) {
        for (int i = 0; i < nw && !stop; i++) poll(&c, &ws[i], width);
        gettimeofday(&t, NULL);
        if (secs > 0 && (t.tv_sec - t0.tv_sec) + (t.tv_usec - t0.tv_usec) / 1e6 >= secs) break;
        usleep(ms * 1000);
    }
    (*c.dev)->Release(c.dev);
    return rc;
}
