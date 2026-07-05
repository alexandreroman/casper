Download `Casper-<version>-arm64.zip`, unzip, and move `Casper.app` to `/Applications`.

**This build is not code-signed or notarized.** On first launch macOS Gatekeeper will block it. To open it:

- Right-click `Casper.app` ▸ **Open**, then confirm; or
- run `xattr -dr com.apple.quarantine /Applications/Casper.app`.

Requires macOS 15+ on Apple Silicon (arm64). No Homebrew or other dependencies needed — the app is self-contained.
