---
name: brioctl
description: Read and change webcam settings on macOS with the brioctl CLI (Logitech MX Brio and other UVC cameras) - use for requests about the webcam or camera picture, brightness, exposure, white balance, field of view (FOV), zoom, HDR, Show Mode, or "I look too dark/warm/blurry".
---

# brioctl: operate the webcam from the shell

`brioctl` reads and writes camera settings (macOS only). Install: `brew install petrochen/tap/brioctl`. Full guide:
`docs/agents.md` in the brioctl repo. Ranges differ per camera: **`brioctl describe --json` is the source of truth** for
names, ranges, defaults, settle times and risky controls. Use only controls it lists.

## Loop: read, act, verify

1. Read: `brioctl --json` (settings, `status.video.on`), `brioctl describe --json`, and
   `brioctl capture --json -o frame.jpg` (measure the picture; `--json` implies `--stats`).
2. Decide the smallest change from the stats below.
3. Act: `brioctl NAME VALUE [NAME VALUE ...]`, e.g. `brioctl hdr on expcomp 135`.
4. Wait for the camera to settle, then check: `brioctl get NAME` and `brioctl capture --json` again.

Change one or two things at a time. Always use `--json` when parsing. With several cameras pass `--camera ID`
(`brioctl list --json`). Check the exit status: 1 error, 2 camera not chosen or bad command line, 3 capture permission
denied (tell the user to allow the terminal in System Settings, Privacy & Security, Camera). Errors are plain text on
stderr.

## Controls (MX Brio values)

| Name         | Values                | Neutral | Effect                                                            |
| ------------ | --------------------- | ------- | ----------------------------------------------------------------- |
| `expcomp`    | 0-255                 | 128     | Exposure compensation: higher brighter, lower darker              |
| `hdr`        | on, off               | on      | Lifts the shadows (UVC backlight compensation)                    |
| `warmth`     | 0-100                 | 50      | White balance, blue to warm: higher warmer, lower cooler          |
| `tint`       | 0-100                 | 50      | Tint                                                              |
| `vibrance`   | 0-255                 | 128     | Vibrance                                                          |
| `fov`        | 90, 78, 65            | 90      | Field of view in degrees, a digital crop (65 tightest)            |
| `zoom`       | 100-400               | 100     | Digital zoom, 100 = 1x                                            |
| `pan`, `tilt`| -20..20 degrees       | 0       | Move the zoomed frame                                             |
| `showmode`   | on, off               | off     | Desk view when the camera is tilted down; sets fov and zoom       |
| `ae`         | auto, manual          | auto    | `exposure` (3-2047, 100 us) and `gain` need `ae manual`           |
| `awb`, `wb`  | on/off; 2800-7500 K   | on      | `wb` needs `awb off`                                              |
| `af`, `focus`| on/off; 0-255         | on      | `focus` needs `af off`                                            |
| `brightness`, `contrast`, `saturation`, `sharpness` | 0-255 | 128 | Plain UVC image controls (`saturation 0` = black and white) |
| `flicker`    | 50, 60                | 60      | Mains frequency in Hz; match the country to avoid bands           |
| `priority`   | fps, exposure         | exposure| What to keep in low light                                         |
| `smooth`     | on, off               | off     | Zoom and pan glide in about 3 s                                   |
| `mic`        | on, off               | off     | Camera microphone; camera restarts about 2 s after a change       |

A value marked `*` (or `"auto": true`) is being set by an automatic mode; switch the mode off before writing it, and
restore `auto` afterwards.

## Settle times (`settle_seconds` from `describe`, MX Brio)

`zoom`, `pan`: 3.5 s. `expcomp`, `hdr`, `warmth`, `tint`, `wb`, `awb`, `ae`, `exposure`, `gain`, `priority`: 1 s.
Everything else: 0.3 s. `mic` also restarts the camera about 2 s after a change. `describe` wins if it differs.
`capture` waits `--wait` (default 1 s) before the first frame; for zoom/pan add `sleep 3.5`.

## Reading `capture --stats`

- `y_mean` (0-255): roughly 90-140 for a face in a normal room; judge by clipping and by looking at the frame.
  Low with no clipping: raise `expcomp`. High: lower it.
- `clip_high_pct` (luma > 235) above 2: blown highlights. Lower `expcomp` or turn `hdr on`.
- `clip_low_pct` (luma < 16) high: crushed shadows. Raise `expcomp` or turn `hdr on`.
- `y_p95` minus `y_p5` large: high-contrast scene (window behind the user); prefer `hdr on` over raising `expcomp`.
- `wb_bias` (r_mean / b_mean): above 1.15 too warm, lower `warmth`; below 0.85 too cool, raise `warmth`. A coloured
  scene skews it.
- `sharpness` (Laplacian variance): compare before and after on the same scene. Low: check `af` and `focus`.
- Real MX Brio on a lit desk: `y_mean` ~95, `y_p5` 17, `y_p95` 174, `clip_low_pct` 3.7, `clip_high_pct` 0, `wb_bias` 1.03,
  `sharpness` ~480-510: dark-ish, nothing blown, room to raise `expcomp`.
- `--count 3 --interval 1` gives an `avg` if frames fluctuate. `capture` is read-only and works while another app
  streams; without `--size` it keeps that app's format, so never pass `--size` during a call.

## Persistence

`brioctl save NAME` / `brioctl apply NAME` store and restore settings (`brioctl profiles --json` lists files and
presets). A `watch` LaunchAgent puts `~/.config/brioctl/settings` back on connect and video start and undoes unsaved
changes, so run `brioctl save` after a change the user wants to keep (ask before overwriting their file), or point them
to "Remember current settings" in the menu bar app.

## Do not

- Never run `factory-reset`. Do not run `defaults` without asking.
- Never toggle `mic` or change `fov` during a live call without asking the user: other people see it and the camera
  restarts (`mic`). Say before changing `zoom`, `pan`, `tilt`, `showmode`.
- `describe` marks `mic` and `privacy` as `risky`: never write a risky control without asking.
- Never write a control that `brioctl describe` does not list; do not retry a refused write with other spellings.
- Do not set `privacy`, or leave `ae`/`awb`/`af` manual, without telling the user.
- The output contains the camera's serial number: do not paste it publicly.
