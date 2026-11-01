# brioctl

brioctl is a command-line tool for macOS that reads and changes the settings of UVC webcams, and of the Logitech MX Brio
(USB `046d:0944`) in particular, without the manufacturer's desktop software. For the MX Brio it covers the field of
view, Show Mode, HDR, white balance warmth, tint, vibrance, zoom, pan and tilt, exposure, focus and the camera
microphone. For any other UVC camera it offers the standard controls the camera declares. It can re-apply your
settings every time the camera is connected or video starts. It is one C file that talks to the camera through IOKit.
It needs no driver, no root and no third-party library.

Not affiliated with or endorsed by Logitech. See [Disclaimer](#disclaimer).

## Features

- Any UVC camera: `brioctl list` shows them, `--camera` picks one, and `show` lists the standard controls the camera
  declares (exposure, gain, white balance, focus, brightness, contrast, hue, gamma, sharpness, zoom, pan, tilt, roll,
  iris, privacy and more) with the camera's own ranges.
- Settings that Logitech's apps control through the camera: field of view (90, 78 or 65 degrees), Show Mode, HDR,
  white balance warmth, tint, vibrance, exposure compensation, camera microphone on and off.
- Digital zoom, pan and tilt, and smooth zoom: zoom and pan glide to the new value in about 3 seconds.
- All standard UVC exposure and image controls: auto exposure, exposure time, gain, anti-flicker, brightness,
  contrast, saturation, sharpness, auto white balance, white balance temperature, autofocus, focus, low-light priority.
- The macOS input volume of the camera microphone (`micgain`).
- Presets, including `colorboost`, and named settings files: `save` and `apply`.
- `import optionsplus` turns the settings Logi Options+ saved for the camera into a settings file, without a camera.
- `watch`, a LaunchAgent that re-applies your settings when the camera is connected and when video starts.
- A [menu bar app](#menu-bar-app) with the same controls, global hotkeys and a `brioctl://` URL scheme for Shortcuts.
- `--json` output and `get NAME` for scripts.
- `snapshot` for bug reports, `defaults` to go back to the camera's default values, and `factory-reset` to restart the
  camera with factory settings and then restore yours.
- A read-only `dump` of every unit and extension control the camera has.

## Menu bar app

`brioctl.app` puts the controls in the menu bar. Click the camera icon and a small window shows the settings of the
chosen camera, grouped as in `brioctl show` (Logitech, Framing, Exposure and image, Found in the firmware). Each one
has the control its kind and range call for: a switch, a segmented control, a menu or a slider. A line under the camera
name says whether video is on and whether the camera shows the desk. With several cameras a menu at the top picks one.
The Presets menu applies a preset or a saved file, and "Save current as..." stores the camera's settings under a name.

The app contains the command-line tool (`brioctl.app/Contents/Resources/brioctl`) and does everything through it: it
reads `--json` and changes settings with the commands you would type. It never opens the camera itself, so it needs no
camera permission. It needs macOS 13 or later, on Apple Silicon or Intel, and has no Dock icon.

Install it with Homebrew:

```sh
brew install --cask petrochen/tap/brioctl-app
```

Or download `brioctl-app-1.1.0.zip` from the GitHub releases page, unzip it and move `brioctl.app` to `/Applications`.
The app is ad-hoc signed and not notarized, so macOS refuses the first launch of a copy that a browser downloaded. Open
System Settings, Privacy & Security, and choose "Open Anyway" for brioctl, or remove the quarantine attribute before
you start it:

```sh
xattr -dr com.apple.quarantine /Applications/brioctl.app
```

The Homebrew cask removes the attribute for you. To build the app yourself, run `make app` (it needs Swift, which comes
with Xcode and the Command Line Tools) and open `app/build/brioctl.app`. See [app/README.md](app/README.md).

The gear icon opens the app's settings:

- **Re-apply settings automatically** saves the current settings and installs the LaunchAgent
  `com.github.petrochen.brioctl`, which runs `brioctl watch` with the tool inside the app (see
  [Apply settings automatically](#apply-settings-automatically)). An agent that `make agent` or Homebrew
  (`homebrew.mxcl.brioctl`) installed is left alone, and the app works with it.
- **Launch at login** writes `~/Library/LaunchAgents/com.github.petrochen.brioctl.app.plist`, which opens the app when
  you log in. It works from the packaged `brioctl.app` only.
- **Global hotkeys** are off until you switch them on. They need no Accessibility permission, act on the chosen camera
  and do nothing when the camera lacks the control. If another app already uses a key, the settings page says so.

  | Keys | Action     |
  | ---- | ---------- |
  | ⌃⌥⌘1 | `fov 90`   |
  | ⌃⌥⌘2 | `fov 78`   |
  | ⌃⌥⌘3 | `fov 65`   |
  | ⌃⌥⌘0 | `zoom 100` |
  | ⌃⌥⌘= | `zoom` +25 |
  | ⌃⌥⌘- | `zoom` −25 |

**Changes made in the app are saved for auto-apply.** `brioctl watch` puts `~/.config/brioctl/settings` back when the
camera connects and when video starts, which would undo a change made in the app. So while an agent with the label
`com.github.petrochen.brioctl` or `homebrew.mxcl.brioctl` is installed, whoever installed it, the app runs
`brioctl [--camera ID] save` about a second after its last change: a slider, a menu, a preset, a hotkey or a URL. A
burst of slider moves gives one save, and the window shows "Saved for auto-apply" when it is done. If the agent follows
another camera than the chosen one, the app leaves the file alone. With no agent installed the app saves nothing on its
own; "Remember current settings" in the settings writes the file once.

**URL scheme.** The app handles `brioctl://` URLs, for the Open URLs action in Shortcuts and for scripts. They start the
app when it is not running:

```sh
open "brioctl://set?fov=78&zoom=115"    # change settings of the chosen camera
open "brioctl://apply?name=warmer"      # apply a preset or a saved file
open "brioctl://camera?id=2"            # choose the camera: an index, a serial number or a location
```

A URL can only change settings, apply a preset or a saved file, and choose the camera. Names the camera does not have
are ignored, and so are values that are not plain words or numbers.

## Requirements

- macOS 12 or later, on Apple Silicon or Intel. The menu bar app needs macOS 13.
- A UVC camera. Full support is for the Logitech MX Brio (`046d:0944`), tested with firmware 1.1.394. See
  [Cameras](#cameras) for the others.
- To build from source: Xcode or the Command Line Tools (`xcode-select --install`).

## Install

With Homebrew:

```sh
brew install petrochen/tap/brioctl
```

From the release tarball (a universal binary for Apple Silicon and Intel), from the GitHub releases page:

```sh
tar xzf brioctl-1.1.0-macos-universal.tar.gz
cd brioctl-1.1.0-macos-universal
xattr -d com.apple.quarantine brioctl   # only needed if a browser downloaded the tarball
install -m 755 brioctl ~/bin/brioctl
```

The binary is ad-hoc signed and not notarized, so macOS quarantines a tarball downloaded with a browser and refuses
to run `brioctl` from it. The `xattr` command removes the quarantine attribute. Homebrew and builds from source are
not affected.

From source:

```sh
make && make install
```

`make install` copies the binary to `~/bin` by default. Choose another place with `PREFIX`:

```sh
make && sudo make install PREFIX=/usr/local   # installs /usr/local/bin/brioctl
```

`make universal` builds a binary for both Apple Silicon and Intel (macOS 12 or later), and `make dist` packs it with
the README and the license into `brioctl-VERSION-macos-universal.tar.gz`. `make app` builds the
[menu bar app](#menu-bar-app) (`app/build/brioctl.app`) and `make app-zip` packs it into
`app/build/brioctl-app-VERSION.zip`; neither is part of `make`.

## Usage

```sh
brioctl                              # show all settings
brioctl list                         # the UVC cameras brioctl finds (add --json for scripts)
brioctl --camera 2 fov 78            # use another camera: an index or serial number from the list, or a location
brioctl --json                       # the same as one JSON object, for scripts
brioctl get fov                      # print one value only (settings and micgain); exit code 1 if unreadable
brioctl fov 78 zoom 115 flicker 50   # change one or more settings
brioctl hdr off
brioctl ae manual exposure 150       # manual values need the automatic mode switched off first
brioctl micgain 0.28                 # input volume of the camera microphone in macOS
brioctl smooth on                    # zoom and pan glide to the new value (about 3 s)
brioctl save                         # save the current settings to ~/.config/brioctl/settings
brioctl save meeting                 # or to ~/.config/brioctl/meeting
brioctl apply                        # put the saved settings back (apply meeting, apply warmer, ...)
brioctl profiles [--json]            # list the presets and the saved files
brioctl import optionsplus [DB]      # the settings Logi Options+ saved, as a settings file (--save NAME writes it)
brioctl defaults                     # camera default values, except mic and showmode; no restart
brioctl factory-reset --yes          # restart the camera with factory settings, then restore yours
brioctl watch                        # apply now, on connect and on video start (see below)
brioctl dump                         # all units and registers of the camera, read-only
brioctl snapshot [FILE]              # every register brioctl reads, serial number masked
brioctl --version
brioctl help
```

When several settings are given in one command, `mic` is written last: changing it restarts the camera.

## Cameras

`brioctl list` finds every USB device that has a UVC VideoControl interface:

```
#   id         name        model       support       serial        location
1   046d:0944  MX Brio     MX Brio     full          XXXXXXXXXXXX  0x110000
2   1234:5678  Some Cam    -           standard      ABC123        0x120000
```

`--camera ID` before the command (or anywhere in the line) chooses one. ID is the index, the serial number or the USB
location from the list. `brioctl list --json` prints the same as `{"cameras":[{"index":1,"vid":"046d",...}]}`. Without
`--camera`, brioctl uses the only camera, or, if there are several, the only one it knows (support `full` or
`experimental`). If it cannot choose, it prints the list and exits with status 2. `watch` uses the same rules, except
that without `--camera` it never takes a camera it does not know: it waits for the MX Brio instead, so a LaunchAgent
that was started without the MX Brio does not apply your MX Brio settings to another camera.

| Support        | Cameras                                                                                                          | What brioctl does                                                                                                                                                                          |
| -------------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `full`         | Logitech MX Brio (`046d:0944`)                                                                                   | Everything in this document.                                                                                                                                                               |
| `experimental` | Logitech Brio (`085e`), Brio 500 (`0943`), Brio 501 (`0946`), Brio 505 (`0919`), Brio 4K Stream Edition (`086b`) | The standard controls, the field of view, and `hdr` (Brio, Brio 500, 4K Stream Edition) and Show Mode (Brio 500). Other projects report that these work. They are not tested with brioctl. |
| `standard`     | Every other UVC camera                                                                                           | The standard UVC controls the camera declares. brioctl never writes to an extension unit of such a camera.                                                                                 |

`show` of an experimental camera says so in one line. If you have one of those cameras, please run
`brioctl snapshot report.snap` and send the file.

For a standard control to appear, the camera has to declare it in the descriptor (the control bitmaps of its camera
terminal and processing unit). The ranges in `show` are the camera's own (`GET_MIN` and `GET_MAX`). The backlight
compensation control is called `hdr` on the Logitech cameras that have an HDR switch (it is on or off there) and
`backlight` (a number) on the others. Either name is accepted on every camera.

## Example output

```
MX Brio  firmware 1.1.394  serial XXXXXXXXXXXX  colour code 2

Status (read-only)
  video       on, 1920x1080
  led         on
  desk view   off
  rightsight  off, speed normal, framing normal (stored for Logitech's app)

Logitech (mapped from Logi Tune)
  fov         78        default 90                    field of view in degrees: 90, 78, 65
  showmode    on        default off                   Show Mode (flip the picture when tilted to the desk): on, off
  hdr         on        default on                    HDR (UVC backlight compensation): on, off
  warmth      62        default 50        0-100       white balance warmth, 50 = neutral
  tint        50        default 50        0-100       tint, 50 = neutral
  vibrance    128       default 128       0-255       vibrance, 128 = neutral
  expcomp     128       default 128       0-255       exposure compensation, 128 = neutral
  mic         on        default off                   camera microphone: on, off (camera restarts on change)

Framing
  zoom        115       default 100       100-400     zoom, 100 = 1x on Logitech cameras
  pan         0         default 0         -20..20     move the zoomed frame, in degrees
  tilt        0         default 0         -20..20     move the zoomed frame, in degrees

Exposure and image (standard UVC)
  priority    exposure  default ?                     in low light keep: fps, exposure
  ae          auto      default auto                  auto exposure: auto, manual
  exposure    1250*     default 156       3-2047      exposure time in 100 us units (ae manual)
  gain        0*        default 0         0-255       gain
  flicker     50        default 60                    anti-flicker, mains frequency in Hz: 50, 60
  brightness  128       default 128       0-255       brightness
  contrast    128       default 128       0-255       contrast
  saturation  128       default 128       0-255       saturation
  sharpness   128       default 128       0-255       sharpness
  awb         on        default on                    auto white balance: on, off
  wb          4100*     default 5000      2800-7500   white balance in kelvin (awb off)
  af          on        default on                    autofocus: on, off
  focus       14*       default 0         0-255       focus (af off)

Found in the firmware, not used by Logitech's apps
  smooth      off       default off                   glide to new zoom and pan in about 3 s: on, off

Microphone (macOS)
  micgain     0.2785    default -         0-1         input volume

* set automatically right now
```

A `*` after a value means an automatic mode (`ae`, `awb`, `af`) is setting it right now. You can write such a value
only after switching the automatic mode off, and `save` does not store it.

The Status section only reports: whether video is running and at what resolution, whether the indicator LED is on,
whether the camera is tilted to the desk (Show Mode) and what is stored in the RightSight settings block.

`brioctl`, `brioctl --json`, `brioctl list` and `brioctl dump` print the camera's serial number. Mask it before you post
their output. `brioctl snapshot` and `tools/hidmon` already do.

`brioctl help` lists all setting names. What a camera has depends on the camera: `brioctl` shows only the settings it
has, with its own range for each number.

## Settings

| Name         | Values                                | What it does                                                                                                                 |
| ------------ | ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `fov`        | `90`, `78`, `65` (degrees)            | Field of view. A digital crop.                                                                                               |
| `showmode`   | `on`, `off`                           | Show Mode. When the camera is tilted down to the desk it switches to a desk view and sets the field of view and zoom itself. |
| `hdr`        | `on`, `off`                           | HDR. This is the UVC backlight compensation control. It lifts the shadows.                                                   |
| `warmth`     | 0 to 100, 50 is neutral               | White balance warmth, from blue to warm.                                                                                     |
| `tint`       | 0 to 100, 50 is neutral               | Tint.                                                                                                                        |
| `vibrance`   | 0 to 255, 128 is neutral              | Vibrance.                                                                                                                    |
| `expcomp`    | 0 to 255, 128 is neutral              | Exposure compensation.                                                                                                       |
| `mic`        | `on`, `off`                           | Camera microphone. The camera restarts about 2 seconds after a change.                                                       |
| `zoom`       | 100 to 400 (100 is 1x)                | Digital zoom.                                                                                                                |
| `pan`        | -20 to 20 (degrees)                   | Moves the zoomed frame sideways.                                                                                             |
| `tilt`       | -20 to 20 (degrees)                   | Moves the zoomed frame up and down.                                                                                          |
| `priority`   | `fps`, `exposure`                     | What to keep in low light: the frame rate or the exposure time.                                                              |
| `ae`         | `auto`, `manual`                      | Auto exposure. `exposure` and `gain` can be written only in `manual`.                                                        |
| `exposure`   | 3 to 2047 (units of 100 microseconds) | Exposure time.                                                                                                               |
| `gain`       | 0 to 255                              | Sensor gain.                                                                                                                 |
| `flicker`    | `50`, `60` (Hz)                       | Anti-flicker: the frequency of the mains power.                                                                              |
| `brightness` | 0 to 255                              | Brightness. Default 128.                                                                                                     |
| `contrast`   | 0 to 255                              | Contrast. Default 128.                                                                                                       |
| `saturation` | 0 to 255                              | Saturation. Default 128.                                                                                                     |
| `sharpness`  | 0 to 255                              | Sharpness. Default 128.                                                                                                      |
| `awb`        | `on`, `off`                           | Automatic white balance.                                                                                                     |
| `wb`         | 2800 to 7500 (kelvin)                 | White balance temperature. Can be written only with `awb` off.                                                               |
| `af`         | `on`, `off`                           | Autofocus.                                                                                                                   |
| `focus`      | 0 to 255                              | Focus. Can be written only with `af` off.                                                                                    |
| `smooth`     | `on`, `off`                           | Zoom and pan glide to a new value in about 3 seconds. The camera forgets it on power loss.                                   |
| `micgain`    | 0 to 1                                | Input volume of the camera microphone in macOS. Not a camera register.                                                       |
| `backlight`  | number                                | Backlight compensation of a camera without an HDR switch. The same control as `hdr`.                                         |
| `hue`        | number, may be negative               | Other cameras. Hue. Can be written only with `hueauto` off.                                                                  |
| `hueauto`    | `on`, `off`                           | Other cameras. Automatic hue.                                                                                                |
| `gamma`      | number                                | Other cameras. Gamma.                                                                                                        |
| `iris`       | number (f-number times 100)           | Other cameras. Iris.                                                                                                         |
| `roll`       | degrees, may be negative              | Other cameras. Rotates the picture.                                                                                          |
| `privacy`    | `on`, `off`                           | Other cameras. Privacy shutter; many cameras only report it.                                                                 |

`brioctl help` prints the same list. The camera's own default for each setting is in the `default` column of the
output above.[^defaults] The values in the table are those of the MX Brio. Other cameras have their own ranges and
choices: `anti-flicker` can also be `off` or `auto` and `ae` can be `shutter` where the camera lists it, and `show`
prints what the camera accepts.

[^defaults]:
    For `showmode` and `mic` the camera reports "off" as the default, but after a factory reset the firmware
    turns both on. See [Factory reset](docs/registers.md#factory-reset) in the register notes. `brioctl defaults`
    leaves those two settings alone for this reason.

## Presets

`brioctl apply NAME` accepts these names as well as saved files:

| Preset       | Sets                          |
| ------------ | ----------------------------- |
| `neutral`    | `warmth 50`, `saturation 128` |
| `warmer`     | `warmth 60`                   |
| `cooler`     | `warmth 40`                   |
| `bw`         | `saturation 0`                |
| `standard`   | `priority exposure`           |
| `streaming`  | `priority fps`                |
| `colorboost` | `saturation 255`              |

`colorboost` needs an explanation. The camera has a hidden Color Boost switch that doubles the saturation, but it is
lost when the video restarts and when saturation is written. `saturation 255` gives the same picture from the default
128, and the camera keeps it, so the preset uses that. The measurements are in [docs/registers.md](docs/registers.md).

## Import from Logi Options+

If Logi Options+ has set up your camera, `brioctl import optionsplus` turns the settings it saved into a brioctl
settings file. That helps after a power loss or a factory reset, or when you remove Logi Options+ and want the same
picture. It needs no camera and writes nothing to the camera or to the app's files.

```sh
brioctl import optionsplus                  # print the settings file
brioctl import optionsplus --save fromapp   # write it to ~/.config/brioctl/fromapp instead
brioctl apply fromapp                       # put it on the camera
brioctl import optionsplus ~/backup/settings.db   # a copy of the database
```

It reads `~/Library/Application Support/LogiOptionsPlus/settings.db`, or the file you name. The output starts with
`# imported from ...` comments, then one `name value` line per setting, then `# skipped:` lines for everything it did
not take over (the same lines go to stderr). Short example:

```
# imported from Logi Options+ 2.9.994631 on 2026-11-01 22:17
# camera 046d:0944
# MX Brio, profile PROFILE_NAME_DEFAULT
fov 78
showmode on
...
awb on
af on
micgain 0.2785
# skipped: mic (Logi Options+ does not keep the camera microphone on or off; apply leaves it as it is)
# skipped: videoPreview (no brioctl equivalent)
```

What it takes, for the preset each card of the app has selected in the profile `PROFILE_NAME_DEFAULT` (the first
profile if there is none of that name), and the MX Brio first if the app knows several cameras:

| Logi Options+                                 | brioctl                                             |
| --------------------------------------------- | --------------------------------------------------- |
| field of view 90, 78, 65; Show Mode; HDR      | `fov`, `showmode`, `hdr`                            |
| warmth, tint, vibrance, exposure compensation | `warmth`, `tint`, `vibrance`, `expcomp`             |
| zoom                                          | `zoom`                                              |
| low-light priority                            | `priority exposure` or `fps`                        |
| automatic exposure                            | `ae auto`                                           |
| anti-flicker 50 or 60                         | `flicker`                                           |
| brightness, contrast, saturation, sharpness   | the same names                                      |
| white balance: automatic                      | `awb on`                                            |
| white balance: manual                         | `awb off`, `wb`, with a `# check:` line (see below) |
| autofocus                                     | `af on`                                             |
| microphone volume (input)                     | `micgain`                                           |

What it leaves out, and why:

- Manual exposure time and gain. The numbers in Logi Options+ are its own scale and were not matched to the camera's
  units, so a manual exposure is skipped as a whole (`ae`, `exposure`, `gain`).
- Manual focus, and pan or tilt away from the centre: the scale of the numbers is not known. Pan and tilt at the centre
  become `pan 0` and `tilt 0`.
- Manual white balance is imported as kelvin, which is probably what it is but has not been checked against the
  camera, so the file says `# check:` next to it. Values outside 2800 to 7500 are skipped.
- RightSight (Logitech's app does the framing on the computer), the video preview, background blur and the like: they
  are not camera settings. They are listed by name when the app has them on.
- The camera microphone on and off (`mic`). The app does not keep it in this file, so the imported file has no `mic`
  line and `apply` leaves the microphone as it is.
- A field the app left out is not guessed. Optional ones (HDR, Show Mode, tint, anti-flicker) give no line and no
  comment; any other missing or out-of-range field gets a `# skipped:` line.

The format was read from Logi Options+ 2.9.994631 (settings schema 26). Another schema version is imported too, with a
`# check:` line and a warning. A file that does not look like Logi Options+ settings is an error that names the schema
version it found. The database is opened read-only and immutable, so a running Logi Options+ is not disturbed, but
changes it still holds in `settings.db-wal` are not seen: brioctl says so on stderr, and quitting the app before the
import fixes it. Logi Tune keeps nothing on disk to import: run `brioctl save` while the camera has your settings.

## JSON

`brioctl --json` prints one JSON object on one line, for scripts and apps. Errors are not JSON: they go to stderr as
text with a non-zero exit status.

- `device`: `model` (the name in brioctl's table, or null), `name` (the USB product name), `vid`, `pid` (hex strings),
  `support`, `index`, `location`, `serial`, `firmware` and `colour` (null where the camera does not say).
- `status`: `video`, `led`, `desk_view` and `rightsight`, null where the camera is not an MX Brio.
- `settings`: one entry for each setting the camera has, named as on the command line. Each has `value`, `default`,
  `auto` (an automatic mode drives it now), `group` (`Logitech`, `Framing`, `Exposure and image` or `Found in the
firmware`), `writable` (it can be set and no automatic mode drives it now), `kind` (`number`, `choice` or `bool`)
  and `help`. A number has `min`, `max` and `step`, scaled like the value (pan and tilt in degrees); a choice has
  `choices`, the names it accepts.
- `micgain`: the macOS input volume, or null.

`brioctl list --json` prints `{"cameras":[{"index":1,"vid":"046d","pid":"0944","name":"MX Brio","model":"MX Brio",
"support":"full","serial":"...","location":"0x110000"}]}`. `brioctl profiles --json` prints
`{"presets":[{"name":"warmer","settings":{"warmth":"60"}}],"saved":["meeting","settings"],"dir":"/Users/you/.config/brioctl"}`.

## Apply settings automatically

The camera forgets some settings when it loses power, and image settings can be lost when video starts.
`brioctl watch` puts your settings back:

```sh
brioctl save        # store the current settings in ~/.config/brioctl/settings
make agent          # install brioctl to PREFIX/bin and start "brioctl watch" at login
make unagent        # remove it again
```

With Homebrew, `brew services start brioctl` does the same. The [menu bar app](#menu-bar-app) can install the agent
too, and keeps the settings file up to date when you change something in it.

`make agent` installs a LaunchAgent with the label `com.github.petrochen.brioctl` in `~/Library/LaunchAgents`. If
`~/.config/brioctl/settings` does not exist yet, it saves the current settings first. The log is
`~/Library/Logs/brioctl.log`.

What `watch` does:

- It applies `~/.config/brioctl/settings` (or the file you name: `brioctl watch FILE`) when it starts and every time
  the camera is connected. A camera that is still starting up is retried a few times.
- When video starts, `watch` waits 2 seconds and applies the file again, because image settings can be lost when the
  stream starts. The MX Brio announces it with HID report `0x40`. For every camera `watch` also listens to CoreMediaIO:
  the property `DeviceIsRunningSomewhere` of the camera's device changes from false to true while some app starts to
  use the camera. Reading and listening to it does not open the camera and needs no camera permission. Both signals
  feed the same timer, so one start gives one apply.
- It never changes `mic` while video is on. The camera restarts after that write, which would cut the picture and the
  sound in the middle of a call. If the file differs from the camera, the log says `mic: not changed while video is on`.
- While the camera shows the desk (Show Mode, `desk view on` in the status), it skips `fov`, `zoom`, `pan` and `tilt`.
  The camera sets those itself at that moment. The log has one line about it. A manual `brioctl apply` is not affected.
- It follows one camera: the one you chose with `--camera`, found again after a reconnect by its vendor and product id
  and serial number. If the file was saved from another model, the log has a warning.
- It logs only the settings it actually changed. The lines `HID listening`, `HID device removed`,
  `CoreMediaIO listening` and `CoreMediaIO device removed` show whether `watch` is listening to the camera after the
  camera has restarted. If macOS does not let `watch` open the HID
  interface, it logs a warning and applies settings on connect only.

A log looks like this:

```
2026-11-01 17:57:38 video started
fov 90
warmth 55
2026-11-01 17:57:38 mic: not changed while video is on
2026-11-01 17:57:38 applied (2 changed)
```

## Safety

brioctl writes to the camera, so it is careful about what it writes.

- It writes only the controls in its own table. Everything else is read-only.
- Logitech extension units are written only on the models in the table above, and only the controls each model is
  known to have: the field of view on all of them, Show Mode on the Brio 500 and the MX Brio, the rest on the MX Brio.
  On any other camera, brioctl writes standard UVC controls only. The values of such a control come from brioctl's own
  table, never from the camera's `GET_MAX` (the field of view reports 255 as its maximum and only 0, 1 and 2 do
  anything).
- It never writes these registers: the factory reset (except for `factory-reset --yes`), the flash lock, the lens
  motor and lens memory service command, the restart command, the factory optics calibration switch, the chip debug
  unit and the chip command and firmware update unit. What each one does is described in
  [docs/registers.md](docs/registers.md#registers-brioctl-never-writes).
- For the Logitech extension controls it first reads the control's size (`GET_LEN`) and `GET_INFO`. If the firmware has
  changed the layout, or the control does not say it can be written, the write is cancelled.
- It reads `GET_INFO` and refuses to write a value that an automatic mode is setting right now.
- It checks the value against the `GET_MIN` and `GET_MAX` of the camera before writing.
- Pan and tilt share one register, and `smooth` shares one with its speed. The other fields are read first and kept.
- A value that is already set is not written again, which avoids needless flash wear and camera restarts.
- After each write it reads the value back. If the camera did not keep it, brioctl says so and exits with an error.
- `save` leaves out values that the camera would not accept.
- `import optionsplus` never opens the camera. It opens Logi Options+'s database read-only and immutable, so SQLite
  creates, locks and changes nothing in the app's folder. It uses only the camera settings in the document; the
  account data stored beside them is never printed or kept.
- `factory-reset` works on the MX Brio only. It does nothing without `--yes`. With it, your settings are saved to `~/.config/brioctl/before-reset`
  first and applied again after the camera is back.
- `dump` asks the service registers, and all registers of an extension unit it does not know, only for `GET_INFO` and
  `GET_LEN`. `snapshot` never reads the value of the factory
  reset or the flash lock. `tools/hidmon` and `tools/uvcwatch` have no write code at all.

None of this is a guarantee. You write to your camera at your own risk.

## What the MX Brio cannot do

- The indicator LED. The camera ignores LED writes. Retail units are locked in a state where the firmware drops them.
- RightLight. The register exists and accepts a write, but nothing changes in the picture, the exposure or the gain.
  The function has no effect in this firmware.
- RightSight auto-framing. It is done by Logitech's desktop app on the computer. The camera only stores the app's
  settings. brioctl shows them in the status but does not do any framing.
- Firmware updates. Not supported. A wrong write to that part of the camera can damage it.
- The state of the privacy shutter. The camera does not report it.

## How it works

brioctl sends USB Video Class requests (`GET_CUR`, `SET_CUR`, `GET_MIN` and so on) to the camera's VideoControl
interface with `IOUSBDeviceInterface::DeviceRequestTO`. The device is not opened or seized, so the camera driver keeps
working, settings can be changed while video is streaming, and no root is needed. The units are found by reading the
configuration descriptor, and the Logitech extension units by their GUID. The standard controls a camera has are the
ones its camera terminal and processing unit declare in their `bmControls`.

The standard controls follow the UVC specification. The Logitech extension controls are not documented by Logitech.
The register map in [docs/registers.md](docs/registers.md) comes from observing Logitech's apps, from analysing the
camera firmware for interoperability, and from tests on a real camera, and every fact in it is marked as measured or
inferred.

`micgain` is different: the camera microphone's input volume is kept by macOS, so it is set through CoreAudio.

## Testing

```sh
make test       # the command-line tool
make test-app   # the menu bar app: unit tests of its Swift package (app/README.md)
```

The tests run without a camera. The same `brioctl.c` is built with `-DBRIOCTL_FAKE`, and a camera emulator answers its
requests from a register snapshot, `tests/mxbrio-1.1.394.snap`, which was taken from a real MX Brio with
`brioctl snapshot`. `BRIOCTL_FAKE` can name several snapshots separated by `:`, which gives several cameras for `list`
and `--camera`. `tests/make-fixtures.py` (`make fixtures`) derives the other fixtures from the MX Brio snapshot: a
generic UVC camera without extension units, one with more standard controls, and a simulated Brio 500.
The `import optionsplus` tests read `tests/optionsplus-sample.db`, the settings database of Logi Options+ 2.9.994631
with the serial number and ids replaced (`tests/optionsplus-sample.json` is the document in it); the tests derive the
variants they need from the JSON with Python.

For a bug report, run `brioctl snapshot report.snap` and attach the file. It contains the USB descriptor and every
register brioctl reads, with the serial number replaced by zeros. It is read-only.

`tools/` has two read-only monitors, `hidmon` and `uvcwatch`, for finding out what the camera does. See
[tools/README.md](tools/README.md).

## Related projects

- [cameractrls](https://github.com/soyersoyer/cameractrls): camera controls for Linux, including some Logitech
  extension controls such as the MX Brio field of view.
- [uvc-util](https://github.com/jtfrey/uvc-util): a macOS command-line tool for the standard UVC controls.
- libwebcam (`uvcdynctrl`): a Linux library whose Logitech XML file describes the extension units of older Logitech
  cameras.

## License

MIT, see [LICENSE](LICENSE).

## Disclaimer

brioctl is an independent project. It is not affiliated with, authorized by or endorsed by Logitech. Logitech, MX Brio
and other product names are trademarks of their owners, and they are used here only to name the hardware the tool
works with.

The software is provided as is, without warranty. It sends commands to the firmware of your camera, using
undocumented controls. Use it at your own risk.
