# Formula for later: fill in url/sha256 after the first release (git tag v0.1.0)
# and put it into a tap: brew tap pmmodlin/tap && brew install clones.
class Clones < Formula
  desc "Run several isolated Claude Desktop instances side by side"
  homepage "https://github.com/pmmodlin/clones"
  url "https://github.com/pmmodlin/clones/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/pmmodlin/clones.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :ventura

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/clones"
    generate_completions_from_executable(bin/"clones", "completion")
  end

  def caveats
    <<~EOS
      Sign in to a profile with `clones login <name>` (or with the email code):
      macOS hands claude:// links to any running Claude instance.
      Diagnostics: clones doctor
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/clones --version")
    ENV["CLONES_HOME"] = testpath/"clones"
    system bin/"clones", "add", "brewtest", "--no-app"
    assert_match "brewtest", shell_output("#{bin}/clones ls --no-size")
  end
end
