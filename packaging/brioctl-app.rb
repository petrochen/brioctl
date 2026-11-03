# Copy of Casks/brioctl-app.rb in petrochen/homebrew-tap. On a new release: update version and sha256
# (curl -sL <url> | shasum -a 256, or shasum -a 256 app/build/brioctl-app-<version>.zip) here and in the tap.
# The zip is built and attached to the GitHub release by CI (make app-zip).
# Written for the current Homebrew DSL (postflight_steps, depends_on macos: :ventura). Homebrew before 7 wants
# `postflight do system_command "/usr/bin/xattr", args: [...] end` and `depends_on macos: ">= :ventura"` instead.
cask "brioctl-app" do
  version "1.2.0"
  sha256 "f4b578329046aa125f10e4dd1ba3b386559d9cf268ae45dc1cb46beae0887b01"

  url "https://github.com/petrochen/brioctl/releases/download/v#{version}/brioctl-app-#{version}.zip"
  name "brioctl"
  desc "Menu bar app for Logitech MX Brio and other UVC webcams"
  homepage "https://github.com/petrochen/brioctl"

  depends_on macos: :ventura

  app "brioctl.app"

  # The app is ad-hoc signed and not notarized (no Apple Developer subscription). Gatekeeper would refuse to open a
  # quarantined copy without a trip to System Settings, so the quarantine attribute is removed after the install.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/brioctl.app"]
  end

  uninstall quit: "com.github.petrochen.brioctl.app"

  # Only what the app alone creates: its "Launch at login" agent (com.github.petrochen.brioctl.app), its defaults
  # domain and its caches. Left out on purpose: ~/Library/LaunchAgents/com.github.petrochen.brioctl.plist, the
  # `brioctl watch` agent. The CLI installs it under the same label (`make agent`), so zapping the app must not
  # remove the CLI's agent; the caveats tell the user to turn the app's own copy off before uninstalling. The same
  # goes for ~/.config/brioctl (the settings file) and ~/Library/Logs/brioctl.log, which the CLI shares.
  zap trash: [
    "~/Library/Caches/com.github.petrochen.brioctl.app",
    "~/Library/LaunchAgents/com.github.petrochen.brioctl.app.plist",
    "~/Library/Preferences/com.github.petrochen.brioctl.app.plist",
    "~/Library/Saved Application State/com.github.petrochen.brioctl.app.savedState",
  ]

  caveats <<~EOS
    brioctl.app is signed ad hoc and not notarized by Apple. Homebrew removes the quarantine attribute
    after installing it, so macOS opens it without the "unidentified developer" dialog. The source is
    public: https://github.com/petrochen/brioctl (make app builds the same bundle).

    The app lives in the menu bar (no Dock icon) and does not need camera permission.
    Open it once from /Applications; "Launch at login" is in its settings (gear icon).

    If you turn on "Re-apply settings automatically" in the app, its LaunchAgent runs the brioctl inside
    the app. Turn it off before "brew uninstall --cask brioctl-app", or the agent keeps starting a program
    that is gone. The command-line formula (brew install petrochen/tap/brioctl) can be installed next to
    the app; its brew services agent is then the one the app keeps its settings file up to date for.
  EOS
end
