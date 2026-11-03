# brioctl for AI agents

This page is for an AI agent (Claude Code, Codex, Cursor, Raycast AI, or any assistant with a shell tool) that has to
look at a webcam picture and change the camera's settings for the user, for example "I look too dark" or "switch to the
narrow view". It needs no MCP server: `brioctl` is a normal command-line tool, and every step below is one shell
command. Claude Code and Codex can load the compact version of this page as a skill:
[skills/brioctl/SKILL.md](../skills/brioctl/SKILL.md).

```sh
brew install petrochen/tap/brioctl
```

`brioctl` works on macOS only. It reads and writes the camera's own settings; it does not process the video. A change
affects every app that uses the camera, such as Zoom, Meet, FaceTime and OBS.

## The loop: read, act, verify

Never guess what the camera has or what it is set to. Start with `brioctl auto --json` (add `--dry-run` to see the plan
first): it measures the face, changes `expcomp`, `hdr` and `warmth` in small steps and says what it did. Then verify
with a frame and tune by hand only what is still wrong. The loop by hand, in this order:

1. **Read.** `brioctl --json` prints one JSON object with the camera, its status (`video` on or off) and every setting
   with its value, default, range and whether an automatic mode is setting it right now. `brioctl describe --json` adds,
   for every control, `meaning`, `effect_on_image`, `settle_seconds` and `risky` (with a `risk` text).
   `brioctl capture --json -o frame.jpg` takes a picture and measures it (`--json` implies `--stats`).
2. **Decide.** Compare the numbers with the thresholds below and pick the smallest change that helps.
3. **Act.** `brioctl NAME VALUE [NAME VALUE ...]`, for example `brioctl expcomp 140 warmth 55`.
4. **Verify.** Wait for the camera to settle (see the table), then `brioctl get NAME` to confirm the value, and
   `brioctl capture --json` to confirm the picture. If it is not better, change one thing back and try again.

Change one or two settings at a time and measure after each step. `brioctl` reads the value back after every write and
exits with an error if the camera did not keep it.

## Controls

The values are those of the MX Brio. Other cameras have their own ranges and only the controls their descriptor
declares: take ranges from `brioctl describe --json`, not from this page. "Neutral" is the value that adds no effect.

### Logitech settings (MX Brio; some also on other Brio models)

| Name       | Values                  | Neutral / default | What it does                                                                |
| ---------- | ----------------------- | ----------------- | --------------------------------------------------------------------------- |
| `fov`      | `90`, `78`, `65`        | 90 is the default | Field of view in degrees. A digital crop: 65 is tighter, 90 is widest.      |
| `showmode` | `on`, `off`             | off               | Show Mode. Tilted down to the desk, the camera shows the desk and sets the field of view and zoom itself. |
| `hdr`      | `on`, `off`             | on                | HDR. This is the UVC backlight compensation. It lifts the shadows.          |
| `warmth`   | 0 to 100                | 50                | White balance warmth. Higher is warmer (more orange), lower is cooler (more blue). |
| `tint`     | 0 to 100                | 50                | Tint.                                                                       |
| `vibrance` | 0 to 255                | 128               | Vibrance.                                                                   |
| `expcomp`  | 0 to 255                | 128               | Exposure compensation. Higher is brighter, lower is darker.                 |
| `mic`      | `on`, `off`             | off (see below)   | Camera microphone. The camera restarts about 2 seconds after a change.      |

### Framing

| Name     | Values                | Neutral | What it does                                                                         |
| -------- | --------------------- | ------- | ------------------------------------------------------------------------------------ |
| `zoom`   | 100 to 400            | 100     | Digital zoom. 100 is 1x.                                                             |
| `pan`    | -20 to 20 (degrees)   | 0       | Moves the zoomed frame sideways. It has an effect only when zoomed in.               |
| `tilt`   | -20 to 20 (degrees)   | 0       | Moves the zoomed frame up and down. It has an effect only when zoomed in.            |
| `roll`   | degrees               | -       | Rotates the picture, where the camera has it.                                        |
| `smooth` | `on`, `off`           | off     | Zoom and pan glide to the new value in about 3 seconds (MX Brio).                    |

