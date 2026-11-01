// hidmon: watch what the Logitech MX Brio reports on its HID interface.
//
// Prints the device, its usage pairs and a summary of the report descriptor, then a timestamp, report ID and hex
// for every input report until Ctrl-C (or -t SECONDS). Read-only: the device is opened without seizing, and no
// output or feature report is ever sent and no report is requested (no IOHIDDeviceSetReport, no GET_REPORT).
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hidsystem/IOHIDLib.h>

#define VID 0x046d
#define PID 0x0944  // MX Brio

enum { DIR_IN, DIR_OUT, DIR_FEAT };
static const char *DIR_NAME[] = {"input", "output", "feature"};

#define MAXREP 64
#define MAXUSE 8

typedef struct {
    int id, dir, bits;
    uint32_t coll;            // top-level collection: page << 16 | usage
    int nuse;
    uint32_t use[MAXUSE][2];  // page << 16 | usage; min and max of a range, equal for a single usage
} Report;

static const struct { uint32_t page; const char *name; } PAGES[] = {
    {0x01, "Generic Desktop"}, {0x07, "Keyboard"}, {0x08, "LED"}, {0x09, "Button"},
    {0x0b, "Telephony"},       {0x0c, "Consumer"},
};

static const struct { uint32_t usage; const char *name; } USAGES[] = {
    {0x000b0005, "Headset"},  {0x000b0020, "Hook Switch"}, {0x000b002a, "Line"},    {0x000b002f, "Phone Mute"},
    {0x00080009, "Mute LED"}, {0x00080017, "Off-Hook LED"}, {0x00080018, "Ring LED"},
};

static const char *pageName(uint32_t page) {
    if (page >= 0xff00) return "vendor";
    for (size_t i = 0; i < sizeof PAGES / sizeof *PAGES; i++)
        if (PAGES[i].page == page) return PAGES[i].name;
    return "";
}

static const char *usageName(uint32_t u) {
    for (size_t i = 0; i < sizeof USAGES / sizeof *USAGES; i++)
        if (USAGES[i].usage == u) return USAGES[i].name;
    return NULL;
}

static Report *findReport(Report *r, int *nr, int id, int dir, uint32_t coll) {
    for (int i = 0; i < *nr; i++)
        if (r[i].id == id && r[i].dir == dir) return &r[i];
    if (*nr == MAXREP) return NULL;
    Report *e = &r[(*nr)++];
    memset(e, 0, sizeof *e);
    e->id = id;
    e->dir = dir;
    e->coll = coll;
    return e;
}

static void addUsage(Report *e, uint32_t lo, uint32_t hi) {
    for (int i = 0; i < e->nuse; i++)
        if (e->use[i][0] == lo && e->use[i][1] == hi) return;
    if (e->nuse < MAXUSE) {
        e->use[e->nuse][0] = lo;
        e->use[e->nuse][1] = hi;
        e->nuse++;
    }
}

// Walks the short items of a report descriptor and adds up the bits of every report ID and direction.
static int parseDescriptor(const uint8_t *d, int n, Report *r) {
    struct { uint32_t page, size, count, id; } g = {0}, stack[8];
    struct { uint32_t v; int full, range; } loc[MAXUSE];  // local usages until the next main item
    int sp = 0, nr = 0, nloc = 0, depth = 0;
    uint32_t coll = 0, umin = 0;
    int uminFull = 0;

    for (int i = 0; i < n;) {
        uint8_t p = d[i];
        if (p == 0xfe) {  // long item
            if (i + 2 > n) break;
            i += 3 + d[i + 1];
            continue;
        }
        int sz = (p & 3) == 3 ? 4 : p & 3, type = p >> 2 & 3, tag = p >> 4;
        if (i + 1 + sz > n) break;
        uint32_t v = 0;
        for (int k = sz - 1; k >= 0; k--) v = v << 8 | d[i + 1 + k];
        i += 1 + sz;

        if (type == 1) {  // global
            if (tag == 0) g.page = v;
            else if (tag == 7) g.size = v;
            else if (tag == 8) g.id = v;
            else if (tag == 9) g.count = v;
            else if (tag == 10 && sp < 8) stack[sp++] = g;
            else if (tag == 11 && sp > 0) g = stack[--sp];
        } else if (type == 2) {  // local: a 4-byte usage carries its page, a shorter one takes the current page
            if (tag == 1) {
                umin = v;
                uminFull = sz == 4;
            } else if ((tag == 0 || tag == 2) && nloc < MAXUSE) {
                loc[nloc].v = v;
                loc[nloc].full = sz == 4;
                loc[nloc].range = tag == 2;
                nloc++;
            }
        } else if (type == 0) {  // main
#define FULL(x, f) ((f) ? (x) : g.page << 16 | ((x) & 0xffff))
            if (tag == 10) {  // collection
                if (depth++ == 0) coll = nloc ? FULL(loc[0].v, loc[0].full) : g.page << 16;
            } else if (tag == 12) {  // end collection
                if (depth > 0) depth--;
            } else if (tag == 8 || tag == 9 || tag == 11) {  // input, output, feature
                Report *e = findReport(r, &nr, g.id, tag == 8 ? DIR_IN : tag == 9 ? DIR_OUT : DIR_FEAT, coll);
                if (e) {
                    e->bits += g.size * g.count;
                    if (!(v & 1))  // constant items are padding
                        for (int k = 0; k < nloc; k++) {
                            uint32_t hi = FULL(loc[k].v, loc[k].full);
                            addUsage(e, loc[k].range ? FULL(umin, uminFull) : hi, hi);
                        }
                }
            }
#undef FULL
            nloc = 0;
        }
    }
    return nr;
}

