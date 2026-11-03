// brioctl capture: frames from a camera with AVFoundation. See capture.h.
// The camera is opened like any other app opens it, as one more client, so it works while a video call is running.
// With -DBRIOCTL_FAKE (the test build) no camera is touched: every frame is a synthetic picture.
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Vision/Vision.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "capture.h"

// --- statistics, plain C on the BGRA picture ------------------------------------------------------------------------

static int lumaOf(int r, int g, int b) { return (77 * r + 150 * g + 29 * b + 128) >> 8; }

void brioctl_picture_stats(const uint8_t *bgra, int w, int h, size_t stride, struct capture_stats *s) {
    memset(s, 0, sizeof *s);
    s->width = w;
    s->height = h;
    if (w <= 0 || h <= 0) return;
    double n = (double)w * h, sumY = 0, sumY2 = 0, sumR = 0, sumG = 0, sumB = 0, sumS = 0;
    long hist[256] = {0};
    for (int y = 0; y < h; y++) {
        const uint8_t *p = bgra + (size_t)y * stride;
        for (int x = 0; x < w; x++, p += 4) {
            int b = p[0], g = p[1], r = p[2], mx = r > g ? r : g, mn = r < g ? r : g;
            if (b > mx) mx = b;
            if (b < mn) mn = b;
            int Y = lumaOf(r, g, b);
            hist[Y]++;
            sumY += Y;
            sumY2 += (double)Y * Y;
            sumR += r;
            sumG += g;
            sumB += b;
            if (mx) sumS += (double)(mx - mn) / mx;
        }
    }
    s->y_mean = sumY / n;
    double var = sumY2 / n - s->y_mean * s->y_mean;
    s->y_stddev = var > 0 ? sqrt(var) : 0;
    long low = 0, high = 0, cum = 0;
    int got5 = 0, got95 = 0;
    for (int v = 0; v < 256; v++) {
        if (v < 16) low += hist[v];
        if (v > 235) high += hist[v];
        cum += hist[v];
        if (!got5 && cum >= 0.05 * n) s->y_p5 = v, got5 = 1;
        if (!got95 && cum >= 0.95 * n) s->y_p95 = v, got95 = 1;
    }
    s->clip_low_pct = 100.0 * low / n;
    s->clip_high_pct = 100.0 * high / n;
    s->saturation_mean = sumS / n;
    s->r_mean = sumR / n;
    s->g_mean = sumG / n;
    s->b_mean = sumB / n;
    s->wb_bias = s->b_mean > 0 ? s->r_mean / s->b_mean : -1;

    // Sharpness: average the luma in f x f blocks so the picture is at most 640 wide, then the variance of the
    // 3x3 Laplacian (4-neighbour kernel) over the inner pixels.
    int f = (w + 639) / 640, sw = w / f, sh = h / f;
    if (sw < 3 || sh < 3) return;
    float *small = malloc((size_t)sw * sh * sizeof *small);
    if (!small) return;
    for (int y = 0; y < sh; y++)
        for (int x = 0; x < sw; x++) {
            long acc = 0;
            for (int dy = 0; dy < f; dy++) {
                const uint8_t *p = bgra + (size_t)(y * f + dy) * stride + (size_t)x * f * 4;
                for (int dx = 0; dx < f; dx++, p += 4) acc += lumaOf(p[2], p[1], p[0]);
            }
            small[y * sw + x] = (float)acc / (f * f);
        }
    double sum = 0, sum2 = 0;
    long cnt = 0;
    for (int y = 1; y < sh - 1; y++)
        for (int x = 1; x < sw - 1; x++) {
            const float *c = small + y * sw + x;
            double l = c[-1] + c[1] + c[-sw] + c[sw] - 4.0 * c[0];
            sum += l;
            sum2 += l * l;
            cnt++;
        }
    double m = sum / cnt, v = sum2 / cnt - m * m;
    s->sharpness = v > 0 ? v : 0;
    free(small);
}

// --- file names -----------------------------------------------------------------------------------------------------

