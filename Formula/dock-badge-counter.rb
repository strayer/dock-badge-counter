class DockBadgeCounter < Formula
  desc "macOS command-line tool that reads notification badge counts from Dock applications"
  homepage "https://github.com/strayer/dock-badge-counter"
  url "https://github.com/strayer/dock-badge-counter/archive/v0.0.1.tar.gz"
  sha256 "1cb4bbb9d674c87a4666e17e30a1cfbedaa2e3ca4abff2bfcfd5686bb01f22a9"
  license "MIT"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/dock-badge-counter"
  end

  test do
    # Test that the binary exists and shows help
    assert_match "dock-badge-counter", shell_output("#{bin}/dock-badge-counter --help")
  end
end