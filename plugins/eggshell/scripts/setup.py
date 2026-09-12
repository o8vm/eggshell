#!/usr/bin/env python3
"""Set up local memory for a project, or check its configuration without changes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


def target():
    system = {'Darwin': 'macos', 'Linux': 'linux'}.get(platform.system())
    machine = {'arm64': 'aarch64', 'aarch64': 'aarch64',
               'x86_64': 'x86_64', 'amd64': 'x86_64'}.get(platform.machine().lower())
    if not system or not machine:
        raise ValueError('Eggshell requires macOS or Linux on ARM64 or x86-64.')
    return f'{system}-{machine}'


def extract_runtime(archive, destination, expected):
    digest = hashlib.sha256()
    with archive.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != expected:
        raise ValueError('Runtime checksum mismatch; nothing was installed.')
    with tarfile.open(archive, 'r:gz') as bundle:
        members = bundle.getmembers()
        if len(members) != 1 or members[0].name != 'eggshell' or not members[0].isfile():
            raise ValueError('Runtime archive must contain exactly one regular eggshell executable.')
        if members[0].size > 512 * 1024 * 1024:
            raise ValueError('Runtime executable exceeds the size limit.')
        with bundle.extractfile(members[0]) as source, destination.open('wb') as output:
            shutil.copyfileobj(source, output)
    destination.chmod(0o755)


def inspect_project(runtime, project, environment):
    result = subprocess.run([str(runtime), 'egg', 'doctor'], cwd=project,
                            env=environment, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f'Eggshell setup check exited {result.returncode}.')
    return json.loads(result.stdout)


def initialize_project(runtime, project, environment):
    """Let the runtime resolve existing project/global settings; never replace them."""
    report = inspect_project(runtime, project, environment)
    if report['configuration'] == 'missing':
        subprocess.run([str(runtime), 'egg', 'init'], cwd=project,
                       env=environment, check=True)
        report = inspect_project(runtime, project, environment)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', default=os.environ.get('EGGSHELL_PREFIX', str(Path.home() / '.local')))
    parser.add_argument('--project', type=Path, default=Path.cwd(),
                        help='Project to configure (defaults to the current directory).')
    parser.add_argument('--check', action='store_true',
                        help='Read setup status; do not download, initialize, or enable anything.')
    args = parser.parse_args()
    prefix = Path(args.prefix).expanduser()
    if not prefix.is_absolute():
        raise ValueError('--prefix must be an absolute path.')
    project = args.project.resolve(strict=True)
    if not project.is_dir():
        raise ValueError('--project must be a directory.')
    environment = dict(os.environ, EGGSHELL_PREFIX=str(prefix))
    # A different project's setup must not reuse the caller's chat profile.
    environment.pop('CODEX_THREAD_ID', None)
    installed = prefix / 'libexec/eggshell'
    if args.check:
        marker = prefix / 'libexec/eggshell.owner'
        if (not os.access(installed, os.X_OK) or not marker.is_file()
                or marker.read_text().strip() != 'o8vm/eggshell'):
            print(json.dumps({'runtime': 'missing', 'configuration': 'unknown',
                              'next_step': 'Ask Codex: Set up Eggshell for this project.'}))
            return 1
        help_result = subprocess.run([str(installed), 'egg', '--help'], env=environment,
                                     check=True, text=True, capture_output=True)
        if 'doctor' not in help_result.stdout:
            print(json.dumps({'runtime': 'update_required', 'configuration': 'unchecked',
                              'next_step': 'Run this setup without --check to update the runtime.'}))
            return 1
        report = inspect_project(installed, project, environment)
        print(json.dumps(report, indent=2))
        return 0 if report['configuration'] == 'ready' else 1
    manifest = json.loads((Path(__file__).resolve().parent.parent / 'runtime.json').read_text())
    asset = manifest['targets'][target()]
    url = f"https://github.com/momonpya/eggshell/releases/download/{manifest['release']}/{asset['file']}"
    with tempfile.TemporaryDirectory(prefix='eggshell-setup-') as directory:
        archive = Path(directory) / 'runtime.tar.gz'
        total = 0
        with urllib.request.urlopen(url, timeout=60) as response, archive.open('wb') as output:
            while block := response.read(1024 * 1024):
                total += len(block)
                if total > 100 * 1024 * 1024:
                    raise ValueError('Runtime download exceeds the size limit.')
                output.write(block)
        executable = Path(directory) / 'eggshell'
        extract_runtime(archive, executable, asset['sha256'])
        subprocess.run([str(executable), 'install', 'runtime'], env=environment, check=True)
    report = initialize_project(installed, project, environment)
    print(json.dumps(report, indent=2))
    print('Local setup complete. Memory activation is not yet verified.')
    print('In Codex, review Eggshell in /hooks and start a new chat in this project.')
    print('Look for "Eggshell session hook connected", then run !egg doctor.')
    print('Verify a saved investigation and a related follow-up in a separate chat with !egg graph.')
    print(f'For terminal controls, add {prefix}/bin to PATH.')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, tarfile.TarError) as error:
        raise SystemExit(f'eggshell setup: {error}')
