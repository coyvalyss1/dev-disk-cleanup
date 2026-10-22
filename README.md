# dev-disk-cleanup

> Tiered disk cleanup for macOS developer machines. Reclaims caches and stale build output, including the builds AI coding agents leave behind, while keeping your active work.

## Problem

Building with AI coding agents fills a Mac faster than it used to:

- Agents build iOS apps with `xcodebuild -derivedDataPath /tmp/...` or into their own scratch folders. At 3-4 GB per build, those copies bypass Xcode's DerivedData folder, so nothing else ever removes them.
- Xcode DerivedData, simulators, and per-version iOS DeviceSupport symbols (about 6 GB each) pile up.
- Browser, editor, AI-tool, and package-manager caches grow quietly.

Losing 30 GB in a day is possible; a periodic cleanup that doesn't know about agent builds can't keep up.

## What it does

- **Keeps active work:** recent DerivedData (14 days by default) and any agent build touched in the last 24 hours or used by a running process are kept.
- **Tiered:** light cache cleanup on every run; deeper cleanup only below a free-space threshold (50 GB by default) or with `--force`.
- **Dry run:** `--dry-run` shows exactly what would go, with sizes.
- **Configurable:** your own extra targets and thresholds live in a config file, never in the script.
- **Works from AI CLIs:** ships a `disk-cleanup` skill for Claude Code and Codex.
- **No dependencies:** bash and standard macOS tools.

## What gets cleaned

### Tier 1: every run
- **Stale agent builds:** DerivedData-shaped folders under `/private/tmp` (including agent scratchpads) idle for 24 hours, or 12 hours below the threshold
- **Browsers:** Chrome cache and code cache (all profiles), Chrome's on-device AI model (re-downloads if needed), crash reports
- **Editors and AI tools:** Cursor, Claude Desktop, and Codex caches and logs; Slack caches
- **Old Codex versions:** self-update releases older than the current one and the one before it (newer staged updates and versions a running process uses are kept)
- **Package managers:** npm, Homebrew downloads, SwiftPM repositories, pip, uv, Puppeteer, Playwright, node-gyp, Firebase
- **Other apps:** Adobe caches and logs, Spotify cache, Signal updater, Python bytecode cache
- Anything you list in `EXTRA_CACHE_TARGETS`

