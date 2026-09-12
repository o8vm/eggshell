"""Real-process lifecycle regressions; no LLM, network, or installed runtime.

Each test owns its temporary data, managers, locks, and fake provider processes.
The production native-hook entrypoint is exercised, not a second implementation.
"""
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / '.lake/build/bin/eggshell'


def wait_for(predicate, seconds=8):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(.025)
    raise AssertionError('condition did not become true before deadline')


def rpc(endpoint, kind, payload=None):
    request = json.dumps(dict(secret=endpoint['secret'], kind=kind, payload=payload)).encode()
    with socket.create_connection(('127.0.0.1', endpoint['port']), timeout=4) as connection:
        connection.settimeout(25)
        connection.sendall(struct.pack('!I', len(request)) + request)
        def read(size):
            result = b''
            while len(result) < size:
                chunk = connection.recv(size - len(result))
                if not chunk:
                    raise EOFError('incomplete daemon reply')
                result += chunk
            return result
        return json.loads(read(struct.unpack('!I', read(4))[0]))


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='eggshell-lifecycle-')
        self.root = Path(self.temp.name).resolve()
        self.data = self.root / 'data'
        self.config = self.root / 'global.toml'
        self.config.write_text('semantic_matcher = false\n'
            'default = "work"\n[eggs]\nproject = "work.egg"\n'
            '[profiles.work]\nread = ["project"]\nwrite = "project"\n')
        (self.root / '.eggshell.toml').write_text(
            'default = "work"\n[eggs]\nproject = "work.egg"\n'
            '[profiles.work]\nread = ["project"]\nwrite = "project"\n')
        self.env = dict(os.environ, EGGSHELL_DATA_ROOT=str(self.data),
                        EGGSHELL_CONFIG=str(self.config))
        self.env.pop('PLUGIN_ROOT', None)
        self.children = []

    def tearDown(self):
        for endpoint in self.data.glob('sessions/*/daemon.json'):
            try:
                rpc(json.loads(endpoint.read_text()), 'shutdown')
            except (OSError, EOFError, ValueError):
                pass
        for child in self.children:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=3)
            for stream in (child.stdin, child.stdout, child.stderr):
                if stream and not stream.closed:
                    stream.close()
        self.temp.cleanup()

    def input(self, event, session='chat', turn='turn', **extra):
        return dict(hook_event_name=event, session_id=session, turn_id=turn,
                    cwd=str(self.root), **extra)

    def hook(self, event, session='chat', turn='turn', **extra):
        start = time.monotonic()
        result = subprocess.run([BIN, 'codex-hook'], input=json.dumps(
            self.input(event, session, turn, **extra)), text=True, capture_output=True,
            env=self.env, cwd=self.root, timeout=28)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout), time.monotonic() - start

    def start(self, session='chat', turn='turn'):
        self.hook('SessionStart', session, turn)
        self.hook('UserPromptSubmit', session, turn, prompt='Inspect the clock implementation')

    def post(self, use='probe', marker='observed_clock_fact', session='chat', turn='turn'):
        return self.hook('PostToolUse', session, turn, tool_name='shell', tool_use_id=use,
                         tool_input={'command': 'cat clock.c'}, tool_response={'output': marker})

    def state(self, session='chat'):
        return json.loads((self.data / 'sessions' / session / 'state.json').read_text())

    def endpoint(self, session='chat'):
        return json.loads((self.data / 'sessions' / session / 'daemon.json').read_text())

    def egg(self):
        path = self.root / 'work.egg'
        return path.read_bytes() if path.exists() else b''

    def test_setup_status_reports_actual_hook_and_preserves_compaction(self):
        started, _ = self.hook('SessionStart', source='startup')
        self.assertIn('session hook connected', started['systemMessage'])
        self.assertIn('memory read/write', started['systemMessage'])
        self.assertNotIn('hookSpecificOutput', started)
        env = dict(self.env, CODEX_THREAD_ID='chat')
        before = self.state()
        result = subprocess.run([BIN, 'egg', 'doctor'], env=env, cwd=self.root,
                                capture_output=True, text=True, check=True)
        report = json.loads(result.stdout)
        self.assertEqual(report['configuration'], 'ready')
        self.assertTrue(report['session_state_present'])
        self.assertFalse(report['handoff_observed'])
        self.assertEqual(self.state(), before)
        compacted, _ = self.hook('SessionStart', source='compact')
        self.assertEqual(compacted, {})
        self.assertEqual(self.state()['epoch'], before['epoch'] + 1)
        subprocess.run([BIN, 'egg', 'off'], env=env, cwd=self.root,
                       capture_output=True, check=True)
        resumed, _ = self.hook('SessionStart', source='resume')
        self.assertIn('memory is off', resumed['systemMessage'])
        self.assertFalse(self.state()['enabled'])

    def test_missing_configuration_notice_and_readonly_doctor(self):
        self.env.pop('EGGSHELL_CONFIG', None)
        self.env['EGGSHELL_PREFIX'] = str(self.root / 'prefix')
        (self.root / '.eggshell.toml').unlink()
        doctor = subprocess.run([BIN, 'egg', 'doctor'], env=self.env, cwd=self.root,
                                text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(doctor.stdout)['configuration'], 'missing')
        self.assertFalse(self.data.exists())
        message, _ = self.hook('SessionStart', source='startup')
        self.assertIn('not configured', message['systemMessage'])
        self.assertNotIn('hookSpecificOutput', message)
        self.assertFalse(self.egg())
        state = self.data / 'sessions/chat/state.json'
        state.write_text('{broken')
        result = subprocess.run([BIN, 'egg', 'doctor'], cwd=self.root,
            env=dict(self.env, CODEX_THREAD_ID='chat'), text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state.read_text(), '{broken')
        self.assertFalse(list(state.parent.glob('*.corrupt-*')))

    def test_partial_results_reach_egg_before_stop_and_replay_is_idempotent(self):
        self.start()
        # Existing installations have no lifecycle epoch/offers/closed fields.
        for name, fields in [('state.json', ('epoch', 'offers')), ('pending.json', ('closed',))]:
            path = self.data / 'sessions/chat' / name
            old = json.loads(path.read_text())
            for field in fields:
                old.pop(field, None)
            path.write_text(json.dumps(old))
        self.post()
        wait_for(lambda: b'observed_clock_fact' in self.egg())
        pending = json.loads((self.data / 'sessions/chat/pending.json').read_text())
        self.assertIsNone(pending['finalMessage'])
        self.assertNotIn(b'interrupted before final response', self.egg())
        # An independent chat must be able to reuse the saved child Work even
        # before the original chat produces any final answer.
        self.start('partial-reader')
        reused, _ = self.hook('PreToolUse', 'partial-reader', tool_name='shell',
                             tool_use_id='partial-reuse', tool_input={'command': 'cat clock.c'})
        self.assertIn('permissionDecision', json.dumps(reused))
        before = self.egg()
        self.post()
        wait_for(lambda: not list((self.data / 'sessions/chat/checkpoints').glob('*.json')))
        self.assertEqual(self.egg(), before)

    def test_authority_contention_retains_results_and_retries_without_a_new_turn(self):
        self.start()
        with open(self.root / 'work.egg.guard', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.post(marker='retained_after_busy_authority')
            queue = self.data / 'sessions/chat/checkpoints'
            wait_for(lambda: list(queue.glob('*.json')))
            self.hook('PostCompact')
            reused, _ = self.hook('PreToolUse', tool_name='shell', tool_use_id='reused-pending',
                                  tool_input={'command': 'cat clock.c'})
            self.assertIn('retained_after_busy_authority', json.dumps(reused))
            _, elapsed = self.hook('Stop', last_assistant_message=None)
            self.assertLess(elapsed, 2.5)
            time.sleep(1.3)  # force a failed authority-lock attempt
            self.assertTrue(list(queue.glob('*.json')))
            self.assertNotIn(b'retained_after_busy_authority', self.egg())
        wait_for(lambda: b'retained_after_busy_authority' in self.egg())
        wait_for(lambda: not list(queue.glob('*.json')))
        pending = json.loads((self.data / 'sessions/chat/pending.json').read_text())
        self.assertTrue(pending['closed'])
        self.assertIsNone(pending['finalMessage'])

    def test_killed_lock_owner_does_not_leave_a_permanent_lock(self):
        self.start()
        marker = self.root / 'locked'
        child = subprocess.Popen([sys.executable, '-c',
            'import fcntl,time,pathlib,sys; f=open(sys.argv[1],"a"); '
            'fcntl.flock(f,fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); time.sleep(60)',
            str(self.root / 'work.egg.guard'), str(marker)], start_new_session=True)
        self.children.append(child)
        wait_for(marker.exists)
        self.post(marker='saved_after_lock_owner_died')
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=3)
        wait_for(lambda: b'saved_after_lock_owner_died' in self.egg())

    def test_writer_crash_retries_durable_checkpoint_without_a_new_turn(self):
        self.start()
        with open(self.root / 'work.egg.guard', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.post(marker='survives_writer_crash')
            manager = self.endpoint()['pid']
            def writer_pid():
                listing = subprocess.run(['ps', '-axo', 'pid,ppid,args'],
                                         capture_output=True, text=True, check=True).stdout
                for line in listing.splitlines():
                    fields = line.split(None, 2)
                    if len(fields) == 3 and fields[1] == str(manager) and 'codex-worker save' in fields[2]:
                        return int(fields[0])
            writer = wait_for(writer_pid)
            os.kill(writer, signal.SIGKILL)
            self.assertTrue(list((self.data / 'sessions/chat/checkpoints').glob('*.json')))
        wait_for(lambda: b'survives_writer_crash' in self.egg())
        wait_for(lambda: not list((self.data / 'sessions/chat/checkpoints').glob('*.json')))
        self.assertIsNone(json.loads((self.data / 'sessions/chat/pending.json').read_text())['finalMessage'])

    def test_manager_restart_preserves_uncommitted_partial_work(self):
        self.start()
        with open(self.root / 'work.egg.guard', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.post(marker='survives_manager_crash')
            before = self.endpoint()
            os.kill(before['pid'], signal.SIGKILL)
            self.hook('SessionStart')
            self.assertNotEqual(self.endpoint()['secret'], before['secret'])
        wait_for(lambda: b'survives_manager_crash' in self.egg())

    def test_abandoned_partial_write_does_not_block_later_commits(self):
        self.start()
        self.post(marker='committed_before_crash')
        wait_for(lambda: b'committed_before_crash' in self.egg())
        # Reproduce the on-disk boundary of SIGKILL before atomic rename.
        # Cover both the former fixed filename and an abandoned unique file.
        abandoned = [self.root / 'work.egg.tmp', self.root / 'work.egg.tmp-999999-0']
        for path in abandoned:
            path.write_bytes(b'{"incomplete":')
        self.post(use='after-crash', marker='committed_after_crash')
        wait_for(lambda: b'committed_after_crash' in self.egg())
        self.assertIn(b'committed_before_crash', self.egg())
        json.loads(self.egg())
        wait_for(lambda: not list((self.data / 'sessions/chat/checkpoints').glob('*.json')))
        for path in abandoned:
            self.assertEqual(path.read_bytes(), b'{"incomplete":')

    def test_journal_recovers_a_missing_checkpoint_without_stop_or_another_hook(self):
        self.start()
        # Stop the background consumer while reproducing a hook exit between
        # its two atomic writes: the receipt exists but its checkpoint does not.
        files = self.data / 'sessions/chat'
        with open(files / 'save.guard', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.post(marker='recovered_from_native_journal')
            receipts = list((files / 'tools').glob('*/*.json'))
            self.assertTrue(receipts)
            unreadable = receipts[0].parent / 'unreadable.json'
            unreadable.write_text('tr')
            for path in (files / 'checkpoints').glob('*.json'):
                path.unlink()
            self.assertNotIn(b'recovered_from_native_journal', self.egg())
        wait_for(lambda: b'recovered_from_native_journal' in self.egg())
        self.assertIsNone(json.loads((files / 'pending.json').read_text())['finalMessage'])
        self.assertNotIn(b'interrupted before final response', self.egg())
        wait_for(lambda: not list((files / 'checkpoints').glob('*.json')))
        self.assertEqual(unreadable.read_text(), 'tr')

    def test_manager_ownership_and_cross_chat_rejection(self):
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            list(pool.map(lambda _: self.hook('SessionStart'), range(4)))
        self.start('second', 'second-turn')
        first, second = self.endpoint(), self.endpoint('second')
        self.assertNotEqual(first['port'], second['port'])
        self.assertNotEqual(first['secret'], second['secret'])
        self.assertFalse(rpc(first, 'hook', self.input('PostCompact', 'second'))['ok'])
        # The kernel lease also rejects a duplicate manager started directly.
        duplicate = subprocess.run([BIN, 'codex-daemon', 'chat'], env=self.env,
                                   capture_output=True, timeout=3)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertEqual(self.endpoint()['secret'], first['secret'])

    def test_corrupt_state_can_be_disabled_without_parsing_pending_or_config(self):
        self.start()
        files = self.data / 'sessions/chat'
        (files / 'state.json').write_text('tr')
        (files / 'pending.json').write_text('tr')
        working_config = self.config.read_text()
        self.config.write_text('this is malformed')
        result = subprocess.run([BIN, 'egg', 'off'], env=dict(self.env, CODEX_THREAD_ID='chat'),
                                cwd=self.root, text=True, capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state()['enabled'])
        self.assertTrue(list(files.glob('state.json.corrupt-*')))
        self.assertTrue(list(files.glob('pending.json.corrupt-*')))
        output, elapsed = self.hook('PostCompact')
        self.assertEqual(output, {})
        self.assertLess(elapsed, 2.5)
        self.config.write_text(working_config.replace('work\"', 'research\"').replace('profiles.work', 'profiles.research'))
        enabled = subprocess.run([BIN, 'egg', 'on'], env=dict(self.env, CODEX_THREAD_ID='chat'),
                                 cwd=self.root, text=True, capture_output=True, timeout=3)
        self.assertEqual(enabled.returncode, 0, enabled.stderr)
        self.assertTrue(self.state()['enabled'])
        self.assertEqual(self.state()['profile'], 'research')

    def test_same_operation_can_reuse_new_evidence_after_an_earlier_denial(self):
        self.start('seed')
        self.post(session='seed', marker='first_clock_observation')
        wait_for(lambda: b'first_clock_observation' in self.egg())
        self.start('reader')
        first, _ = self.hook('PreToolUse', 'reader', tool_name='shell',
                             tool_use_id='first-read', tool_input={'command': 'cat clock.c'})
        self.assertEqual(first['hookSpecificOutput']['permissionDecision'], 'deny')

        # Another chat records a new observation of the same native Work.
        # The earlier denial must not exempt this operation from evidence reuse.
        self.start('second-seed')
        self.post(session='second-seed', marker='second_clock_observation')
        wait_for(lambda: b'second_clock_observation' in self.egg())
        second, _ = self.hook('PreToolUse', 'reader', tool_name='shell',
                              tool_use_id='second-read', tool_input={'command': 'cat clock.c'})
        self.assertIn('second_clock_observation', json.dumps(second))
        self.assertEqual(second['hookSpecificOutput']['permissionDecision'], 'deny')

        # Evidence-specific deduplication still prevents an unchanged receipt
        # from being presented as a new reason to replan the same work.
        unchanged, _ = self.hook('PreToolUse', 'reader', tool_name='shell',
                                 tool_use_id='unchanged-read', tool_input={'command': 'cat clock.c'})
        self.assertNotIn('permissionDecision', json.dumps(unchanged))

    def test_lost_delivery_receipt_never_marks_context_delivered(self):
        self.start()
        self.post()
        self.hook('Stop', last_assistant_message='The clock investigation is complete')
        wait_for(lambda: b'The clock investigation is complete' in self.egg())
        self.start('reader')
        self.hook('PostCompact', 'reader')
        endpoint = self.endpoint('reader')
        response = rpc(endpoint, 'hook', self.input('PreToolUse', 'reader',
            tool_name='shell', tool_use_id='read-again', tool_input={'command': 'cat clock.c'},
            _eggshell_receipt='lost-receipt'))
        self.assertTrue(response['ok'])
        self.assertIn('observed_clock_fact', response['output'])
        self.assertFalse(any(key.startswith('g:') for key in self.state('reader')['deliveredGraphs']))
        self.hook('PostCompact', 'reader')
        rpc(endpoint, 'ack', {'receipt': 'lost-receipt'})
        self.assertFalse(any(key.startswith('g:') for key in self.state('reader')['deliveredGraphs']))
        again, _ = self.hook('PreToolUse', 'reader', tool_name='shell',
                             tool_use_id='read-again-2', tool_input={'command': 'cat clock.c'})
        self.assertNotIn('permissionDecision', json.dumps(again))
        self.assertIn('observed_clock_fact', json.dumps(again))

    def test_expired_search_is_reaped_and_the_next_hook_can_save(self):
        self.start('seed')
        self.post(session='seed')
        self.hook('Stop', 'seed', last_assistant_message='clock result for retrieval')
        wait_for(lambda: b'clock result for retrieval' in self.egg())
        self.hook('SessionStart', 'deadline')
        provider = self.root / 'timeout-provider.py'
        marker = self.root / 'timeout-provider-pid'
        provider.write_text('import os,pathlib,sys,time\n'
            'sys.stdin.readline()\npathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n'
            'time.sleep(60)\n')
        config = self.root / 'timeout.toml'
        config.write_text(self.config.read_text().replace('semantic_matcher = false',
            'semantic_matcher = ' + json.dumps([sys.executable, str(provider), str(marker)])))
        peer_clock = int(rpc(self.endpoint('deadline'), 'ping')['output'])
        start = time.monotonic()
        response = rpc(self.endpoint('deadline'), 'hook', self.input('UserPromptSubmit', 'deadline',
            prompt='Recall the clock result', _eggshell_config=str(config),
            _eggshell_deadline=peer_clock + 800, _eggshell_receipt='expired'))
        self.assertLess(time.monotonic() - start, 2)
        self.assertTrue(marker.exists(), 'the hang fixture did not actually start')
        self.assertEqual(json.loads(response['output']), {})
        self.assertFalse(self.state('deadline')['offers'])
        self.post(session='deadline', marker='saved_after_search_deadline')
        wait_for(lambda: b'saved_after_search_deadline' in self.egg())

    def test_hung_search_does_not_block_partial_save_stop_or_another_chat(self):
        self.start('seed')
        self.post(session='seed')
        self.hook('Stop', 'seed', last_assistant_message='clock investigation completed')
        wait_for(lambda: b'clock investigation completed' in self.egg())
        provider = self.root / 'hung.py'
        marker = self.root / 'provider-pids'
        provider.write_text('import os,sys,time,subprocess,json,pathlib\n'
            'for line in sys.stdin:\n'
            ' child=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"])\n'
            ' pathlib.Path(sys.argv[1]).write_text(json.dumps([os.getpid(),child.pid]))\n'
            ' time.sleep(60)\n')
        slow_config = self.root / 'slow.toml'
        slow_config.write_text(self.config.read_text().replace('semantic_matcher = false',
            'semantic_matcher = ' + json.dumps([sys.executable, str(provider), str(marker)])))
        slow = subprocess.Popen([BIN, 'codex-hook'], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=self.root,
            env=dict(self.env, EGGSHELL_CONFIG=str(slow_config)), start_new_session=True)
        self.children.append(slow)
        slow.stdin.write(json.dumps(self.input('UserPromptSubmit', 'slow',
            prompt='What did we find about the clock?')))
        slow.stdin.close()
        wait_for(marker.exists)
        pids = json.loads(marker.read_text())
        self.post(session='slow', marker='saved_while_search_hung')
        wait_for(lambda: b'saved_while_search_hung' in self.egg())
        start = time.monotonic()
        self.start('independent')
        self.assertLess(time.monotonic() - start, 3)
        _, elapsed = self.hook('Stop', 'slow', last_assistant_message=None)
        self.assertLess(elapsed, 2.5)
        slow.wait(timeout=4)
        self.assertEqual(slow.returncode, 0)
        self.assertEqual(json.loads(slow.stdout.read()), {})
        def dead(pid):
            try:
                os.kill(pid, 0)
                # A zombie is already terminated; its init-owned reaping is OS work.
                status = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)],
                                        capture_output=True, text=True).stdout.strip()
                return status.startswith('Z') or not status
            except ProcessLookupError:
                return True
        wait_for(lambda: all(dead(pid) for pid in pids))
        self.assertFalse(self.state('slow')['offers'])


if __name__ == '__main__':
    unittest.main()
