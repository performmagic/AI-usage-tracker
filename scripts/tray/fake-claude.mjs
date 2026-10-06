// Test double for the Claude CLI, used only by scripts/tray/tests-refresh.ps1.
// Behaves like an interactive CLI: waits for "/exit" + Enter typed into its console, then acts by mode.
// FAKE_CLAUDE_DIR holds mode.txt, .credentials.json, .claude.json and the starts.log it appends to.
// modes: refresh (extend expiry, exit 0) | noextend (exit 0) | exit1 | corrupt (break .claude.json, extend) | slow (3 s, then refresh) | hang (never exits)
import fs from 'node:fs';
import path from 'node:path';

const dir = process.env.FAKE_CLAUDE_DIR;
const mode = () => fs.readFileSync(path.join(dir, 'mode.txt'), 'utf8').trim();
const otherClaudeVars = Object.keys(process.env)
  .filter((key) => /^(CLAUDE|ANTHROPIC)/.test(key) && key !== 'CLAUDE_CODE_SKIP_PROMPT_HISTORY').length;
fs.appendFileSync(
  path.join(dir, 'starts.log'),
  `pid=${process.pid} skipHistory=${process.env.CLAUDE_CODE_SKIP_PROMPT_HISTORY ?? ''} otherClaudeVars=${otherClaudeVars} cwd=${process.cwd()}\n`
);

const extend = () => fs.writeFileSync(
  path.join(dir, '.credentials.json'),
  JSON.stringify({ claudeAiOauth: { accessToken: 'FAKE-TEST-TOKEN', expiresAt: Date.now() + 8 * 3600 * 1000 } })
);

function finish() {
  const current = mode();
  if (current === 'hang') return;
  if (current === 'exit1') process.exit(1);
  if (current === 'noextend') process.exit(0);
  if (current === 'corrupt') {
    fs.writeFileSync(path.join(dir, '.claude.json'), '{broken');
    extend();
    process.exit(0);
  }
  if (current === 'slow') {
    setTimeout(() => { extend(); process.exit(0); }, 3000);
    return;
  }
  extend();
  process.exit(0);
}

if (process.stdin.isTTY) process.stdin.setRawMode(true);
let typed = '';
process.stdin.on('data', (chunk) => {
  typed += chunk.toString();
  const at = typed.indexOf('/exit');
  if (at >= 0 && /[\r\n]/.test(typed.slice(at))) finish();
});
process.stdin.resume();
setInterval(() => {}, 1000);
