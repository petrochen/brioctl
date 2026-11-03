# Changelog

## 1.2.0 — 2026-11-03

### Added

- `brioctl auto [--dry-run] [--save] [--json] [--framing]`: measures the picture (two frames averaged, 2 s after each
  change), nudges `expcomp`, `hdr` and `warmth` in up to 4 steps, stops when in range, not improving or oscillating.
- `brioctl capture` reports the largest face of each frame (Vision): `face` statistics, `faces`, `face_fraction`,
  `face_center`.
- `brioctl capture [-o PATH] [--count N] [--interval SEC] [--wait SEC] [--size WxH] [--stats] [--json]`: JPEG frames
  and picture statistics through AVFoundation, while another app uses the camera; exit status 3 if access is denied.
- `brioctl describe [--json]`: every control with range, default, meaning, effect on the picture, `settle_seconds`
  and `risky`; read-only.
- Relative values (`expcomp +10 warmth -5`, `fov +` / `fov -`).
- `--dry-run` for setting values, `apply`, `defaults` and `undo`; prints `NAME old -> new`, writes nothing.
- `brioctl undo` puts back what the last changing command replaced (`~/.config/brioctl/undo`, serial masked).
- `--save` after a change runs `brioctl save`, so `watch` keeps it.
- `brioctl install-skill [--uninstall]` copies the AI agent skill into every existing `~/.claude/skills` and
  `~/.codex/skills`.

### Changed

- `undo` keeps the value from before the first write of a control within one command.
- `make` with no target builds the CLI.
- `-N` on a named control (`fov -1`) exits with status 2; `-N` on an unsigned number (`warmth -1`) is relative.

## 1.1.0 — 2026-11-02

### Added

- Any UVC camera. `brioctl list [--json]` shows every USB device with a VideoControl interface, with its model and
  support level (`full`, `experimental`, `standard`). The global `--camera ID` (index, serial number or location
  `0x…`, anywhere in the line) chooses one for every command. Without it brioctl uses the only camera, or the only
  one it knows, or prints the list and exits with status 2.
- The standard controls a camera has are read from the control bitmaps (`bmControls`) of its camera terminal and
  processing unit. `show`, `--json`, `save`, `defaults` and `snapshot` list only what the camera declares, with its
  own ranges (`GET_MIN`, `GET_MAX`, `GET_RES`, `GET_DEF`). New controls: `hue`, `hueauto`, `gamma`, `iris`, `roll` and
  `privacy`. `ae` also takes `shutter` and `flicker` also `off` and `auto` where the camera lists them. See
  `docs/registers.md`.
- `hdr` and `backlight` are one control (UVC backlight compensation). It is called `hdr` on the Logitech models with an
  HDR switch and `backlight` on the others, and both names, and both styles of value (`on` and `off`, or numbers),
  work on every camera.
- `pan` and `tilt` accept decimals, rounded to the camera's unit (arc seconds). The MX Brio may accept whole degrees
  only.
- `privacy` is only set on purpose, by name on the command line or by `apply`: `save` does not write it, `defaults`
  does not reset it and `watch` does not apply it.
- Experimental support for the Logitech Brio (`085e`), Brio 500 (`0943`), Brio 501 (`0946`), Brio 505 (`0919`) and
  Brio 4K Stream Edition (`086b`), from what other projects report (cameractrls v0.6.10 and OpenLogi issue 1222) and
  not tested with brioctl: the field of view on all of them, Show Mode on the Brio 500. `brioctl snapshot` reports
  are welcome. Extension units are written only on models of this table, only after `GET_LEN` and the write bit of
  `GET_INFO` agree, and never with a value taken from `GET_MAX`.
- `save` writes a `# camera VID:PID SERIAL` line, and `apply` warns about a file saved from another model.
- `watch` works with any camera. It sees video start through CoreMediaIO (`DeviceIsRunningSomewhere`, no camera
  permission needed) as well as through the MX Brio's HID report, and one start gives one apply. It follows the chosen
  camera, found again after a reconnect by vendor id, product id and serial number. Without `--camera` it follows the
  only camera with full support, or else the only one with experimental support; with no such camera, or no clear
  choice, it says why once and waits.
- `--json` contract for scripts and the app: `device` has `vid`, `pid`, `name`, `support`, `index` and `location`;
  every setting has `value`, `default`, `auto`, `writable`, `group`, `kind` (`number`, `choice` or `bool`), `help` and
  `min`, `max`, `step` or `choices`; the four `status` fields are null on cameras other than the MX Brio; boolean
  values are the strings `"on"` and `"off"`. New: `list --json` and `profiles --json`.
- `import optionsplus [DB] [--save NAME]` turns the camera settings saved by Logi Options+ (2.9, `settings.db` in
  `~/Library/Application Support/LogiOptionsPlus`) into a settings file for `apply`, on stdout or in
  `~/.config/brioctl/NAME`. It needs no camera and opens the database read-only and immutable, with SQLite's JSON
  functions. Up to 21 settings come from the selected presets; manual exposure and gain, manual focus, pan and tilt
  away from the centre, RightSight and the app's own options are listed as `# skipped:` notices on stderr, and manual
  white balance is taken with a `# check:` notice. It warns when `settings.db-wal` exists, because Logi Options+ is then
  running and its latest changes are not read. Logi Tune keeps no settings file and cannot be imported.
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
- Snapshots have `device`, `name` and `serial` lines (snapshots from 1.0 still load). `BRIOCTL_FAKE` takes several
  snapshots separated by `:`, and `make fixtures` writes a generic UVC camera, one with more standard controls and a
  simulated Brio 500 for the tests.

### Changed

- A number is written only inside the `GET_MIN` to `GET_MAX` range the camera reports. A control that reports no range
  is refused (`range unknown, not writing`), and `save` leaves such a number out. A standard control that `GET_INFO`
  says cannot be written is refused too.
- `show` prints what the camera accepts: ranges and the names of values come from the camera, not from a fixed text.
  `brioctl help` lists every setting name. `brightness` is signed, as UVC defines it.
- `factory-reset` refuses every camera but the MX Brio. `dump` asks every register of an extension unit it does not
  know only for `GET_INFO` and `GET_LEN`.
- brioctl links the system `libsqlite3` and the CoreMediaIO framework.

### Fixed

- JSON strings from USB descriptors (product name, serial number) with non-ASCII characters were escaped byte by byte
  and came out as the wrong characters. Valid UTF-8 now becomes `\uXXXX` escapes and anything else U+FFFD.
- A number that overflowed when scaled (`pan` and `tilt` are multiplied by 3600) could wrap into the range and be
  written. It is refused now.
- With two MX Brios connected, `watch` reacted to the HID video report of either one. It listens only to the camera it
  follows.

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
