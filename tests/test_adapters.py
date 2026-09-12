"""Independent adapters against the real unchanged Eggshell memory engine."""
import concurrent.futures
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import test_hook_lifecycle as lifecycle

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / 'adapters/eggshell_adapter.py'
BRIDGE = ROOT / 'adapters/native/.lake/build/bin/eggshell_bridge'
sys.path.insert(0, str(ROOT / 'adapters'))
import eggshell_adapter as adapter
import install as installer


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.fixture = lifecycle.LifecycleTests()
        self.fixture.setUp()
        self.root = self.fixture.root
        self.env = self.fixture.env
        self.env['EGGSHELL_PREFIX'] = str(self.root / 'prefix')

    def tearDown(self):
        self.fixture.tearDown()

    def raw(self, client, event, session='chat', turn='turn', **fields):
        native = next(key for key, value in adapter.EVENTS[client].items() if value == event)
        raw = dict(hook_event_name=native, cwd=str(self.root), **fields)
        if client == 'cursor':
            raw.update(conversation_id=session, generation_id=turn, workspace_roots=[str(self.root)])
        else:
            raw['session_id'] = session
            if client == 'opencode':
                raw['turn_id'] = turn
        if client == 'gemini':
            raw.pop('tool_use_id', None)
            if 'last_assistant_message' in raw:
                raw['prompt_response'] = raw.pop('last_assistant_message')
        if client == 'cursor' and 'tool_response' in raw:
            raw['tool_output'] = json.dumps(raw.pop('tool_response'))
        return raw

    def send(self, client, raw):
        result = subprocess.run([sys.executable, ADAPTER, 'hook', client, '--bridge', BRIDGE],
            input=json.dumps(raw), text=True, capture_output=True, env=self.env,
            cwd=self.root, timeout=35)
        self.assertEqual(result.returncode, 0, result.stderr)
        try:
            parsed = json.loads(result.stdout)
        except ValueError:
            self.fail('hook did not emit exactly one JSON object: ' + result.stdout + result.stderr)
        return parsed

    def hook(self, client, event, session='chat', turn='turn', **fields):
        return self.send(client, self.raw(client, event, session, turn, **fields))

    def start(self, client, session='chat', turn='turn'):
        self.hook(client, 'SessionStart', session, turn, source='startup')
        return self.hook(client, 'UserPromptSubmit', session, turn,
                         prompt='Inspect the clock implementation')

    def tool(self, client, marker, call='call', session='chat', turn='turn', command='cat clock.c'):
        fields = dict(tool_name='shell', tool_use_id=call, tool_input={'command': command})
        self.hook(client, 'PreToolUse', session, turn, **fields)
        return self.hook(client, 'PostToolUse', session, turn,
                         tool_response={'output': marker}, **fields)

    def state(self, client, session='chat'):
        return json.loads((self.fixture.data / 'sessions' /
            adapter.session_key(client, session) / 'state.json').read_text())

    def test_each_adapter_saves_progress_before_stop_and_reuses_in_a_new_chat(self):
        for client in adapter.CLIENTS:
            with self.subTest(client=client):
                session = client + '-writer'
                self.start(client, session)
                marker = 'partial_fact_from_' + client
                command = 'cat ' + client + '-clock.c'
                self.tool(client, marker, session=session, command=command)
                lifecycle.wait_for(lambda: marker.encode() in self.fixture.egg())
                reader = client + '-reader'
                self.start(client, reader)
                result = self.hook(client, 'PreToolUse', reader,
                    tool_name='shell', tool_use_id='reader-probe',
                    tool_input={'command': command})
                reply = result.get('output', result)
                self.assertTrue(adapter.is_denied(reply), result)

    def test_different_harnesses_do_not_share_a_chat_manager(self):
        native = '../../same-native-id'
        for client in adapter.CLIENTS:
            self.start(client, native)
        directories = [self.fixture.data / 'sessions' / adapter.session_key(client, native)
                       for client in adapter.CLIENTS]
        endpoints = [json.loads((directory / 'daemon.json').read_text()) for directory in directories]
        self.assertEqual(len({endpoint['pid'] for endpoint in endpoints}), 4)
        self.assertEqual(len({endpoint['session'] for endpoint in endpoints}), 4)

    def test_unsupported_cursor_prompt_context_is_not_marked_delivered(self):
        self.start('claude', 'writer')
        self.tool('claude', 'a_saved_clock_result', session='writer')
        self.hook('claude', 'Stop', 'writer', last_assistant_message='The clock is monotonic.')
        lifecycle.wait_for(lambda: b'The clock is monotonic.' in self.fixture.egg())
        reply = self.start('cursor', 'reader')
        self.assertEqual(reply, {})
        self.assertEqual(self.state('cursor', 'reader')['lastHandoff'], '')

    def test_opencode_acknowledges_only_after_host_insertion_and_rejects_stale_ack(self):
        self.start('claude', 'writer')
        self.tool('claude', 'acknowledgement_marker', session='writer')
        lifecycle.wait_for(lambda: b'acknowledgement_marker' in self.fixture.egg())
        self.start('opencode', 'reader')
        reply = self.hook('opencode', 'PreToolUse', 'reader', tool_name='shell',
            tool_use_id='reuse', tool_input={'command': 'cat clock.c'})
        self.assertTrue(adapter.is_denied(reply['output']), reply)
        self.assertEqual(self.state('opencode', 'reader')['lastHandoff'], '')
        self.hook('opencode', 'PostCompact', 'reader')
        ack = {key: reply[key] for key in ('session_id', 'receipt')}
        result = subprocess.run([sys.executable, ADAPTER, 'ack', 'opencode', '--bridge', BRIDGE],
            input=json.dumps(ack), text=True, capture_output=True, env=self.env, cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state('opencode', 'reader')['lastHandoff'], '')

    def test_cursor_answer_is_final_only_when_the_loop_completes(self):
        self.start('cursor')
        self.tool('cursor', 'cursor_partial_marker')
        self.hook('cursor', 'AssistantMessage', text='A candidate answer before loop completion.')
        self.assertNotIn(b'A candidate answer', self.fixture.egg())
        self.hook('cursor', 'Stop', status='aborted')
        self.assertNotIn(b'A candidate answer', self.fixture.egg())
        self.start('cursor', turn='next')
        self.hook('cursor', 'AssistantMessage', turn='next', text='The final verified clock answer.')
        self.hook('cursor', 'Stop', turn='next', status='completed')
        lifecycle.wait_for(lambda: b'The final verified clock answer.' in self.fixture.egg())

    def test_parallel_identical_gemini_tools_keep_both_results(self):
        self.start('gemini')
        fields = dict(tool_name='run_shell_command', tool_input={'command': 'cat clock.c'})
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(self.hook, 'gemini', 'PreToolUse', **fields) for _ in range(2)]
            for future in futures:
                future.result()
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(self.hook, 'gemini', 'PostToolUse',
                tool_response={'llmContent': marker}, **fields)
                for marker in ('gemini_parallel_one', 'gemini_parallel_two')]
            for future in futures:
                future.result()
        lifecycle.wait_for(lambda: b'gemini_parallel_one' in self.fixture.egg() and
                           b'gemini_parallel_two' in self.fixture.egg())

    def test_failed_tools_are_recorded_as_errors(self):
        self.start('claude')
        self.hook('claude', 'PreToolUse', tool_name='Bash', tool_use_id='failed',
                  tool_input={'command': 'missing-command'})
        raw = self.raw('claude', 'PostToolUse', tool_name='Bash', tool_use_id='failed',
                       tool_input={'command': 'missing-command'}, error='command not found')
        raw['hook_event_name'] = 'PostToolUseFailure'
        self.send('claude', raw)
        lifecycle.wait_for(lambda: b'command not found' in self.fixture.egg())
        self.assertIn(b'is_error', self.fixture.egg())

    def test_late_tool_result_is_saved_under_its_original_turn(self):
        self.start('claude')
        fields = dict(tool_name='Bash', tool_use_id='late', tool_input={'command': 'cat late.c'})
        self.hook('claude', 'PreToolUse', **fields)
        self.hook('claude', 'Stop', last_assistant_message='The earlier task is closed.')
        lifecycle.wait_for(lambda: b'The earlier task is closed.' in self.fixture.egg())
        self.hook('claude', 'UserPromptSubmit', prompt='A different subsequent task')
        self.hook('claude', 'PostToolUse', tool_response={'output': 'LATE_ORIGINAL_RESULT'}, **fields)
        lifecycle.wait_for(lambda: b'LATE_ORIGINAL_RESULT' in self.fixture.egg())

    def test_off_does_not_save_cursor_answer_or_tool_results(self):
        self.start('cursor')
        session = adapter.session_key('cursor', 'chat')
        subprocess.run([BRIDGE, 'egg', 'off'], env=dict(self.env, CODEX_THREAD_ID=session),
                       cwd=self.root, capture_output=True, check=True)
        self.hook('cursor', 'AssistantMessage', text='PRIVATE_ANSWER_SHOULD_NOT_BE_SAVED')
        self.tool('cursor', 'PRIVATE_TOOL_SHOULD_NOT_BE_SAVED')
        self.hook('cursor', 'Stop', status='completed')
        self.assertNotIn(b'PRIVATE_', self.fixture.egg())
        self.assertFalse(list(self.fixture.data.glob('sessions/*/adapter-drafts/*.json')))

    def test_one_turn_private_profile_does_not_store_a_cursor_draft(self):
        self.fixture.config.write_text(self.fixture.config.read_text() +
            '\n[profiles.private]\nread = ["project"]\n')
        self.hook('cursor', 'SessionStart', source='startup')
        env = dict(self.env, CODEX_THREAD_ID=adapter.session_key('cursor', 'chat'))
        subprocess.run([BRIDGE, 'egg', 'next', 'private'], env=env, cwd=self.root,
                       capture_output=True, check=True)
        self.hook('cursor', 'UserPromptSubmit', prompt='A private investigation')
        self.hook('cursor', 'AssistantMessage', text='PRIVATE_TURN_ANSWER')
        self.assertFalse(list(self.fixture.data.glob('sessions/*/adapter-drafts/*.json')))
        self.hook('cursor', 'Stop', status='completed')
        self.assertNotIn(b'PRIVATE_TURN_ANSWER', self.fixture.egg())

    def test_gemini_ambiguous_results_are_retained_without_a_false_parent(self):
        self.start('gemini')
        fields = dict(tool_name='run_shell_command', tool_input={'command': 'cat overlap.c'})
        self.hook('gemini', 'PreToolUse', **fields)
        self.hook('gemini', 'UserPromptSubmit', prompt='A different overlapping turn')
        self.hook('gemini', 'PreToolUse', **fields)
        self.hook('gemini', 'PostToolUse', tool_response={'llmContent': 'AMBIGUOUS_RESULT'}, **fields)
        files = list((self.fixture.data / 'adapters/unattributed').glob('*/*.json'))
        self.assertEqual(len(files), 1)
        receipt = json.loads(files[0].read_text())
        self.assertNotIn('turn_id', receipt)
        self.assertEqual(receipt['tool_response']['llmContent'], 'AMBIGUOUS_RESULT')
        self.assertNotIn(b'AMBIGUOUS_RESULT', self.fixture.egg())

    def test_gemini_replayed_timestamp_keeps_original_tool_identity(self):
        self.start('gemini')
        fields = dict(tool_name='run_shell_command', tool_input={'command': 'cat replay.c'})
        self.hook('gemini', 'PreToolUse', timestamp='2026-09-12T00:00:00.000Z', **fields)
        raw = self.raw('gemini', 'PostToolUse', timestamp='2026-09-12T00:00:01.000Z',
                       tool_response={'llmContent': 'REPLAYED_RESULT'}, **fields)
        self.send('gemini', raw)
        lifecycle.wait_for(lambda: b'REPLAYED_RESULT' in self.fixture.egg())
        before = self.fixture.egg()
        self.send('gemini', raw)
        self.assertEqual(self.fixture.egg(), before)

    def test_ack_failure_does_not_append_a_second_json_response(self):
        raw = self.raw('claude', 'UserPromptSubmit', prompt='A question')
        output = io.StringIO()
        receipt = dict(ok=True, output={'hookSpecificOutput': {'additionalContext': 'Prior work'}},
                       receipt='receipt')
        with mock.patch.object(adapter, 'invoke', side_effect=[receipt, RuntimeError('ack unavailable')]), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            adapter.run_hook('claude', raw, BRIDGE, self.root / 'adapter-state')
        self.assertEqual(json.loads(output.getvalue())['hookSpecificOutput']['additionalContext'], 'Prior work')

    def test_stop_outputs_never_request_an_agent_retry(self):
        malicious = {'continue': True, 'followup_message': 'repeat forever',
            'decision': 'block', 'reason': 'repeat',
            'hookSpecificOutput': {'additionalContext': 'repeat',
                'permissionDecision': 'deny', 'permissionDecisionReason': 'repeat'}}
        for client in adapter.CLIENTS:
            for event in ('Stop', 'Interrupt', 'SessionEnd'):
                self.assertEqual(adapter.translate(client, event, malicious), {})

    def test_installation_preserves_other_hooks_and_uninstall_removes_only_ours(self):
        prefix = self.root / "adapter prefix's"
        for client in adapter.CLIENTS:
            with self.subTest(client=client):
                project = self.root / client
                project.mkdir()
                config = project / installer.CONFIGS[client]
                if client != 'opencode':
                    config.parent.mkdir(parents=True)
                    initial = {'otherSetting': True, 'hooks': {'SomeOtherEvent': [{'command': 'keep-me'}]}}
                    if client == 'cursor':
                        initial['version'] = 1
                    config.write_text(json.dumps(initial))
                installer.install(client, project, prefix, BRIDGE)
                first = config.read_text()
                installer.install(client, project, prefix, BRIDGE)
                self.assertEqual(config.read_text(), first)
                installer.install(client, project, prefix, BRIDGE, uninstall=True)
                if client == 'opencode':
                    self.assertFalse(config.exists())
                else:
                    self.assertEqual(json.loads(config.read_text()), initial)
                self.assertTrue((prefix / 'share/eggshell-adapters/eggshell-bridge').exists())

    def test_invalid_configuration_and_unowned_plugin_are_not_overwritten(self):
        for client in ('claude', 'opencode'):
            project = self.root / ('invalid-' + client)
            config = project / installer.CONFIGS[client]
            config.parent.mkdir(parents=True)
            config.write_text('preserve this unowned content')
            with self.assertRaises(ValueError):
                installer.install(client, project, self.root / 'prefix', BRIDGE)
            self.assertEqual(config.read_text(), 'preserve this unowned content')


if __name__ == '__main__':
    unittest.main()
