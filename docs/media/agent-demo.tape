# VHS tape for docs/media/agent-demo.gif: the agent loop (read, auto, verify, undo).
# Render with `make demo-gif` (add this target: `demo-gif: tests/brioctl-fake` then `vhs docs/media/agent-demo.tape`).
# Run it from the repository root. It uses the fake build, so no camera is touched:
#   BRIOCTL_FAKE points at a throwaway copy of tests/mxbrio-1.1.394.snap, and the `brioctl` alias runs tests/brioctl-fake.
# NOT rendered yet. The fake build has no camera: its `capture` draws a picture that follows the fake camera's expcomp
# and warmth, with one fixed face, so `auto` converges (expcomp 128 -> 152, warmth 62 -> 50 in two steps).
# Install vhs: brew install vhs

Output docs/media/agent-demo.gif

Set Shell "bash"
Set FontSize 16
Set Width 1200
Set Height 640
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set PlaybackSpeed 1

# Setup, hidden: fake camera, a `brioctl` command that is the fake build, a throwaway HOME for undo history.
Hide
Type "export PS1='$ ' HOME=$(mktemp -d) BRIOCTL_FAKE=$(mktemp -d)/camera.snap" Enter
Type "cp tests/mxbrio-1.1.394.snap $BRIOCTL_FAKE && alias brioctl=$PWD/tests/brioctl-fake" Enter
Type "clear" Enter
Show

Type "# 1. Read: how does my face look?" Enter
Sleep 600ms
Type "brioctl capture --json | jq '.avg.face | {y_mean, wb_bias}'" Enter
Sleep 2500ms

Type "# 2. Preview: auto measures and says what it would change. Nothing is written yet." Enter
Sleep 600ms
Type "brioctl auto --dry-run" Enter
Sleep 3000ms

Type "# 3. Act: up to 4 measured steps, kept with --save" Enter
Sleep 600ms
Type "brioctl auto --save" Enter
Sleep 3500ms

Type "# 4. Verify: measure again" Enter
Sleep 600ms
Type "brioctl capture --json | jq '.avg.face | {y_mean, wb_bias}'" Enter
Sleep 3000ms

Type "# Not better? The whole run is one undo" Enter
Sleep 600ms
Type "brioctl undo --dry-run" Enter
Sleep 3500ms
