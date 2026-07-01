---
description: Toggle my desktop companion pet (Claude spark)
allowed-tools: Bash(pwsh:*)
---
!`pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/pet-toggle.ps1"`

The command above toggled the desktop pet and printed `on` or `off`. Just tell the user briefly: `on` -> the pet opened; `off` -> the pet closed. Do nothing else.
