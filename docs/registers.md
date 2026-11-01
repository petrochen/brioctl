# MX Brio register map

What the Logitech MX Brio (USB `046d:0944`) exposes over USB and what each control does. This is the reference
behind `brioctl`. It describes behaviour only: what you can read, what you can write, and what the camera does
about it. The last sections before "Not known" cover the other cameras: the
[experimental Logitech models](#experimental-models), the
[standard controls](#standard-controls-of-other-cameras) of any UVC camera and
[how `watch` sees video start](#video-start-through-coremediaio).

## Where this comes from

- Observing Logitech's desktop apps as they configure the camera.
- Analysing the camera firmware, for interoperability only.
- Tests on a real camera: reading and writing registers, watching USB and HID traffic, and measuring video frames.

Each fact is marked:

- **measured**: checked on a real camera, by reading or writing a register, by watching HID reports, or by measuring
  the video.
- **inferred**: taken from the apps or from the firmware analysis and not confirmed by a test on the camera, or only
  partly confirmed.
- **reported**: taken from another project's report about a camera other than the MX Brio. Not tested with brioctl.

The tests were done on one camera with firmware 1.1.394 (`01 01 8a 01`). Other firmware versions or other units
may differ, which is why `brioctl` checks the size and range of a control before it writes to it.

This is not official documentation. Logitech does not publish it.

## How registers are addressed

Everything uses standard USB Video Class (UVC) control requests on the VideoControl interface. The camera answers
them without being opened, also while video is streaming, and without root.

| Field           | Value                                                                                                                           |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `bmRequestType` | `0xA1` (device to host) for reads, `0x21` (host to device) for writes; type class, recipient interface                          |
| `bRequest`      | `SET_CUR` 0x01, `GET_CUR` 0x81, `GET_MIN` 0x82, `GET_MAX` 0x83, `GET_RES` 0x84, `GET_LEN` 0x85, `GET_INFO` 0x86, `GET_DEF` 0x87 |
| `wValue`        | selector << 8                                                                                                                   |
| `wIndex`        | unit id in the high byte, VideoControl interface number in the low byte                                                         |

- `GET_INFO` returns one byte: bit 0 the control can be read, bit 1 it can be written, bit 2 it is currently driven
  by an automatic mode (for example exposure while auto exposure is on).
- `GET_LEN` returns the size of an extension control in bytes (2 bytes, little endian). The standard controls do not
  answer it reliably, their sizes come from the UVC specification.
- Multi-byte values are little endian.
- Unit ids come from the configuration descriptor and are assigned by the camera. `brioctl` finds the extension units
  by GUID and does not rely on the ids below.

## USB interfaces

| Interface | Class                       | Use                                |
| --------- | --------------------------- | ---------------------------------- |
| 0         | VideoControl                | all registers in this document     |
| 1         | VideoStreaming              | the video                          |
| 2         | HID                         | stream and Show Mode notifications |
| 3         | vendor specific (`ff`/`ff`) | not used by brioctl                |
| 4, 5      | audio control and streaming | the microphone                     |

All measured. The HID interface has several Logitech vendor usage pages and a Telephony page with a headset usage
(a mute button and mute indicator for conferencing software). brioctl does not use any of them.

## Units and GUIDs

Unit ids as seen on firmware 1.1.394.

| Unit | Kind            | GUID                                   | Name used here       |
| ---- | --------------- | -------------------------------------- | -------------------- |
| 1    | camera terminal | -                                      | CT (standard UVC)    |
| 3    | processing unit | -                                      | PU (standard UVC)    |
| 2    | extension unit  | `2c49d16a-32b8-4485-3ea8-643a152362f2` | unit 2, no known use |
| 6    | extension unit  | `23e49ed0-1178-4f31-ae52-d2fb8a8d3b48` | AIT custom           |
| 8    | extension unit  | `69678ee4-410f-40db-a850-7420d7d8240e` | Device info          |
| 9    | extension unit  | `1f5d4ca9-de11-4487-840d-50933c8ec8d1` | Test Debug           |
| 10   | extension unit  | `49e40215-f434-47fe-b158-0e885023e51b` | Videopipe            |
| 11   | extension unit  | `ffe52d21-8030-4e2c-82d9-f587d00540bd` | Peripheral           |
| 21   | extension unit  | `5a6d654c-7e35-4d4e-810d-069d15e0f79b` | Video Statistics     |
| 22   | extension unit  | `29144c1f-658d-4f47-a40f-0ed339428bf0` | App Settings         |

The GUIDs are read from the descriptor (measured). The names are the ones Logitech's software uses (inferred).
Below, "Videopipe 5" means selector 5 of the Videopipe unit, and so on. The descriptor lists which selectors a unit
offers. A few selectors answer even though the descriptor leaves them out; they are marked "not in descriptor".

## Standard UVC controls

The camera terminal advertises zoom, absolute pan and tilt, exposure mode, exposure time, low-light priority,
absolute focus and autofocus. The processing unit advertises backlight compensation, brightness, contrast,
saturation, sharpness, gain, power line frequency, white balance temperature and automatic white balance. There is
no hue, gamma, iris, roll, privacy or shutter control. All of this was read from the descriptor and the controls
(measured). How brioctl decides which standard controls any other camera has is under
[Standard controls of other cameras](#standard-controls-of-other-cameras).

| brioctl name  | Unit / selector | Size | Values                                 | Notes                                                                                         |
| ------------- | --------------- | ---- | -------------------------------------- | --------------------------------------------------------------------------------------------- |
| `priority`    | CT / 3          | 1    | 0 = keep frame rate, 1 = keep exposure | low-light behaviour; see "What survives power loss"                                           |
| `ae`          | CT / 2          | 1    | 8 = auto, 1 = manual                   | exposure time and gain follow the mode                                                        |
| `exposure`    | CT / 4          | 4    | 3 to 2047, unit 100 microseconds       | writable only with `ae` manual; factory default 156                                           |
| `af`          | CT / 8          | 1    | 0 or 1                                 | default on                                                                                    |
| `focus`       | CT / 6          | 2    | 0 to 255                               | writable only with `af` off                                                                   |
| `zoom`        | CT / 0x0B       | 2    | 100 to 400 (100 = 1x)                  | digital zoom                                                                                  |
| `pan`, `tilt` | CT / 0x0D       | 8    | two signed 32-bit values, arc seconds  | range -72000 to 72000, step 3600 (-20 to 20 degrees); pan is the first value, tilt the second |
| `hdr`         | PU / 1          | 2    | 0 or 1                                 | backlight compensation; default on                                                            |
| `gain`        | PU / 4          | 2    | 0 to 255                               | writable only with `ae` manual                                                                |
| `flicker`     | PU / 5          | 1    | 1 = 50 Hz, 2 = 60 Hz                   | the camera's own default is 60 Hz                                                             |
| `brightness`  | PU / 2          | 2    | 0 to 255, default 128                  |                                                                                               |
| `contrast`    | PU / 3          | 2    | 0 to 255, default 128                  |                                                                                               |
| `saturation`  | PU / 7          | 2    | 0 to 255, default 128                  | see "Color Boost"                                                                             |
| `sharpness`   | PU / 8          | 2    | 0 to 255, default 128                  |                                                                                               |
| `awb`         | PU / 0x0B       | 1    | 0 or 1                                 | default on                                                                                    |
| `wb`          | PU / 0x0A       | 2    | 2800 to 7500 kelvin                    | writable only with `awb` off; factory default 5000                                            |

While an automatic mode drives a value (exposure, gain, white balance, focus), `GET_INFO` has bit 2 set and the
camera refuses writes to that value. `brioctl` shows such values with a `*`. Ranges and defaults are measured.

HDR is measured by video frames: with HDR on the shadows are lighter (10th percentile of luma 73 to 76 against 53 to
62 with it off) and the 90th percentile stays about the same (212 to 213 against 193 to 235).

The camera reports 1 to 2 as the range of anti-flicker (measured), so the standard's values 0 (off) and 3 (auto) are
not available.

## Videopipe (unit 10)

| Selector | Size | Range      | Meaning                                                                                                                         | Evidence            |
| -------- | ---- | ---------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| 1        | 1    | 0 to 1     | Color Boost, see below. Not in descriptor.                                                                                      | measured            |
| 2        | 1    | 0 to 1     | Factory optics calibration mode. Service register, never written.                                                               | inferred            |
| 3        | 1    | 0 to 1     | No effect. Not in descriptor.                                                                                                   | inferred            |
| 4        | 1    | 0 to 1     | RightLight. Writes are accepted and change nothing, see "RightLight".                                                           | measured            |
| 5        | 1    | 0 to 2     | Field of view: 0 = 90 degrees, 1 = 78, 2 = 65. The register reports 0 to 255 as its range.                                      | measured            |
| 6        | 2    | 100 to 400 | Zoom. Mirrors the standard zoom: both read the same value.                                                                      | measured            |
| 8        | 6    | -          | Unclear, probably crop size. Not written.                                                                                       | inferred            |
| 9        | 2    | -          | Unclear. Not written.                                                                                                           | inferred            |
| 10       | 2    | -          | Read-only, constant 1.                                                                                                          | measured            |
| 11       | 2    | 50 to 80   | JPEG quality of the MJPEG stream. Reads 70 during video and 0 when video is off. Writes do not stick, the camera sets it again. | measured / inferred |
| 12       | 1    | 0 to 1     | No effect.                                                                                                                      | inferred            |
| 13       | 1    | 0 to 1     | Show Mode on or off. Factory value on, although `GET_DEF` says 0.                                                               | measured            |
| 18       | 1    | 0 to 100   | Tint. Default 50.                                                                                                               | measured            |
| 19       | 1    | 0 to 255   | Exposure compensation. Default 128.                                                                                             | measured            |
| 20       | 1    | 0 to 255   | Vibrance. Default 128.                                                                                                          | measured            |
| 21       | 1    | 0 to 100   | White balance warmth. Default 50.                                                                                               | measured            |

The field of view is a digital crop, and selector 6 is calculated relative to it (both inferred).

Warmth is measured by video frames (YUV chroma, mean U / V): warmth 0 gives 146 / 82 (blue), 50 gives 118 / 134,
100 gives 87 / 160 (warm).

Selectors 7, 17 and 22 (image stabilisation, automatic rotation, pause) exist on other Logitech cameras and are absent
from this camera's descriptor (measured). Videopipe 5, 13 and 18 to 21 are the selectors Logitech's apps use for the
settings of the same names (inferred); reading and writing them works on the camera (measured).

## Peripheral (unit 11)

| Selector | Size | Range                             | Meaning                                                                                                     | Evidence |
| -------- | ---- | --------------------------------- | ----------------------------------------------------------------------------------------------------------- | -------- |
| 3        | 3    | byte 0: 0 or 1; speed 10 to 100   | Smooth zoom and pan, see "Smooth zoom and pan".                                                             | measured |
| 6        | 2    | -                                 | Read-only, 0, unused.                                                                                       | measured |
| 7        | 3    | -                                 | Lens motor and lens memory service commands. Never written.                                                 | inferred |
| 9        | 6    | -                                 | Indicator LED, see "LED". Byte 1 is 1 while the LED is on.                                                  | measured |
| 12       | 8    | two signed 32-bit values, +-72000 | Another pan / tilt pair. Writing it changes an internal framing mode whose meaning is unknown. Not written. | inferred |
| 15       | 12   | -                                 | Audio block: mono or stereo and noise-processing parameters. Not written, a wrong value spoils the sound.   | inferred |
| 16       | 1    | 0 to 1                            | Camera microphone on or off. Changing it restarts the camera, see "Microphone".                             | inferred |
| 17       | 1    | 0 to 1                            | Restart. Never written, see "Registers brioctl never writes".                                               | inferred |
| 18       | 1    | 0 to 1                            | Audio LED flag. The camera stores it and nothing uses it.                                                   | inferred |
| 24       | 4    | byte 0: 0 or 1                    | RightSight Ctl, see "RightSight".                                                                           | inferred |

Selectors 1 and 2 (button triggers) and 26 (noise suppression level) exist on other Logitech cameras and are absent
from this one (measured).

## Device info (unit 8)

| Selector | Size | Meaning                                                                              | Evidence |
| -------- | ---- | ------------------------------------------------------------------------------------ | -------- |
| 1        | 4    | Firmware version: major, minor, 16-bit build. `01 01 8a 01` is 1.1.394.              | measured |
| 2, 4, 5  | 2    | Constants.                                                                           | measured |
| 6        | 6    | USB ids: vendor `046d`, product `0944`, device release `0021` (little endian words). | measured |
| 7        | 12   | Serial number, ASCII. This is why `snapshot` replaces it with zeros.                 | measured |
| 8        | 9    | Security information. Not used.                                                      | measured |
| 9, 10    | 2, 4 | Constants (9 is also part of a service data channel).                                | measured |
| 11       | 1    | Body colour code. 2 on the camera tested.                                            | measured |
| 12       | 1    | Factory reset: see "Factory reset". Only `0xAA` is ever written.                     | measured |
| 13       | 17   | Flash lock: a 16-byte key and a "locked" byte. Never written.                        | inferred |
| 14       | 1    | 1 while the camera is tilted to the desk and shows it (Show Mode active).            | measured |

Info 3 (not in descriptor) and 9 are a service data channel shared with Test Debug; brioctl does not use them.
Selector 13 reads as locked (last byte 1) on the camera tested.

## Video Statistics (unit 21) and App Settings (unit 22)

**Video Statistics 1** (6 bytes, read-only). Byte 0 is 1 while video is streaming. Byte 1 was always 2. Bytes 2 to 3
and 4 to 5 are the width and height of the current or last stream. Measured: `01 02 80 07 38 04` while a camera app
was open (1920 x 1080); the previous stream was 1280 x 720. After a power loss all bytes are zero.

**Video Statistics 2** (1 byte, read-only, 1): the state of an output pin of the camera's chip (inferred). It is
not the shutter: it stays 1 with the shutter closed (measured).

**App Settings 1** (30 bytes): the settings block of Logitech's RightSight application. The camera only stores it
and passes it on to that application (inferred). Layout as seen with Logitech's app (inferred): byte 0 marker (1),
byte 1 enabled, byte 2 speed (0 slower, 1 normal, 2 faster), byte 3 framing (0 closer, 1 normal, 2 further);
bytes 4 and 5 say which program stored it. The block is empty after a power loss (measured). brioctl only reads
it, for the `rightsight` line in its status.

## Other units

- **Unit 2** (`2c49d16a-...`): four-byte values that look like memory pointers; no known use. Never written.
- **AIT custom** (unit 6): chip commands and the firmware update channel. Selector 10 reads back a short ASCII
  identifier. Never written.
- **Test Debug** (unit 9): direct access to chip registers, lens memory, sensor and image-processing debug
  switches. On a retail unit the camera ignores most of it (see "Flash lock"). Never written.

## HID reports

Input reports on interface 2. The camera sends nothing while no video is running.

| Report | When                                                                                          | Content                                                                                                                                | Evidence |
| ------ | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `0x40` | Video starts: `40 10`, then `40 02` about 160 ms later. About 3 s after video stops: `40 14`. | Stream state.                                                                                                                          | measured |
| `0x55` | The camera is tilted to the desk and back.                                                    | Byte 5 is 1 when tilted, 0 when back. Example: `55 00 00 a4 00 01 00`.                                                                 | measured |
| `0x0a` | After a Show Mode change.                                                                     | Records of number, length, value: 1 zoom (2 bytes), 2 field of view, 3 flip (0 or 1), 4 and 5 four bytes each (probably pan and tilt). | measured |

Writing RightSight Ctl makes the camera send `40 18` (inferred). `brioctl watch` listens to report `0x40` only: after
`10` or `02` it waits 2 seconds and applies the settings file again. Only the MX Brio is known to send it. For every
camera, `watch` also sees video start through CoreMediaIO, see
[below](#video-start-through-coremediaio).

## Behaviour

### Show Mode

Measured. When the camera is tilted to the desk, report `0x55` arrives. About one second later the camera sets the
field of view to 65 degrees and zoom to 100 on its own, and Device info 14 becomes 1. When the camera is tilted back,
the previous field of view and zoom (78 degrees and 115 in the test) come back and Device info 14 returns to 0. The
picture flip that Show Mode is meant to produce was not checked by eye. The register changes were. The camera does
all of this by itself; Logitech's app only shows a notification (inferred).

### Color Boost

Videopipe 1 (not in descriptor). Measured with video frames (mean saturation of the frame):

| Setting                  | Mean saturation |
| ------------------------ | --------------- |
| saturation 128 (default) | 24.5            |
| Color Boost on           | 49.2            |
| `saturation 255`         | 49.2            |

Color Boost does not change the stored saturation. It sends the image processor twice the saturation, capped at 255
(inferred), so `saturation 255` gives the same picture from the default 128, and unlike Color Boost the camera keeps
it. Color Boost is lost easily (all measured):

- Writing any saturation while it is on removes the effect (24.3 to 24.7), although the register still reads 1.
- Written while no video runs, it does nothing once video starts (25.2).
- Written during video it works (48.9) until the video restarts, then it is gone (25.6) while the register still
  reads 1.

For that reason `brioctl` offers it only as the preset `colorboost`, which is `saturation 255`.

### Smooth zoom and pan

Peripheral 3: byte 0 turns the glide on, bytes 1 to 2 are a speed from 10 to 100 (the camera clamps it, factory value
50). Measured by frame differences: with it off, zoom 115 to 300 and pan -10 to 10 degrees happen within one frame.
With it on they take about 2.8 s for zoom and 3 s for pan. Speed 10, 50, 100 and even 0 gave the same time, so the
speed field has no measurable effect on manual zoom and pan; `brioctl` does not offer it. The setting is not stored:
after a power loss it is off and the speed field reads 0 until the first write. The speed may matter to RightSight's
own framing movements (inferred).

### Microphone

Peripheral 16 turns the camera microphone on or off. The camera stores the value and restarts about two seconds
later, because the set of USB interfaces changes (inferred). `brioctl` therefore writes `mic` last, and `watch`
never changes it while video is on. The input volume is not a camera register: macOS keeps it, and `micgain` sets it
through CoreAudio.

### RightSight

Automatic framing is done by Logitech's desktop software on the computer, not by the camera (inferred). It moves
the frame with zoom, pan and tilt. The camera only stores the settings block (App Settings 1).

Peripheral 24 byte 0, "RightSight Ctl", is a flag that the software sets when it is in charge of framing. While it
is set and no video is running, the camera ignores zoom and pan/tilt writes (inferred, from the firmware analysis).
When `brioctl` sees a zoom or pan value that did not stick and the flag is set, it says so.

### LED

Peripheral 9, byte 1 reads 1 while video runs and 0 otherwise. Writing mode 0 (off) or 2 (blink) during video is
accepted without an error and ignored: the LED stays on and the register keeps its value (measured). The camera is
in a locked state (see "Flash lock") in which it drops LED writes (inferred). LED control is therefore not
available on this camera.

### RightLight

Videopipe 4 accepts a write of 1 and holds it. At normal light the picture, the exposure time (15.6 ms) and the gain
did not change (measured). The camera does nothing with the value (inferred). RightLight has no effect in this
firmware.

### Shutter

The built-in privacy shutter is not reported by any register or HID report. Closing it changed only the exposure
time (measured). There is no UVC privacy control.

### Flash lock

Device info 13 holds a key and a flag. On retail units the flag is set. A locked camera drops LED writes and most
Test Debug commands (inferred). Writing a key changes the lock, so brioctl never touches it.

### Factory reset

Device info 12: writing `0xAA` erases the saved settings and restarts the camera. Measured: the write returned
without an error, the camera left the USB bus and was back after 0.7 s with field of view 90 degrees, zoom 100,
warmth 50, anti-flicker 60 Hz and low-light priority "frame rate". Show Mode and the microphone were on afterwards,
although `GET_DEF` reports 0 for both: they are the camera's own defaults when nothing is stored. For this reason
`brioctl defaults` leaves those two alone. `brioctl factory-reset --yes` saves your settings first, writes `0xAA`,
waits for the camera and applies the saved file.

## What survives power loss

The camera writes changed settings to flash a few seconds after the change (inferred), which is why `brioctl` does
not write a value that is already set.

Measured: after the camera was unplugged for 5 to 10 seconds, every setting `brioctl` writes was still there, except
low-light priority, which went back to 0 (frame rate). The firmware stores it too (inferred), so the cause of the
reset is unknown; it may be the computer that sets it when the camera connects. `brioctl watch` writes it back.

Also not stored (measured): smooth zoom and pan, Color Boost, and the RightSight block.

Stored (inferred from the firmware analysis, except where the test above covers it): HDR, brightness, contrast,
anti-flicker, saturation, sharpness, zoom, pan, tilt, field of view, Show Mode, exposure mode, exposure time and
gain (only in manual mode), low-light priority, autofocus, focus, white balance mode and temperature, microphone,
tint, exposure compensation, vibrance and warmth.

## Factory defaults

What the camera uses when nothing is stored, for example after a factory reset. Rows marked measured were read from
the camera after `factory-reset`; the others come from the firmware analysis (inferred).

| Setting                                     | Default             | Evidence                              |
| ------------------------------------------- | ------------------- | ------------------------------------- |
| Field of view                               | 90 degrees          | measured                              |
| Zoom, pan, tilt                             | 100, 0, 0           | measured (zoom), inferred (pan, tilt) |
| Warmth                                      | 50                  | measured                              |
| Anti-flicker                                | 60 Hz               | measured                              |
| Low-light priority                          | frame rate          | measured                              |
| Show Mode                                   | on                  | measured                              |
| Microphone                                  | on                  | measured                              |
| HDR                                         | on                  | inferred                              |
| Brightness, contrast, saturation, sharpness | 128                 | inferred                              |
| Tint                                        | 50                  | inferred                              |
| Exposure compensation, vibrance             | 128                 | inferred                              |
| Auto exposure; exposure time                | auto; 156 (15.6 ms) | inferred                              |
| Autofocus, auto white balance               | on                  | inferred                              |
| White balance temperature                   | 5000 K              | inferred                              |

## Registers brioctl never writes

`brioctl` writes only the controls in its own table. It reads a control's size with `GET_LEN` first and refuses to
write if the size is not what it expects. `dump` asks service registers only for `GET_INFO` and `GET_LEN`, and
`snapshot` never reads values of the factory reset or the flash lock.

| Register          | What it does                                                                                                                                       |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Test Debug (all)  | Direct access to chip registers, lens memory, sensor and image-processing switches.                                                                |
| AIT custom (all)  | Chip commands and the firmware update channel. A wrong write can damage the camera.                                                                |
| Device info 12    | Factory reset. brioctl writes `0xAA` only for `factory-reset --yes`, after saving your settings.                                                   |
| Device info 13    | Flash lock. A key locks or unlocks it.                                                                                                             |
| Peripheral 7      | Lens motor and lens memory service commands, including writes to the lens memory.                                                                  |
| Peripheral 17     | Restarts the camera when a non-zero value is written. On another Logitech camera (StreamCam) others report it as a factory reset.                  |
| Videopipe 2       | Switches to the factory optics calibration mode.                                                                                                   |
| Unit 2            | Unknown.                                                                                                                                           |
| Peripheral 12, 15 | Unknown framing mode and the audio block. Wrong values distort the sound or the framing.                                                           |
| Other cameras     | Every extension unit of a camera that is not in the model table, and every register of an unknown GUID. `dump` asks only `GET_INFO` and `GET_LEN`. |

## Experimental models

`brioctl` knows six Logitech models by their USB product id (vendor `046d`). The MX Brio is `full`: the register notes
above are about it. The other five are `experimental`: brioctl writes only the extension controls that other projects
report for them, and the standard controls the camera declares. Nothing here was tested with brioctl (evidence:
reported), and nothing in the table is known for these cameras beyond the sources below.

| Model                  | Product id | `fov` (Videopipe 5) | `showmode` (Videopipe 13) | Backlight compensation is named | Source                      |
| ---------------------- | ---------- | ------------------- | ------------------------- | ------------------------------- | --------------------------- |
| MX Brio                | `0944`     | yes                 | yes                       | `hdr`                           | measured (this document)    |
| Brio 500               | `0943`     | yes                 | yes                       | `hdr`                           | cameractrls, OpenLogi #1222 |
| Brio                   | `085e`     | yes                 | no                        | `hdr`                           | cameractrls                 |
| Brio 501               | `0946`     | yes                 | no                        | `backlight`                     | cameractrls                 |
| Brio 505               | `0919`     | yes                 | no                        | `backlight`                     | cameractrls                 |
| Brio 4K Stream Edition | `086b`     | yes                 | no                        | `hdr`                           | cameractrls                 |

"yes" means brioctl offers the setting for the model; "no" means it does not, which says nothing about the camera.

Sources:

- **cameractrls** v0.6.10 (`cameractrls.py` in [soyersoyer/cameractrls](https://github.com/soyersoyer/cameractrls)).
  The list `LOGITECH_BRIO_FOV_DEV_MATCH` names these product ids and no others for the field of view: `046d:085e`
  (Brio), `046d:0943` (Brio 500), `046d:0946` (Brio 501), `046d:0919` (Brio 505), `046d:086b` (Brio 4K Stream Edition)
  and `046d:0944` (MX Brio). The control is selector `0x05` of the extension unit with the GUID
  `49e40215-f434-47fe-b158-0e885023e51b`, one byte at offset 0: `0x00` is 90 degrees, `0x01` is 78, `0x02` is 65. That
  GUID is the Videopipe unit above.
- **OpenLogi issue 1222** ([AprilNEA/OpenLogi](https://github.com/AprilNEA/OpenLogi/issues/1222)), from a Brio 500
  (`046d:0943`). A read-only probe of the same unit found the field of view at selector 5 (one byte, readable and
  writable, `GET_MIN` 0, `GET_MAX` 255, `GET_DEF` 0) and Show Mode at selector 13 (one byte, `GET_MIN` 0, `GET_MAX` 1,
  `GET_DEF` 0). Writes of 3 or 255 to the field of view succeed on the wire and are discarded, so the reported range
  cannot be used. The issue also says the HDR switch of Logi Tune on that camera is not an extension control: it
  writes the backlight compensation of the processing unit.

What brioctl does with this:

- **Extension writes.** `fov` on all six models, `showmode` on the MX Brio and the Brio 500. Nothing else is written to
  an extension unit of an experimental camera: warmth, tint, vibrance, exposure compensation, `mic`, `smooth`, the
  status registers and `micgain` are for the MX Brio only, because their layout on the other cameras is not known.
- **Guards.** The unit must be in the descriptor (found by GUID), `GET_LEN` must be 1 and `GET_INFO` must have the write
  bit. The values come from brioctl's table (0, 1, 2 for the field of view, 0 and 1 for Show Mode), never from `GET_MAX`.
  After the write the value is read back.
- **HDR.** On a model with an HDR switch the standard backlight compensation control is named `hdr` (on, off). OpenLogi
  confirms that for the Brio 500. The Brio and the Brio 4K Stream Edition follow the same naming by assumption (evidence:
  reported at most); the Brio 501 and 505 use `backlight` (a number). It is the standard control either way, it exists
  only if the camera declares it, and both names work on every camera.
- **Reports.** `brioctl snapshot report.snap` writes the descriptor and every register brioctl reads, with the serial
  number masked. That is what is needed to confirm or correct a row.

## Standard controls of other cameras

For any UVC camera, `brioctl` walks the configuration descriptor, takes the first VideoControl interface, in it the first
camera terminal (input terminal of type `0x0201`) and the first processing unit, and reads their `bmControls`. A
standard control exists for brioctl when the camera declares its bit. The bit numbers are those of UVC 1.5, tables 3-6
(camera terminal) and 3-8 (processing unit); they do not follow the selector numbers. The camera terminal's
`bControlSize` is at offset 14 of its descriptor and its bitmap starts at 15; the processing unit's is at 7 and 8.

Camera terminal (CT):

| Bit | Selector | brioctl name  | Size | Notes                                     |
| --- | -------- | ------------- | ---- | ----------------------------------------- |
| 1   | `0x02`   | `ae`          | 1    | the modes come from `GET_RES`, see below  |
| 2   | `0x03`   | `priority`    | 1    | 0 = keep frame rate, 1 = keep exposure    |
| 3   | `0x04`   | `exposure`    | 4    | absolute, units of 100 microseconds       |
| 5   | `0x06`   | `focus`       | 2    | absolute                                  |
| 7   | `0x09`   | `iris`        | 2    | absolute, f-number times 100              |
| 9   | `0x0B`   | `zoom`        | 2    | absolute                                  |
| 11  | `0x0D`   | `pan`, `tilt` | 8    | two signed 32-bit values, arc seconds     |
| 13  | `0x0F`   | `roll`        | 2    | absolute, signed, degrees                 |
| 17  | `0x08`   | `af`          | 1    | autofocus                                 |
| 18  | `0x11`   | `privacy`     | 1    | privacy shutter, many cameras only report |

Processing unit (PU):

| Bit | Selector | brioctl name        | Size | Notes                                    |
| --- | -------- | ------------------- | ---- | ---------------------------------------- |
| 0   | `0x02`   | `brightness`        | 2    | signed                                   |
| 1   | `0x03`   | `contrast`          | 2    |                                          |
| 2   | `0x06`   | `hue`               | 2    | signed; writable only with `hueauto` off |
| 3   | `0x07`   | `saturation`        | 2    |                                          |
| 4   | `0x08`   | `sharpness`         | 2    |                                          |
| 5   | `0x09`   | `gamma`             | 2    |                                          |
| 6   | `0x0A`   | `wb`                | 2    | writable only with `awb` off             |
| 8   | `0x01`   | `hdr` / `backlight` | 2    | backlight compensation, see above        |
| 9   | `0x04`   | `gain`              | 2    |                                          |
| 10  | `0x05`   | `flicker`           | 1    | power line frequency                     |
| 11  | `0x10`   | `hueauto`           | 1    |                                          |
| 12  | `0x0B`   | `awb`               | 1    |                                          |

The relative controls, scanning mode, white balance component, digital multiplier and the other bits are not used.

How the values are read:

- Range, step and default come from the camera each time: `GET_MIN`, `GET_MAX`, `GET_RES`, `GET_DEF`. A number is
  written only inside the range the camera reported, so a camera that does not answer `GET_MIN` and `GET_MAX` gets no
  numeric writes. `GET_INFO` says whether a control can be written (bit 1) and whether an automatic mode drives it now
  (bit 2).
- Named values are offered only if the camera accepts them. Power line frequency: 0 `off`, 1 `50`, 2 `60`, 3 `auto`,
  limited to the range the camera reports. Exposure mode: the bit mask in `GET_RES` lists the modes (1 manual, 2 auto,
  4 shutter priority, 8 aperture priority); `auto` is mode 8 on the Logitech cameras and mode 2 on most others (mode 8
  if the camera lists both), `manual` is 1 and `shutter` is 4.
- Zoom is the camera's own scale. 100 is 1x on the Logitech cameras.
- The Logitech extension units are used only on the models in the table above. On every other camera they are not
  written, and `dump` asks an unknown unit for `GET_INFO` and `GET_LEN` only.

## Video start through CoreMediaIO

`brioctl watch` applies your settings again when video starts, because image settings can be lost with the stream. The
MX Brio announces a start with HID report `0x40` (see above). Other cameras send no such report that brioctl knows, so
`watch` also uses CoreMediaIO, which lists every camera on macOS:

- **Device.** For a USB UVC camera the CoreMediaIO device UID is `0x`, the USB location id in hex without leading zeros,
  the vendor id and the product id as four hex digits each. The MX Brio at location `0x110000` is
  `0x110000046d0944`. The model UID is `UVC Camera VendorID_1133 ProductID_2372` (the ids in decimal) and the transport
  type is `usb ` (observed on macOS 26 with an MX Brio; the same form is assumed for other USB cameras). If the camera
  sits on another port than expected, `watch` takes the one USB device whose UID ends with the vendor and product id,
  provided there is exactly one.
- **Signal.** The property `kCMIODevicePropertyDeviceIsRunningSomewhere` is true while any process streams from the
  camera. `watch` reads it and listens for changes; a change from false to true is a video start. Reading and
  listening do not open the camera and need no camera permission. A second listener on the list of devices attaches
  the first one again when the camera is unplugged and connected.
- **One apply per start.** The HID report and CoreMediaIO feed the same 2 second timer: every signal restarts the wait,
  and a signal that arrives within 3 seconds after an apply has finished is ignored. So one start gives one apply,
  whichever signal comes first.

Evidence: the UID form was observed on one MX Brio (macOS 26). That the property changes when an app starts streaming is
inferred from its documented meaning; it was not tested with other cameras.

## Not known

- What the bytes of Videopipe 8 and 9, the audio block in Peripheral 15, Device info 3 and 9, and the framing mode set
  by Peripheral 12 mean.
- What the output pin behind Video Statistics 2 is connected to.
- Why low-light priority is lost on power loss.
- Whether the speed field in Peripheral 3 matters for anything.
- The HID reports `0x41` to `0x47`, `0x01` and `0x9a` never appeared during testing.

## Related sources

- cameractrls (Linux) documents the field of view and LED selectors. Its list of Brio product ids is the source of the
  [experimental models](#experimental-models).
- OpenLogi issue 1222 (a Brio 500) documents the field of view, Show Mode and the HDR switch of that camera.
- libwebcam's Logitech XML describes the older Logitech extension units. Some selectors were reused for other
  functions on newer cameras (Videopipe 5 was RightLight ZOI there and is the field of view here), so a size check is
  required before writing anything.
