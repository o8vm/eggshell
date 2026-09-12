import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const bridge = fileURLToPath(new URL('./eggshell-bridge', import.meta.url));
const prefix = fileURLToPath(new URL('../../', import.meta.url));

function command(mode, payload, directory) {
  return new Promise((resolve, reject) => {
    const child = spawn(bridge, [mode, 'opencode'], {
      cwd: directory, stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, EGGSHELL_PREFIX: prefix },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', (data) => { stdout += data; });
    child.stderr.setEncoding('utf8').on('data', (data) => { stderr += data; });
    child.on('error', reject);
    child.on('close', (code) => {
      if (stderr) console.error(stderr.trim());
      if (code !== 0) return reject(new Error(`Eggshell adapter exited with ${code}`));
      try { resolve(stdout.trim() ? JSON.parse(stdout) : {}); }
      catch (error) { reject(error); }
    });
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(payload));
  });
}

/** The runner argument is a transport seam for deterministic contract tests. */
export function createEggshellHooks(directory, run = command) {
  const textParts = new Map();
  const completions = new Map();

  async function hook(session, event, fields = {}) {
    try {
      return await run('hook', {
        hook_event_name: event, session_id: session, cwd: directory, ...fields,
      }, directory);
    } catch (error) {
      console.error(`Eggshell: ${error.message}`);
      return {};
    }
  }

  async function ack(receipt) {
    if (!receipt.receipt || !receipt.session_id) return;
    try {
      await run('ack', { receipt: receipt.receipt, session_id: receipt.session_id }, directory);
    } catch (error) {
      console.error(`Eggshell delivery receipt: ${error.message}`);
    }
  }

  return {
    'chat.message': async (input, output) => {
      const text = output.parts.filter((part) =>
        part.type === 'text' && !part.synthetic && !part.ignored).map((part) => part.text).join('\n');
      if (!text || !output.message.id) return;
      const receipt = await hook(input.sessionID, 'UserPromptSubmit', {
        turn_id: output.message.id, prompt: text,
      });
      const context = receipt.output?.hookSpecificOutput?.additionalContext;
      if (context) {
        output.parts.push({ type: 'text', id: `prt_eggshell${randomUUID().replaceAll('-', '')}`,
          sessionID: input.sessionID, messageID: output.message.id, synthetic: true, text: context });
        await ack(receipt);
      }
    },
    'tool.execute.before': async (input, output) => {
      const receipt = await hook(input.sessionID, 'PreToolUse', {
        tool_name: input.tool, tool_use_id: input.callID, tool_input: output.args,
      });
      const decision = receipt.output?.hookSpecificOutput;
      if (decision?.permissionDecision === 'deny') {
        await ack(receipt);
        throw new Error(decision.permissionDecisionReason);
      }
    },
    'tool.execute.after': async (input, output) => {
      // Capture the original result before attaching memory to the model output.
      const receipt = await hook(input.sessionID, 'PostToolUse', {
        tool_name: input.tool, tool_use_id: input.callID, tool_input: input.args,
        tool_response: { title: output.title, output: output.output, metadata: output.metadata },
      });
      const context = receipt.output?.hookSpecificOutput?.additionalContext;
      if (context) {
        output.output += `\n\n${context}`;
        await ack(receipt);
      }
    },
    'experimental.text.complete': async (input, output) => {
      const key = `${input.sessionID}\n${input.messageID}`;
      const parts = textParts.get(key) || new Map();
      parts.set(input.partID, output.text);
      textParts.set(key, parts);
    },
    event: async ({ event }) => {
      const properties = event.properties;
      if (event.type === 'session.created') {
        await hook(properties.info.id, 'SessionStart', { source: 'startup' });
      } else if (event.type === 'session.compacted') {
        await hook(properties.sessionID, 'PostCompact');
      } else if (event.type === 'message.updated') {
        const message = properties.info;
        if (message.role === 'assistant' && message.time?.completed && message.finish === 'stop' && !message.error) {
          completions.set(message.sessionID, { id: message.id, turn: message.parentID });
        }
      } else if (event.type === 'session.idle') {
        const session = properties.sessionID;
        const completed = completions.get(session);
        const parts = completed && textParts.get(`${session}\n${completed.id}`);
        await hook(session, 'Stop', completed ? {
          turn_id: completed.turn,
          ...(parts ? { last_assistant_message: [...parts.values()].join('\n') } : {}),
        } : {});
        completions.delete(session);
        for (const key of textParts.keys()) if (key.startsWith(`${session}\n`)) textParts.delete(key);
      } else if (event.type === 'session.error') {
        if (properties.sessionID) await hook(properties.sessionID, 'Interrupt');
      } else if (event.type === 'session.deleted') {
        await hook(properties.info.id, 'SessionEnd');
        completions.delete(properties.info.id);
        for (const key of textParts.keys()) if (key.startsWith(`${properties.info.id}\n`)) textParts.delete(key);
      }
    },
  };
}

export const Eggshell = async ({ directory }) => createEggshellHooks(directory);