### Exposure and image (standard UVC)

| Name                  | Values                      | Default (MX Brio) | What it does                                                          |
| --------------------- | --------------------------- | ----------------- | --------------------------------------------------------------------- |
| `ae`                  | `auto`, `manual`            | auto              | Auto exposure. `exposure` and `gain` can be written only in `manual`. |
| `exposure`            | 3 to 2047                   | -                 | Exposure time in units of 100 microseconds (`ae manual` only).        |
| `gain`                | 0 to 255                    | -                 | Sensor gain (`ae manual` only).                                       |
| `priority`            | `fps`, `exposure`           | exposure          | What to keep in low light: the frame rate or the exposure time.       |
| `flicker`             | `50`, `60`                  | 60                | Anti-flicker: the frequency of the mains power in Hz. Set it to the local mains (50 in Europe); a wrong value shows bands in the picture. |
| `brightness`          | 0 to 255                    | 128               | Brightness.                                                           |
| `contrast`            | 0 to 255                    | 128               | Contrast.                                                             |
| `saturation`          | 0 to 255                    | 128               | Saturation. 0 is black and white.                                     |
| `sharpness`           | 0 to 255                    | 128               | Sharpness.                                                            |
| `awb`                 | `on`, `off`                 | on                | Automatic white balance.                                              |
| `wb`                  | 2800 to 7500 (kelvin)       | 5000              | White balance temperature (`awb off` only).                           |
| `af`                  | `on`, `off`                 | on                | Autofocus.                                                            |
| `focus`               | 0 to 255                    | -                 | Focus (`af off` only).                                                |
| `hueauto`, `hue`      | `on`, `off`; number         | -                 | Automatic hue; manual hue needs `hueauto off`.                        |
| `gamma`, `iris`       | number                      | -                 | Gamma; iris as f-number times 100.                                    |
| `backlight`           | number or `on`, `off`       | -                 | The same control as `hdr`, on cameras that have no HDR switch.        |
| `privacy`             | `on`, `off`                 | -                 | Privacy shutter. Many cameras only report it. Set it by hand only.    |
| `micgain`             | 0 to 1                      | -                 | Input volume of the camera microphone in macOS (MX Brio).             |

A `*` after a value in `brioctl` output, or `"auto": true` in the JSON, means an automatic mode (`ae`, `awb`, `af`) is
setting that value right now. To write such a value, switch the automatic mode off first: `brioctl ae manual exposure
150`. Manual modes stop adapting to the light, so tell the user and return to `auto` when done.

### Which control for which complaint

- **Too dark or too bright:** `expcomp` first (higher is brighter); `brightness` is the plain UVC alternative.
- **Window or lamp blown out behind the user, face dark:** `hdr on` lifts the shadows. If the highlights still clip,
  lower `expcomp`.
- **HDR makes the picture look wrong:** `hdr off` and compare; it is just a switch.
- **Too orange or too blue:** `warmth` (lower is cooler). For a fixed colour temperature use `awb off` and `wb`.
- **Too tight or too wide:** `fov` (90, 78 or 65). A smaller field of view is a tighter crop. For a finer step use
  `zoom`.
- **Face off-centre after zooming in:** `pan` and `tilt`.
- **Desk view:** `showmode on` and tilt the camera down; the camera then chooses the field of view and zoom itself.
- **Bands or flicker in the picture:** `flicker 50` or `flicker 60` to match the mains frequency.
- **Soft picture:** check `af`; see "Reading capture stats".

## Settle times

Changing a setting returns at once; the picture takes time to follow. Wait before you measure.

