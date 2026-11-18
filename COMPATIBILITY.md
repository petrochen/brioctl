# Compatibility

brioctl has been tested on hardware with two cameras, the Logitech MX Brio and the Logitech StreamCam. The other
Logitech models below are known from what other projects report and from the list Logitech's own app keeps of what it
offers for each model; they are marked experimental. Every other UVC camera gets the standard controls only.

`brioctl list` shows each connected camera with its support level (`full`, `experimental` or `standard`).

| Model                               | USB id      | Standard controls | FOV | Show Mode, HDR and others                                                                         | `watch` | Status                   | Reported by |
| ----------------------------------- | ----------- | ----------------- | --- | ------------------------------------------------------------------------------------------------- | ------- | ------------------------ | ----------- |
| Logitech MX Brio                    | `046d:0944` | yes               | yes | Show Mode, HDR, warmth, tint, vibrance, exposure compensation, mic, smooth zoom, mic gain, status | yes     | full, tested on hardware | maintainer  |
| Logitech StreamCam                  | `046d:0893` | yes               | no  | HDR, image stabilisation, stereo microphone, orientation sensor                                   | yes     | full, tested on hardware | maintainer  |
| Logitech Brio 500                   | `046d:0943` | yes               | yes | Show Mode, HDR                                                                                    | yes     | experimental, untested   | -           |
| Logitech Brio                       | `046d:085e` | yes               | yes | HDR                                                                                               | yes     | experimental, untested   | -           |
| Logitech Brio 501                   | `046d:0946` | yes               | yes | Show Mode, HDR                                                                                    | yes     | experimental, untested   | -           |
| Logitech Brio 505                   | `046d:0919` | yes               | yes | Show Mode, HDR                                                                                    | yes     | experimental, untested   | -           |
| Logitech Brio 4K Stream Edition     | `046d:086b` | yes               | yes | HDR                                                                                               | yes     | experimental, untested   | -           |
| Logitech 4K Pro Magnetic            | `046d:087f` | yes               | yes | HDR                                                                                               | yes     | experimental, untested   | -           |
| Logitech MX Brio 705 for Business   | `046d:091d` | yes               | yes | Show Mode, HDR                                                                                    | yes     | experimental, untested   | -           |
| Logitech MX Brio (another id)       | `046d:0947` | yes               | yes | Show Mode, HDR                                                                                    | yes     | experimental, untested   | -           |
| Logitech Brio 920                   | `046d:0964` | yes               | yes | HDR                                                                                               | yes     | experimental, untested   | -           |
| Logitech Brio 920 for Business      | `046d:0998` | yes               | yes | HDR                                                                                               | yes     | experimental, untested   | -           |
| Logitech Brio 920 Plus              | `046d:099a` | yes               | yes | HDR                                                                                               | yes     | experimental, untested   | -           |
| Logitech Brio 920 Plus for Business | `046d:0999` | yes               | yes | HDR                                                                                               | yes     | experimental, untested   | -           |
| Logitech Reach                      | `046d:0948` | yes               | no  | HDR, image stabilisation, stereo microphone                                                       | yes     | experimental, untested   | -           |
| Any other UVC camera                | any         | those it declares | no  | no                                                                                                | yes     | standard, untested       | -           |

Standard controls are the UVC controls the camera declares. FOV is the 90/78/65 switch, written on the experimental
models only after the camera confirms the control. `hdr` is the backlight compensation. `watch` works with any camera.

## Untested on hardware

Everything except the MX Brio and the StreamCam is untested on hardware. Please report what you see with the
[camera report](https://github.com/petrochen/brioctl/issues/new?template=camera_report.yml) issue template and the
file `brioctl snapshot` writes: it is all brioctl needs to test itself with your camera. Reports move a camera from
untested to tested in this table and credit you in the "Reported by" column. To add the camera's own controls
yourself, see [CONTRIBUTING.md](CONTRIBUTING.md#add-a-camera).
