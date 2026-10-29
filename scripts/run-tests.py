#!/usr/bin/env python3
"""Build and run FineTune tests; unit tests use an inert AppKit host, never FineTuneApp.init()."""
import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def run(command, *, env, log=None):
    if log:
        print(f"Running {command[1] if len(command) > 1 else command[0]} → {log}", flush=True)
        with log.open('w') as stream:
            result = subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT)
        lines = log.read_text(errors='replace').splitlines()
        summaries = [line for line in lines if 'Test run with ' in line or 'Executed ' in line or line.startswith('** ')]
        print('\n'.join(summaries or lines[-5:]), flush=True)
        if result.returncode:
            print('\n'.join(lines[-70:]), file=sys.stderr)
    else:
        result = subprocess.run(command, env=env, check=False)
    if result.returncode:
        raise SystemExit(result.returncode)


def resolve_paths(value, *, products, original_host):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(products)).replace('__TESTHOST__', str(original_host))
    if isinstance(value, list):
        return [resolve_paths(v, products=products, original_host=original_host) for v in value]
    if isinstance(value, dict):
        return {k: resolve_paths(v, products=products, original_host=original_host) for k, v in value.items()}
    return value


def isolate_unit_tests(manifest, run_dir, developer, env):
    products = manifest.parent
    with manifest.open('rb') as stream:
        data = plistlib.load(stream)
    configurations = data.get('TestConfigurations', [])
    selected = [(configuration, target) for configuration in configurations
                for target in configuration['TestTargets'] if target.get('BlueprintName') == 'FineTuneTests']
    if len(selected) != 1:
        raise SystemExit('Expected exactly one FineTuneTests target in the generated xctestrun.')
    configuration, source = selected[0]
    original_host = Path(source['TestHostPath'].replace('__TESTROOT__', str(products)))
    target = resolve_paths(copy.deepcopy(source), products=products, original_host=original_host)
    bundle = Path(target['TestBundlePath'])
    app_macos = original_host / 'Contents/MacOS' if original_host.suffix == '.app' else original_host.parent
    app_contents = app_macos.parent
    build_products = app_contents.parent.parent
    library = app_macos / 'FineTune.debug.dylib'
    if not library.is_file() or not bundle.is_dir():
        raise SystemExit('Missing Debug test bundle or FineTune.debug.dylib; rebuild with ENABLE_DEBUG_DYLIB=YES.')
    platform = developer / 'Platforms/MacOSX.platform/Developer'
    runner = platform / 'Library/Xcode/Agents/xctest'
    host_app = run_dir / 'FineTuneTestHost.app'
    host_executable = host_app / 'Contents/MacOS/xctest'
    host_executable.parent.mkdir(parents=True)
    shutil.copy2(runner, host_executable)
    with (host_app / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': 'com.finetune.tests.isolated-host',
                      'CFBundleName': 'FineTune Tests', 'CFBundleExecutable': 'xctest',
                      'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': True}, stream)
    run(['/usr/bin/codesign', '--force', '--sign', '-', str(host_app)], env=env)
    target.update(TestHostPath=str(host_executable), TestBundlePath=str(bundle),
                  IsAppHostedTestBundle=False, ParallelizationEnabled=False,
                  DependentProductPaths=[str(bundle), str(library)])
    target.pop('TestHostBundleIdentifier', None)
    # XCTestBundleInject would execute the production entry point. The inert
    # xctest host instead loads the app's Debug library as a normal dependency.
    target['EnvironmentVariables'] = {}
    test_root = run_dir / 'unit-data'
    test_root.mkdir()
    target['TestingEnvironmentVariables'] = {
        'FINETUNE_TEST_MODE': 'unit',
        'FINETUNE_TEST_DATA_ROOT': str(test_root),
        'DYLD_LIBRARY_PATH': ':'.join(map(str, [app_macos, build_products, platform / 'usr/lib'])),
        'DYLD_FRAMEWORK_PATH': ':'.join(map(str, [build_products, build_products / 'PackageFrameworks',
                                               app_contents / 'Frameworks', platform / 'Library/Frameworks']))
    }
    config = copy.deepcopy(configuration)
    config['TestTargets'] = [target]
    data['TestConfigurations'] = [config]
    data.pop('CodeCoverageBuildableInfos', None)
    output = run_dir / 'UnitTests.xctestrun'
    with output.open('wb') as stream:
        plistlib.dump(data, stream)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=['unit', 'ui', 'all'], default='unit',
                        help='unit (default) runs all FineTuneTests; ui/all launch the real UI integration host')
    parser.add_argument('--build-dir', type=Path, help='defaults to build/tests in the repository')
    parser.add_argument('--packages-dir', type=Path, help='optional existing package checkout cache')
    parser.add_argument('--skip-build', action='store_true', help='use the latest existing Debug test build')
    parser.add_argument('--only', action='append', default=[], metavar='TARGET/SUITE[/TEST]',
                        help='repeat to select tests; without this, every test in the chosen target runs')
    args = parser.parse_args()
    allowed_targets = {'unit': {'FineTuneTests'}, 'ui': {'FineTuneUITests'}, 'all': {'FineTuneTests', 'FineTuneUITests'}}[args.suite]
    for selection in args.only:
        if selection.split('/')[0] not in allowed_targets:
            parser.error(f'Invalid test target for --suite {args.suite}: {selection}')
    repo = Path(__file__).resolve().parents[1]
    if not (repo / 'FineTune.xcodeproj').is_dir():
        parser.error('Run the script from its scripts/ location in the FineTune repository.')
    env = os.environ.copy()
    developer = Path(env.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
    if not (developer / 'usr/bin/xcodebuild').is_file():
        developer = Path(subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True).strip())
    if not (developer / 'usr/bin/xcodebuild').is_file():
        parser.error('Full Xcode is required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer.')
    env['DEVELOPER_DIR'] = str(developer)
    if args.suite in ('ui', 'all'):
        running = subprocess.run(['/usr/bin/pgrep', '-x', 'FineTune'], capture_output=True)
        if running.returncode == 0:
            parser.error('UI integration launches FineTune and its audio services. Quit the running FineTune first, or use --suite unit.')
    build_dir = (args.build_dir or repo / 'build/tests').resolve()
    products = build_dir / 'DerivedData/Build/Products'
    packages = (args.packages_dir or build_dir / 'SourcePackages').resolve()
    run_dir = build_dir / 'runs' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    run_dir.mkdir(parents=True)
    xcodebuild = str(developer / 'usr/bin/xcodebuild')
    destination = f'platform=macOS,arch={os.uname().machine}'
    if not args.skip_build:
        run([xcodebuild, 'build-for-testing', '-project', str(repo / 'FineTune.xcodeproj'),
             '-scheme', 'FineTune', '-destination', destination, '-derivedDataPath', str(build_dir / 'DerivedData'),
             '-clonedSourcePackagesDirPath', str(packages), '-disableAutomaticPackageResolution',
             'ENABLE_DEBUG_DYLIB=YES', 'CODE_SIGNING_ALLOWED=' + ('NO' if args.suite == 'unit' else 'YES')], env=env, log=run_dir / 'build.log')
    manifests = sorted(products.glob('FineTune_*.xctestrun'), key=lambda p: p.stat().st_mtime, reverse=True)
    if not manifests:
        parser.error('No xctestrun found; run without --skip-build.')
    manifest = manifests[0]
    suites = ['unit', 'ui'] if args.suite == 'all' else [args.suite]
    for suite in suites:
        selected_manifest = isolate_unit_tests(manifest, run_dir, developer, env) if suite == 'unit' else manifest
        target = 'FineTuneTests' if suite == 'unit' else 'FineTuneUITests'
        selections = [item for item in args.only if item.split('/')[0] == target]
        if args.only and not selections:
            continue
        run([xcodebuild, 'test-without-building', '-xctestrun', str(selected_manifest),
             '-destination', destination, '-parallel-testing-enabled', 'NO',
             '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '60',
             '-maximum-test-execution-time-allowance', '120',
             *[f'-only-testing:{item}' for item in (selections or [target])],
             '-resultBundlePath', str(run_dir / f'{suite}.xcresult')], env=env, log=run_dir / f'{suite}.log')
        report = subprocess.run([str(developer / 'usr/bin/xcresulttool'), 'get', 'test-results', 'summary',
                                 '--path', str(run_dir / f'{suite}.xcresult'), '--format', 'json'],
                                env=env, text=True, capture_output=True)
        if report.returncode:
            raise SystemExit(f'Could not read test summary: {report.stderr}')
        summary = json.loads(report.stdout)
        (run_dir / f'{suite}-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        if summary.get('totalTestCount', 0) == 0 or summary.get('passedTests', 0) == 0:
            raise SystemExit('No tests passed. Check --only filters and skipped tests; an empty run is not success.')
        if summary.get('failedTests', 0):
            raise SystemExit('The result bundle contains failed tests.')
        print(f"{suite}: {summary['passedTests']} passed, {summary.get('skippedTests', 0)} skipped", flush=True)
    print(f'Results: {run_dir}', flush=True)


if __name__ == '__main__':
    main()