| Change                                                                   | Wait (`settle_seconds` in `describe`) |
| ------------------------------------------------------------------------ | ------------------------------------- |
| `zoom`, `pan` (MX Brio; they glide to the new value)                     | 3.5 s                                 |
| `expcomp`, `hdr`, `warmth`, `tint`, `wb`, `awb`, `ae`, `exposure`, `gain`, `priority` | 1 s                      |
| everything else (`fov`, `tilt`, `flicker`, `brightness`, `af`, ...)      | 0.3 s                                 |
| `mic`                                                                    | 0.3 s, but the camera restarts about 2 s after the change |

`brioctl describe --json` gives `settle_seconds` for every control of the connected camera; the numbers above are the
ones it reports for the MX Brio, and `describe` wins if they differ. In auto exposure the picture may need longer to
converge. `brioctl capture` waits `--wait SEC` (default 1) between opening the camera and the first frame, so for a
zoom change add your own `sleep`:

```sh
brioctl zoom 150 && sleep 3.5 && brioctl capture --json -o frame.jpg
```

## Reading capture stats

```sh
brioctl capture --json -o frame.jpg
```

It writes a JPEG (default `./capture.jpg`; with `--count N`, `capture-1.jpg`, `capture-2.jpg`, ...) and prints one line:
`{"files":[...],"frames":[{...}],"avg":{...}}`. `--json` always includes the statistics. Without `--json` and `--stats`
only the file names are printed. Options: `-o PATH`, `--count N` (1 to 100), `--interval SEC` (default 1), `--wait SEC`
(default 1, before the first frame), `--size WxH`, `--camera ID`.

`capture` only reads: it writes nothing to the camera's registers. It works while another app (a video call) is using the
camera. Without `--size` it keeps the format that other app chose, because changing the format would restart its stream;
`--size WxH` forces one, so do not pass it during a call. When no other app is streaming it uses the camera's largest
format up to 1920x1080.

It needs camera permission for the app you ran `brioctl` from (Terminal, an editor, the app that runs the agent). macOS
asks once. If it was refused, `capture` says how to change it (System Settings, Privacy & Security, Camera) and exits
with status 3. Relay that to the user; you cannot grant it yourself.

Each frame and `avg` also have `face` (`null` without a face; `--no-face` skips the detection): the same statistics
over the largest face box enlarged by 20%, plus `faces`, `face_fraction` (box area / frame area) and `face_center`
(`x`, `y`, 0 to 1 from the top left). Judge exposure and white balance on `face` when it is there: a window or a wall
skews the frame numbers. `face_fraction` below 0.04 means the face is small in the picture: `fov -` or `zoom +25`.

Per frame and in `avg`: `width`, `height`, `y_mean`, `y_p5`, `y_p95`, `y_stddev`, `clip_low_pct`, `clip_high_pct`,
`saturation_mean`, `rgb_mean` (`r`, `g`, `b`), `wb_bias` and `sharpness`.

| Stat                    | Meaning and thresholds                                                                           |
| ----------------------- | ------------------------------------------------------------------------------------------------ |
| `y_mean`                | Mean luma, 0 to 255. For a face in a normal room, roughly 90 to 140. Judge by clipping and by looking at the frame, not by this number alone. |
| `y_p5`, `y_p95`         | 5th and 95th percentile of brightness. A wide gap is a high-contrast scene (window behind the user). |
| `y_stddev`              | Contrast of the picture. Very low is flat or grey.                                               |
| `clip_low_pct`          | Percent of pixels with luma below 16 (crushed blacks). A high value means lost shadow detail: raise `expcomp` or enable `hdr`. |
| `clip_high_pct`         | Percent of pixels with luma above 235 (blown whites). Above 2 % the highlights are blown: lower `expcomp` or enable `hdr`. |
| `saturation_mean`       | Colour strength of the picture.                                                                  |
| `rgb_mean`              | Mean red, green and blue.                                                                        |
| `wb_bias`               | `r_mean / b_mean`, or `null` if blue is zero. About 1.0 is neutral. Above 1.15 the picture is too warm: lower `warmth`. Below 0.85 it is too cool: raise `warmth`. A scene with a lot of one colour (a red wall) skews this: judge it together with the image. |
| `sharpness`             | Variance of a 3x3 Laplacian of the luma, measured on the picture reduced to at most 640 pixels wide. Higher is sharper. It depends on the scene, so compare before and after on the same scene. A low value with `af` off means the focus may be wrong: check `af` and `focus`. |

