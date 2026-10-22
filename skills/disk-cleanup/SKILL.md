---
name: disk-cleanup
description: Free disk space on this Mac with dev-disk-cleanup. Use when the disk is full or low on space, the user asks to clean up their Mac, asks what is taking up space, or asks whether the scheduled cleanup ran. Runs dry runs, normal or forced cleanups, checks the daily schedule and logs, and finds what is filling the disk.
---

# Disk cleanup

The engine is `dev-disk-cleanup.sh`, two folders above this file once its symlink is
resolved: the root of a git clone, or `~/.dev-disk-cleanup/` when installed with
`install.sh`. Settings are sourced from `$DEV_DISK_CLEANUP_CONFIG`, else
`~/.config/dev-disk-cleanup/config.sh` (see `config.example.sh`).

## Commands

```bash
ENGINE="$(cd "$(dirname "$(readlink -f <path-to-this-SKILL.md>)")/../.." && pwd)/dev-disk-cleanup.sh"
"$ENGINE" --dry-run --force   # preview every tier; deletes nothing
"$ENGINE"                     # tier 1, plus tiers 2-3 below THRESHOLD_GB
"$ENGINE" --force             # all tiers regardless of free space
"$ENGINE" --help
```

- **"What would it delete?"** Run the dry run and summarize by size; delete nothing.
- **"Clean up" / "out of space":** check free space (`df -h /System/Volumes/Data`), run
  the normal run, and report free space before and after from its log lines.
- Use `--force` only when the user asks for a full cleanup or a normal run did not help.

## Tiers

1. **Every run:** browser, editor, AI-tool, and package-manager caches; stale agent
   builds (Xcode DerivedData created with `-derivedDataPath` under `/private/tmp` or agent
   scratchpads, idle 24h, or 12h below threshold, and not used by a running process);
   Codex releases older than the current one and the one before it; `EXTRA_CACHE_TARGETS`.
2. **Below threshold or `--force`:** stale Xcode DerivedData (default 14 days), simulators
   unused 30 days, superseded iOS DeviceSupport, simulator runtimes unused 60 days,
   unreferenced Ollama blobs, `EXTRA_BUILD_TARGETS`, optional installers in Downloads,
   then `ARCHIVE_HOOK prune` for chat retention.
3. **Below threshold or `--force`:** old Claude downloads.

## Schedule and logs

- Log: `$LOG_DIR/disk-cleanup.log` (default `~/Library/Logs/dev-disk-cleanup/`).
- Scheduled job: `launchctl list | grep disk-cleanup`, then
  `launchctl print gui/$(id -u)/<label>` for `runs`, `last exit code`, and interval.
- Confirm a run happened from the log's `Disk cleanup started` / `Free space after` lines,
  never from the schedule alone. `Cleanup PARTIAL` means a step failed; read the lines above it.

## When cleanup does not free enough

Measure before deleting anything else. Size candidates with `du -sm` per entry (avoid
whole-home `find`; it is slow): `/private/tmp`, `~/Library/Developer`, `~/Library/Caches`,
`~/Library/Application Support`, `~/Downloads`. Recurring culprits: agent build folders
outside DerivedData, and apps re-downloading large caches after deletion.

**Never delete directly; explain and let the user decide:**
- `~/Library/Metadata/CoreSpotlight`: Spotlight's index. Restart first; rebuild via
  Spotlight settings if it stays huge or `corespotlightd` stays pegged.
- `~/Library/Caches/CloudKit`: iCloud's upload/download staging. Deleting it can corrupt
  sync state; let pending transfers finish.
- Anything not covered by the engine or the user's config. Propose adding it to the
  config instead of a one-off `rm`.