// count 1: the path as given. More: "-N" before the extension of the last path component, or at the end without one.
static void frameName(const char *path, int i, int count, char *out, size_t n) {
    if (count <= 1) { snprintf(out, n, "%s", path); return; }
    const char *slash = strrchr(path, '/'), *dot = strrchr(path, '.');
    if (!dot || (slash && dot < slash) || dot == (slash ? slash + 1 : path)) snprintf(out, n, "%s-%d", path, i + 1);
    else snprintf(out, n, "%.*s-%d%s", (int)(dot - path), path, i + 1, dot);
}

// --- JPEG -----------------------------------------------------------------------------------------------------------

static int writeJPEG(const uint8_t *bgra, int w, int h, size_t stride, const char *path, char *err, size_t en) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate((void *)bgra, w, h, 8, stride, cs,
                                             (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    if (!img) { snprintf(err, en, "cannot build the picture for %s", path); return -1; }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dst = url ? CGImageDestinationCreateWithURL(url, CFSTR("public.jpeg"), 1, NULL) : NULL;
    int ok = 0;
    if (dst) {
        double q = 0.9;
        CFNumberRef qn = CFNumberCreate(NULL, kCFNumberDoubleType, &q);
        CFStringRef keys[] = {kCGImageDestinationLossyCompressionQuality};
        CFTypeRef vals[] = {qn};
        CFDictionaryRef opt = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 1,
                                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CGImageDestinationAddImage(dst, img, opt);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(opt);
        CFRelease(qn);
        CFRelease(dst);
    }
    if (url) CFRelease(url);
    CGImageRelease(img);
    if (!ok) { snprintf(err, en, "cannot write %s", path); return -1; }
    return 0;
}

// --- faces ----------------------------------------------------------------------------------------------------------

// Statistics of the face box (pixels, from the top left) enlarged by 20%.
static void faceRegion(const uint8_t *bgra, int w, int h, size_t stride, double bx, double by, double bw, double bh,
                       int faces, struct capture_face *f) {
    memset(f, 0, sizeof *f);
    if (faces <= 0 || bw <= 0 || bh <= 0) return;
    double x0 = bx - 0.1 * bw, y0 = by - 0.1 * bh, x1 = bx + 1.1 * bw, y1 = by + 1.1 * bh;
    int ix0 = x0 < 0 ? 0 : (int)x0, iy0 = y0 < 0 ? 0 : (int)y0, ix1 = x1 > w ? w : (int)x1, iy1 = y1 > h ? h : (int)y1;
    if (ix1 - ix0 < 2 || iy1 - iy0 < 2) return;
    f->faces = faces;
    f->fraction = bw * bh / ((double)w * h);
    f->cx = (bx + bw / 2) / w;
    f->cy = (by + bh / 2) / h;
    brioctl_picture_stats(bgra + (size_t)iy0 * stride + (size_t)ix0 * 4, ix1 - ix0, iy1 - iy0, stride, &f->stats);
}

#ifdef BRIOCTL_FAKE
// The fake picture has one face, always in the same place (BRIOCTL_FAKE_CAPTURE_NOFACE=1: none;
// BRIOCTL_FAKE_CAPTURE_SMALLFACE=1: a small one, 1% of the frame).
static void fakeFaceBox(int w, int h, double *bx, double *by, double *bw, double *bh) {
    if (getenv("BRIOCTL_FAKE_CAPTURE_SMALLFACE")) *bx = w * 9 / 20, *by = h * 9 / 20, *bw = w / 10, *bh = h / 10;
    else *bx = w * 2 / 5, *by = h * 3 / 10, *bw = w / 5, *bh = h * 2 / 5;
}

static int findFace(const uint8_t *bgra, int w, int h, size_t stride, double *bx, double *by, double *bw, double *bh) {
    (void)bgra, (void)stride;  // Vision is never called on the fake picture
    if (getenv("BRIOCTL_FAKE_CAPTURE_NOFACE")) return 0;
    fakeFaceBox(w, h, bx, by, bw, bh);
    return 1;
}
#else
// Vision on the picture reduced to at most 640 wide (nearest pixel: enough to find a face). The largest face, as a
// box in pixels of the full picture; returns the number of faces.
static int findFace(const uint8_t *bgra, int w, int h, size_t stride, double *bx, double *by, double *bw, double *bh) {
    int f = (w + 639) / 640, sw = w / f, sh = h / f;
    if (sw < 16 || sh < 16) return 0;
    uint8_t *small = malloc((size_t)sw * sh * 4);
    if (!small) return 0;
    for (int y = 0; y < sh; y++)
        for (int x = 0; x < sw; x++)
            memcpy(small + ((size_t)y * sw + x) * 4, bgra + (size_t)(y * f + f / 2) * stride + (size_t)(x * f + f / 2) * 4, 4);
    int n = 0;
    @autoreleasepool {
        CVPixelBufferRef pb = NULL;
        if (CVPixelBufferCreateWithBytes(NULL, sw, sh, kCVPixelFormatType_32BGRA, small, (size_t)sw * 4, NULL, NULL,
                                         NULL, &pb) == kCVReturnSuccess) {
            VNDetectFaceRectanglesRequest *req = [[VNDetectFaceRectanglesRequest alloc] init];
            VNImageRequestHandler *hd = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
            NSError *e = nil;
            if ([hd performRequests:@[ req ] error:&e]) {
                double best = 0;
                for (VNFaceObservation *o in req.results) {  // normalised, origin at the bottom left
                    CGRect r = o.boundingBox;
                    n++;
                    if (r.size.width * r.size.height > best) {
                        best = r.size.width * r.size.height;
                        *bx = r.origin.x * w, *bw = r.size.width * w;
                        *bh = r.size.height * h, *by = (1 - r.origin.y - r.size.height) * h;
                    }
                }
            }
            CVPixelBufferRelease(pb);
        }
    }
    free(small);
    return n;
}
#endif

// --- the frames -----------------------------------------------------------------------------------------------------

static int saveFrame(const uint8_t *bgra, int w, int h, size_t stride, struct capture_result *r, const char *path,
                     const struct capture_opts *o) {
    snprintf(r->path[r->n], CAPTURE_PATH_MAX, "%s", path);
    if (writeJPEG(bgra, w, h, stride, path, r->error, sizeof r->error)) return -1;
    brioctl_picture_stats(bgra, w, h, stride, &r->stats[r->n]);
    double bx = 0, by = 0, bw = 0, bh = 0;
    int faces = o->no_face ? 0 : findFace(bgra, w, h, stride, &bx, &by, &bw, &bh);
    faceRegion(bgra, w, h, stride, bx, by, bw, bh, faces, &r->face[r->n]);
    r->n++;
    return 0;
}

#ifdef BRIOCTL_FAKE

// A gradient with a bright square and a face (a flat block), the same every time: red grows to the right, green
// downwards, blue is 64. With o->have_state the picture follows the camera: the face gets brighter by 2% per step of
// expcomp above 128 (the rest by 0.5%) and redder by 1% per step of warmth above 50 (the rest by 0.3%).
// BRIOCTL_FAKE_CAPTURE_BRIGHT=1 adds a blown-out window on the right (200 instead of 255 when hdr is on).
int brioctl_capture(const struct capture_opts *o, struct capture_result *r) {
    memset(r, 0, sizeof *r);
    if (getenv("BRIOCTL_FAKE_CAPTURE_DENIED")) {
        snprintf(r->error, sizeof r->error, "camera access is denied");
        return 3;
    }
    int w = o->width ? o->width : 640, h = o->height ? o->height : 360;
    size_t stride = (size_t)w * 4;
    uint8_t *px = malloc(stride * h);
    if (!px) { snprintf(r->error, sizeof r->error, "out of memory"); return 1; }
    double ef = 1, bf = 1, wd = 0;
    if (o->have_state) {
        ef = 1 + (o->expcomp - 128) * 0.02, bf = 1 + (o->expcomp - 128) * 0.005, wd = (o->warmth - 50) * 0.01;
        if (ef < 0.1) ef = 0.1;
        if (bf < 0.1) bf = 0.1;
    }
    int window = getenv("BRIOCTL_FAKE_CAPTURE_BRIGHT") ? (o->have_state && o->hdr ? 200 : 255) : 0;
    double fx, fy, fw, fh;
    fakeFaceBox(w, h, &fx, &fy, &fw, &fh);
#define CLAMP255(v) ((v) > 255 ? 255 : (v) < 0 ? 0 : (uint8_t)(v))
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            uint8_t *p = px + y * stride + x * 4;
            int sq = x >= w / 8 && x < w / 4 && y >= h / 8 && y < h / 4;
            if (x >= fx && x < fx + fw && y >= fy && y < fy + fh) {
                p[0] = CLAMP255(88 * ef * (1 - wd));
                p[1] = CLAMP255(72 * ef);
                p[2] = CLAMP255(80 * ef * (1 + wd));
            } else if (sq) {
                p[0] = p[1] = p[2] = 255;
            } else if (window && x >= w * 3 / 4) {
                p[0] = p[1] = p[2] = (uint8_t)window;
            } else {
                double b = 64 * bf * (1 - 0.3 * wd), g = (y * 255 / (h > 1 ? h - 1 : 1)) * bf,
                       rr = (x * 255 / (w > 1 ? w - 1 : 1)) * bf * (1 + 0.3 * wd);
                p[0] = CLAMP255(b), p[1] = CLAMP255(g), p[2] = CLAMP255(rr);
            }
            p[3] = 255;
        }
    int rc = 0;
    for (int i = 0; i < o->count && !rc; i++) {  // no waiting: the tests must not sleep
        char name[CAPTURE_PATH_MAX];
        frameName(o->path, i, o->count, name, sizeof name);
        rc = saveFrame(px, w, h, stride, r, name, o) ? 1 : 0;
    }
    free(px);
    return rc;
}

