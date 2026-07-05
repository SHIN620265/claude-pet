// claude-pet companion: tab-level jump for VS Code integrated terminals.
//
// The pet (a separate desktop process) can only bring the whole VS Code window to the
// front -- no external API can focus a specific integrated terminal. This extension
// closes that gap from the inside: the pet drops the clicked session's ancestor PID
// chain into ~/.claude/pet-data/jump-req-<nonce>.json (unique name, written via
// tmp+rename, so a *.json is always complete); every VS Code window runs one
// instance of this extension, and ONLY the window whose own terminals contain one of
// those PIDs acts (terminal.processId is the shell VS Code spawned -- the claude
// process's parent -- so ownership is exact, never guessed). The owner focuses the
// terminal and writes jump-ack.json so the pet's log can tell handshake from silence.
//
// Deliberately boring: one file, no dependencies, no state beyond a dedup nonce,
// nothing ever sent anywhere. Requests older than 5s (or replayed nonces) are ignored,
// so a stale file left on disk can never flip a tab days later.

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');

const DATA_DIR = path.join(os.homedir(), '.claude', 'pet-data');
const REQ_RE = /^jump-req-[0-9a-f]{8,}\.json$/;
const ACK_FILE = path.join(DATA_DIR, 'jump-ack.json');
const MAX_AGE_MS = 5000;

let lastNonce = '';
let watcher = null;

function readRequest(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null; // half-written files can't appear (tmp+rename); garbage stays ignored
  }
}

async function act(req) {
  if (!req || typeof req.nonce !== 'string' || req.nonce === lastNonce) return;
  if (!Array.isArray(req.ancestorPids) || req.ancestorPids.length === 0) return;
  if (typeof req.ts !== 'number' || Math.abs(Date.now() - req.ts) > MAX_AGE_MS) return;
  const wanted = new Set(req.ancestorPids);
  for (const term of vscode.window.terminals) {
    let pid;
    try {
      pid = await term.processId;
    } catch {
      continue;
    }
    if (pid && wanted.has(pid)) {
      lastNonce = req.nonce;
      term.show(false); // false = take focus, not just reveal
      try {
        fs.writeFileSync(
          ACK_FILE,
          JSON.stringify({ nonce: req.nonce, matchedPid: pid, ts: Date.now() })
        );
      } catch {}
      return;
    }
  }
  // no terminal of THIS window owns the session: stay silent, another window's
  // instance (or nobody, if the session lives in Windows Terminal) will answer
}

function activate() {
  try {
    watcher = fs.watch(DATA_DIR, (evt, fname) => {
      if (fname && REQ_RE.test(fname)) act(readRequest(path.join(DATA_DIR, fname)));
    });
  } catch {
    // pet-data dir missing = pet never ran; nothing to do until next window reload
  }
  // catch-up: onStartupFinished fires seconds after a window (re)load, so a card
  // clicked during that gap would die unheard -- act on the newest request if it is
  // still inside the freshness window (the 5s expiry + nonce dedup keep this honest)
  try {
    const cand = fs.readdirSync(DATA_DIR).filter((f) => REQ_RE.test(f));
    if (cand.length) {
      const newest = cand
        .map((f) => ({ f, m: fs.statSync(path.join(DATA_DIR, f)).mtimeMs }))
        .sort((a, b) => b.m - a.m)[0];
      act(readRequest(path.join(DATA_DIR, newest.f)));
    }
  } catch {}
}

function deactivate() {
  if (watcher) {
    try {
      watcher.close();
    } catch {}
    watcher = null;
  }
}

module.exports = { activate, deactivate };
