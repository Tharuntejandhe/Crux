# Homebrew cask for Novex.
#
# To offer `brew install`, create a tap repo named "homebrew-novex" under your
# GitHub account and drop this file in its Casks/ folder. Then users run:
#
#     brew install --cask <your-user>/novex/novex
#
# Update `version` and `sha256` on every release (sha256 of the released Novex.zip:
#   shasum -a 256 dist/Novex.zip).  Replace OWNER with your GitHub username.
cask "novex" do
  version "0.1.2"
  sha256 "2029901ffa8e92782f79eacee27ca63b6988d3f788ba1060223ab0c84a1bee4a"

  url "https://github.com/Tharuntejandhe/Novex/releases/download/v#{version}/Novex.zip"
  name "Novex"
  desc "On-device, private email assistant that lives in your menu bar"
  homepage "https://github.com/Tharuntejandhe/Novex"

  depends_on macos: :tahoe # macOS 26+ (minimum)

  app "Novex.app"

  caveats <<~EOS
    Novex is open-source and NOT notarized (no paid Apple Developer ID), so macOS
    will warn on first launch. Either:
      • right-click Novex.app → Open → Open, or
      • run:  xattr -dr com.apple.quarantine "#{appdir}/Novex.app"

    Novex reads Mail on-device and needs Full Disk Access:
      System Settings → Privacy & Security → Full Disk Access → enable Novex.

    The AI features need an Apple Silicon Mac on macOS 26+ with Apple
    Intelligence enabled. Everything is on-device — your mail never leaves your Mac.
  EOS
end
