# Contributing

## Build and test

```sh
make            # the command-line tool, ./brioctl
make test       # offline tests against recorded camera snapshots, no camera needed
make app        # the menu bar app (needs Swift), build/brioctl.app
make test-app   # unit tests of the app
```

The tests never touch a real camera: the same source is built with `-DBRIOCTL_FAKE` and answers from the register
snapshots in `tests/` (`make fixtures` derives the generated ones). `brioctl snapshot FILE` makes one of your camera.

## Report a camera

Only the MX Brio and the StreamCam are tested on hardware. With another UVC camera, run `brioctl list`, try a few
settings and open a [camera report](https://github.com/petrochen/brioctl/issues/new?template=camera_report.yml) with
the file `brioctl snapshot` writes (read-only, serial number masked). Status per model:
[COMPATIBILITY.md](COMPATIBILITY.md). Do not write to unknown registers.

## Add a camera

A camera's own controls are a snapshot and a few lines of `brioctl.c`; `make test` then checks them without the camera.

1. `brioctl --camera ID snapshot tests/NAME.snap`: the descriptor and every register `dump` reads.
2. List what the camera has beyond the standard controls, as `STREAMCAM` does: name, unit, selector, size, values. Add
   its row to `MODELS`. A unit brioctl does not look for yet needs its GUID in `UNIT_GUID`.
3. Say where each control comes from (another project, the vendor's app, a measurement) in the comment above
   `MODELS` and in [docs/registers.md](docs/registers.md). Only a model checked on hardware is `tested`.
4. Add a test to `tests/run.sh` that reads and writes each new control on the snapshot (`t_streamcam` is the pattern)
   and the row to [COMPATIBILITY.md](COMPATIBILITY.md).

brioctl writes a register of an extension unit only where the model lists it, the camera reports the listed size and
says the register can be set. Firmware, debug, restart and reset registers are never offered, whatever a list says.

## Bugs and ideas

Open a bug report with the output of `brioctl snapshot`. Questions and ideas go to Discussions.
