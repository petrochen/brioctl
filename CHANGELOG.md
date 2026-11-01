# Changelog

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
