# Using the Swidux Agent Skill

Install the bundled `swidux-ref` skill so your AI coding assistant has Swidux's architecture rules and code templates on hand.

## Overview

Swidux ships a companion agent skill (`swidux-ref`) for AI coding assistants like Claude Code. It contains the architecture rules, conventions, and code templates an assistant needs to generate correct Swidux code without you re-explaining the patterns.

The skill files live in this repo at `.claude/skills/swidux-ref/`:

- `SKILL.md` — architecture rules (the 10 rules, the dispatch lifecycle, plugin shapes, anti-patterns).
- `swidux-patterns.md` — copy-pasteable code templates for `AppState`, `AppAction`, reducers, `AppStore` factory, views, plugin wiring, and Swift Testing reducer tests.

## Installing the skill

Claude Code does **not** auto-discover skills inside Swift Package dependencies. SwiftPM resolves checkouts into `.build/checkouts/...` (CLI) or hashed DerivedData paths (Xcode), and Claude Code only loads skills from a fixed set of locations:

| Scope | Path |
|---|---|
| Personal | `~/.claude/skills/<skill-name>/SKILL.md` |
| Project | `<project>/.claude/skills/<skill-name>/SKILL.md` |
| Plugin | bundled inside an installed Claude Code plugin |

Pick one of the three install methods below.

### Option 1 — Symlink from a Swidux clone (recommended for personal use)

Clone Swidux somewhere stable, then symlink the skill folder into your personal scope:

```bash
git clone https://github.com/heirloomlogic/Swidux ~/code/Swidux
ln -s ~/code/Swidux/.claude/skills/swidux-ref ~/.claude/skills/swidux-ref
```

The skill stays in sync as you `git pull` the Swidux clone.

### Option 2 — Commit a copy in your project (recommended for teams)

If you want everyone on your team to get the skill without per-developer setup, copy the folder into your project's `.claude/skills/`:

```bash
mkdir -p .claude/skills
cp -R path/to/Swidux-clone/.claude/skills/swidux-ref .claude/skills/swidux-ref
git add .claude/skills/swidux-ref
```

Now the skill loads whenever anyone opens the project in Claude Code. Re-copy when you upgrade Swidux.

### Option 3 — Other AI assistants

The skill files are plain Markdown. Point your assistant's context, system prompt, or rules file at `swidux-ref/SKILL.md` and `swidux-ref/swidux-patterns.md` to load the architecture reference and code templates.

## What it helps with

| Task | What the skill teaches the assistant |
|---|---|
| Add a new feature | Generates the full stack: state slice, action enum, reducer, view binding |
| Wire ``EntityStore`` mutations | Uses ``EntityStore/modify(_:_:)`` for in-place edits and the subscript setter for inserts/deletes |
| Configure persistence | Uses ``StateWriter`` per slice; never writes `save()` in a reducer |
| Build form inputs | Uses controlled `Binding(get:set:)` instead of `@State` buffering |
| Write effects | Specializes ``Effect`` and ``Send``; runs work with `Task { @concurrent in }` |
| Add undo/redo | Wires ``UndoPlugin`` with `isUndoable` and `coalescing` predicates |
| Wire a paywall | Wires `PaywallPlugin` against a `PaywallService` conformer |
| Wire a killswitch | Wires `KillswitchPlugin` against a `KillswitchService` |
| Wire a parental gate | Wires `ParentalGatePlugin` and gates an action behind a passed reason |
| Scaffold a new app | Creates files in the correct order with the canonical layout |

## Example prompts

With the skill loaded, these requests produce correct Swidux code on the first try:

- "Add a Tag feature with CRUD operations"
- "Wire persistence for the new Campaign entity"
- "Add undo support for card editing"
- "Add a paywall with a RevenueCat-shaped service"
- "Add a parental gate before the in-app purchase"
- "Add a version killswitch with a 1-hour cache"
- "Scaffold a new macOS app using Swidux"

## Updating the skill

When Swidux releases a new version, refresh whichever copy of the skill you're using:

- **Symlinked install:** `git pull` the Swidux clone.
- **Project-committed install:** re-copy the `swidux-ref` folder.

Skill files version with the rest of the package.