The thresholds are rules of thumb. Look at the JPEG too if you can view images. Average over `--count 3 --interval 1` to
avoid a bad single frame, and note that auto exposure changes the numbers from frame to frame.

## `brioctl auto`

`brioctl auto --json` is the first step for "I look too dark/warm". Each step takes a frame, judges the face (the frame
when there is none, and then `note` says so) and changes at most `expcomp` +-12 (kept in 96-176), `hdr on`, and `warmth`
+-6 (kept in 30-70; `wb` +-300 K with `awb` off), then waits 1 s and measures again. It stops with `stopped`:
`in_range`, `no_improvement`, `max_steps` (default 4) or `dry_run`. It never touches `mic`, `privacy`, `fov` or `zoom`;
with `--framing` it may step `fov -` and `zoom +25` when `face_fraction` is below 0.04, otherwise it only puts that in
`recommendations`. `--dry-run` takes one frame and lists step 1 without writing; `--save` keeps the result; one
`brioctl undo` reverts the whole run. Read `before`, `after` and `applied`, check the picture, and correct by hand what
`recommendations` points at (framing, focus, a blown window with `hdr` already on). The rule table is in the README,
"Automatic adjustment".

## Worked example: "make me brighter but keep the window from blowing out"

The first set of numbers is a real MX Brio on a lit desk; the change that follows is a plausible one. Use the same
reasoning with your own numbers.

```text
$ brioctl capture --json -o before.jpg
{"files":["before.jpg"],"frames":[{"width":1920,"height":1080,"y_mean":95,"y_p5":17,"y_p95":174,"clip_low_pct":3.7,
 "clip_high_pct":0.0,"wb_bias":1.03,"sharpness":490,...}],"avg":{...}}
```

The picture is on the dark side (`y_mean` 95, 3.7 % of the pixels crushed to black) and nothing is blown out
(`clip_high_pct` 0; `y_p95` is 174, well under 235). There is room to brighten: raise `expcomp` a little and measure
again. If `clip_high_pct` climbs above 2 (a window behind the user starts to clip), step `expcomp` back and turn
`hdr on` instead, which lifts shadows without raising highlights.

```text
$ brioctl expcomp 145
$ sleep 1.5
$ brioctl get expcomp
145
$ brioctl capture --json -o after.jpg
```

Compare `y_mean`, `clip_low_pct` and `clip_high_pct` before and after, look at `after.jpg` if you can view images, and
tell the user what changed (`expcomp` 128 to 145) and why. `brioctl expcomp 128` is the neutral value if they want it
back.

## More than one camera

`brioctl list --json` lists every UVC camera with an index, serial number and location. `--camera ID` (index, serial
or location) may stand anywhere on the line and works with every command. Without it `brioctl` uses the only camera, or
the only one it fully knows; when it cannot choose it prints the list and exits with status 2. In a setup with an
external camera and a built-in one, always pass `--camera`.

## Keeping the settings

Settings live in the camera, and some are lost when the camera loses power or the video restarts.

- `brioctl save` writes the current settings to `~/.config/brioctl/settings`; `brioctl save meeting` writes the file
  `meeting`. `brioctl apply meeting` puts them back. `brioctl profiles --json` lists the saved files and the presets
  (`neutral`, `warmer`, `cooler`, `bw`, `standard`, `streaming`, `colorboost`).
