# Homebrew formula for robo-pen.
#
# Distributed via the `robsman/homebrew-tap` repo. To install:
#
#   brew install robsman/tap/robo-pen
#
# On every new GitHub release, bump `version` + `sha256` (the release
# tarball is `robo-pen-vX.Y.Z.tar.gz`, attached to the GitHub release).
# `brew bump-formula-pr` automates the bump.

class RoboPen < Formula
  desc "Run coding agents inside isolated Apple Container sandboxes (Claude Code, OpenCode, …)"
  homepage "https://github.com/robsman/robo-pen"
  url "https://github.com/robsman/robo-pen/releases/download/v0.1.2/robo-pen-v0.1.2.tar.gz"
  sha256 "40eecf88ddd8e9c8899d5c068641d228d9dc8bdba5a59e3baa725b0397ce68b4"
  license "MIT"

  # Apple Container only runs on Apple Silicon + macOS 26+. We declare the
  # constraint here so brew refuses to install on incompatible systems.
  depends_on :macos
  depends_on arch: :arm64
  depends_on "container"
  depends_on "jq"
  depends_on "just"

  def install
    # Repo files live at HOMEBREW_PREFIX/share/robo-pen/. The `rp` wrapper
    # auto-resolves ROBO_PEN_DIR to its own directory, so we point its
    # symlink target at <share>/rp and the wrapper finds the Justfile
    # next to it.
    libexec.install Dir["*"]
    bin.install_symlink libexec/"rp"
  end

  def caveats
    <<~EOS
      One-time setup (starts the Apple Container service + pulls pre-built images):

        rp setup

      First-time pulling ~1.5 GB of pre-built images; subsequent runs are
      instant. Run `RP_BUILD_FROM_SOURCE=1 rp setup` if you'd rather
      build the images locally (~15 min).

      Workspace bootstrap (run inside your project):

        cd ~/my-project
        rp init                       # creates .rp/{config.yaml,shadow}
        rp run                        # auto-creates container, launches agent

      Docs: https://github.com/robsman/robo-pen
    EOS
  end

  test do
    # The wrapper resolves its own path; running with --help is the lightest
    # smoke test that doesn't require Apple Container to be running.
    assert_match "Usage:", shell_output("#{bin}/rp --help")
  end
end
