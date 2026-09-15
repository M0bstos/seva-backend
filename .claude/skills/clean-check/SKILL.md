---
name: clean-check
description: Run every check in the repo, then remove unused code, exports, files and dependencies and report exactly what was removed. Use when asked for a clean check, or before a handover.
---

# Clean check

## 1. Run everything

```bash
deno task check      # format, lint, type-check functions
deno task test       # Edge Function tests
deno task db:test    # reset, db lint, pgTAP including the §9.7 security gates
```

Never skip, disable or weaken a check to make it pass — fix the cause. A `// deno-lint-ignore` needs a one-line reason.

## 2. Remove what nothing uses

- Unused exports, functions, types and constants.
- Files nothing imports, including `.gitkeep` placeholders in directories that now hold real content.
- Dependencies in `deno.json`, and imports, that nothing references.
- Commented-out code. Git keeps the history.
- Comments that restate a signature, banner comments and TODOs.

## 3. Run everything again

A removal that breaks a check means the thing was used. Put it back and say why it looked unused.

## 4. Report

List exactly what was removed and why, then the final state of all three checks. If anything is red, say so and include the output. Never report a clean check on red.