### Tier 2: below threshold or `--force`
- **Xcode:** DerivedData older than 14 days; DerivedData idle 24 hours (12 below the threshold) when its project no longer exists or isn't in `DERIVED_DATA_PRIMARY_PROJECTS` (e.g. agent worktrees); ModuleCache, unavailable simulators, simulators unused for 30 days
- **Cursor:** cache files not accessed in 14 days
- **iOS DeviceSupport:** older iOS versions for a device model once a newer one exists (kept for 30 days)
- **Simulator runtimes** unused for 60 days (Xcode re-downloads them)
- **Ollama:** blobs no model manifest references (skipped if manifests can't be read)
- Optional: installers (`.dmg`, `.xip`) in Downloads, if `CLEAN_DOWNLOADED_INSTALLERS=true`
- Anything you list in `EXTRA_BUILD_TARGETS`
- Optional: your `ARCHIVE_HOOK prune` step (see Configuration)

### Tier 3: below threshold or `--force`
- Claude downloads older than 14 days (only when that folder exceeds 50 MB)

### Never touched
- Source code, git repositories, working files, `node_modules/`
- `.env` files, credentials, keys
- Documents, Desktop, iCloud Drive
- Spotlight's index and iCloud's CloudKit cache (deleting them can corrupt search or sync state)
- Chat transcripts, unless your own `ARCHIVE_HOOK` prunes them after verifying a backup

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/coyvalyss1/dev-disk-cleanup/main/install.sh | bash
```

or from a clone:

```bash
git clone https://github.com/coyvalyss1/dev-disk-cleanup.git
cd dev-disk-cleanup
./dev-disk-cleanup.sh --dry-run --force   # preview first
./install.sh
```

The installer copies the script to `~/.dev-disk-cleanup/`, creates `~/.config/dev-disk-cleanup/config.sh` from the example if you don't have one, links the `disk-cleanup` skill into `~/.claude/skills` and `~/.codex/skills` if those tools are installed, and loads a launchd job that runs **daily and at login**. Loading the job starts one run right away.

## Usage

```bash
~/.dev-disk-cleanup/dev-disk-cleanup.sh --dry-run --force  # preview every tier; deletes nothing
~/.dev-disk-cleanup/dev-disk-cleanup.sh                    # tier 1, plus tiers 2-3 below threshold
~/.dev-disk-cleanup/dev-disk-cleanup.sh --force            # all tiers now
~/.dev-disk-cleanup/dev-disk-cleanup.sh --help

tail -f ~/Library/Logs/dev-disk-cleanup/disk-cleanup.log
```

Each run logs free space before and after. `Cleanup PARTIAL` (exit 1) means a step failed; the lines above it say which.

### Managing the schedule

```bash
launchctl print gui/$(id -u)/com.dev-disk-cleanup | grep -E 'runs|last exit'
launchctl bootout gui/$(id -u)/com.dev-disk-cleanup                                  # disable
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dev-disk-cleanup.plist   # re-enable

# Uninstall
launchctl bootout gui/$(id -u)/com.dev-disk-cleanup
rm ~/Library/LaunchAgents/com.dev-disk-cleanup.plist
rm -rf ~/.dev-disk-cleanup ~/.config/dev-disk-cleanup
```

## Configuration

Settings are a sourced shell file: `$DEV_DISK_CLEANUP_CONFIG`, else `~/.config/dev-disk-cleanup/config.sh`. Every setting is optional; see [`config.example.sh`](config.example.sh).

```bash
THRESHOLD_GB=50                 # run tiers 2-3 below this much free space
DERIVED_DATA_STALE_DAYS=14      # keep DerivedData touched within this many days
DERIVED_DATA_PRIMARY_PROJECTS=("$HOME/code/MyApp")  # other projects' DerivedData counts as agent builds
CLEAN_DOWNLOADED_INSTALLERS=false
EXTRA_CACHE_TARGETS=("$HOME/Library/Caches/com.example.app|Example app cache")
EXTRA_BUILD_TARGETS=("$HOME/code/my-app/dist|my-app build output")
ARCHIVE_HOOK="$HOME/bin/my-chat-archive-hook.sh"
```

`ARCHIVE_HOOK` is for AI chat retention. It's called as `backup` or `prune [--dry-run]` and must delete only chats it has verified in its own backup; a nonzero exit marks the run partial.

Keeping the config outside the script means you can update the script without losing your settings, and keep the config in your own dotfiles repo.

## Using it from Claude Code or Codex

The installer links `skills/disk-cleanup` into each CLI's skills folder. Then ask "I'm out of disk space" or "did the cleanup run?" and the agent will preview, run, check the schedule, and measure what's filling the disk, without deleting system-managed data like the Spotlight index.

## Typical results

From the author's machine, September 2026:

```
Stale agent builds (two iOS builds in /tmp):  6.7 GB
Superseded iOS DeviceSupport:                  5.7 GB
Chrome on-device AI model:                     4.2 GB
pip + Python bytecode caches:                  2.1 GB
```

## Tests

```bash
python3 -m unittest discover -s tests
```

The tests run the script against a throwaway directory and never touch your real home folder.

## Requirements

- macOS 12 or later, with the pre-installed bash 3.2
- Optional: Xcode (DerivedData, simulators, runtimes), npm, Ollama

## Contributing

Ideas for new safe cleanup targets are welcome: open an issue or a pull request with the path, what creates it, and why it's safe to delete.

## License

MIT; see [LICENSE](LICENSE).

## Author

Built by [@coyvalyss1](https://github.com/coyvalyss1) at Valyss LLC, for developers building with AI. Other Valyss tools:

- [model-matchmaker](https://github.com/coyvalyss1/model-matchmaker): routes prompts to the right model tier in Cursor and Claude Code
- [cursor-toolkit](https://github.com/coyvalyss1/cursor-toolkit): Cursor rules, skills, and best practices
- [multi-product-context](https://github.com/coyvalyss1/multi-product-context): instant context for AI agents in multi-product workspaces
