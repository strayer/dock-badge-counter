class DockBadgeCounter < Formula
  desc "Read notification badge counts from macOS Dock applications, once or as a watcher"
  homepage "https://github.com/strayer/dock-badge-counter"
  url "https://github.com/strayer/dock-badge-counter/archive/v0.0.1.tar.gz"
  sha256 "1cb4bbb9d674c87a4666e17e30a1cfbedaa2e3ca4abff2bfcfd5686bb01f22a9"
  license "MIT"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/dock-badge-counter"
    pkgetc.install "examples/config.toml" => "config.toml.example"
  end

  # `brew services start dock-badge-counter` runs the watcher as a launchd user agent.
  # Configure it in ~/.config/dock-badge-counter/config.toml (see the example in #{etc}).
  service do
    run [opt_bin/"dock-badge-counter", "watch"]
    keep_alive true
    environment_variables PATH: std_service_path_env
    log_path var/"log/dock-badge-counter.log"
    error_log_path var/"log/dock-badge-counter.log"
  end

  def caveats
    <<~EOS
      The watcher needs Accessibility permission for the binary itself:
        System Settings > Privacy & Security > Accessibility > + > #{opt_bin}/dock-badge-counter
      A permission prompt is shown on first start. After a `brew upgrade` the grant must be
      renewed, because the binary's ad-hoc code signature changes.

      Example config: #{pkgetc}/config.toml.example
    EOS
  end

  test do
    assert_match "dock-badge-counter", shell_output("#{bin}/dock-badge-counter --help")
    assert_match version.to_s, shell_output("#{bin}/dock-badge-counter --version")
  end
end
