# brioctl

brioctl is a command-line tool for macOS that reads and changes the settings of the Logitech MX Brio webcam
(USB `046d:0944`) without Logitech's desktop software. It covers the field of view, Show Mode, HDR, white balance
warmth, tint, vibrance, zoom, pan and tilt, exposure, focus and the camera microphone, and it can re-apply your
settings every time the camera is connected or video starts. It is one C file that talks to the camera through IOKit.
It needs no driver, no root and no third-party library.

Not affiliated with or endorsed by Logitech. See [Disclaimer](#disclaimer).

## Features

- Settings that Logitech's apps control through the camera: field of view (90, 78 or 65 degrees), Show Mode, HDR,
  white balance warmth, tint, vibrance, exposure compensation, camera microphone on and off.
- Digital zoom, pan and tilt, and smooth zoom: zoom and pan glide to the new value in about 3 seconds.
- All standard UVC exposure and image controls: auto exposure, exposure time, gain, anti-flicker, brightness,
  contrast, saturation, sharpness, auto white balance, white balance temperature, autofocus, focus, low-light priority.
- The macOS input volume of the camera microphone (`micgain`).
- Presets, including `colorboost`, and named settings files: `save` and `apply`.
- `watch`, a LaunchAgent that re-applies your settings when the camera is connected and when video starts.
- `--json` output and `get NAME` for scripts.
- `snapshot` for bug reports, `defaults` to go back to the camera's default values, and `factory-reset` to restart the
  camera with factory settings and then restore yours.
- A read-only `dump` of every unit and extension control the camera has.

## Requirements

- macOS 12 or later, on Apple Silicon or Intel.
- A Logitech MX Brio (`046d:0944`). Tested with firmware 1.1.394.
- To build from source: Xcode or the Command Line Tools (`xcode-select --install`).

## Install

With Homebrew:

```sh
brew install petrochen/tap/brioctl
```

From the release tarball (a universal binary for Apple Silicon and Intel), from the GitHub releases page:

```sh
tar xzf brioctl-1.0.0-macos-universal.tar.gz
cd brioctl-1.0.0-macos-universal
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
the README and the license into `brioctl-VERSION-macos-universal.tar.gz`.

## Usage

```sh
brioctl                              # show all settings
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
brioctl profiles                     # list the presets and the saved files
brioctl defaults                     # camera default values, except mic and showmode; no restart
brioctl factory-reset --yes          # restart the camera with factory settings, then restore yours
brioctl watch                        # apply now, on connect and on video start (see below)
brioctl dump                         # all units and registers of the camera, read-only
brioctl snapshot [FILE]              # every register brioctl reads, serial number masked
brioctl --version
brioctl help
```

When several settings are given in one command, `mic` is written last: changing it restarts the camera.

## Example output

```
MX Brio  firmware 1.1.394  serial XXXXXXXXXXXX  colour code 2

Status (read-only)
  video       on, 1920x1080
  led         on
  desk view   off
  rightsight  off, speed normal, framing normal (stored for Logitech's app)

Logitech (mapped from Logi Tune)
  fov         78        default 90        field of view in degrees: 90, 78, 65
  showmode    on        default off       Show Mode, flip the picture when tilted to the desk
  hdr         on        default on        HDR (UVC backlight compensation): on, off
  warmth      62        default 50        white balance warmth: 0-100, 50 = neutral
  tint        50        default 50        tint: 0-100, 50 = neutral
  vibrance    128       default 128       vibrance: 0-255, 128 = neutral
  expcomp     128       default 128       exposure compensation: 0-255, 128 = neutral
  mic         on        default off       camera microphone: on, off (camera restarts on change)

Framing
  zoom        115       default 100       digital zoom: 100 = 1x ... 400 = 4x
  pan         0         default 0         move the zoomed frame, degrees: -20...20
  tilt        0         default 0         move the zoomed frame, degrees: -20...20

Exposure and image (standard UVC)
  priority    exposure  default ?         in low light keep: fps, exposure
  ae          auto      default auto      auto exposure: auto, manual
  exposure    1250*     default 156       exposure time in 100 us units: 3-2047 (ae manual)
  gain        0*        default 0         gain: 0-255 (ae manual)
  flicker     50        default 60        anti-flicker, mains frequency in Hz: 50, 60
  brightness  128       default 128       brightness: 0-255
  contrast    128       default 128       contrast: 0-255
  saturation  128       default 128       saturation: 0-255
  sharpness   128       default 128       sharpness: 0-255
  awb         on        default on        auto white balance: on, off
  wb          4151*     default 5000      white balance in kelvin: 2800-7500 (awb off)
  af          on        default on        autofocus: on, off
  focus       14*       default 0         focus: 0-255 (af off)

Found in the firmware, not used by Logitech's apps
  smooth      off       default off       glide to new zoom and pan in about 3 s: on, off

Microphone (macOS)
  micgain     0.2785    default -         input volume: 0-1

* set automatically right now
```

A `*` after a value means an automatic mode (`ae`, `awb`, `af`) is setting it right now. You can write such a value
only after switching the automatic mode off, and `save` does not store it.

The Status section only reports: whether video is running and at what resolution, whether the indicator LED is on,
whether the camera is tilted to the desk (Show Mode) and what is stored in the RightSight settings block.

`brioctl`, `brioctl --json` and `brioctl dump` print the camera's serial number. Mask it before you post their output.
`brioctl snapshot` and `tools/hidmon` already do.

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

`brioctl help` prints the same list. The camera's own default for each setting is in the `default` column of the
output above.[^defaults]

[^defaults]: For `showmode` and `mic` the camera reports "off" as the default, but after a factory reset the firmware
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

## Apply settings automatically

The camera forgets some settings when it loses power, and image settings can be lost when video starts.
`brioctl watch` puts your settings back:

```sh
brioctl save        # store the current settings in ~/.config/brioctl/settings
make agent          # install brioctl to PREFIX/bin and start "brioctl watch" at login
make unagent        # remove it again
```

With Homebrew, `brew services start brioctl` does the same.

`make agent` installs a LaunchAgent with the label `com.github.petrochen.brioctl` in `~/Library/LaunchAgents`. If
`~/.config/brioctl/settings` does not exist yet, it saves the current settings first. The log is
`~/Library/Logs/brioctl.log`.

What `watch` does:

- It applies `~/.config/brioctl/settings` (or the file you name: `brioctl watch FILE`) when it starts and every time
  the camera is connected. A camera that is still starting up is retried a few times.
- When video starts, the camera sends HID report `0x40`. `watch` waits 2 seconds after the last such report and applies
  the file again, because image settings can be lost when the stream starts.
- It never changes `mic` while video is on. The camera restarts after that write, which would cut the picture and the
  sound in the middle of a call. If the file differs from the camera, the log says `mic: not changed while video is on`.
- While the camera shows the desk (Show Mode, `desk view on` in the status), it skips `fov`, `zoom`, `pan` and `tilt`.
  The camera sets those itself at that moment. The log has one line about it. A manual `brioctl apply` is not affected.
- It logs only the settings it actually changed. The lines `HID listening` and `HID device removed` show whether
  `watch` is listening to the camera after the camera has restarted. If macOS does not let `watch` open the HID
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
- It never writes these registers: the factory reset (except for `factory-reset --yes`), the flash lock, the lens
  motor and lens memory service command, the restart command, the factory optics calibration switch, the chip debug
  unit and the chip command and firmware update unit. What each one does is described in
  [docs/registers.md](docs/registers.md#registers-brioctl-never-writes).
- For the Logitech extension controls it first reads the control's size (`GET_LEN`). If the firmware has changed the
  layout, the write is cancelled.
- It reads `GET_INFO` and refuses to write a value that an automatic mode is setting right now.
- It checks the value against the `GET_MIN` and `GET_MAX` of the camera before writing.
- Pan and tilt share one register, and `smooth` shares one with its speed. The other fields are read first and kept.
- A value that is already set is not written again, which avoids needless flash wear and camera restarts.
- After each write it reads the value back. If the camera did not keep it, brioctl says so and exits with an error.
- `save` leaves out values that the camera would not accept.
- `factory-reset` does nothing without `--yes`. With it, your settings are saved to `~/.config/brioctl/before-reset`
  first and applied again after the camera is back.
- `dump` asks the service registers only for `GET_INFO` and `GET_LEN`. `snapshot` never reads the value of the factory
  reset or the flash lock. `tools/hidmon` and `tools/uvcwatch` have no write code at all.

None of this is a guarantee. You write to your camera at your own risk.

## What this camera cannot do

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
configuration descriptor, and the Logitech extension units by their GUID.

The standard controls follow the UVC specification. The Logitech extension controls are not documented by Logitech.
The register map in [docs/registers.md](docs/registers.md) comes from observing Logitech's apps, from analysing the
camera firmware for interoperability, and from tests on a real camera, and every fact in it is marked as measured or
inferred.

`micgain` is different: the camera microphone's input volume is kept by macOS, so it is set through CoreAudio.

## Testing

```sh
make test
```

The tests run without a camera. The same `brioctl.c` is built with `-DBRIOCTL_FAKE`, and a camera emulator answers its
requests from a register snapshot, `tests/mxbrio-1.1.394.snap`, which was taken from a real MX Brio with
`brioctl snapshot`.

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
