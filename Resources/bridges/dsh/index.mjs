import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';

export const name = 'starbud-bridge';
// Host-side only. No dependency on dsh-pet, UI, model tools, or credentials.
export function apply(ctx, config = {}) {
  if (!config.helperPath) throw new Error('QWhaleMaiden helperPath is required');
  const epoch = randomUUID(), sessions = new Map(), queue = [];
  let child = null, disposed = false, timer = null;
  function pump() {
    if (disposed || child || !queue.length) return;
    const payload = queue.shift();
    child = spawn(config.helperPath, ['hook', '--agent', 'dsh', '--silent'], { stdio: ['pipe', 'ignore', 'ignore'] });
    const current = child;
    timer = setTimeout(() => current.kill(), 1500);
    const done = () => {
      if (child !== current) return;
      clearTimeout(timer); child = null; pump();
    };
    current.on('error', done); current.on('close', done);
    current.stdin.on('error', () => {});
    current.stdin.end(JSON.stringify(payload));
  }
  function enqueue(payload) {
    if (queue.length >= 64) queue.shift();
    queue.push(payload); pump();
  }
  const off = ctx.on('session/event', (session, event) => {
    if (disposed || !event?.type || session?.header?.origin === 'subagent' || session?.header?.delegationDepth > 0) return;
    const id = String(session?.header?.id ?? session?.id ?? '');
    if (!id || id.length > 200) return;
    const data = event.data ?? {};
    if (event.type === 'turn/start') {
      if (Number.isFinite(event.seq) && sessions.get(id)?.startSeq === event.seq) return;
      if (sessions.size >= 256 && !sessions.has(id)) sessions.delete(sessions.keys().next().value);
      sessions.set(id, { turn: `${epoch}:${event.seq ?? randomUUID()}`, sequence: 0, startSeq: event.seq, lastSeq: -1, waiting: null });
    }
    const state = sessions.get(id);
    if (!state) return; // Don't replay pre-bridge historical completion.
    if (Number.isFinite(event.seq)) {
      if (event.seq <= state.lastSeq) return;
      state.lastSeq = event.seq;
    }
    const type = event.type;
    if (!['turn/start', 'turn/end', 'tool/call', 'tool/result', 'approval/asked'].includes(type)) return;
    const tool = typeof data.name === 'string' ? data.name : '';
    const call = typeof data.callId === 'string' ? data.callId : typeof data.id === 'string' ? data.id : null;
    const payload = { session_id: id, turn_id: state.turn, epoch, sequence: ++state.sequence,
      event_id: `${epoch}:${id}:${state.sequence}`, event_type: type };
    if (type === 'tool/call') payload.tool_name = tool;
    if (type === 'turn/end') payload.reason = String(data.reason?.kind ?? 'unknown');
    if (type === 'approval/asked' || type === 'tool/call' && tool === 'ask_user_question') {
      state.waiting = call ?? payload.event_id;
      payload.request_id = state.waiting;
    }
    if (type === 'tool/result' && call && call === state.waiting) {
      payload.resolves_wait = true; payload.request_id = call; state.waiting = null;
    }
    // All messages, tool arguments/results and approval details remain inside DSH.
    enqueue(payload);
  });
  ctx.effect(() => () => {
    disposed = true; off(); queue.length = 0; sessions.clear();
    clearTimeout(timer); child?.kill(); child = null;
  });
}
