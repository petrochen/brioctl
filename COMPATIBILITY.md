# Compatibility

brioctl has been tested on hardware with one camera, the Logitech MX Brio. The other Brio models below are known from
what other projects report and are marked experimental. Every other UVC camera gets the standard controls only.

`brioctl list` shows each connected camera with its support level (`full`, `experimental` or `standard`).

| Model                           | USB id      | Standard controls | FOV | Show Mode, HDR and others                   | `watch` | Status                   | Reported by |
| ------------------------------- | ----------- | ----------------- | --- | ------------------------------------------- | ------- | ------------------------ | ----------- |
| Logitech MX Brio                | `046d:0944` | yes               | yes | Show Mode, HDR, RightSight status, mic gain | yes     | full, tested on hardware | maintainer  |
| Logitech Brio 500               | `046d:0943` | yes               | yes | Show Mode, HDR                              | yes     | experimental, untested   | -           |
| Logitech Brio                   | `046d:085e` | yes               | yes | HDR                                         | yes     | experimental, untested   | -           |
| Logitech Brio 501               | `046d:0946` | yes               | yes | -                                           | yes     | experimental, untested   | -           |
| Logitech Brio 505               | `046d:0919` | yes               | yes | -                                           | yes     | experimental, untested   | -           |
| Logitech Brio 4K Stream Edition | `046d:086b` | yes               | yes | HDR                                         | yes     | experimental, untested   | -           |
| Any other UVC camera            | any         | those it declares | no  | no                                          | yes     | standard, untested       | -           |

Standard controls are the UVC controls the camera declares. FOV is the 90/78/65 switch, written on the experimental
models only after the camera confirms the control. `hdr` is the backlight compensation. `watch` works with any camera.

## Untested on hardware

Everything except the MX Brio is untested on hardware. Please report what you see with the
[camera report](https://github.com/petrochen/brioctl/issues/new?template=camera_report.yml) issue template. Reports
move a camera from untested to tested in this table and credit you in the "Reported by" column.
