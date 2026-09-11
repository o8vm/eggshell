#!/usr/bin/env python3
"""Install the pinned local runtime without registering another Codex plugin."""
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', default=os.environ.get('EGGSHELL_PREFIX', str(Path.home() / '.local')))
    args = parser.parse_args()
    prefix = Path(args.prefix).expanduser()
    if not prefix.is_absolute():
        raise ValueError('--prefix must be an absolute path.')
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
        environment = dict(os.environ, EGGSHELL_PREFIX=str(prefix))
        subprocess.run([str(executable), 'install', 'runtime'], env=environment, check=True)
    print(f'Runtime ready. Add {prefix}/bin to PATH, initialize your project, and review /hooks.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, tarfile.TarError) as error:
        raise SystemExit(f'eggshell setup: {error}')
