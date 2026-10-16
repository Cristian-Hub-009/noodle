# Generated from packaging/homebrew/noodle.rb in pcybriwsky/noodle, so edit it there.
# Each release fills in version and sha256 and pushes the result to pcybriwsky/homebrew-tap.
cask "noodle" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/pcybriwsky/noodle/releases/download/v#{version}/Noodle.zip"
  name "Noodle"
  desc "Desk stretches while Claude Code is working"
  homepage "https://tonitherigatoni.com"

  depends_on macos: :ventura
  depends_on formula: "jq"

  app "Noodle.app"
  binary "#{appdir}/Noodle.app/Contents/Resources/bin/noodle"

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
