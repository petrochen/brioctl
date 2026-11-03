# Contributing

## Build and test

```sh
make            # the command-line tool, ./brioctl
make test       # offline tests against recorded camera snapshots, no camera needed
make app        # the menu bar app (needs Swift), build/brioctl.app
make test-app   # unit tests of the app
```

The tests never touch a real camera: the same source is built with `-DBRIOCTL_FAKE` and answers from the register
snapshots in `tests/` (`make fixtures` derives the others). `brioctl snapshot FILE` makes one for a bug report.

## Report a camera

Only the MX Brio is tested on hardware. With another UVC camera, run `brioctl list`, try a few settings and open a
[camera report](https://github.com/petrochen/brioctl/issues/new?template=camera_report.yml) with the output of
`brioctl dump` (read-only). Status per model: [COMPATIBILITY.md](COMPATIBILITY.md). Do not write to unknown registers.

## Bugs and ideas

Open a bug report with the output of `brioctl snapshot`. Questions and ideas go to Discussions.
