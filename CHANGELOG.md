# Changelog

## Unreleased (1.1)

- Any UVC camera: `brioctl list [--json]` shows every USB device with a VideoControl interface, with its model and
  support level (`full`, `experimental`, `standard`); `--camera ID` (index, serial number or location) chooses one for
  every command. Without it brioctl uses the only camera, or the only one it knows, or exits with status 2.
- The standard controls a camera has are read from the control bitmaps of its camera terminal and processing unit.
  New: `hue`, `hueauto`, `gamma`, `iris`, `roll`, `privacy`; `brightness` and `hue` are signed. `show` prints each
  numeric control's own range; flicker and exposure mode offer what the camera lists. Backlight compensation is `hdr`
  on the Logitech models with an HDR switch and `backlight` on the others; both names work everywhere.
- Experimental support for the Logitech Brio (`085e`), Brio 500 (`0943`), Brio 501 (`0946`), Brio 505 (`0919`) and
  Brio 4K Stream Edition (`086b`), from what other projects report: the field of view on all of them, Show Mode on the
  Brio 500. Extension units are written only on models of this table, only after `GET_LEN` and the `SET` bit of
  `GET_INFO` agree, and never with a value taken from `GET_MAX`.
- `watch` follows the chosen camera (vendor id, product id and serial number) and detects video start for every
  camera through CoreMediaIO (`DeviceIsRunningSomewhere`, no camera permission needed), next to the MX Brio HID report.
  Without `--camera` it still waits for the MX Brio when no Logitech camera is connected.
- `save` writes a `# camera VID:PID SERIAL` line and `apply` warns about a file from another model.
- `--json`: `device` gains `vid`, `pid`, `support`, `index`, `location` and `name`; every setting gains `group`,
  `writable`, `kind`, `help` and `min`, `max`, `step` or `choices`. New: `profiles --json`.
- `factory-reset` works on the MX Brio only. `dump` reads no value of an unknown extension unit. JSON strings from USB
  descriptors are escaped as UTF-8.
- Snapshots have `device`, `name` and `serial` lines (snapshots from 1.0 still load); `BRIOCTL_FAKE` takes several
  snapshots separated by `:`; `make fixtures` writes the generic and Brio 500 test cameras.

## 1.0.0 — 2026-11-01

First public release.

- Settings Logitech's apps control through the camera: field of view (90, 78, 65 degrees), Show Mode, HDR, white
  balance warmth, tint, vibrance, exposure compensation, camera microphone on and off.
- Digital zoom, pan and tilt, and smooth zoom (zoom and pan glide to the new value in about 3 seconds).
- All standard UVC exposure and image controls: auto exposure, exposure time, gain, anti-flicker, brightness,
  contrast, saturation, sharpness, auto white balance, white balance temperature, autofocus, focus, low-light
  priority.
- macOS input volume of the camera microphone (`micgain`).
- Built-in presets: `neutral`, `warmer`, `cooler`, `bw`, `standard`, `streaming` and `colorboost`.
- `save` and `apply` for named settings files, `profiles` to list them.
- `watch` and a LaunchAgent (`make agent`): settings are applied when the camera is connected and again when video
  starts. It never changes the microphone while video is on and leaves framing to the camera while it shows the desk.
- `--json` output and `get NAME` for scripts.
- `defaults` (camera defaults without a restart) and `factory-reset --yes` (restart with factory settings, then
  restore your own).
- Read-only `dump` of all units and extension controls, and `snapshot` for bug reports (serial number masked).
- Offline test suite (`make test`) that runs against a camera emulator built from a register snapshot.
- Universal binary (`make universal`) and release tarball (`make dist`).
- `tools/hidmon` and `tools/uvcwatch`: read-only monitors for the HID interface and the UVC registers.
