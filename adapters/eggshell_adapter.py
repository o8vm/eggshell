#!/usr/bin/env python3
"""Host adapters for Eggshell's separate bridge; no retrieval implementation.

Only opaque turn/call identifiers live in the adapter database. Tool bodies are
journaled by the engine before RPC/search. All locks end before a process call.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import uuid

CLIENTS = ('claude', 'gemini', 'cursor', 'opencode')
EVENTS = {
    'claude': dict(SessionStart='SessionStart', UserPromptSubmit='UserPromptSubmit',
                   PreToolUse='PreToolUse', PostToolUse='PostToolUse',
                   PostToolUseFailure='PostToolUse', Stop='Stop',
                   StopFailure='Interrupt', SessionEnd='SessionEnd'),
    'gemini': dict(SessionStart='SessionStart', BeforeAgent='UserPromptSubmit',
                   BeforeTool='PreToolUse', AfterTool='PostToolUse',
                   AfterAgent='Stop', PreCompress='PostCompact', SessionEnd='SessionEnd'),
    'cursor': dict(sessionStart='SessionStart', beforeSubmitPrompt='UserPromptSubmit',
                   preToolUse='PreToolUse', postToolUse='PostToolUse',
                   postToolUseFailure='PostToolUse', afterAgentResponse='AssistantMessage',
                   stop='Stop', preCompact='PostCompact', sessionEnd='SessionEnd'),
    'opencode': {name: name for name in ('SessionStart', 'UserPromptSubmit',
                 'PreToolUse', 'PostToolUse', 'PostCompact', 'Stop', 'Interrupt', 'SessionEnd')},
}
CONTEXT_EVENTS = {
    'claude': ('UserPromptSubmit', 'PreToolUse', 'PostToolUse'),
    'gemini': ('UserPromptSubmit', 'PostToolUse'),
    'cursor': ('PostToolUse',),
    'opencode': ('UserPromptSubmit', 'PostToolUse'),
}


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def session_key(client, native):
    if client not in CLIENTS or not isinstance(native, str) or not native:
        raise ValueError('hook must provide a nonempty native session ID')
    return client + '-' + hashlib.sha256(native.encode()).hexdigest()


def data_root():
    prefix = Path(os.environ.get('EGGSHELL_PREFIX', str(Path.home() / '.local')))
    root = Path(os.environ.get('EGGSHELL_DATA_ROOT', str(prefix / 'share/eggshell/plugin')))
    if not root.is_absolute():
        raise ValueError('EGGSHELL_DATA_ROOT must be absolute')
    return root / 'adapters'


def require_text(raw, key):
    value = raw.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError('hook must provide ' + key)
    return value


class UnattributedResult(ValueError):
    def __init__(self, event, recordable=False):
        super().__init__('tool result has no unambiguous originating turn; not attached to another task')
        self.event = dict(event)
        self.event.pop('turn_id', None)
        self.recordable = recordable


class Correlation:
    """A short per-chat transaction, never a search lock or a second manager."""
    def __init__(self, root, session):
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        root.chmod(0o700)
        path = root / (session + '.sqlite3')
        self.db = sqlite3.connect(path, timeout=.1)
        path.chmod(0o600)
        self.db.execute('PRAGMA secure_delete=ON')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS calls (
                id TEXT PRIMARY KEY, native TEXT NOT NULL, turn TEXT NOT NULL,
                finished INTEGER NOT NULL DEFAULT 0, writable INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS calls_native ON calls(native, finished);
            CREATE TABLE IF NOT EXISTS receipts (stamp TEXT PRIMARY KEY, id TEXT NOT NULL, turn TEXT NOT NULL);
        ''')

    def __enter__(self):
        self.db.execute('BEGIN IMMEDIATE')
        return self

    def __exit__(self, error_type, error, traceback):
        if error_type:
            self.db.rollback()
        else:
            self.db.commit()
        self.db.close()

    def get(self, key):
        row = self.db.execute('SELECT value FROM state WHERE key=?', (key,)).fetchone()
        return row[0] if row else None

    def put(self, key, value):
        self.db.execute('INSERT OR REPLACE INTO state VALUES (?,?)', (key, value))

    def bind(self, native, turn, explicit):
        call = explicit or uuid.uuid4().hex
        existing = self.db.execute('SELECT turn FROM calls WHERE id=?', (call,)).fetchone()
        if existing and existing[0] != turn:
            raise ValueError('native tool ID was reused across different turns')
        self.db.execute('INSERT OR IGNORE INTO calls(id,native,turn) VALUES (?,?,?)',
                        (call, native, turn))
        return call

    def terminal(self, native, explicit, turn):
        if explicit:
            rows = self.db.execute('SELECT id,turn FROM calls WHERE id=?', (explicit,)).fetchall()
        else:
            rows = self.db.execute('SELECT id,turn FROM calls WHERE native=? AND finished=0 '
                                   'ORDER BY rowid', (native,)).fetchall()
        if turn:
            rows = [row for row in rows if row[1] == turn]
        if not rows and explicit and turn:
            return self.bind(native, turn, explicit), turn
        if not rows or len({row[1] for row in rows}) != 1:
            raise ValueError('tool result has no unambiguous originating turn')
        call, original_turn = rows[0]
        self.db.execute('UPDATE calls SET finished=1 WHERE id=?', (call,))
        return call, original_turn


def normalize(client, raw, root):
    if not isinstance(raw, dict):
        raise ValueError('hook input must be an object')
    native_event = raw.get('hook_event_name')
    event = EVENTS[client].get(native_event)
    if event is None:
        return None
    native = require_text(raw, 'conversation_id' if client == 'cursor' else 'session_id')
    session = session_key(client, native)
    cwd = raw.get('cwd')
    if not cwd:
        roots = raw.get('workspace_roots', [])
        if not isinstance(roots, list) or len(roots) != 1:
            raise ValueError('hook must identify one project working directory')
        cwd = roots[0]
    if not isinstance(cwd, str) or not Path(cwd).is_absolute():
        raise ValueError('hook working directory must be absolute')
    result = dict(session_id=session, cwd=cwd, hook_event_name=event)
    # Do not forward account details, transcripts, reasoning, or internal fields.
    for key in ('source', 'prompt', 'tool_name', 'tool_input', 'tool_response'):
        if key in raw:
            result[key] = raw[key]
    explicit_turn = raw.get('generation_id' if client == 'cursor' else 'turn_id')
    if explicit_turn is not None and (not isinstance(explicit_turn, str) or not explicit_turn):
        raise ValueError('invalid native turn ID')
    with Correlation(root, session) as state:
        if event == 'UserPromptSubmit':
            require_text(raw, 'prompt')
            turn = explicit_turn or uuid.uuid4().hex
            state.put('turn', turn)
            result['turn_id'] = turn
            return result
        turn = explicit_turn or state.get('turn')
        if turn:
            result['turn_id'] = turn
        if event in ('PreToolUse', 'PostToolUse'):
            name = require_text(raw, 'tool_name')
            if 'tool_input' not in raw:
                raise ValueError('missing tool_input')
            call = raw.get('tool_use_id')
            if call is not None and (not isinstance(call, str) or not call):
                raise ValueError('invalid tool call ID')
            native_call = call or hashlib.sha256(encode([name, raw['tool_input']]).encode()).hexdigest()
            stamp = raw.get('timestamp')
            stamp_key = hashlib.sha256(encode([native_event, native_call, stamp]).encode()).hexdigest() \
                if isinstance(stamp, str) and stamp else None
            if event == 'PreToolUse':
                if not turn:
                    raise ValueError('tool arrived before a user turn')
                result['tool_use_id'] = state.bind(native_call, turn, call or stamp_key)
            else:
                if native_event in ('PostToolUseFailure', 'postToolUseFailure'):
                    result['tool_response'] = dict(error=raw.get('error'), is_error=True)
                elif client == 'cursor':
                    response = raw.get('tool_output')
                    if isinstance(response, str):
                        try:
                            response = json.loads(response)
                        except ValueError:
                            pass
                    result['tool_response'] = response
                elif 'tool_response' not in raw:
                    raise ValueError('missing tool_response')
                previous = state.db.execute('SELECT id,turn FROM receipts WHERE stamp=?',
                                             (stamp_key,)).fetchone() if stamp_key else None
                try:
                    call, turn = previous or state.terminal(native_call, call, explicit_turn)
                except ValueError:
                    permissions = state.db.execute('SELECT writable FROM calls WHERE native=?',
                                                    (native_call,)).fetchall()
                    raise UnattributedResult(result, bool(permissions) and
                                              all(row[0] for row in permissions)) from None
                result.update(tool_use_id=call, turn_id=turn)
                if stamp_key:
                    state.db.execute('INSERT OR IGNORE INTO receipts VALUES (?,?,?)', (stamp_key, call, turn))
        if event == 'Stop':
            field = 'prompt_response' if client == 'gemini' else 'last_assistant_message'
            final = raw.get(field)
            if isinstance(final, str):
                result['last_assistant_message'] = final
    return result


def translate(client, event, output):
    """Return only fields accepted by the host for this event.

    End-of-turn hooks always return {}, regardless of the engine reply.
    Unsupported advisory output is never acknowledged as delivered.
    """
    if event not in ('UserPromptSubmit', 'PreToolUse', 'PostToolUse'):
        return {}
    specific = output.get('hookSpecificOutput', {})
    if not isinstance(specific, dict):
        return {}
    if event == 'PreToolUse' and specific.get('permissionDecision') == 'deny':
        reason = specific.get('permissionDecisionReason', '')
        if not isinstance(reason, str) or not reason:
            return {}
        if client in ('claude', 'opencode'):
            return {'hookSpecificOutput': dict(hookEventName='PreToolUse',
                permissionDecision='deny', permissionDecisionReason=reason)}
        if client == 'gemini':
            return dict(decision='deny', reason=reason)
        return dict(permission='deny', agent_message=reason)
    context = specific.get('additionalContext', '')
    if event not in CONTEXT_EVENTS[client] or not isinstance(context, str) or not context:
        return {}
    if client == 'cursor':
        return dict(additional_context=context)
    target_event = ('BeforeAgent' if event == 'UserPromptSubmit' else 'AfterTool') \
        if client == 'gemini' else event
    return {'hookSpecificOutput': dict(hookEventName=target_event, additionalContext=context)}


def invoke(bridge, command, payload, cwd, session=None):
    env = dict(os.environ)
    # An installed Codex plugin must not redirect this companion's manager.
    env.pop('PLUGIN_ROOT', None)
    env.pop('CODEX_THREAD_ID', None)
    if session:
        env['CODEX_THREAD_ID'] = session
    child = subprocess.Popen([str(bridge), *command], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd, env=env,
        start_new_session=True, text=True)
    try:
        stdout, stderr = child.communicate(encode(payload) if payload is not None else '', timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        raise RuntimeError('adapter bridge timed out; the engine retains captured tool results')
    if stderr:
        print(stderr.rstrip(), file=sys.stderr)
    if child.returncode:
        raise RuntimeError('adapter bridge exited with code ' + str(child.returncode))
    return json.loads(stdout) if stdout.strip() else {}


def is_denied(reply):
    return (reply.get('permission') == 'deny' or reply.get('decision') == 'deny' or
            reply.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny')


def record_call_status(root, event, reply, writable):
    if event['hook_event_name'] != 'PreToolUse':
        return
    with Correlation(root, event['session_id']) as state:
        state.db.execute('UPDATE calls SET finished=?, writable=? WHERE id=?',
                         (int(is_denied(reply)), int(writable), event['tool_use_id']))


def draft_response(bridge, event, raw):
    """Cursor reports answer text separately from loop completion.

    Keep a temporary candidate only while memory is writable. Never turn an
    intermediate assistant message or an aborted loop into a final outcome.
    """
    turn = event.get('turn_id')
    if not turn:
        return
    if event['hook_event_name'] == 'AssistantMessage':
        if isinstance(raw.get('text'), str):
            invoke(bridge, ['draft'], dict(event, text=raw['text']), event['cwd'])
    elif event['hook_event_name'] == 'Stop':
        event['_adapter_use_draft'] = raw.get('status') == 'completed'


def run_hook(client, raw, bridge, root):
    event = normalize(client, raw, root)
    if event is None:
        print('{}', flush=True)
        return
    if client == 'cursor':
        draft_response(bridge, event, raw)
        if event['hook_event_name'] == 'AssistantMessage':
            print('{}', flush=True)
            return
    receipt = invoke(bridge, ['deliver'], event, event['cwd'])
    if not receipt.get('ok'):
        print('{}', flush=True)
        return
    reply = translate(client, event['hook_event_name'], receipt['output'])
    record_call_status(root, event, reply, receipt.get('writable', False))
    if client == 'opencode':
        # The JS plugin confirms only after mutating the host's output object.
        print(encode(dict(output=reply, receipt=receipt['receipt'],
                          session_id=event['session_id'])), flush=True)
    else:
        print(encode(reply), flush=True)
        if reply:
            try:
                invoke(bridge, ['ack'], dict(session_id=event['session_id'],
                    receipt=receipt['receipt']), event['cwd'])
            except (OSError, ValueError, RuntimeError) as error:
                # stdout already contains the complete hook response.
                print('Eggshell delivery receipt: ' + str(error), file=sys.stderr)


def retain_unattributed(bridge, root, event):
    # Keep ambiguous evidence private, only when this chat permits writing.
    report = invoke(bridge, ['egg', 'doctor'], None, event['cwd'], event['session_id'])
    if report.get('memory') != 'read/write':
        return
    directory = root / 'unattributed' / event['session_id']
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / (uuid.uuid4().hex + '.json')
    with path.open('x') as stream:
        os.chmod(path, 0o600)
        stream.write(encode(event))
        stream.flush()
        os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('hook', 'ack', 'control'))
    parser.add_argument('client', choices=CLIENTS)
    parser.add_argument('--bridge', type=Path,
                        default=Path(__file__).resolve().with_name('eggshell-bridge'))
    parser.add_argument('--session')
    parser.add_argument('commands', nargs='*')
    args = parser.parse_intermixed_args()
    if args.mode == 'control':
        if not args.session:
            parser.error('control requires --session with the native chat ID')
        session = session_key(args.client, args.session)
        env = dict(os.environ, CODEX_THREAD_ID=session)
        env.pop('PLUGIN_ROOT', None)
        if args.commands == ['doctor']:
            report = invoke(args.bridge, ['egg', 'doctor'], None, os.getcwd(), session)
            report['hook_trust'] = 'Review hooks in ' + args.client
            report['next_step'] = 'Restart the agent and verify saving and delivery with the two-chat example.'
            print(json.dumps(report, indent=2))
            return 0
        return subprocess.call([str(args.bridge), 'egg', *args.commands], env=env)
    try:
        root = data_root()
        raw = json.load(sys.stdin)
        if args.mode == 'ack':
            if not require_text(raw, 'session_id').startswith(args.client + '-'):
                raise ValueError('receipt belongs to another harness')
            invoke(args.bridge, ['ack'], raw, os.getcwd())
        else:
            run_hook(args.client, raw, args.bridge, root)
        return 0
    except (OSError, ValueError, RuntimeError, sqlite3.Error) as error:
        if isinstance(error, UnattributedResult) and error.recordable:
            try:
                retain_unattributed(args.bridge, root, error.event)
            except (OSError, ValueError, RuntimeError) as retention_error:
                print('Eggshell could not retain ambiguous evidence: ' + str(retention_error), file=sys.stderr)
        print('Eggshell adapter: ' + str(error), file=sys.stderr)
        if args.mode == 'hook':
            print('{}', flush=True)
            return 0
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
