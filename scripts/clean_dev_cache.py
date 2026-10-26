#!/usr/bin/env python3
"""Remove only verified, unused build caches directly below this repo's work/.

Default: dry run. --apply deletes after fresh process, Git, tree and open-file
checks. Keep one newest simulator build, one newest device build, and the newest
two xcresult bundles. Standalone generated module caches are all disposable.
Unknown/mixed build types and source snapshots are retained. No external paths,
App data, outputs, signing inputs, or simulator data are inspected or cleaned.
"""
import argparse
from contextlib import contextmanager
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys


class SafetyError(RuntimeError):
    pass


@dataclass(frozen=True)
class Tree:
    size: int
    newest: int
    fingerprint: str
    files: tuple = field(repr=False)


@dataclass(frozen=True)
class Candidate:
    path: Path
    kind: str
    tree: Tree


class SystemProbe:
    """System checks are separate so tests never depend on host build processes."""
    BUILD_TOOLS = {
        'xcodebuild', 'swift', 'swiftc', 'swift-frontend',
        'swift-driver', 'clang', 'clang++', 'ld', 'actool', 'ibtool', 'metal',
        'assetcatalogbuilder', 'builtin-swiftTaskExecution', 'xctest', 'xcrun',
        'swift-build', 'swift-test', 'swift-package', 'SwiftBuild',
        'make', 'ninja', 'cmake', 'libtool', 'dsymutil', 'codesign',
    }

    def run(self, command):
        try:
            return subprocess.run(command, capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            raise SafetyError(f'{Path(command[0]).name} inspection unavailable') from None

    def processes(self):
        result = self.run(['ps', '-axo', 'comm='])
        if result.returncode or result.stderr:
            raise SafetyError('process inspection failed')
        active = {Path(line.strip()).name for line in result.stdout.decode().splitlines()}
        # Xcode's XCBBuildService/SWBBuildService can remain resident while idle.
        # Their use of a cleanup target is checked by unopened(), like any other
        # process; an idle service alone does not mean a build is in progress.
        building = active & self.BUILD_TOOLS
        if building:
            raise SafetyError('a build or test tool is running: ' + ', '.join(sorted(building)))

    def git_safe(self, root, target):
        prefix = ['git', '-C', str(root)]
        top = self.run(prefix + ['rev-parse', '--show-toplevel'])
        if top.returncode or top.stderr or Path(os.fsdecode(top.stdout).strip()).resolve() != root:
            raise SafetyError('cannot verify the exact Git repository')
        relative = target.relative_to(root).as_posix()
        ignored = self.run(prefix + ['check-ignore', '--quiet', '--no-index', '--', relative])
        if ignored.returncode or ignored.stderr:
            raise SafetyError('target is not verifiably Git-ignored')
        tracked = self.run(prefix + ['ls-files', '-z', '--', f':(literal){relative}'])
        if tracked.returncode or tracked.stderr or tracked.stdout:
            raise SafetyError('target contains tracked files or Git inspection failed')

    def unopened(self, target):
        result = self.run(['lsof', '-nP', '-t', '+D', str(target)])
        # lsof returns 1 with no output when it found no open files.
        if result.stderr or result.returncode not in (0, 1):
            raise SafetyError('open-file inspection failed')
        if result.stdout or result.returncode == 0:
            raise SafetyError('target has open files')


def scan_tree(path):
    """Never follow links; fingerprint metadata and reject nested repositories."""
    digest = hashlib.sha256()
    size = newest = 0
    files = []
    stack = [path]
    try:
        while stack:
            item = stack.pop()
            metadata = item.lstat()
            relative = item.relative_to(path).as_posix()
            if stat.S_ISLNK(metadata.st_mode) or item.name == '.git':
                raise SafetyError('tree contains a symbolic link or nested Git repository')
            if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
                raise SafetyError('tree contains a special file')
            digest.update(os.fsencode(relative))
            digest.update(repr((metadata.st_dev, metadata.st_ino, metadata.st_mode,
                                metadata.st_size, metadata.st_mtime_ns)).encode())
            newest = max(newest, metadata.st_mtime_ns)
            if stat.S_ISDIR(metadata.st_mode):
                stack.extend(sorted(item.iterdir(), reverse=True))
            else:
                size += metadata.st_size
                files.append(relative)
    except OSError:
        raise SafetyError('tree inspection failed') from None
    return Tree(size, newest, digest.hexdigest(), tuple(files))


class Cleaner:
    DERIVED_NAMES = {
        'info.plist', 'Build', 'Logs', 'ModuleCache.noindex', 'SDKStatCaches.noindex',
        'Index.noindex', 'CompilationCache.noindex', 'TestResults',
        'ClangStatCache.noindex',
    }
    RESULT_NAMES = {'Info.plist', 'Data', 'Staging', 'database.sqlite3',
                    'database.sqlite3-shm', 'database.sqlite3-wal'}
    SWIFTPM_REQUIRED = {'build.db', 'debug.yaml', 'workspace-state.json'}
    SWIFTPM_NAMES = SWIFTPM_REQUIRED | {'.lock', 'plugin-tools.yaml', 'artifacts',
                      'checkouts', 'repositories', 'debug', 'arm64-apple-macosx', 'x86_64-apple-macosx'}
    MODULE_NAME = re.compile(r'(?:[A-Za-z0-9_.-]*ModuleCache|[A-Za-z0-9_.-]*module-cache|[A-Za-z0-9_.-]*TypecheckCache)(?:\.noindex)?')
    MODULE_FILE = re.compile(r'[A-Za-z0-9_.+-]+\.(?:pcm|swiftmodule|swiftdoc|swiftsourceinfo)')

    def __init__(self, repo_root, probe=None, keep_results=2):
        original = Path(repo_root).absolute()
        if original.is_symlink():
            raise SafetyError('repository root must not be a symbolic link')
        self.root = original.resolve()
        self.work = self.root / 'work'
        self.probe = probe or SystemProbe()
        if keep_results < 0:
            raise ValueError('keep_results must be non-negative')
        self.keep_results = keep_results

    def check_work(self):
        if self.work.is_symlink() or not self.work.is_dir():
            raise SafetyError('work/ is missing, not a directory, or a symbolic link')

    def plausible(self, path):
        # Inspect only direct names before the full no-link tree check.
        names = {entry.name for entry in path.iterdir()}
        return (self.MODULE_NAME.fullmatch(path.name)
                or {'info.plist', 'Build'} <= names <= self.DERIVED_NAMES
                or (path.name.endswith('.xcresult') and {'Info.plist', 'Data'} <= names <= self.RESULT_NAMES)
                or (path.name.endswith('Build') and self.SWIFTPM_REQUIRED <= names <= self.SWIFTPM_NAMES))

    def own_project(self, project):
        if not project.is_absolute() or project.name not in ('VYu.xcodeproj', 'VYu.xcworkspace'):
            return False
        if project.parent != self.root and self.work not in project.parents:
            return False
        try:
            current = self.root
            for part in project.relative_to(self.root).parts:
                if part == '..':
                    return False
                current = current / part
                if current.is_symlink() or not current.is_dir():
                    return False
        except (OSError, ValueError):
            return False
        return True

    def classify(self, path):
        names = {entry.name for entry in path.iterdir()}
        if {'info.plist', 'Build'} <= names and names <= self.DERIVED_NAMES:
            info = plistlib.loads((path / 'info.plist').read_bytes())
            project = Path(info.get('WorkspacePath', ''))
            # Do not clean DerivedData for a different project, even inside work/.
            if not self.own_project(project):
                return None
            if not (path / 'Build').is_dir() or not any(
                    (path / name).is_dir() for name in ('Logs', 'ModuleCache.noindex', 'SDKStatCaches.noindex')):
                return None
            products = path / 'Build' / 'Products'
            product_dirs = [entry.name for entry in products.iterdir() if entry.is_dir()] if products.is_dir() else []
            platforms = {name.rsplit('-', 1)[-1] for name in product_dirs}
            if not platforms <= {'iphonesimulator', 'iphoneos'}:
                return 'unknown-build'
            return next(iter(platforms)) if len(platforms) == 1 else 'unknown-build'
        if path.name.endswith('.xcresult') and {'Info.plist', 'Data'} <= names <= self.RESULT_NAMES:
            info = plistlib.loads((path / 'Info.plist').read_bytes())
            if isinstance(info, dict) and {'rootId', 'version'} <= info.keys() and (path / 'Data').is_dir():
                return 'xcresult'
        if self.MODULE_NAME.fullmatch(path.name):
            return 'module-cache'
        if path.name.endswith('Build') and self.SWIFTPM_REQUIRED <= names <= self.SWIFTPM_NAMES:
            package = self.work / path.name[:-5]
            if package.is_symlink() or not (package / 'Package.swift').is_file() or not (package / 'Sources').is_dir():
                return None
            if any((path / name).is_dir() and any((path / name).iterdir())
                   for name in ('artifacts', 'checkouts', 'repositories')):
                return None  # May contain downloaded source, never a cache-only target.
            state = json.loads((path / 'workspace-state.json').read_text())
            descriptions = [path / triple / 'debug' / 'description.json'
                            for triple in ('arm64-apple-macosx', 'x86_64-apple-macosx')]
            if (isinstance(state, dict) and {'object', 'version'} <= state.keys()
                    and any(file.is_file() and 'swiftCommands' in json.loads(file.read_text()) for file in descriptions)):
                return 'swiftpm-cache'
        return None

    def validate(self, path, kind):
        self.check_work()
        if path.parent != self.work or path.is_symlink() or not path.is_dir():
            raise SafetyError('target is not a direct, real work/ directory')
        self.probe.git_safe(self.root, path)
        tree = scan_tree(path)
        if kind == 'module-cache':
            if not tree.files:
                raise SafetyError('empty or unrecognized module cache')
            for relative in tree.files:
                parts = Path(relative).parts
                if (len(parts) > 2 or any(not re.fullmatch(r'[A-Z0-9]{5,}', part) for part in parts[:-1])
                        or not (self.MODULE_FILE.fullmatch(parts[-1]) or parts[-1] in ('modules.timestamp', 'modules.idx'))):
                    if len(parts) == 1 and parts[-1].endswith('.abi.json'):
                        abi = json.loads((path / relative).read_text())
                        if isinstance(abi, dict) and 'ABIRoot' in abi:
                            continue
                    raise SafetyError('module cache contains non-generated files')
            if not any(name.endswith(('.pcm', '.swiftmodule')) for name in tree.files):
                raise SafetyError('module cache has no generated modules')
        return tree

    def plan(self):
        self.check_work()
        report = {'apply': False, 'retention': {'iphonesimulator': 1, 'iphoneos': 1,
                  'xcresult': self.keep_results, 'module-cache': 0, 'swiftpm-cache': 0}, 'blocked': [],
                  'delete': [], 'keep': [], 'skipped': [], 'deleted_bytes': 0}
        try:
            self.probe.processes()
        except SafetyError as error:
            report['blocked'].append(str(error))
        candidates = []
        for path in sorted(self.work.iterdir()):
            if path.is_symlink() or not path.is_dir():
                continue
            try:
                if not self.plausible(path):
                    continue
                tree = self.validate(path, 'module-cache' if self.MODULE_NAME.fullmatch(path.name) else 'pending')
                kind = self.classify(path)
                if kind:
                    candidates.append(Candidate(path, kind, tree))
            except (SafetyError, OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException) as error:
                reason = str(error) if isinstance(error, SafetyError) else 'cache format inspection failed'
                report['skipped'].append({'path': path.relative_to(self.root).as_posix(), 'reason': reason})
        for kind in ('iphonesimulator', 'iphoneos', 'xcresult', 'module-cache', 'swiftpm-cache', 'unknown-build'):
            group = sorted((item for item in candidates if item.kind == kind),
                           key=lambda item: (-item.tree.newest, item.path.name))
            keep = len(group) if kind == 'unknown-build' else report['retention'][kind]
            for index, item in enumerate(group):
                entry = {'path': item.path.relative_to(self.root).as_posix(), 'kind': kind,
                         'bytes': item.tree.size, 'fingerprint': item.tree.fingerprint}
                report['keep' if index < keep else 'delete'].append(entry)
        report['candidate_bytes'] = sum(item['bytes'] for item in report['delete'])
        return report

    @contextmanager
    def pinned_work(self):
        if not hasattr(os, 'O_NOFOLLOW') or not hasattr(os, 'O_DIRECTORY') or not hasattr(os, 'fchdir'):
            raise SafetyError('this system cannot pin work/ safely')
        self.check_work()
        fd = os.open(self.work, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            yield fd
        finally:
            os.close(fd)

    def same_work(self, fd):
        metadata = self.work.lstat()
        pinned = os.fstat(fd)
        if not stat.S_ISDIR(metadata.st_mode) or (metadata.st_dev, metadata.st_ino) != (pinned.st_dev, pinned.st_ino):
            raise SafetyError('work/ changed since inspection')

    def apply(self, report):
        """Pin work/ and revalidate every target; refuse the batch on preflight errors."""
        if report['blocked']:
            raise SafetyError('; '.join(report['blocked']))
        if not shutil.rmtree.avoids_symlink_attacks:
            raise SafetyError('this Python cannot safely remove directory trees')
        with self.pinned_work() as work_fd:
            self.probe.processes()
            for entry in report['delete']:
                self.same_work(work_fd)
                self.revalidate(entry)
                self.probe.unopened(self.root / entry['path'])
            report['apply'] = True
            report['deleted'] = []
            for entry in report['delete']:
                path = self.root / entry['path']
                self.same_work(work_fd)
                self.revalidate(entry)
                self.probe.unopened(path)
                self.probe.processes()
                self.same_work(work_fd)
                # Python 3.9 lacks rmtree(dir_fd=). A pinned cwd gives its fd-based
                # implementation the same boundary, even if work/ is swapped.
                cwd_fd = os.open('.', os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fchdir(work_fd)
                    shutil.rmtree(path.name)
                finally:
                    os.fchdir(cwd_fd)
                    os.close(cwd_fd)
                report['deleted'].append(entry['path'])
                report['deleted_bytes'] += entry['bytes']
        return report

    def revalidate(self, entry):
        path = self.root / entry['path']
        # Validate boundary before reading plist or enumerating any target.
        if path.parent != self.work or path.is_symlink():
            raise SafetyError('target left the work/ boundary')
        tree = self.validate(path, entry['kind'])
        if self.classify(path) != entry['kind'] or tree.fingerprint != entry['fingerprint']:
            raise SafetyError('target changed since inspection; run a new dry run')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='delete verified unused caches (default: dry run)')
    parser.add_argument('--keep-results', type=int, default=2, metavar='N', help='keep latest N xcresult bundles (default: 2)')
    parser.add_argument('--json', action='store_true', help='print a JSON report instead of human-readable output')
    args = parser.parse_args()
    report = None
    try:
        cleaner = Cleaner(Path(__file__).resolve().parents[1], keep_results=args.keep_results)
        report = cleaner.plan()
        if args.apply:
            cleaner.apply(report)
    except (SafetyError, OSError, ValueError) as error:
        # Do not include subprocess output, plist values, URLs, or file contents.
        message = str(error) if isinstance(error, (SafetyError, ValueError)) else 'filesystem operation failed'
        if args.json:
            print(json.dumps({'error': message, 'report': report}, indent=2))
        else:
            print('Refused: ' + message, file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        action = 'Deleted' if args.apply else 'Would delete'
        print(f"{action} {len(report['delete'])} caches, {report['candidate_bytes'] / (1024 ** 3):.2f} GiB")
        print('Keep: newest simulator build + newest device build; '
              f"latest {args.keep_results} xcresult bundles; unknown/mixed builds and all other work retained.")
        for entry in report['delete']:
            print(f"  {entry['path']} ({entry['bytes'] / (1024 ** 2):.1f} MiB)")
        for reason in report['blocked']:
            print('Apply blocked: ' + reason)
        if report['skipped']:
            print(f"Skipped {len(report['skipped'])} unverified caches (use --json for reasons).")
        if not args.apply:
            print('Dry run only. Use --apply after reviewing the list.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
