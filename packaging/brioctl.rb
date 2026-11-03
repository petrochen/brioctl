# Copy of Formula/brioctl.rb in petrochen/homebrew-tap. On a new release: update url and sha256
# (curl -sL <url> | shasum -a 256) here and in the tap.
class Brioctl < Formula
  desc "Command-line control for the Logitech MX Brio webcam"
  homepage "https://github.com/petrochen/brioctl"
  url "https://github.com/petrochen/brioctl/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "c9703bfda8e9de91cd5328441f0239b1e5dc0ad09797d2ea6ae4b23f3727bf9c"
  license "MIT"

  depends_on :macos

  def install
    system "make", "VERSION=#{version}"
    bin.install "brioctl"
    (share/"brioctl/skills/brioctl").install "skills/brioctl/SKILL.md"
  end

  # brew services start brioctl
  service do
    run [opt_bin/"brioctl", "watch"]
    keep_alive true
    log_path var/"log/brioctl.log"
    error_log_path var/"log/brioctl.log"
  end

  def caveats
    <<~EOS
      brioctl re-applies saved settings whenever the camera is connected or video starts.
      To set that up:

        1. Set the camera the way you want it:   brioctl fov 78 warmth 60 ...
        2. Save the settings:                    brioctl save
        3. Start the agent:                      brew services start brioctl

      For Claude Code or Codex: brioctl install-skill

      The settings file is ~/.config/brioctl/settings and the log is #{var}/log/brioctl.log.
      If you installed the agent with "make agent" before, remove it first: make unagent
    EOS
  end

  test do
    assert_match "brioctl #{version}", shell_output("#{bin}/brioctl --version")
    assert_match "usage: brioctl", shell_output("#{bin}/brioctl help")
  end
end
