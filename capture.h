// capture: one or more frames of a camera as JPEG files, with picture statistics. The AVFoundation code lives in
// capture.m; nothing else in brioctl touches AVFoundation, so only `brioctl capture` can trigger the camera
// permission prompt of macOS.
#ifndef BRIOCTL_CAPTURE_H
#define BRIOCTL_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

#define CAPTURE_MAX_FRAMES 100
#define CAPTURE_PATH_MAX 1024

struct capture_opts {
    const char *path;     // JPEG file; with count > 1, "-N" goes before the extension
    int count;            // frames, 1 to CAPTURE_MAX_FRAMES
    double interval;      // seconds between frames
    double wait;          // seconds between opening the session and the first frame
    int width, height;    // requested size; 0 = the highest resolution up to 1920x1080
    int vid, pid;         // the camera, as brioctl list shows it
    unsigned loc;         // USB location id
};

// All values are plain numbers of the picture; wb_bias is r_mean / b_mean, negative if blue is zero.
struct capture_stats {
    int width, height;
    double y_mean, y_p5, y_p95, y_stddev;  // luma 0-255 (Rec. 601); stddev is the contrast
    double clip_low_pct, clip_high_pct;    // share of pixels with Y < 16 and Y > 235, in percent
    double saturation_mean;                // HSV S, 0-1
    double r_mean, g_mean, b_mean, wb_bias;
    double sharpness;                      // variance of a 3x3 Laplacian of Y, picture reduced to at most 640 wide
};

struct capture_result {
    int n;
    char path[CAPTURE_MAX_FRAMES][CAPTURE_PATH_MAX];
    struct capture_stats stats[CAPTURE_MAX_FRAMES];
    char error[256];
};

// 0 on success, 1 on an error (message in r->error), 3 if camera access is denied (message in r->error). Frames
// written before an error stay on disk and are counted in r->n.
int brioctl_capture(const struct capture_opts *o, struct capture_result *r);

// Statistics of a BGRA picture (stride in bytes).
void brioctl_picture_stats(const uint8_t *bgra, int w, int h, size_t stride, struct capture_stats *s);

#endif