- `brioctl watch` (run by a LaunchAgent) re-applies the saved file when the camera is connected and when video starts.
  It puts `~/.config/brioctl/settings` back, so a change that you make and do not save is undone at the next video
  start. After a change the user wants to keep, run `brioctl save` (when a `watch` agent is installed) or ask the user
  to use "Remember current settings" in the menu bar app.
- `brioctl expcomp +10 --save` changes a value and saves in one step (`--save` also works with `apply`, `defaults` and
  `undo`). Without it a change is gone after the next video start when `watch` runs.
- `save` does not store values that an automatic mode is setting.

Ask before you `save` over the user's existing file.

## Relative values, dry run and undo

- **Relative values.** `brioctl expcomp +10 warmth -5 zoom +25` adds to the current value and clamps to the camera's
  range, so you do not need to read first. It works on numbers only; `hdr +1` or `flicker -` exits with status 2 and
  writes nothing. `fov +` and `fov -` step to the next wider or narrower angle (65, 78, 90). On a signed control
  (`pan`, `tilt`, `roll`, `brightness`, `hue`) `-10` is the absolute value -10; write `+-10` to subtract.
- **`--dry-run`** (anywhere in the line) prints `NAME old -> new` or `NAME value unchanged` and writes nothing; with
  `--json` it prints `{"changes":[{"name","from","to","unchanged"}]}`. Use it before an `apply`, `defaults` or a
  large change you want to describe to the user. Values are checked as for a real write.
- **`brioctl undo`** puts back what the last changing command replaced (`set`, `apply`, `defaults`). It keeps the old
  values in `~/.config/brioctl/undo`, and the undo itself can be undone. Offer it when the user dislikes a change.
  `brioctl undo --dry-run` shows what it would do. Only the last command is kept.
- `brioctl install-skill` copies this skill into `~/.claude/skills/brioctl` and `~/.codex/skills/brioctl`.

## Errors and exit codes

Errors go to stderr as plain text, not JSON, with a non-zero exit status: **1** for an error (a setting the camera does
not have, a value out of range, a write the camera did not keep, a camera that cannot be read, `get` of an unreadable
value), **2** when the camera cannot be chosen or the command line is wrong, **3** when `capture` is denied camera
permission (macOS Privacy & Security, Camera). Check the exit status after every command. Do not retry a refused write with a different spelling:
read `brioctl describe --json` and use a name and value it lists. `brioctl` writes a number only inside the range the
camera reports.

Always pass `--json` when you parse output (`capture --json` includes the stats), and take values from `get NAME` or the JSON, never from the text layout.
The text output and the JSON contain the camera's serial number; do not paste either into a public place.

## Do not

- **Never run `brioctl factory-reset`.** It restarts the camera with factory settings. It needs `--yes` for a reason.
- **`describe` marks `mic` and `privacy` as `risky`** (`mic` restarts the camera about 2 s after a change and cuts the
  video; `privacy` may cover the lens). Never write a control with `"risky": true` without asking the user.
- **Do not change `mic` or `fov` during a live call without asking the user.** The camera microphone switch restarts
  the camera; `fov` is visible to everyone on the call. Both cut or change the picture other people see. `showmode`,
  `zoom` and `pan`/`tilt` are visible to others too: say what you are about to do.
- **Do not write a control that `brioctl describe` does not list for this camera.** Other cameras have only the
  controls they declare.
- Do not run `brioctl defaults` without asking: it overwrites the user's tuning (it leaves `mic`, `showmode` and
  `privacy` alone).
- Do not pass `--size` to `capture` while a call is running: it forces a format and restarts the other app's stream.
- Do not set `privacy` or leave `ae`, `awb` or `af` in manual mode without telling the user.
- Do not run `import optionsplus`, `dump` or `snapshot` unless the user asks; they are for migration and bug reports.

## Claude Desktop, ChatGPT and other apps without a shell

An app with no shell tool can run `brioctl` through a generic shell-command MCP server that you install and configure
yourself; `brioctl` itself has no MCP server.
