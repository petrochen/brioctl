# Contributing

## Build and test

```sh
make            # the command-line tool, ./brioctl
make test       # offline tests against recorded camera snapshots, no camera needed
make app        # the menu bar app (needs Swift), build/brioctl.app
make test-app   # unit tests of the app
```

The tests never touch a real camera. They run the same source against snapshots in `tests/`.

## Report a camera

brioctl is tested on hardware with the MX Brio only. If you own another UVC camera, run `brioctl list`, try a few
settings and open a [camera report](https://github.com/petrochen/brioctl/issues/new?template=camera_report.yml). Attach
the output of `brioctl dump`, which only reads the camera. The current state of each model is in
[COMPATIBILITY.md](COMPATIBILITY.md).

You do not need to touch firmware or write to unknown registers for any of this, and please do not. brioctl writes only
the controls it knows.

## Bugs and ideas

Open a bug report with the output of `brioctl snapshot`. Questions and ideas go to Discussions.