#else

@interface BrioSink : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic) dispatch_semaphore_t got;
@property(nonatomic) CVPixelBufferRef frame;  // retained, set while `want`
@property(nonatomic) BOOL want;
@end

@implementation BrioSink
- (instancetype)init {
    if ((self = [super init])) _got = dispatch_semaphore_create(0);
    return self;
}
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sb
           fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    @synchronized(self) {
        if (!self.want) return;
        self.want = NO;
        self.frame = CVPixelBufferRetain(pb);
    }
    dispatch_semaphore_signal(self.got);
}
@end

// The AVCaptureDevice of a USB camera. Its uniqueID is "0x" + location id + vendor id + product id in hex, with the
// vendor id not padded ("0x1110000046d0944" for location 0x1110000, 046d:0944); that is what brioctl list shows, so
// two identical cameras stay apart. The model id ("UVC Camera VendorID_1133 ProductID_2372") is the fallback if the
// uniqueID has another shape, and only when it names exactly one camera.
static AVCaptureDevice *findDevice(const struct capture_opts *o) {
    NSMutableArray *types = [NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [types addObject:AVCaptureDeviceTypeExternalUnknown];
#pragma clang diagnostic pop
    if (@available(macOS 14.0, *)) [types addObject:AVCaptureDeviceTypeExternal];
    NSArray<AVCaptureDevice *> *all =
        [[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                                mediaType:AVMediaTypeVideo
                                                                 position:AVCaptureDevicePositionUnspecified] devices];
    NSString *want = [NSString stringWithFormat:@"0x%x%x%04x", o->loc, o->vid, o->pid];
    for (AVCaptureDevice *d in all)
        if ([d.uniqueID caseInsensitiveCompare:want] == NSOrderedSame) return d;
    NSString *model = [NSString stringWithFormat:@"VendorID_%d ProductID_%d", o->vid, o->pid];
    AVCaptureDevice *only = nil;
    int n = 0;
    for (AVCaptureDevice *d in all)
        if ([d.modelID containsString:model]) only = d, n++;
    return n == 1 ? only : nil;
}

static AVCaptureDeviceFormat *pickFormat(AVCaptureDevice *d, int w, int h) {
    AVCaptureDeviceFormat *best = nil;
    double bestFps = 0;
    long bestArea = 0;
    for (AVCaptureDeviceFormat *f in d.formats) {
        CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        long area = (long)dim.width * dim.height;
        if (w ? !(dim.width == w && dim.height == h) : (dim.width > 1920 || dim.height > 1080)) continue;
        double fps = 0;
        for (AVFrameRateRange *rr in f.videoSupportedFrameRateRanges)
            if (rr.maxFrameRate > fps) fps = rr.maxFrameRate;
        if (!best || area > bestArea || (area == bestArea && fps > bestFps)) best = f, bestArea = area, bestFps = fps;
    }
    return best;
}

static void fail(struct capture_result *r, const char *fmt, const char *arg) {
    snprintf(r->error, sizeof r->error, fmt, arg ? arg : "");
}

int brioctl_capture(const struct capture_opts *o, struct capture_result *r) {
    @autoreleasepool {
        memset(r, 0, sizeof *r);
        AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (st == AVAuthorizationStatusNotDetermined) {  // macOS asks the user; the terminal app gets the permission
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL granted) {
                                         (void)granted;
                                         dispatch_semaphore_signal(sem);
                                     }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        }
        if (st != AVAuthorizationStatusAuthorized) {
            fail(r, "camera access is %s: allow your terminal app in System Settings > Privacy & Security > Camera",
                 st == AVAuthorizationStatusRestricted ? "restricted" : "denied");
            return 3;
        }
        AVCaptureDevice *dev = findDevice(o);
        if (!dev) { fail(r, "macOS has no video device for this camera (try unplugging it and plugging it in)", NULL); return 1; }

        // A format is only changed when a size was asked for, or when nobody else uses the camera: the format is
        // shared, and changing it restarts the stream of another app.
        AVCaptureDeviceFormat *fmt = pickFormat(dev, o->width, o->height);
        if (o->width && !fmt) {
            NSMutableOrderedSet *sizes = [NSMutableOrderedSet orderedSet];
            for (AVCaptureDeviceFormat *f in dev.formats) {
                CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
                [sizes addObject:[NSString stringWithFormat:@"%dx%d", d.width, d.height]];
            }
            snprintf(r->error, sizeof r->error, "no %dx%d format; the camera offers %s", o->width, o->height,
                     [[sizes.array componentsJoinedByString:@" "] UTF8String]);
            return 1;
        }
        BOOL change = fmt && fmt != dev.activeFormat && (o->width || !dev.isInUseByAnotherApplication);

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        NSError *e = nil;
        AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&e];
        if (!in) { fail(r, "cannot open the camera: %s", e.localizedDescription.UTF8String); return 1; }
        AVCaptureVideoDataOutput *out = [[AVCaptureVideoDataOutput alloc] init];
        out.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
        out.alwaysDiscardsLateVideoFrames = YES;
        BrioSink *sink = [[BrioSink alloc] init];
        dispatch_queue_t q = dispatch_queue_create("brioctl.capture", DISPATCH_QUEUE_SERIAL);
        [out setSampleBufferDelegate:sink queue:q];
        [session beginConfiguration];
        if (![session canAddInput:in] || ![session canAddOutput:out]) {
            [session commitConfiguration];
            fail(r, "cannot start a capture session on this camera", NULL);
            return 1;
        }
        [session addInput:in];
        [session addOutput:out];
        [session commitConfiguration];
        if (change) {
            if ([dev lockForConfiguration:&e]) {
                dev.activeFormat = fmt;
                [dev unlockForConfiguration];
            } else if (o->width) {
                fail(r, "cannot change the camera's format: %s", e.localizedDescription.UTF8String);
                return 1;
            }
        }
        // Setting activeFormat on a device that is in a session makes the session follow it (input priority).
        [session startRunning];
        int rc = 0;
        [NSThread sleepForTimeInterval:o->wait];
        for (int i = 0; i < o->count && !rc; i++) {
            if (i) [NSThread sleepForTimeInterval:o->interval];
            @synchronized(sink) { sink.want = YES; }
            if (dispatch_semaphore_wait(sink.got, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
                @synchronized(sink) { sink.want = NO; }
                fail(r, "no frame from the camera within 10 seconds", NULL);
                rc = 1;
                break;
            }
            CVPixelBufferRef pb;
            @synchronized(sink) { pb = sink.frame; sink.frame = NULL; }
            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            char name[CAPTURE_PATH_MAX];
            frameName(o->path, i, o->count, name, sizeof name);
            rc = saveFrame(CVPixelBufferGetBaseAddress(pb), (int)CVPixelBufferGetWidth(pb),
                           (int)CVPixelBufferGetHeight(pb), CVPixelBufferGetBytesPerRow(pb), r, name, o) ? 1 : 0;
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferRelease(pb);
        }
        [session stopRunning];
        return rc;
    }
}

#endif
