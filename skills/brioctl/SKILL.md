---
name: brioctl
description: Read and change webcam settings on macOS with the brioctl CLI (Logitech MX Brio and other UVC cameras) - use for requests about the webcam or camera picture, brightness, exposure, white balance, field of view (FOV), zoom, HDR, Show Mode, or "I look too dark/warm/blurry".
---

# brioctl: operate the webcam from the shell

`brioctl` reads and writes camera settings (macOS only). Install: `brew install petrochen/tap/brioctl`. Ranges differ
per camera: **`brioctl describe --json` is the source of truth** for names, ranges, defaults, settle times and risky
controls. Use only controls it lists.

## Loop: auto, verify, hand-tune

Start with `brioctl auto --json` (`--dry-run` first if unsure): it measures the face (two frames averaged, 2 s after
each change), changes `expcomp` +-10 / `hdr` / `warmth` +-4 in up to 4 steps (`expcomp` stays 96-176, `warmth` 30-70),
never `mic`, `privacy`, `fov` or `zoom` (`--framing` allows `fov -` / `zoom +25` for a small face), and returns
`before`, `after`, `applied`, `recommendations`, `stopped` (`in_range`, `no_improvement`, `oscillating`, `max_steps`,
`dry_run`). One `brioctl undo` reverts the run; `--save` keeps it. Then verify and fix by hand only what is left:

1. Read: `brioctl --json` (settings, `status.video.on`), `brioctl describe --json`, `brioctl capture --json -o f.jpg`.
2. Act with the smallest change the stats below call for: `brioctl hdr on expcomp 135`.
3. Wait for the camera to settle, then check `brioctl get NAME` and `brioctl capture --json` again.

Relative values skip the read: `brioctl expcomp +10 warmth -5` (numbers only, clamped to the range; `pan +-5` to subtract
on a signed control, `fov +` / `fov -` for the next wider / narrower angle). Preview with `--dry-run` (`--json` gives
`{"changes":[{"name","from","to","unchanged"}]}`); put back the last change with `brioctl undo`.

Change one or two things at a time. Use `--json` when parsing. With several cameras pass `--camera ID` (`brioctl list
--json`). Exit status: 1 error, 2 camera not chosen or bad command line, 3 capture permission denied (tell the user to
allow the terminal in System Settings, Privacy & Security, Camera). Errors are plain text on stderr.

## Controls (MX Brio values)

| Name                                                | Values              | Neutral  | Effect                                                      |
| --------------------------------------------------- | ------------------- | -------- | ----------------------------------------------------------- |
| `expcomp`                                           | 0-255               | 128      | Exposure compensation: higher brighter, lower darker        |
| `hdr`                                               | on, off             | on       | Lifts the shadows (UVC backlight compensation)              |
| `warmth`                                            | 0-100               | 50       | White balance, blue to warm: higher warmer, lower cooler    |
| `tint`                                              | 0-100               | 50       | Tint                                                        |
| `vibrance`                                          | 0-255               | 128      | Vibrance                                                    |
| `fov`                                               | 90, 78, 65          | 90       | Field of view in degrees, a digital crop (65 tightest)      |
| `zoom`                                              | 100-400             | 100      | Digital zoom, 100 = 1x                                      |
| `pan`, `tilt`                                       | -20..20 degrees     | 0        | Move the zoomed frame                                       |
| `showmode`                                          | on, off             | off      | Desk view when the camera is tilted down; sets fov and zoom |
| `ae`                                                | auto, manual        | auto     | `exposure` (3-2047, 100 us) and `gain` need `ae manual`     |
| `awb`, `wb`                                         | on/off; 2800-7500 K | on       | `wb` needs `awb off`                                        |
| `af`, `focus`                                       | on/off; 0-255       | on       | `focus` needs `af off`                                      |
| `brightness`, `contrast`, `saturation`, `sharpness` | 0-255               | 128      | Plain UVC image controls (`saturation 0` = black and white) |
| `flicker`                                           | 50, 60              | 60       | Mains frequency in Hz; match the country to avoid bands     |
| `priority`                                          | fps, exposure       | exposure | What to keep in low light                                   |
| `smooth`                                            | on, off             | off      | Zoom and pan glide in about 3 s                             |
| `mic`                                               | on, off             | off      | Camera microphone; camera restarts about 2 s after a change |

A value marked `*` (`"auto": true`) is set by an automatic mode: switch the mode off first, restore `auto` afterwards.

## Settle times (`settle_seconds` from `describe` wins)

MX Brio: `zoom`, `pan` 3.5 s; `expcomp`, `hdr`, `warmth`, `tint`, `wb`, `awb`, `ae`, `exposure`, `gain` 1 s (the picture
keeps adapting for about 2 s); the rest 0.3 s. `mic` restarts the camera about 2 s later. `capture` waits `--wait`
(default 1 s) before the first frame.

## Reading `capture --stats`

- `face` (in `capture --json`, `null` if none): the same numbers over the face box; judge on it when present.
- `y_mean` (0-255): roughly 90-140 for a face in a normal room; judge by clipping and by looking at the frame.
  Low with no clipping: raise `expcomp`. High: lower it.
- `clip_high_pct` (luma > 235) above 2: blown highlights. Lower `expcomp` or turn `hdr on`.
- `clip_low_pct` (luma < 16) high: crushed shadows. Raise `expcomp` or turn `hdr on`.
- `y_p95` minus `y_p5` large: window behind the user; prefer `hdr on` over raising `expcomp`.
- `wb_bias` (r_mean / b_mean): above 1.15 too warm, lower `warmth`; below 0.85 too cool, raise `warmth`. A coloured
  scene skews it.
- `sharpness` (Laplacian variance): compare before and after on the same scene. Low: check `af` and `focus`.
- Single frames are noisy: `--count 3 --interval 0.5` gives an `avg`. `capture` is read-only and works during a call;
  never pass `--size` then (it restarts the other app's stream).

## Persistence

`brioctl save NAME` / `brioctl apply NAME` store and restore settings (`brioctl profiles --json` lists files and
presets). A `watch` LaunchAgent puts `~/.config/brioctl/settings` back on connect and video start and undoes unsaved
changes, so add `--save` to a change the user wants to keep (`brioctl expcomp +10 --save`; ask before overwriting their
file), or point them to "Remember current settings" in the menu bar app.

## Do not

- Never run `factory-reset`. Do not run `defaults` without asking.
- Never toggle `mic` or change `fov` during a live call without asking the user: other people see it and the camera
  restarts (`mic`). Say before changing `zoom`, `pan`, `tilt`, `showmode`.
- `describe` marks `mic` and `privacy` as `risky`: never write a risky control without asking.
- Never write a control that `brioctl describe` does not list; do not retry a refused write with other spellings.
- Do not set `privacy` or leave `ae`/`awb`/`af` manual without telling the user. Do not paste the serial number.
