# Changelog

## 1.1.0 — unreleased

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
- `import optionsplus [DB] [--save NAME]` turns the camera settings saved by Logi Options+ (2.9, `settings.db` in
  `~/Library/Application Support/LogiOptionsPlus`) into a settings file for `apply`: on stdout, or in
  `~/.config/brioctl/NAME`. It needs no camera and opens the database read-only and immutable, with SQLite's JSON
  functions (brioctl now links the system `libsqlite3`). Up to twenty settings come from the selected presets;
  manual exposure and gain, manual focus, pan and tilt away from the centre, RightSight and the app's own options are
  listed as `# skipped:` lines, manual white balance is taken with a `# check:` line. See the README.
- Menu bar app, `brioctl.app` (macOS 13 or later, universal, ad-hoc signed and not notarized). A window with the
  settings of the chosen camera, drawn from `brioctl --json` (switches, menus, sliders with the camera's own ranges), a
  camera picker, presets, saved files and "Save current as...". It runs the brioctl inside the app and never opens the
  camera, so it needs no camera permission. Install it with `brew install --cask petrochen/tap/brioctl-app`, from
  `brioctl-app-1.1.0.zip` on the release page, or with `make app`.
- The app keeps the settings file in step with its changes. "Re-apply settings automatically" installs the
  `com.github.petrochen.brioctl` agent that runs `brioctl watch` with the tool inside the app, and leaves an agent from
  `make agent` or Homebrew alone. While any such agent is installed, the app runs `brioctl [--camera ID] save` about a
  second after its last change (sliders, menus, presets, hotkeys, URLs), so `watch` does not put the old settings back.
  A burst of changes gives one save, and a camera the agent does not follow is left out. "Remember current settings"
  saves by hand.
- Launch at login (a LaunchAgent that opens the app) and global hotkeys, off until switched on and without any
  Accessibility permission: Control-Option-Command with `1`, `2`, `3` for `fov` 90, 78, 65, `0` for `zoom 100`, `=` and
  `-` for `zoom` +25 and -25.
- URL scheme for Shortcuts ("Open URLs") and scripts: `brioctl://set?fov=78&zoom=115`, `brioctl://apply?name=warmer`,
  `brioctl://camera?id=2`. Names the camera does not have and values that are not plain words or numbers are ignored.
- `make app`, `make app-zip` and `make test-app` build, pack and test the app; `make` and `make test` still do only the
  command-line tool. CI tests and builds the app, checks its signature and architectures, and attaches
  `brioctl-app-VERSION.zip` to the release next to the tarball. The Homebrew formula moves to v1.1.0, and a cask
  `brioctl-app` is drafted in `packaging/`.

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
