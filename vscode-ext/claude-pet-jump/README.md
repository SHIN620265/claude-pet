# Claude Pet Jump (VS Code companion)

Companion extension for [claude-pet](https://github.com/SHIN620265/claude-pet).

Without it, clicking a pet status card brings the VS Code **window** to the front.
With it, the click also focuses **that session's integrated terminal tab** — even with
several Claude Code sessions running in one window.

## How it works

The pet writes the clicked session's ancestor PID chain to a uniquely named
`~/.claude/pet-data/jump-req-<nonce>.json` (tmp + rename, so a `.json` is always
complete). Each VS Code window runs one instance of this extension; only the window
whose own terminals contain one of those PIDs reacts (`terminal.processId` gives the
exact shell PID — ownership is proven, never guessed), calls `terminal.show()` and
writes `jump-ack.json`. Requests expire after 5 seconds and nonces are never replayed.
One file, no dependencies, no telemetry — nothing leaves your machine.

## Install

Until it's on the Marketplace, copy this folder into your local extensions directory
and reload VS Code:

```powershell
Copy-Item -Recurse -Force "$PWD" "$HOME\.vscode\extensions\shin620265.claude-pet-jump-0.1.0"
```

Then run **Developer: Reload Window** (terminals reconnect automatically).

## Requirements

- claude-pet v1.3.0+ (the pet side writes the handshake file)
- Windows (the pet itself is Windows-only)
