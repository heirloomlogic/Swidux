# Using the Swidux Agent Skill

Install the bundled `swidux-ref` skill so your AI coding assistant has Swidux's architecture rules and code templates on hand.

## Overview

Swidux ships a companion agent skill (`swidux-ref`) for AI coding assistants like Claude Code. It contains the architecture rules, conventions, and code templates an assistant needs to generate correct Swidux code without you re-explaining the patterns.

The skill is published in [heirloomlogic/skills](https://github.com/heirloomlogic/skills) — Heirloom Logic's public skills repo — alongside any future Heirloom skills. Two files:

- `SKILL.md` — architecture rules (the 10 rules, the dispatch lifecycle, plugin shapes, anti-patterns).
- `swidux-patterns.md` — copy-pasteable code templates for `AppState`, `AppAction`, reducers, `AppStore` factory, views, plugin wiring, and Swift Testing reducer tests.

## Installing the skill

### GitHub CLI (recommended)

Requires `gh` ≥ v2.90.0 ([install](https://cli.github.com)).

```bash
gh skill install heirloomlogic/skills swidux-ref --agent claude-code --scope user
```

- `--scope user` installs to `~/.claude/skills/swidux-ref/` (loads in every project).
- `--scope project` installs to `<cwd>/.claude/skills/swidux-ref/` (commit it so the whole team gets it).
- Pin a version with `swidux-ref@v1.2.3`. List tags with `git ls-remote --tags https://github.com/heirloomlogic/skills`.
- Other agents: pass `--agent codex`, `--agent cursor`, `--agent gemini-cli`, etc. Run `gh skill install --help` for the full list.

### skills.sh

```bash
npx skillsadd heirloomlogic/skills
```

Indexes the same source repo. Works without a GitHub CLI install.

### Manual (no `gh`, no `npx`)

Claude Code uses `.claude/skills/`. Codex, Cursor, Gemini CLI, and others use `.agents/skills/`. Pick the directory that matches your agent:

```bash
# Claude Code — project install
mkdir -p .claude/skills && \
  curl -fsSL https://github.com/heirloomlogic/skills/archive/refs/heads/main.tar.gz | \
  tar -xz --strip-components=2 -C .claude/skills skills-main/swidux-ref

# Codex / Cursor / Gemini CLI — project install
mkdir -p .agents/skills && \
  curl -fsSL https://github.com/heirloomlogic/skills/archive/refs/heads/main.tar.gz | \
  tar -xz --strip-components=2 -C .agents/skills skills-main/swidux-ref
```

Swap `.claude/skills` / `.agents/skills` for `~/.claude/skills` etc. for a user-wide install. `tar` overwrites by default, so re-running either command updates the skill in place. To pin a version, replace `main` in the URL with the tag name (e.g. `swidux-ref@v1.0.0`).

### Loading content directly (assistants without a skill loader)

The skill files are plain Markdown. Point your assistant's system prompt or rules file at:

- `https://raw.githubusercontent.com/heirloomlogic/skills/main/swidux-ref/SKILL.md`
- `https://raw.githubusercontent.com/heirloomlogic/skills/main/swidux-ref/swidux-patterns.md`

## What it helps with

| Task | What the skill teaches the assistant |
|---|---|
| Add a new feature | Generates the full stack: state slice, action enum, reducer, view binding |
| Wire ``EntityStore`` mutations | Uses ``EntityStore/modify(_:_:)`` for in-place edits and the subscript setter for inserts/deletes |
| Configure persistence | Uses ``StateWriter`` per slice; never writes `save()` in a reducer |
| Build form inputs | Uses ``Store/binding(_:sending:)`` for keypath reads, `Binding(get:set:)` for transformed reads; never buffers in `@State` |
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

Re-run whichever install command you used originally — `gh skill install ...`, `npx skillsadd ...`, or the `curl | tar` one-liner. Each overwrites the existing copy in place.

The skill versions independently of the Swidux Swift package: tags on `heirloomlogic/skills` follow the form `swidux-ref@vX.Y.Z`. Pass a tag explicitly (`gh skill install heirloomlogic/skills swidux-ref@v1.2.3 ...`, or substitute the tag for `main` in the curl URL) to lock to a known version.
