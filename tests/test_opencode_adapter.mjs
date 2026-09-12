import assert from 'node:assert/strict';
import test from 'node:test';
import { createEggshellHooks } from '../adapters/opencode.mjs';

function receipt(context) {
  return { output: { hookSpecificOutput: { additionalContext: context } },
    receipt: 'receipt', session_id: 'opencode-native-session' };
}

test('prompt context is a separate synthetic part and ack follows insertion', async () => {
  const original = { type: 'text', text: 'Inspect clock.c', id: 'prt_original' };
  const output = { message: { id: 'msg_user' }, parts: [original] };
  const calls = [];
  const hooks = createEggshellHooks('/project', async (mode, payload) => {
    calls.push([mode, payload]);
    if (mode === 'ack') assert.equal(output.parts[1].text, 'Saved work');
    return mode === 'hook' ? receipt('Saved work') : {};
  });
  await hooks['chat.message']({ sessionID: 'session' }, output);
  assert.deepEqual(output.parts[0], original);
  assert.equal(output.parts[1].synthetic, true);
  assert.equal(calls[0][1].prompt, 'Inspect clock.c');
  assert.equal(calls[0][1].turn_id, 'msg_user');
  assert.deepEqual(calls.map(([mode]) => mode), ['hook', 'ack']);
});

test('tool capture excludes the memory that is added afterwards', async () => {
  const output = { title: 'Read clock', output: 'original result', metadata: {} };
  const hooks = createEggshellHooks('/project', async (mode, payload) => {
    if (mode === 'hook') {
      assert.equal(payload.tool_response.output, 'original result');
      return receipt('Prior evidence');
    }
    assert.equal(output.output, 'original result\n\nPrior evidence');
    return {};
  });
  await hooks['tool.execute.after']({ sessionID: 'session', callID: 'tool', tool: 'read',
    args: { filePath: '/project/clock.c' } }, output);
});

test('a covered operation is denied through the tool hook, with its reason intact', async () => {
  const calls = [];
  const hooks = createEggshellHooks('/project', async (mode) => {
    calls.push(mode);
    return { output: { hookSpecificOutput: {
      permissionDecision: 'deny', permissionDecisionReason: 'Reuse the supported result.',
    } }, receipt: 'receipt', session_id: 'opencode-native-session' };
  });
  await assert.rejects(hooks['tool.execute.before']({ sessionID: 'session', callID: 'tool', tool: 'read' },
    { args: { filePath: 'clock.c' } }), /Reuse the supported result/);
  assert.deepEqual(calls, ['hook', 'ack']);
});

test('a completed assistant answer is saved only when the agent becomes idle', async () => {
  const events = [];
  const hooks = createEggshellHooks('/project', async (mode, payload) => {
    events.push(payload);
    return {};
  });
  await hooks['experimental.text.complete']({ sessionID: 'session', messageID: 'answer', partID: 'part' },
    { text: 'Final supported answer' });
  assert.equal(events.length, 0);
  await hooks.event({ event: { type: 'message.updated', properties: { info: {
    role: 'assistant', id: 'answer', sessionID: 'session', parentID: 'user-turn',
    time: { completed: 123 }, finish: 'stop',
  } } } });
  assert.equal(events.length, 0);
  await hooks.event({ event: { type: 'session.idle', properties: { sessionID: 'session' } } });
  assert.deepEqual(events.map((event) => event.hook_event_name), ['Stop']);
  assert.equal(events[0].last_assistant_message, 'Final supported answer');
  assert.equal(events[0].turn_id, 'user-turn');
});

test('tool-call messages are not treated as completed answers', async () => {
  const events = [];
  const hooks = createEggshellHooks('/project', async (mode, payload) => { events.push(payload); return {}; });
  await hooks.event({ event: { type: 'message.updated', properties: { info: {
    role: 'assistant', id: 'tools', sessionID: 'session', parentID: 'user-turn',
    time: { completed: 123 }, finish: 'tool-calls',
  } } } });
  await hooks.event({ event: { type: 'session.idle', properties: { sessionID: 'session' } } });
  assert.equal(events[0].last_assistant_message, undefined);
});

test('compaction and stop never add an automatic follow-up or modify the compaction prompt', async () => {
  const events = [];
  const hooks = createEggshellHooks('/project', async (mode, payload) => { events.push(payload); return {}; });
  assert.equal(hooks['experimental.session.compacting'], undefined);
  await hooks.event({ event: { type: 'session.compacted', properties: { sessionID: 'session' } } });
  await hooks.event({ event: { type: 'session.idle', properties: { sessionID: 'session' } } });
  assert.deepEqual(events.map((event) => event.hook_event_name), ['PostCompact', 'Stop']);
  assert.ok(events.every((event) => !('followup_message' in event)));
});
