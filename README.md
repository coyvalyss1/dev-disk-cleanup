# dev-disk-cleanup

> Smart disk space cleanup for macOS developers. Safely reclaims gigabytes of space from caches and build artifacts while preserving your active work.

Built for developers working with AI tools who accumulate build artifacts, browser caches, and simulator images faster than traditional workflows.

## Problem

When you're building with AI assistants, scaffolding prototypes, and working across multiple projects, your Mac fills up fast:

- Xcode DerivedData builds pile up (5-10 GB per project)
- Chrome caches across profiles (5-10 GB)
- npm, Homebrew, and package manager caches (3-5 GB)
- iOS simulators and app updater caches (2-5 GB each)
- Adobe and other app caches (50+ GB)

Most developers don't realize they've lost 30-50 GB until their machine slows down or Xcode complains.

## Solution

`dev-disk-cleanup` is a smart, conservative cleanup script that:

✅ **Preserves active work** — keeps recent builds (modified within 14 days)  
✅ **Tiered cleanup** — light weekly cache cleanup, deeper cleanup only when needed  
✅ **Threshold-based** — runs full cleanup only when free space drops below 50 GB  
✅ **Dry-run mode** — see exactly what would be cleaned before committing  
✅ **Zero dependencies** — pure bash, works on any Mac out of the box  
✅ **Automatic scheduling** — runs via launchd weekly + on login

## What Gets Cleaned

### Tier 1 (Always safe, runs weekly)
- **Browser caches**: Chrome, Chromium (all profiles)
- **App updaters**: Signal, Ledger, Spotify
- **Package managers**: npm, Homebrew downloads, SwiftPM repos
- **Dev tools**: node-gyp, Playwright
- **Adobe caches**: Can grow to 50+ GB

### Tier 2 (Only when below 50 GB or `--force`)
- **Xcode DerivedData**: Stale builds (older than 14 days, keeps recent)
- **Editor caches**: Cursor, VS Code (stale cache files only)
- **iOS Simulators**: Unavailable/broken simulators only

### What's NEVER Touched
- Source code, git repos, working files
- `node_modules/` directories
- `.env`, credentials, API keys
- iCloud data, Documents, Desktop
- Active builds (modified within 14 days)

## Installation

### Quick Install (Automatic Scheduling)

```bash
curl -fsSL https://raw.githubusercontent.com/coyvalyss1/dev-disk-cleanup/main/install.sh | bash
```

This installs the script to `~/.dev-disk-cleanup/` and sets up automatic scheduling via launchd.

### Manual Install

```bash
# Clone the repo
git clone https://github.com/coyvalyss1/dev-disk-cleanup.git
cd dev-disk-cleanup

# Make executable
chmod +x dev-disk-cleanup.sh

# Run directly
./dev-disk-cleanup.sh --dry-run  # Preview what would be cleaned
./dev-disk-cleanup.sh            # Run cleanup
```

## Usage

### Automatic Mode (After Install)
- Runs every 7 days (light cache cleanup)
- Checks on every login (full cleanup if below 50 GB free)
- No action required

### Manual Commands

```bash
# Preview what would be cleaned (safe, no changes)
~/.dev-disk-cleanup/dev-disk-cleanup.sh --dry-run

# Run normal cleanup (tier 1, or tier 2 if below 50 GB)
~/.dev-disk-cleanup/dev-disk-cleanup.sh

# Force full cleanup regardless of free space
~/.dev-disk-cleanup/dev-disk-cleanup.sh --force

# Show help
~/.dev-disk-cleanup/dev-disk-cleanup.sh --help

# View logs
tail -f ~/.dev-disk-cleanup/cleanup.log
```

### Management

```bash
# Check if automatic cleanup is running
launchctl list | grep dev-disk-cleanup

# Disable automatic cleanup
launchctl unload ~/Library/LaunchAgents/com.dev-disk-cleanup.plist

# Re-enable automatic cleanup
launchctl load ~/Library/LaunchAgents/com.dev-disk-cleanup.plist

# Uninstall completely
launchctl unload ~/Library/LaunchAgents/com.dev-disk-cleanup.plist
rm ~/Library/LaunchAgents/com.dev-disk-cleanup.plist
rm -rf ~/.dev-disk-cleanup
```

## Configuration

Edit `~/.dev-disk-cleanup/dev-disk-cleanup.sh` to customize:

```bash
THRESHOLD_GB=50    # Trigger tier 2 cleanup when below this (GB)
STALE_DAYS=14      # How old builds must be to clean (days)
```

## Typical Results

### Light Cleanup (Tier 1)
```
Adobe caches: 518 MB freed
Chrome caches: 4.0 GB freed
Homebrew downloads: 258 MB freed
npm cache: 2.2 GB freed
SwiftPM repos: 403 MB freed
──────────────────────────
Total: ~8 GB recovered
```

### Full Cleanup (Tier 1 + Tier 2)
```
[Tier 1 cleanup as above]
Stale DerivedData: 7.6 GB freed
Cursor stale caches: 1.2 GB freed
──────────────────────────
Total: ~17 GB recovered
```

Active builds preserved, so next compile is fast.

## Why This Tool?

Existing tools like CleanMyMac are either:
- **Paid** ($30-100/year)
- **Too aggressive** (delete everything, slow down builds)
- **Not dev-aware** (don't understand DerivedData, npm caches, etc.)

`dev-disk-cleanup` is:
- **Free and open source** (MIT license)
- **Conservative** (keeps recent builds, only cleans stale artifacts)
- **Dev-context aware** (knows what's safe to delete and what's not)
- **Performance-conscious** (preserves active work to keep builds fast)

## Requirements

- macOS 10.14+ (Mojave or later)
- Bash 3.2+ (pre-installed on macOS)
- Optional: Xcode (for DerivedData cleanup)
- Optional: npm (for npm cache cleanup)

## Contributing

Contributions welcome! If you have ideas for additional safe cleanup targets or improvements:

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/new-target`)
3. Commit your changes (`git commit -m 'Add cleanup for X'`)
4. Push to the branch (`git push origin feature/new-target`)
5. Open a Pull Request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Author

Built by [@coyvalyss1](https://github.com/coyvalyss1) / Valyss LLC for developers building with AI.

## Related Projects

- [DoMoreWorld](https://domoreworld.com) - AI for purpose, creativity, and connection
- [Art Ping Pong](https://artpingpong.art) - AI-powered collaborative art game

---

**Note**: Always run with `--dry-run` first to preview what would be cleaned. This tool is conservative by design, but your disk space situation is unique.
