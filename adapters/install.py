#!/usr/bin/env python3
"""Install one project adapter without changing the Eggshell or Codex package."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

from eggshell_adapter import CLIENTS, EVENTS

SOURCE = Path(__file__).resolve().parent
OWNER = 'momonpya/eggshell-adapters-v1\n'
CONFIGS = dict(claude='.claude/settings.json', gemini='.gemini/settings.json',
               cursor='.cursor/hooks.json', opencode='.opencode/plugins/eggshell.js')


def atomic_write(path, contents, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path, value):
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    atomic_write(path, (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode(), mode)


def read_document(path):
    if not path.exists():
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(str(path) + ' must contain a JSON object')
    return value


def remove_entries(document, entries, client):
    hooks = document.get('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('existing hooks must be an object')
    for event, owned in entries.items():
        current = hooks.get(event, [])
        if not isinstance(current, list):
            raise ValueError('existing hook event must contain an array: ' + event)
        kept = [entry for entry in current if entry != owned]
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
    if hooks:
        document['hooks'] = hooks
    else:
        document.pop('hooks', None)
    return document


def entries_for(client, command):
    entries = {}
    for event in EVENTS[client]:
        # One common upper bound surrounds the engine's own bounded delivery.
        # Stop hooks do not request retries, and errors use the host's fail-open default.
        handler = dict(type='command', command=command, timeout=35000 if client == 'gemini' else 35)
        if client == 'gemini':
            handler['name'] = 'eggshell-' + event
        entries[event] = handler if client == 'cursor' else dict(hooks=[handler])
    return entries


def install(client, project, prefix, bridge, uninstall=False):
    project, prefix, bridge = project.resolve(), prefix.resolve(), bridge.resolve()
    if not project.is_dir():
        raise ValueError('project directory does not exist')
    support = prefix / 'share/eggshell-adapters'
    marker = support / '.owner'
    if support.exists() and (not marker.exists() or marker.read_text() != OWNER):
        raise ValueError('refusing to replace an unowned adapter directory')
    config = project / CONFIGS[client]
    key = hashlib.sha256((client + '\n' + str(config)).encode()).hexdigest()
    receipt_path = support / 'receipts' / (key + '.json')
    previous = read_document(receipt_path)
    if client == 'opencode':
        old = config.read_text() if config.exists() else None
        if old is not None and old != previous.get('contents'):
            raise ValueError('refusing to replace an unowned OpenCode plugin')
        document = None
    else:
        document = read_document(config)
        if client == 'cursor' and document.get('version', 1) != 1:
            raise ValueError('unsupported Cursor hooks schema version')
        remove_entries(document, previous.get('entries', {}), client)
    if uninstall:
        if not previous:
            return dict(status='not-installed', client=client, config=str(config))
        if client == 'opencode':
            config.unlink(missing_ok=True)
        else:
            write_json(config, document)
        receipt_path.unlink()
        return dict(status='removed', client=client, config=str(config),
                    memory='preserved', runtime='preserved')
    checked = subprocess.run([bridge, '--help'], capture_output=True, text=True, check=True)
    if 'Eggshell adapter bridge:' not in checked.stdout:
        raise ValueError('not an Eggshell adapter bridge executable')
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic_write(marker, OWNER.encode())
    installed_bridge = support / 'eggshell-bridge'
    if bridge != installed_bridge:
        atomic_write(installed_bridge, bridge.read_bytes(), 0o755)
    for name in ('eggshell_adapter.py', 'opencode.mjs'):
        atomic_write(support / name, (SOURCE / name).read_bytes(), 0o644)
    command = shlex.join(['env', 'EGGSHELL_PREFIX=' + str(prefix), 'python3',
                         str(support / 'eggshell_adapter.py'), 'hook', client])
    if client == 'opencode':
        contents = ('// Eggshell project adapter. Remove with adapters/install.py --uninstall.\n'
                    'export { Eggshell } from ' + json.dumps((support / 'opencode.mjs').as_uri()) + ';\n')
        receipt = dict(client=client, config=str(config), contents=contents)
        # Store ownership before publishing the project entrypoint.
        write_json(receipt_path, receipt)
        atomic_write(config, contents.encode(), 0o644)
    else:
        entries = entries_for(client, command)
        hooks = document.setdefault('hooks', {})
        if not isinstance(hooks, dict):
            raise ValueError('existing hooks must be an object')
        for event, entry in entries.items():
            current = hooks.setdefault(event, [])
            if not isinstance(current, list):
                raise ValueError('existing hook event must contain an array: ' + event)
            current.append(entry)
        if client == 'cursor':
            document.setdefault('version', 1)
        write_json(receipt_path, dict(client=client, config=str(config), entries=entries))
        write_json(config, document)
    return dict(status='configured', client=client, config=str(config),
                next_step='Review the hooks in your agent, restart the project chat, then verify two-chat reuse.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('client', choices=CLIENTS)
    parser.add_argument('--project', type=Path, default=Path.cwd())
    parser.add_argument('--prefix', type=Path, default=Path(os.environ.get(
        'EGGSHELL_PREFIX', str(Path.home() / '.local'))))
    parser.add_argument('--bridge', type=Path,
                        default=SOURCE / 'native/.lake/build/bin/eggshell_bridge')
    parser.add_argument('--uninstall', action='store_true')
    args = parser.parse_args()
    # Installation owns a separate lock; hook execution never takes it.
    args.prefix.mkdir(parents=True, exist_ok=True)
    with (args.prefix / '.eggshell-adapter-install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = install(args.client, args.project, args.prefix, args.bridge, args.uninstall)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