static void printUsage(uint32_t lo, uint32_t hi, int first) {
    printf("%s%04x:%04x", first ? " " : ", ", lo >> 16, lo & 0xffff);
    if (hi != lo) printf("..%04x", hi & 0xffff);
    else if (usageName(lo)) printf(" %s", usageName(lo));
}

static void printDescriptor(const uint8_t *d, int n) {
    Report r[MAXREP];
    int nr = parseDescriptor(d, n, r);
    printf("report descriptor: %d bytes, %d reports (bytes = payload after the report ID)\n", n, nr);
    printf("  id    type     bytes  collection             usages\n");
    for (int i = 0; i < nr; i++) {
        const Report *e = &r[i];
        char coll[32];
        snprintf(coll, sizeof coll, "%04x:%04x %s", e->coll >> 16, e->coll & 0xffff,
                 usageName(e->coll) ? usageName(e->coll) : pageName(e->coll >> 16));
        printf("  0x%02x  %-7s  %5d  %-21s ", e->id, DIR_NAME[e->dir], (e->bits + 7) / 8, coll);
        for (int k = 0; k < e->nuse; k++) printUsage(e->use[k][0], e->use[k][1], !k);
        printf("\n");
    }
}

static long numberProp(IOHIDDeviceRef dev, CFStringRef key) {
    CFTypeRef v = IOHIDDeviceGetProperty(dev, key);
    long n = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &n);
    return n;
}

static void stringProp(IOHIDDeviceRef dev, CFStringRef key, char *s, size_t n) {
    CFTypeRef v = IOHIDDeviceGetProperty(dev, key);
    s[0] = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, s, n, kCFStringEncodingUTF8);
}

static void printDevice(IOHIDDeviceRef dev) {
    char product[64], maker[64], serial[64], transport[32];
    stringProp(dev, CFSTR(kIOHIDProductKey), product, sizeof product);
    stringProp(dev, CFSTR(kIOHIDManufacturerKey), maker, sizeof maker);
    stringProp(dev, CFSTR(kIOHIDSerialNumberKey), serial, sizeof serial);
    stringProp(dev, CFSTR(kIOHIDTransportKey), transport, sizeof transport);
    printf("%s", product[0] ? product : "?");
    if (maker[0]) printf(" (%s)", maker);
    printf("  %s %04lx:%04lx  location 0x%lx", transport, numberProp(dev, CFSTR(kIOHIDVendorIDKey)),
           numberProp(dev, CFSTR(kIOHIDProductIDKey)), numberProp(dev, CFSTR(kIOHIDLocationIDKey)));
    if (serial[0]) {
        // The serial number is masked (same length), so the output is safe to post.
        printf("  serial ");
        for (const char *c = serial; *c; c++) putchar('X');
    }
    printf("\n  primary usage %04lx:%04lx, usage pairs", numberProp(dev, CFSTR(kIOHIDPrimaryUsagePageKey)),
           numberProp(dev, CFSTR(kIOHIDPrimaryUsageKey)));
    CFTypeRef pairs = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDDeviceUsagePairsKey));
    if (pairs && CFGetTypeID(pairs) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(pairs); i++) {
            CFDictionaryRef p = CFArrayGetValueAtIndex(pairs, i);
            CFNumberRef up = CFDictionaryGetValue(p, CFSTR(kIOHIDDeviceUsagePageKey));
            CFNumberRef u = CFDictionaryGetValue(p, CFSTR(kIOHIDDeviceUsageKey));
            long a = 0, b = 0;
            if (up) CFNumberGetValue(up, kCFNumberLongType, &a);
            if (u) CFNumberGetValue(u, kCFNumberLongType, &b);
            printf(" %04lx:%04lx", a, b);
            if (usageName(a << 16 | b)) printf(" %s", usageName(a << 16 | b));
        }
    }
    printf("\n  max report size: input %ld, output %ld, feature %ld bytes\n",
           numberProp(dev, CFSTR(kIOHIDMaxInputReportSizeKey)), numberProp(dev, CFSTR(kIOHIDMaxOutputReportSizeKey)),
           numberProp(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey)));

    CFTypeRef desc = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDReportDescriptorKey));
    if (desc && CFGetTypeID(desc) == CFDataGetTypeID())
        printDescriptor(CFDataGetBytePtr(desc), (int)CFDataGetLength(desc));
    else
        printf("report descriptor: not available\n");
}

static volatile sig_atomic_t stop;
static long nReports;

