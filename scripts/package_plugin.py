#!/usr/bin/env python3
"""Build a directory ZIP and immutable runtime assets from four tested binaries."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import zipfile

TARGETS = ('linux-aarch64', 'linux-x86_64', 'macos-aarch64', 'macos-x86_64')


def package(runtime_dir, output, release):
    root = Path(__file__).resolve().parent.parent
    output.mkdir(parents=True, exist_ok=True)
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    runtime = {'release': release, 'source_commit': source, 'targets': {}}
    for target in TARGETS:
        archive = runtime_dir / f'eggshell-{target}.tar.gz'
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        name = f'eggshell-runtime-{target}-{digest[:16]}.tar.gz'
        destination = output / name
        shutil.copyfile(archive, destination)
        runtime['targets'][target] = {'file': name, 'sha256': digest}
    with tempfile.TemporaryDirectory(prefix='eggshell-package-') as directory:
        plugin = Path(directory) / 'eggshell'
        shutil.copytree(root / 'plugins' / 'eggshell', plugin,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        (plugin / 'assets').mkdir()
        shutil.copyfile(root / 'docs/assets/brand/eggshell-app-icon-dark-1024.png', plugin / 'assets/icon.png')
        shutil.copyfile(root / 'LICENSE', plugin / 'LICENSE')
        manifest_path = plugin / '.codex-plugin/plugin.json'
        manifest = json.loads(manifest_path.read_text())
        if release != 'v' + manifest['version']:
            raise ValueError('Release tag must match the plugin version.')
        manifest['skills'] = './skills'
        manifest['interface'].update({
            'logo': './assets/icon.png', 'composerIcon': './assets/icon.png',
            'privacyPolicyURL': 'https://github.com/momonpya/eggshell/blob/main/PRIVACY.md',
            'defaultPrompt': ['Set up Eggshell for this Codex project.',
                              'Show what Eggshell handed to this task and why it was selected.',
                              'Help me inspect pending Eggshell work before keeping it.']})
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        (plugin / 'runtime.json').write_text(json.dumps(runtime, indent=2) + '\n')
        archive_path = output / 'eggshell-codex-plugin.zip'
        with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for file in sorted(plugin.rglob('*')):
                if file.is_symlink():
                    raise ValueError(f'Symlinks are not allowed: {file}')
                if file.is_file():
                    info = zipfile.ZipInfo(file.relative_to(plugin).as_posix(), (2026, 1, 1, 0, 0, 0))
                    mode = 0o755 if file.parent.name == 'bin' else 0o644
                    info.external_attr = (stat.S_IFREG | mode) << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, file.read_bytes())
        if archive_path.stat().st_size > 100_000_000:
            raise ValueError('Plugin ZIP exceeds 100 MB.')
        (output / 'runtime.json').write_text(json.dumps(runtime, indent=2) + '\n')
        print(f'{archive_path}: {archive_path.stat().st_size:,} bytes; four pinned runtime assets')
    return archive_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--release', required=True)
    args = parser.parse_args()
    package(args.runtime_dir, args.output, args.release)
