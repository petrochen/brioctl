# VHS tape for docs/media/agent-demo.gif: the agent loop (read, auto, verify, undo). Render from the repository root:
#   make tests/brioctl-fake && vhs docs/media/agent-demo.tape
# It uses the fake build, so no camera is touched: BRIOCTL_FAKE is a throwaway copy of tests/mxbrio-1.1.394.snap and
# `brioctl` is an alias of tests/brioctl-fake. The fake picture follows the fake camera's settings, so `auto` converges.

Output docs/media/agent-demo.gif

Set Shell "bash"
Set FontSize 15
Set Width 1200
Set Height 560
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

Type "# 3. Act: up to 4 measured steps" Enter
Sleep 600ms
Type "brioctl auto" Enter
Sleep 3500ms

Type "# 4. Verify: measure again" Enter
Sleep 600ms
Type "brioctl capture --json | jq '.avg.face | {y_mean, wb_bias}'" Enter
Sleep 3000ms

Type "# Not better? The whole run is one undo" Enter
Sleep 600ms
Type "brioctl undo --dry-run" Enter
Sleep 3500ms
