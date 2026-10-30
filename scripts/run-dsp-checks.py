#!/usr/bin/env python3
"""Run the actual DSP/HAL sources in a small sanitizer harness, without starting FineTune."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

SOURCES = [
    'Audio/Engine/RealtimeSnapshot.swift', 'Audio/Engine/HALExecutor.swift',
    'Audio/Types/BiquadProcessable.swift', 'Audio/EQ/BiquadMath.swift',
    'Audio/EQ/BiquadProcessor.swift', 'Audio/EQ/EQProcessor.swift',
    'Audio/AutoEQ/AutoEQProcessor.swift', 'Audio/Loudness/LoudnessCompensator.swift',
    'Audio/Loudness/ISO226Contours.swift', 'Audio/Engine/SoftLimiter.swift',
    'Audio/Engine/CrossfadeState.swift', 'Audio/Engine/DeviceTransitionCoordinator.swift',
    'Models/EQSettings.swift', 'Models/AutoEQProfile.swift',
]
TESTS = [
    'CrossfadeReadinessTests.swift', 'DeviceTransitionCoordinatorTests.swift', 'CrossfadeConcurrencyTests.swift', 'CrossfadeStateAdversarialTests.swift',
    'RealtimeSnapshotTests.swift', 'HALWorkerPoolTests.swift',
    'BiquadProcessorSignalTests.swift', 'BiquadProcessorSignalAdversarialTests.swift',
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitizer', choices=['thread', 'address'], required=True)
    parser.add_argument('--build-dir', type=Path)
    parser.add_argument('--atomics-path', type=Path, help='optional local Swift Atomics checkout')
    parser.add_argument('--filter', help='optional Swift Testing suite/test filter')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    root = (args.build_dir or repo / 'build/dsp-checks' / args.sanitizer).resolve()
    package = root / 'harness'
    sources = package / 'Sources/FineTune'
    tests = package / 'Tests/FineTuneTests'
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for relative, destination in [(repo / 'FineTune' / s, sources / Path(s).name) for s in SOURCES] + [
        (repo / 'FineTuneTests' / t, tests / t) for t in TESTS
    ]:
        data = relative.read_bytes()
        destination.write_bytes(data)
        manifest[str(relative.relative_to(repo))] = hashlib.sha256(data).hexdigest()
    if args.atomics_path:
        dependency = f'.package(path: {json.dumps(str(args.atomics_path.resolve()))})'
    else:
        dependency = '.package(url: "https://github.com/apple/swift-atomics", exact: "1.3.1")'
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "FineTuneDSPChecks", platforms: [.macOS("14.2")],
    dependencies: [DEPENDENCY], targets: [
        .target(name: "FineTune", dependencies: [.product(name: "Atomics", package: "swift-atomics")],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "FineTuneTests", dependencies: ["FineTune"])
    ], swiftLanguageModes: [.v5])
'''.replace('DEPENDENCY', dependency))
    (root / 'source-hashes.json').write_text(json.dumps(manifest, indent=2) + '\n')
    env = os.environ.copy()
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    command = ['/usr/bin/xcrun', 'swift', 'test', '--package-path', str(package),
               '--scratch-path', str(root / 'build'), '--sanitize', args.sanitizer]
    if args.filter: command += ['--filter', args.filter]
    print(' '.join(command), flush=True)
    result = subprocess.run(command, env=env)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
