#!/usr/bin/env python3
"""Synthetic cache safety tests. Never opens or removes this project's work/."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from clean_dev_cache import Cleaner, SafetyError, SystemProbe


class Probe:
    def __init__(self):
        self.process_error = False
        self.git_errors = set()
        self.open_files = set()
        self.lsof_error = False
        self.events = []

    def processes(self):
        self.events.append(('processes', None))
        if self.process_error:
            raise SafetyError('process inspection failed')

    def git_safe(self, root, target):
        self.events.append(('git', target.name))
        if target.name in self.git_errors:
            raise SafetyError('not ignored or tracked')

    def unopened(self, target):
        self.events.append(('lsof', target.name))
        if self.lsof_error or target.name in self.open_files:
            raise SafetyError('open files or inspection unavailable')


class CleanerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vyu-cache-test-')
        self.root = Path(self.temp.name).resolve()
        self.work = self.root / 'work'
        self.work.mkdir()
        (self.root / 'VYu.xcodeproj').mkdir()
        self.probe = Probe()
        self.cleaner = Cleaner(self.root, self.probe)

    def tearDown(self):
        self.temp.cleanup()

    def timestamp(self, root, value):
        for path in [root, *root.rglob('*')]:
            os.utime(path, (value, value), follow_symlinks=False)
        return root

    def build(self, name, platform='iphonesimulator', value=10):
        path = self.work / name
        (path / 'Build' / 'Products' / ('Debug-' + platform)).mkdir(parents=True)
        (path / 'Logs').mkdir()
        (path / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': str(self.root / 'VYu.xcodeproj')}))
        (path / 'Build' / 'Products' / ('Debug-' + platform) / 'generated').write_bytes(b'abc')
        return self.timestamp(path, value)

    def module(self, name='TestModuleCache', value=10):
        path = self.work / name
        (path / 'ABCD1234').mkdir(parents=True)
        (path / 'ABCD1234' / 'Foundation-1234.pcm').write_bytes(b'cached')
        (path / 'Swift-1234.swiftmodule').write_bytes(b'module')
        return self.timestamp(path, value)

    def result(self, name, value):
        path = self.work / (name + '.xcresult')
        (path / 'Data').mkdir(parents=True)
        (path / 'Info.plist').write_bytes(plistlib.dumps({'rootId': {}, 'version': {}}))
        (path / 'Data' / 'data.0').write_bytes(b'result')
        return self.timestamp(path, value)

    def swiftpm(self):
        package = self.work / 'Check'
        (package / 'Sources').mkdir(parents=True, exist_ok=True)
        (package / 'Package.swift').write_text('// synthetic source, preserve')
        path = self.work / 'CheckBuild'
        (path / 'arm64-apple-macosx' / 'debug' / 'ModuleCache').mkdir(parents=True)
        (path / 'build.db').write_bytes(b'generated')
        (path / 'debug.yaml').write_text('generated: true')
        (path / 'workspace-state.json').write_text(json.dumps({'object': {}, 'version': 6}))
        (path / 'arm64-apple-macosx' / 'debug' / 'description.json').write_text('{"swiftCommands": {}}')
        return path, package

    @staticmethod
    def names(report, key):
        return {Path(entry['path']).name for entry in report[key]}

    def test_dry_run_retains_newest_platforms_two_results_and_unknown_builds(self):
        self.build('OldSim', value=10)
        self.build('NewSim', value=20)
        self.build('OldDevice', 'iphoneos', 11)
        self.build('NewDevice', 'iphoneos', 21)
        self.build('Unknown', 'macosx', 99)
        mixed = self.build('Mixed', value=30)
        (mixed / 'Build' / 'Products' / 'Release-iphoneos').mkdir()
        for index in range(4):
            self.result(str(index), index + 1)
        cache = self.module()
        report = self.cleaner.plan()
        self.assertEqual(self.names(report, 'delete'), {'OldSim', 'OldDevice', '0.xcresult', '1.xcresult', cache.name})
        self.assertEqual(self.names(report, 'keep'), {'NewSim', 'NewDevice', 'Unknown', 'Mixed', '2.xcresult', '3.xcresult'})
        self.assertTrue(cache.exists())
        self.assertFalse(report['apply'])

    def test_ties_are_deterministic_and_keep_override(self):
        self.build('B', value=10)
        self.build('A', value=10)
        self.result('one', 1)
        self.assertEqual(self.names(self.cleaner.plan(), 'keep'), {'A', 'one.xcresult'})
        cleaner = Cleaner(self.root, self.probe, keep_results=0)
        self.assertIn('one.xcresult', self.names(cleaner.plan(), 'delete'))
        with self.assertRaises(ValueError):
            Cleaner(self.root, self.probe, keep_results=-1)

    def test_sources_signing_outputs_backups_and_nested_work_are_untouched(self):
        self.module()
        for relative in ('outputs/VYu.ipa', 'Config/Local.xcconfig', 'work/source/Package.swift',
                         'work/backups/video.mp4', 'work/source/.git/config',
                         'work/source/work/HiddenModuleCache/Swift-1234.swiftmodule'):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('preserve')
        report = self.cleaner.plan()
        self.assertEqual(self.names(report, 'delete'), {'TestModuleCache'})
        self.cleaner.apply(report)
        self.assertTrue((self.root / 'outputs/VYu.ipa').exists())
        self.assertTrue((self.root / 'Config/Local.xcconfig').exists())
        self.assertTrue((self.work / 'source/work/HiddenModuleCache/Swift-1234.swiftmodule').exists())
        self.assertTrue((self.work / 'backups/video.mp4').exists())

    def test_unrecognized_modules_results_and_other_project_derived_data_are_preserved(self):
        module = self.module()
        (module / 'original.mp4').write_bytes(b'real data')
        (self.work / 'Fake.xcresult').mkdir()
        build = self.build('ForeignBuild')
        (build / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': '/other/Foreign.xcodeproj'}))
        build = self.build('ContainsSource')
        (build / 'Sources').mkdir()
        self.assertEqual(self.cleaner.plan()['delete'], [])
        self.assertTrue(module.exists())

    def test_symlinks_and_nested_repositories_never_become_targets(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'preserve').write_text('data')
        (self.work / 'LinkModuleCache').symlink_to(outside, target_is_directory=True)
        cache = self.module('NestedModuleCache')
        (cache / 'link').symlink_to(outside, target_is_directory=True)
        cache = self.module('GitModuleCache')
        (cache / '.git').mkdir()
        build = self.build('InfoLink')
        (build / 'info.plist').unlink()
        (build / 'info.plist').symlink_to(outside / 'preserve')
        self.assertEqual(self.cleaner.plan()['delete'], [])
        self.assertTrue((outside / 'preserve').exists())

    def test_work_and_repository_symlinks_are_rejected(self):
        self.work.rmdir()
        (self.root / 'elsewhere').mkdir()
        self.work.symlink_to(self.root / 'elsewhere', target_is_directory=True)
        with self.assertRaises(SafetyError):
            self.cleaner.plan()
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(SafetyError):
            Cleaner(alias, self.probe)

    def test_git_failures_retain_candidate(self):
        self.module()
        self.probe.git_errors.add('TestModuleCache')
        report = self.cleaner.plan()
        self.assertEqual(report['delete'], [])
        self.assertEqual(len(report['skipped']), 1)

    def test_process_failure_allows_report_but_refuses_apply(self):
        cache = self.module()
        self.probe.process_error = True
        report = self.cleaner.plan()
        self.assertEqual(len(report['delete']), 1)
        with self.assertRaises(SafetyError):
            self.cleaner.apply(report)
        self.assertTrue(cache.exists())

    def test_new_build_process_after_dry_run_refuses_apply(self):
        cache = self.module()
        report = self.cleaner.plan()
        self.probe.process_error = True
        with self.assertRaises(SafetyError):
            self.cleaner.apply(report)
        self.assertTrue(cache.exists())

    def test_open_files_or_unavailable_lsof_prevent_all_deletion(self):
        first = self.module('AModuleCache')
        last = self.module('ZModuleCache')
        report = self.cleaner.plan()
        self.probe.open_files.add(last.name)
        with self.assertRaises(SafetyError):
            self.cleaner.apply(report)
        self.assertTrue(first.exists())
        self.assertTrue(last.exists())
        self.probe.open_files.clear()
        self.probe.lsof_error = True
        with self.assertRaises(SafetyError):
            self.cleaner.apply(report)
        self.assertTrue(first.exists())

    def test_changes_tracking_and_link_swap_after_plan_block_apply(self):
        cache = self.module()
        report = self.cleaner.plan()
        self.probe.git_errors.add(cache.name)
        with self.assertRaises(SafetyError):
            self.cleaner.apply(report)
        self.probe.git_errors.clear()
        (cache / 'Swift-1234.swiftmodule').write_bytes(b'changed')
        with self.assertRaises(SafetyError):
            self.cleaner.apply(report)
        report = self.cleaner.plan()
        cache.rename(self.work / 'preserved')
        cache.symlink_to(self.work / 'preserved', target_is_directory=True)
        with self.assertRaises(SafetyError):
            self.cleaner.apply(report)
        self.assertTrue((self.work / 'preserved').exists())

    def test_apply_is_idempotent_and_checks_open_files_before_each_delete(self):
        self.module('AModuleCache')
        self.module('BModuleCache')
        report = self.cleaner.plan()
        expected_bytes = report['candidate_bytes']
        self.cleaner.apply(report)
        self.assertEqual(report['deleted_bytes'], expected_bytes)
        for name in ('AModuleCache', 'BModuleCache'):
            self.assertEqual(self.probe.events.count(('lsof', name)), 2)
        second = self.cleaner.plan()
        self.cleaner.apply(second)
        self.assertEqual(second['deleted'], [])
        self.assertEqual(second['deleted_bytes'], 0)

    def test_report_cannot_escape_work_boundary(self):
        self.module()
        outside = self.root / 'outside'
        outside.mkdir()
        report = self.cleaner.plan()
        report['delete'][0]['path'] = 'outside'
        with self.assertRaises(SafetyError):
            self.cleaner.apply(report)
        self.assertTrue(outside.exists())

    def test_swiftpm_generated_build_cleaned_but_source_and_links_preserved(self):
        build, package = self.swiftpm()
        report = self.cleaner.plan()
        self.assertEqual(self.names(report, 'delete'), {build.name})
        self.cleaner.apply(report)
        self.assertTrue((package / 'Package.swift').exists())
        build, _ = self.swiftpm()
        (build / 'debug').symlink_to('arm64-apple-macosx/debug', target_is_directory=True)
        report = self.cleaner.plan()
        self.assertEqual(report['delete'], [])
        self.assertIn(build.name, self.names(report, 'skipped'))

    def test_swiftpm_downloaded_source_is_preserved(self):
        build, _ = self.swiftpm()
        (build / 'checkouts' / 'dependency').mkdir(parents=True)
        self.assertEqual(self.cleaner.plan()['delete'], [])

    def test_same_project_snapshot_workspace_accepted_without_cleaning_snapshot(self):
        snapshot = self.work / 'OldSource'
        (snapshot / 'VYu.xcodeproj').mkdir(parents=True)
        (snapshot / '.git').mkdir()
        old = self.build('OldSnapshotBuild', value=10)
        self.build('NewBuild', value=20)
        (old / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': str(snapshot / 'VYu.xcodeproj')}))
        self.timestamp(old, 10)
        report = self.cleaner.plan()
        self.assertIn(old.name, self.names(report, 'delete'))
        self.cleaner.apply(report)
        self.assertTrue((snapshot / 'VYu.xcodeproj').is_dir())
        self.assertTrue((snapshot / '.git').is_dir())

    def test_linked_or_missing_project_snapshot_is_not_inspected(self):
        outside = self.root / 'outside'
        (outside / 'VYu.xcodeproj').mkdir(parents=True)
        linked = self.work / 'LinkedSource'
        linked.symlink_to(outside, target_is_directory=True)
        build = self.build('LinkProjectBuild')
        (build / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': str(linked / 'VYu.xcodeproj')}))
        self.assertEqual(self.cleaner.plan()['delete'], [])
        self.assertEqual(self.cleaner.plan()['keep'], [])
        (build / 'info.plist').write_bytes(plistlib.dumps({'WorkspacePath': str(self.work / 'missing/VYu.xcodeproj')}))
        self.assertEqual(self.cleaner.plan()['keep'], [])

    def test_mixed_device_and_mac_product_kept_even_when_older(self):
        mixed = self.build('MixedDeviceMac', 'iphoneos', 10)
        (mixed / 'Build/Products/Debug-macosx').mkdir()
        self.timestamp(mixed, 10)
        self.build('NewDevice', 'iphoneos', 30)
        report = self.cleaner.plan()
        self.assertIn(mixed.name, self.names(report, 'keep'))
        self.assertEqual(report['delete'], [])

    def test_typecheck_and_generated_abi_json_are_cache_only(self):
        cache = self.module('CoverTypecheckCache')
        (cache / 'VYu.abi.json').write_text('{"ABIRoot": {}, "ConstValues": []}')
        report = self.cleaner.plan()
        self.assertEqual(self.names(report, 'delete'), {cache.name})
        (cache / 'VYu.abi.json').write_text('{"original": "private"}')
        self.assertEqual(self.cleaner.plan()['delete'], [])

    def test_parent_work_swap_during_preflight_refuses_deletion(self):
        cache = self.module()
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / cache.name).mkdir()
        (outside / cache.name / 'original').write_text('preserve')
        report = self.cleaner.plan()
        def swap(_):
            self.work.rename(self.root / 'saved-work')
            self.work.symlink_to(outside, target_is_directory=True)
        self.probe.unopened = swap
        with self.assertRaises(SafetyError):
            self.cleaner.apply(report)
        self.assertTrue((outside / cache.name / 'original').exists())
        self.assertTrue((self.root / 'saved-work' / cache.name).exists())

    def test_pinned_parent_survives_swap_at_rmtree_and_restores_cwd(self):
        cache = self.module()
        outside = self.root / 'outside'
        (outside / cache.name).mkdir(parents=True)
        (outside / cache.name / 'original').write_text('preserve')
        report = self.cleaner.plan()
        remove = shutil.rmtree
        original_cwd = Path.cwd()
        def swap_and_remove(name):
            self.work.rename(self.root / 'saved-work')
            self.work.symlink_to(outside, target_is_directory=True)
            remove(name)
        swap_and_remove.avoids_symlink_attacks = True
        with patch('clean_dev_cache.shutil.rmtree', swap_and_remove):
            self.cleaner.apply(report)
        self.assertTrue((outside / cache.name / 'original').exists())
        self.assertFalse((self.root / 'saved-work' / cache.name).exists())
        self.assertEqual(Path.cwd(), original_cwd)


class SystemProbeTests(unittest.TestCase):
    def result(self, code=0, stdout=b'', stderr=b''):
        return subprocess.CompletedProcess([], code, stdout, stderr)

    def test_process_tool_detection_and_errors(self):
        probe = SystemProbe()
        for output in (b'/Applications/Xcode.app/xcodebuild\n', b'/usr/bin/swift-frontend\n'):
            with patch.object(probe, 'run', return_value=self.result(stdout=output)), self.assertRaises(SafetyError):
                probe.processes()
        with patch.object(probe, 'run', return_value=self.result(code=1)), self.assertRaises(SafetyError):
            probe.processes()
        with patch.object(probe, 'run', return_value=self.result(stdout=b'/usr/bin/python3\n')):
            probe.processes()
        with patch('clean_dev_cache.subprocess.run', side_effect=FileNotFoundError), self.assertRaises(SafetyError):
            probe.processes()

    def test_lsof_only_clean_empty_exit_one_is_safe(self):
        probe = SystemProbe()
        with patch.object(probe, 'run', return_value=self.result(code=1)):
            probe.unopened(Path('/synthetic/cache'))
        for result in (self.result(stdout=b'1234\n'), self.result(), self.result(code=1, stderr=b'warning'), self.result(code=2)):
            with patch.object(probe, 'run', return_value=result), self.assertRaises(SafetyError):
                probe.unopened(Path('/synthetic/cache'))

    def test_resident_xcode_services_do_not_block_but_open_targets_do(self):
        probe = SystemProbe()
        services = b'/Xcode/XCBBuildService\n/Xcode/SWBBuildService\n'
        with patch.object(probe, 'run', return_value=self.result(stdout=services)):
            probe.processes()
        # The service is still unsafe when it holds files in a cleanup target.
        with patch.object(probe, 'run', return_value=self.result(stdout=b'1234\n')):
            with self.assertRaises(SafetyError):
                probe.unopened(Path('/synthetic/cache'))
        with patch.object(probe, 'run', return_value=self.result(stdout=services + b'/usr/bin/swift-frontend\n')):
            with self.assertRaisesRegex(SafetyError, 'swift-frontend'):
                probe.processes()

    def test_git_checks_use_real_ignored_and_tracked_paths(self):
        with tempfile.TemporaryDirectory(prefix='vyu-cache-git-test-') as directory:
            root = Path(directory).resolve()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            target = root / 'work' / 'CacheModuleCache'
            target.mkdir(parents=True)
            (target / 'generated.swiftmodule').write_text('generated')
            probe = SystemProbe()
            with self.assertRaises(SafetyError):
                probe.git_safe(root, target)
            (root / '.gitignore').write_text('work/\n')
            probe.git_safe(root, target)
            subprocess.run(['git', '-C', str(root), 'add', '-f', 'work/CacheModuleCache/generated.swiftmodule'], check=True)
            with self.assertRaises(SafetyError):
                probe.git_safe(root, target)
            nested = root / 'nested'
            nested.mkdir()
            with self.assertRaises(SafetyError):
                probe.git_safe(nested, target)


if __name__ == '__main__':
    unittest.main()
