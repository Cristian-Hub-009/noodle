# Template for Casks/noodle.rb in pcybriwsky/homebrew-tap. The release workflow fills in
# version and sha256 and pushes it there; edit everything else here.
cask "noodle" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/pcybriwsky/noodle/releases/download/v#{version}/Noodle.zip"
  name "Noodle"
  desc "Desk stretches while Claude Code is working"
  homepage "https://github.com/pcybriwsky/noodle"

  depends_on macos: ">= :ventura"
  depends_on formula: "jq"

  app "Noodle.app"
  binary "#{appdir}/Noodle.app/Contents/Resources/bin/noodle"

  # Ad-hoc signed, not notarized. Without this, Gatekeeper refuses to open it.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Noodle.app"]
  end

  uninstall_preflight do
    system_command "#{appdir}/Noodle.app/Contents/Resources/bin/noodle",
                   args: ["remove", "-y"]
  end

  zap trash: "~/.claude-posture"

  caveats <<~EOS
    Connect Noodle to Claude Code (adds two hooks to ~/.claude/settings.json):
      noodle setup
  EOS
end
