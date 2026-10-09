"""Regression checks use disposable fixture paths, never the user's HOME."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / 'dev-disk-cleanup.sh').read_text()


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, CLEANUP_TEST_ROOT=str(self.root),
                        CLEANUP_TMP_ROOT=str(self.root / 'tmp'))
        self.env.pop('DEV_DISK_CLEANUP_CONFIG', None)

    def config(self, body):
        # The script's default config path is under $HOME, which run_cleanup
        # redirects to the fixture root.
        return self.write('.config/dev-disk-cleanup/config.sh', body)

    def failing_hook(self):
        hook = self.write('hook.sh', '#!/bin/bash\nexit 23\n', True)
        self.config(f'ARCHIVE_HOOK="{hook}"\n')

    def write(self, name, content, executable=False):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        if executable:
            p.chmod(0o700)
        return p

    def run_cleanup(self, *args):
        # Redirect path references only; do not repurpose HOME. Stub the two
        # commands that otherwise operate beyond those explicit target paths.
        script = SOURCE.replace('$HOME', '$CLEANUP_TEST_ROOT')
        script = script.replace('set -uo pipefail',
                                'set -uo pipefail\nxcrun() { return 0; }\nnpm() { return 0; }', 1)
        path = self.write('cleanup-under-test.sh', script)
        return subprocess.run(['/bin/bash', str(path), *args], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def test_backup_failure_is_not_reported_as_success(self):
        self.failing_hook()
        result = self.run_cleanup('--backup-only')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Backup-only run FAILED', result.stdout)
        self.assertNotIn('Backup-only run complete', result.stdout)

    def test_failed_archive_retains_old_chats_and_backup_snapshots(self):
        self.failing_hook()
        paths = [self.write('.claude/projects/old/session.jsonl', 'important history'),
                 self.write('.cursor/projects/example/agent-transcripts/old.jsonl', 'important history'),
                 self.write('.claude/backups/chat-backups/old/history.jsonl', 'backup')]
        old = time.time() - 60 * 86400
        for p in paths:
            os.utime(p, (old, old))
            os.utime(p.parent, (old, old))
        result = self.run_cleanup('--force')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Cleanup PARTIAL', result.stdout)
        self.assertTrue(all(p.exists() for p in paths))

    def test_configured_targets_clean_in_their_tier(self):
        cache_dir = self.write('app-cache/blob', 'x' * 4096).parent
        build_dir = self.write('project/build/out.o', 'x' * 4096).parent
        installer = self.write('Downloads/tool.dmg', 'x' * 4096)
        self.config(f'EXTRA_CACHE_TARGETS=("{cache_dir}|app cache")\n'
                    f'EXTRA_BUILD_TARGETS=("{build_dir}|project build")\n'
                    'THRESHOLD_GB=0\n')
        self.run_cleanup()
        self.assertFalse(cache_dir.exists())      # tier 1 always runs
        self.assertTrue(build_dir.exists())       # tier 2 needs threshold or --force
        self.run_cleanup('--force')
        self.assertFalse(build_dir.exists())
        self.assertTrue(installer.exists())       # installers are opt-in

    def test_installers_removed_only_when_enabled(self):
        installer = self.write('Downloads/tool.dmg', 'x' * 4096)
        self.config('CLEAN_DOWNLOADED_INSTALLERS=true\n')
        self.run_cleanup('--force')
        self.assertFalse(installer.exists())

    def test_no_config_runs_clean(self):
        result = self.run_cleanup('--force')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def age(self, path, days):
        old = time.time() - days * 86400
        for p in [path, *path.rglob('*')]:
            os.utime(p, (old, old))

    def test_stale_agent_builds_removed_recent_and_unrelated_kept(self):
        tmp_root = self.root / 'tmp'
        stale = tmp_root / 'MyApp-old-build'
        scratch = tmp_root / 'claude-501/-Users-me/session/scratchpad/dd-feature'
        recent = tmp_root / 'MyApp-active-build'
        unrelated = tmp_root / 'notes'
        for dd in (stale, scratch, recent):
            self.write(str((dd / 'Build/Intermediates.noindex/obj.o').relative_to(self.root)), 'x' * 4096)
        self.write('tmp/notes/Build/keep.txt', 'not derived data')
        for p in (stale, scratch, unrelated):
            self.age(p, 3)
        self.run_cleanup()
        self.assertFalse(stale.exists())
        self.assertFalse(scratch.exists())
        self.assertTrue(recent.exists())
        self.assertTrue(unrelated.exists())

    def derived_data(self, name, workspace=None):
        dd = self.root / 'Library/Developer/Xcode/DerivedData' / name
        self.write(str((dd / 'Build/obj.o').relative_to(self.root)), 'x' * 4096)
        if workspace:
            subprocess.run(['plutil', '-create', 'xml1', str(dd / 'info.plist')], check=True)
            subprocess.run(['plutil', '-insert', 'WorkspacePath', '-string', str(workspace),
                            str(dd / 'info.plist')], check=True)
        return dd

    def test_derived_data_outside_primary_projects_uses_agent_window(self):
        main_ws = self.write('code/MyApp/MyApp.xcodeproj/project.pbxproj', '').parent
        worktree_ws = self.write('code/MyApp-feature/MyApp.xcodeproj/project.pbxproj', '').parent
        main = self.derived_data('MyApp-main', main_ws)
        worktree = self.derived_data('MyApp-worktree', worktree_ws)
        fresh_worktree = self.derived_data('MyApp-worktree-fresh', worktree_ws)
        gone = self.derived_data('MyApp-gone', self.root / 'code/Deleted/MyApp.xcodeproj')
        no_plist = self.derived_data('MyApp-noplist')
        for dd in (main, worktree, gone, no_plist):
            self.age(dd, 2)
        self.config(f'DERIVED_DATA_PRIMARY_PROJECTS=("{main_ws.parent}")\n')
        self.run_cleanup('--force')
        self.assertTrue(main.exists())             # primary: 14-day window
        self.assertFalse(worktree.exists())        # other project: 24h window
        self.assertTrue(fresh_worktree.exists())
        self.assertFalse(gone.exists())
        self.assertFalse(no_plist.exists())

    def test_derived_data_without_primary_projects_keeps_14_day_window(self):
        ws = self.write('code/MyApp/MyApp.xcodeproj/project.pbxproj', '').parent
        dd = self.derived_data('MyApp-any', ws)
        self.age(dd, 2)
        self.run_cleanup('--force')
        self.assertTrue(dd.exists())

    def test_device_support_keeps_newest_per_model(self):
        ds = 'Library/Developer/Xcode/iOS DeviceSupport'
        newest = self.write(f'{ds}/iPhone15,2 26.6 (23G71)/Symbols/a', 'x').parents[1]
        old = self.write(f'{ds}/iPhone15,2 26.5.2 (23F84)/Symbols/a', 'x').parents[1]
        recent = self.write(f'{ds}/iPhone15,2 26.6.1 (23G80)/Symbols/a', 'x').parents[1]
        only = self.write(f'{ds}/iPad13,1 18.6 (22G86)/Symbols/a', 'x').parents[1]
        self.age(newest, 1)
        self.age(old, 60)
        self.age(recent, 5)
        self.age(only, 90)
        self.run_cleanup('--force')
        self.assertTrue(newest.exists())
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())
        self.assertTrue(only.exists())

    def run_blob_check(self, grep_fails=False):
        start = SOURCE.index('clean_orphaned_ollama_blobs()')
        end = SOURCE.index('clean_stale_simulators()', start)
        script = SOURCE[start:end].replace('$HOME', '$CLEANUP_TEST_ROOT')
        script += '\nlog() { printf "%s\\n" "$1"; }\nclean_target() { echo DELETE; }\n'
        if grep_fails:
            script += 'grep() { return 2; }\n'
        script += 'clean_orphaned_ollama_blobs\n'
        return subprocess.run(['/bin/bash'], input=script, env=self.env,
                              capture_output=True, text=True, timeout=5)

    def test_ollama_requires_readable_manifests_and_preserves_references(self):
        self.write('.ollama/blobs/sha256-abc', 'model')
        self.assertNotIn('DELETE', self.run_blob_check().stdout)
        self.write('.ollama/models/manifests/model.json', '{"digest":"sha256:abc"}')
        self.assertNotIn('DELETE', self.run_blob_check().stdout)
        self.assertNotIn('DELETE', self.run_blob_check(grep_fails=True).stdout)
        self.write('.ollama/models/manifests/model.json', '{"digest":"sha256:def"}')
        self.assertIn('DELETE', self.run_blob_check().stdout)


if __name__ == '__main__':
    unittest.main()
