#!/usr/bin/env node
/**
 * AXN beforeSubmitPrompt Hook: route-skills.mjs
 * Generalized from local .cursor/hooks/route-analyst-skills.mjs.
 * Injects analyst/architect/visualizer routing context when the prompt matches.
 * Fail-open on miss or error (always exit 0; {} on miss).
 * Bounded stdin (1 MiB) to prevent memory exhaustion.
 */
import { stdin } from 'node:process';

const MAX_BYTES = Number(process.env.AXN_HOOK_MAX_BYTES || 1048576);

const TRIGGER =
  /\b(workflow|state[\s-]?machine|mermaid|business logic|sla|architecture|visualize|diagram|data flow|flowchart|adr)\b/i;

const CONTEXT = [
  'AXN routing suggestion (use only what matches this prompt):',
  '- Skill `business-analyst` -> extract process/SLA/queues',
  '- Skill `software-architect` or Agent `architect` -> runtime path/C4/ADR',
  '- Skill `workflow-visualizer` -> mermaid/diagram/visual flow',
  'Do not invent business transitions or unverified architectural facts.',
].join('\n');

function promptFrom(input) {
  if (!input || typeof input !== 'object') return '';
  const keys = ['prompt', 'user_prompt', 'content', 'text', 'message'];
  for (const k of keys) {
    const v = input[k];
    if (typeof v === 'string' && v.trim()) return v;
  }
  if (typeof input.arguments === 'string') return input.arguments;
  return '';
}

async function readStdinBounded() {
  const chunks = [];
  let total = 0;
  for await (const chunk of stdin) {
    total += chunk.length;
    if (total > MAX_BYTES) {
      throw new Error('stdin_limit_exceeded');
    }
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8').trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

try {
  const input = await readStdinBounded();
  const prompt = promptFrom(input);
  if (prompt && TRIGGER.test(prompt)) {
    process.stdout.write(JSON.stringify({ additional_context: CONTEXT }));
  } else {
    process.stdout.write('{}');
  }
} catch {
  process.stdout.write('{}');
}
process.exit(0);
