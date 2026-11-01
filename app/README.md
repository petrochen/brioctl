# brioctl menu bar app

A SwiftUI menu bar app for [brioctl](../README.md). It draws the settings of a camera, changes them through the
`brioctl` inside the app bundle, and adds global hotkeys, a `brioctl://` URL scheme, launch at login and an optional
`brioctl watch` LaunchAgent. What it does for a user is described in the [main README](../README.md#menu-bar-app); this
file is for building and changing it.

It is a Swift package (tools version 5.9, Swift 5 language mode, macOS 13 or later) with no dependencies.

## Build

```sh
make          # build/brioctl.app: universal (arm64 and x86_64), ad-hoc signed
make zip      # build/brioctl-app-VERSION.zip, the file of the GitHub release and of the Homebrew cask
make clean
```

From the repository root, `make app`, `make app-zip` and `make test-app` run the same targets. `make` and `make test`
in the root do not build the app.

The bundle holds `Contents/MacOS/brioctl-app`, the CLI built from `../brioctl.c` as `Contents/Resources/brioctl`
(universal, the same `VERSION`), the license and an `Info.plist` made from `Resources/Info.plist.in`. The Makefile
signs it with `codesign --force --deep -s -` and checks it with `codesign --verify --deep --strict`. There is no
Apple Developer account, so the app is not notarized. `VERSION` is a plain assignment in the Makefile; give another
one on the command line (`make zip VERSION=1.1.1`) and the CLI inside is rebuilt with it.

## Run it while developing

Never develop against a real camera. Build the fake CLI (the same source with `-DBRIOCTL_FAKE`: a camera read from a
snapshot file, no USB), and point the app at it. The app reads four environment variables, all in
`Sources/BrioctlCore/AppEnvironment.swift`:

| Variable                     | Meaning                                                                         |
| ---------------------------- | ------------------------------------------------------------------------------- |
| `BRIOCTL_APP_CLI`            | The `brioctl` to run instead of `Contents/Resources/brioctl`.                   |
| `BRIOCTL_APP_AGENTS_DIR`     | The directory of the LaunchAgent plists instead of `~/Library/LaunchAgents`.    |
| `BRIOCTL_APP_DEFAULTS_SUITE` | A UserDefaults suite instead of the app's own preferences.                      |
| `BRIOCTL_FAKE`               | Not read by the app. The fake CLI inherits it: snapshot files separated by `:`. |

```sh
make -C .. tests/brioctl-fake
swift build
D=$(mktemp -d)
mkdir $D/home $D/agents
cp ../tests/mxbrio-1.1.394.snap $D/camera1.snap     # writes go to the copy
cp ../tests/generic-uvc.snap $D/camera2.snap        # optional second camera
BRIOCTL_FAKE=$D/camera1.snap:$D/camera2.snap \
BRIOCTL_APP_CLI=$PWD/../tests/brioctl-fake \
BRIOCTL_APP_AGENTS_DIR=$D/agents \
BRIOCTL_APP_DEFAULTS_SUITE=com.github.petrochen.brioctl.app.dev \
HOME=$D/home \
"$(swift build --show-bin-path)/brioctl-app"
```

The menu bar icon appears and the app runs until you quit it from the window or stop the process. With
`BRIOCTL_APP_AGENTS_DIR` set, "Launch at login" and "Re-apply settings automatically" write their plists into the
temporary directory and the app never calls `launchctl`: the label of the watch agent is the one a real
`make agent` or Homebrew installation uses, so the real launchd must not be asked to load or unload it. The switch
still shows the plist, but nothing runs. (Without the variable the app talks to the real launchd, as it should.)

## Tests

```sh
make test       # builds ../tests/brioctl-fake, then swift test
```

About a hundred tests, about ten seconds. Nothing in them talks to a real camera, runs the real `launchctl` or writes to
the real `~/Library/LaunchAgents`:

- JSON decoding and the control mapping, against fixtures that are the real output of the fake CLI
  (`Tests/make-fixtures.sh` rewrites them).
- The camera store with a scripted CLI (`StubRunner`): arguments, errors per setting, slider debounce, the debounced
  `save` for auto-apply (also with temporary LaunchAgent directories).
- The same store and the app model against the fake CLI and snapshot copies in a temporary directory: changes reach the
  camera, URLs, hotkeys, several cameras, the settings file.
- LaunchAgent plists and the rules for agents the app did not install, with a recording stand-in for `launchctl`.
- Hotkey commands and URL parsing and validation.

`BRIOCTL_RENDER_DIR=/some/dir swift test --filter RenderTests` also draws the main window and the settings page into
PNG files (light and dark), to look at the layout without clicking.

## Smoke test

```sh
make smoke
```

It builds the app, then starts `build/brioctl.app` with `open`, with the environment variables above pointing at the
fake CLI and two emulated cameras. It sends the app `brioctl://` URLs (a cold start with a URL, `set`, `apply`,
`camera`, and URLs that must do nothing) and checks every result by reading the fake cameras. It checks that no
LaunchAgent was written and no settings file saved while there is no agent, then drops a Homebrew-style agent plist
into the temporary agents directory and checks that a change is saved to `~/.config/brioctl/settings` of the fake home
(and not for the standard camera that such an agent would not follow). Then it quits the app. Nothing is clicked. It
refuses to run when a copy of the app is already running, because that copy would receive the URLs.

## How it is built

1. `Sources/brioctl-app` has only the `@main` entry (a `MenuBarExtra` in window style) and the application delegate,
   which receives the `brioctl://` URLs.
2. `Sources/BrioctlCore` holds everything that can be tested, including the SwiftUI views (`Views/`).
3. `CLI.swift` builds the argument arrays (`CLIArguments`, no shell anywhere) and runs the CLI one command at a time
   (`ProcessCLIRunner`, 20 s timeout). Tests replace the runner.
4. `Models.swift` and `OrderedJSON.swift` decode `--json`, `list --json` and `profiles --json`; the JSON parser keeps
   the order of keys. The CLI's JSON is the only interface between the app and the camera.
5. `CameraStore` owns the state of the chosen camera: every write is one CLI call followed by a read of `--json`.
   Sliders wait 0.15 s for a pause. After a write it schedules one `save` a second later when an agent is installed.
6. `ControlMapping` picks the control for a setting from its kind and range.
7. `LaunchAgents.swift` writes and reads the plists for `brioctl watch` and for launch at login behind a `launchctl`
   protocol. It never changes an agent that `make agent` or Homebrew installed.
8. `Hotkeys.swift` registers the global hotkeys with Carbon's `RegisterEventHotKey`, which needs no Accessibility
   permission.
9. `URLCommand.swift` parses the URLs and keeps only what the current camera has; `AppModel` ties these pieces together.
10. `AppEnvironment` is the single place that reads the outside world, so tests and the smoke test can redirect it.
