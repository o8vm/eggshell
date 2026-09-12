"""Check the installation boundary and the downloadable runtime contract."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


setup = module('eggshell_setup', ROOT / 'plugins/eggshell/scripts/setup.py')
packager = module('eggshell_packager', ROOT / 'scripts/package_plugin.py')


def archive_at(file, payload=b'#!/bin/sh\nexit 0\n', symlink=False):
    with tarfile.open(file, 'w:gz') as archive:
        info = tarfile.TarInfo('eggshell')
        if symlink:
            info.type = tarfile.SYMTYPE
            info.linkname = '/tmp/unrelated'
            archive.addfile(info)
        else:
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
    return hashlib.sha256(file.read_bytes()).hexdigest()


class PackageTests(unittest.TestCase):
    def test_checksum_and_archive_type(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'runtime.tar.gz'
            executable = root / 'eggshell'
            digest = archive_at(archive)
            with self.assertRaisesRegex(ValueError, 'checksum'):
                setup.extract_runtime(archive, executable, '0' * 64)
            self.assertFalse(executable.exists())
            setup.extract_runtime(archive, executable, digest)
            self.assertEqual(subprocess.run([executable]).returncode, 0)
            executable.unlink()
            digest = archive_at(archive, symlink=True)
            with self.assertRaisesRegex(ValueError, 'regular'):
                setup.extract_runtime(archive, executable, digest)
            self.assertFalse(executable.exists())

    def test_missing_runtime_does_not_download_or_block_hooks(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, EGGSHELL_PREFIX=directory)
            launcher = ROOT / 'plugins/eggshell/bin/egg'
            result = subprocess.run([launcher, 'codex-hook'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout), {})
            self.assertEqual(list(Path(directory).iterdir()), [])
            result = subprocess.run([launcher, 'inspect'], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not installed', result.stderr)

    def test_missing_runtime_notice_is_startup_only_and_never_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, EGGSHELL_PREFIX=directory)
            launcher = ROOT / 'plugins/eggshell/bin/egg'
            hooks = json.loads((ROOT / 'plugins/eggshell/hooks/hooks.json').read_text())
            for source in ['startup', 'resume', 'clear', 'compact']:
                matched = [g for g in hooks['hooks']['SessionStart']
                           if re.search(g.get('matcher', ''), source)]
                self.assertEqual(len(matched), 1)
                entry = matched[0]['hooks'][0]['command'].split()[-1]
                result = subprocess.run([launcher, entry], env=env, input=json.dumps({
                    'hook_event_name': 'SessionStart', 'source': source}),
                    capture_output=True, text=True, timeout=2)
                self.assertEqual(result.returncode, 0, result.stderr)
                reply = json.loads(result.stdout)
                if source == 'compact':
                    self.assertEqual(reply, {})
                else:
                    self.assertIn('memory is not active', reply['systemMessage'])
                    self.assertIn('Set up Eggshell', reply['systemMessage'])
                    self.assertNotIn('continue', reply)
                    self.assertNotIn('hookSpecificOutput', reply)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_startup_launcher_forwards_the_original_hook_input(self):
        with tempfile.TemporaryDirectory(prefix="egg prefix's ") as directory:
            root = Path(directory)
            runtime = root / 'libexec/eggshell'
            runtime.parent.mkdir()
            runtime.write_text('#!/bin/sh\n[ "$1" = codex-hook ] || exit 9\ncat\n')
            runtime.chmod(0o755)
            (root / 'libexec/eggshell.owner').write_text('o8vm/eggshell\n')
            payload = json.dumps({'hook_event_name': 'SessionStart', 'cwd': "a b'c",
                                  'session_id': 'a-chat'})
            result = subprocess.run([ROOT / 'plugins/eggshell/bin/egg', 'codex-start'],
                input=payload, text=True, capture_output=True,
                env=dict(os.environ, EGGSHELL_PREFIX=directory))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, payload)

    def test_project_setup_preserves_parent_and_global_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            project = root / 'project'
            project.mkdir()
            env = dict(os.environ, EGGSHELL_PREFIX=str(root / 'prefix'),
                       EGGSHELL_DATA_ROOT=str(root / 'data'))
            env.pop('EGGSHELL_CONFIG', None)
            env.pop('CODEX_THREAD_ID', None)
            runtime = ROOT / '.lake/build/bin/eggshell'
            report = setup.initialize_project(runtime, project, env)
            self.assertEqual(report['configuration'], 'ready')
            self.assertFalse(report['session_state_present'])
            self.assertFalse(report['handoff_observed'])
            config = project / '.eggshell.toml'
            custom = config.read_text().replace('default = "work"', 'default = "private"')
            config.write_text(custom)
            nested = project / 'nested'
            nested.mkdir()
            report = setup.initialize_project(runtime, nested, env)
            self.assertEqual(report['memory'], 'read-only')
            self.assertEqual(config.read_text(), custom)
            self.assertFalse((nested / '.eggshell.toml').exists())
            self.assertFalse((project / '.eggs/work.egg').exists())
            other = root / 'other'
            other.mkdir()
            global_config = root / 'prefix/config/eggshell/config.toml'
            global_config.parent.mkdir(parents=True)
            global_config.write_text(custom)
            report = setup.initialize_project(runtime, other, env)
            self.assertEqual(report['memory'], 'read-only')
            self.assertFalse((other / '.eggshell.toml').exists())
            self.assertEqual(global_config.read_text(), custom)
            self.assertFalse((root / 'data').exists())

    def test_setup_check_does_not_install_or_initialize(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.run(['python3', ROOT / 'plugins/eggshell/scripts/setup.py',
                '--check', '--prefix', str(root / 'missing'), '--project', str(root)],
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)['runtime'], 'missing')
            self.assertEqual(list(root.iterdir()), [])

    def test_invalid_existing_configuration_is_reported_and_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            config = root / '.eggshell.toml'
            config.write_text('default = true\n')
            env = dict(os.environ, EGGSHELL_PREFIX=str(root / 'prefix'),
                       EGGSHELL_DATA_ROOT=str(root / 'data'))
            env.pop('EGGSHELL_CONFIG', None)
            env.pop('CODEX_THREAD_ID', None)
            with self.assertRaisesRegex(ValueError, 'expected quoted TOML string'):
                setup.initialize_project(ROOT / '.lake/build/bin/eggshell', root, env)
            self.assertEqual(config.read_text(), 'default = true\n')
            self.assertFalse((root / '.eggs').exists())
            self.assertFalse((root / 'data').exists())

    def test_setup_check_identifies_an_older_runtime_without_modifying_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / 'libexec/eggshell'
            runtime.parent.mkdir()
            old = '#!/bin/sh\n[ "$2" = --help ] || exit 99\nprintf "usage: egg [init|inspect]\\n"\n'
            runtime.write_text(old)
            runtime.chmod(0o755)
            (runtime.parent / 'eggshell.owner').write_text('o8vm/eggshell\n')
            result = subprocess.run(['python3', ROOT / 'plugins/eggshell/scripts/setup.py',
                '--check', '--prefix', str(root), '--project', str(root)],
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(json.loads(result.stdout)['runtime'], 'update_required')
            self.assertEqual(runtime.read_text(), old)
            self.assertFalse((root / '.eggshell.toml').exists())

    def test_runtime_install_preserves_plugin_and_memory(self):
        with tempfile.TemporaryDirectory(prefix="egg package's ") as directory:
            root = Path(directory)
            prefix = root / 'prefix'
            data = root / 'data'
            # Exercise runtime installation without a network/model download.
            # The existing MiniLM tests cover dependency setup separately.
            support = prefix / 'share/eggshell/minilm'
            python = support / 'fastembed-0.8.0/bin/python'
            python.parent.mkdir(parents=True)
            python.write_text('#!/bin/sh\nexit 97\n')
            python.chmod(0o755)
            (support / 'fastembed-0.8.0.model-ready').write_text('ready')
            plugin = prefix / 'plugins/eggshell'
            plugin.mkdir(parents=True)
            (plugin / '.eggshell-owner').write_text('o8vm/eggshell\n')
            (plugin / 'sentinel').write_text('existing plugin')
            memory = prefix / 'work.egg'
            memory.write_bytes(b'user-owned work')
            marketplace = prefix / '.agents/plugins/marketplace.json'
            marketplace.parent.mkdir(parents=True)
            marketplace.write_text('{"keep": "unchanged"}\n')
            fakebin = root / 'bin'
            fakebin.mkdir()
            codex = fakebin / 'codex'
            codex.write_text('#!/bin/sh\nprintf called > "$EGGSHELL_PREFIX/codex-called"\nexit 91\n')
            codex.chmod(0o755)
            env = dict(os.environ, EGGSHELL_PREFIX=str(prefix), EGGSHELL_DATA_ROOT=str(data),
                       PATH=str(fakebin) + os.pathsep + os.environ['PATH'])
            result = subprocess.run([ROOT / '.lake/build/bin/eggshell', 'install', 'runtime'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((prefix / 'codex-called').exists())
            self.assertEqual((plugin / 'sentinel').read_text(), 'existing plugin')
            self.assertEqual(memory.read_bytes(), b'user-owned work')
            self.assertEqual(marketplace.read_text(), '{"keep": "unchanged"}\n')
            project = root / 'project'
            project.mkdir()
            result = subprocess.run([prefix / 'bin/egg', 'init'], cwd=project, env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((project / '.eggshell.toml').exists())

    def test_control_uninstall_checks_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            plugin = prefix / 'plugins/eggshell'
            plugin.mkdir(parents=True)
            sentinel = plugin / 'unrelated-file'
            sentinel.write_text('keep')
            env = dict(os.environ, EGGSHELL_PREFIX=str(prefix),
                       EGGSHELL_DATA_ROOT=str(prefix / 'state'))
            result = subprocess.run([ROOT / '.lake/build/bin/eggshell', 'egg', 'uninstall', 'codex'],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unowned Plugin directory', result.stderr)
            self.assertEqual(sentinel.read_text(), 'keep')

    def test_zip_contains_portable_hooks_and_pinned_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for target in packager.TARGETS:
                archive_at(root / f'eggshell-{target}.tar.gz')
            result = packager.package(root, root / 'output', 'v0.1.0')
            with zipfile.ZipFile(result) as package:
                self.assertIsNone(package.testzip())
                names = package.namelist()
                self.assertIn('.codex-plugin/plugin.json', names)
                self.assertIn('skills/eggshell/SKILL.md', names)
                self.assertIn('bin/egg', names)
                self.assertIn('hooks/hooks.json', names)
                self.assertNotIn('.mcp.json', names)
                self.assertFalse(any('plan' in n.lower() or '.egg' == Path(n).suffix for n in names))
                runtime = json.loads(package.read('runtime.json'))
                self.assertEqual(set(runtime['targets']), set(packager.TARGETS))
                for item in runtime['targets'].values():
                    self.assertEqual(hashlib.sha256((root/'output'/item['file']).read_bytes()).hexdigest(), item['sha256'])


if __name__ == '__main__':
    unittest.main()