static void onSignal(int sig) {
    (void)sig;
    stop = 1;
}

static void stamp(void) {
    struct timeval tv;
    struct tm tm;
    gettimeofday(&tv, NULL);
    localtime_r(&tv.tv_sec, &tm);
    printf("%02d:%02d:%02d.%03d", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
}

static void onReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t id, uint8_t *report,
                     CFIndex len) {
    (void)sender;
    (void)type;
    stamp();
    if (ctx) printf("  dev %ld", (long)ctx);
    printf("  report 0x%02x  %2ld bytes  ", id, (long)len);
    for (CFIndex i = 0; i < len; i++) printf("%02x", report[i]);
    if (result) printf("  (result 0x%x)", result);
    printf("\n");
    fflush(stdout);
    nReports++;
}

static void onRemoved(void *ctx, IOReturn result, void *sender) {
    (void)ctx;
    (void)result;
    (void)sender;
    stamp();
    printf("  device removed\n");
    fflush(stdout);
    stop = 1;
}

static const char *openError(IOReturn kr) {
    switch (kr) {
    case kIOReturnNotPermitted:
        return "not permitted: allow this terminal in System Settings > Privacy & Security > Input Monitoring";
    case kIOReturnExclusiveAccess: return "another process has seized the device";
    case kIOReturnNotPrivileged: return "not privileged";
    default: return "cannot open the device";
    }
}

static void usage(FILE *f) {
    fprintf(f, "usage: hidmon [-t SECONDS]\n"
               "  print the MX Brio HID report descriptor, then every input report until Ctrl-C\n"
               "  or for SECONDS. Read-only: never sends or requests reports.\n");
}

int main(int argc, char **argv) {
    double secs = 0;
    int opt;
    while ((opt = getopt(argc, argv, "t:h")) != -1) {
        if (opt == 't' && (secs = atof(optarg)) > 0) continue;
        usage(opt == 'h' ? stdout : stderr);
        return opt == 'h' ? 0 : 2;
    }
    if (optind < argc) { usage(stderr); return 2; }

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int vid = VID, pid = PID;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberIntType, &vid), np = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFMutableDictionaryRef m =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(m, CFSTR(kIOHIDVendorIDKey), nv);
    CFDictionarySetValue(m, CFSTR(kIOHIDProductIDKey), np);
    IOHIDManagerSetDeviceMatching(mgr, m);
    CFRelease(m);
    CFRelease(nv);
    CFRelease(np);

    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    CFIndex n = set ? CFSetGetCount(set) : 0;
    if (!n) { fprintf(stderr, "MX Brio HID interface not found\n"); return 1; }
    IOHIDDeviceRef *devs = calloc(n, sizeof *devs);
    int *opened = calloc(n, sizeof *opened);
    CFSetGetValues(set, (const void **)devs);

    int nOpen = 0;
    for (CFIndex i = 0; i < n; i++) {
        if (n > 1) printf("dev %ld: ", (long)i + 1);
        printDevice(devs[i]);
        IOReturn kr = IOHIDDeviceOpen(devs[i], kIOHIDOptionsTypeNone);
        if (kr) {
            fprintf(stderr, "open failed: 0x%08x, %s\n", kr, openError(kr));
            continue;
        }
        long size = numberProp(devs[i], CFSTR(kIOHIDMaxInputReportSizeKey));
        if (size <= 0) size = 64;
        IOHIDDeviceRegisterInputReportCallback(devs[i], malloc(size), size, onReport,
                                               n > 1 ? (void *)(i + 1) : NULL);
        IOHIDDeviceRegisterRemovalCallback(devs[i], onRemoved, NULL);
        IOHIDDeviceScheduleWithRunLoop(devs[i], CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        opened[i] = 1;
        nOpen++;
    }
    if (!nOpen) return 1;

    // Input Monitoring only gates keyboard-like devices; shown in case no reports arrive
    IOHIDAccessType acc = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    printf("Input Monitoring for this process: %s\n", acc == kIOHIDAccessTypeGranted  ? "granted"
                                                       : acc == kIOHIDAccessTypeDenied ? "denied"
                                                                                       : "not decided");

    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);
    printf("\nlistening for input reports");
    if (secs > 0) printf(" for %g s", secs);
    printf(", Ctrl-C to stop\n");
    fflush(stdout);

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    while (!stop) {
        double slice = 0.2;
        if (secs > 0) {
            double left = start + secs - CFAbsoluteTimeGetCurrent();
            if (left <= 0) break;
            if (left < slice) slice = left;
        }
        if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, slice, false) == kCFRunLoopRunFinished) usleep(slice * 1e6);
    }
    printf("%ld input reports in %.1f s\n", nReports, CFAbsoluteTimeGetCurrent() - start);

    for (CFIndex i = 0; i < n; i++)
        if (opened[i]) {
            IOHIDDeviceUnscheduleFromRunLoop(devs[i], CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            IOHIDDeviceClose(devs[i], kIOHIDOptionsTypeNone);
        }
    CFRelease(set);
    CFRelease(mgr);
    return 0;
}
