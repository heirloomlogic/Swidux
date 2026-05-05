# Using the Swidux Agent Skill

Use the bundled `swidux-ref` skill to give your AI coding assistant Swidux's architecture rules and code patterns.

## Overview

Swidux includes an agent skill at `skills/swidux-ref/` for AI coding assistants like Claude Code. It contains the architecture rules, conventions, and code templates the assistant needs to generate correct Swidux code without you having to explain the patterns each time.

## What the Skill Covers

The skill contains two files:

- **SKILL.md** — Architecture reference covering the snapshot pattern, controlled components, effect threading, writer ordering, and other rules.
- **swidux-patterns.md** — Code templates for every layer: AppState, AppAction, reducers, AppStore, SwiftData models, DB actors, views, tests, and undo/redo.

With both files loaded, the assistant can scaffold features or catch architectural mistakes without reading every source file.

## Installation

### Claude Code

The skill is auto-discovered when you work in a project that depends on Swidux. If your downstream app has Swidux as a package dependency, symlink or copy the skill into your project:

```bash
# From your app's root directory
mkdir -p skills
cp -r path/to/Swidux/skills/swidux-ref skills/
```

The skill activates automatically when the assistant detects Swidux-related work — adding actions, modifying reducers, creating effects, working with ``EntityStore``, configuring ``PersistencePlugin``, or scaffolding a new app.

### Other Assistants

The skill files are plain Markdown. Point your assistant's context or system prompt at `skills/swidux-ref/SKILL.md` to load the architecture reference.

## What It Helps With

| Task | How the skill helps |
|------|-------------------|
| Add a new feature | Generates the full stack: value type, action enum, reducer, ``StateWriter``, view |
| Wire ``EntityStore`` mutations | Uses `modify` for conditional updates, subscript for inserts/deletes |
| Configure persistence | Respects writer ordering (leaves first, aggregates last) |
| Create form bindings | Uses controlled component pattern (`Binding(get:set:)`) instead of `@State` |
| Write effects | Uses `Task { @concurrent in }`, never bare `Task { }` |
| Add undo/redo | Wires ``UndoPlugin`` with coalescing and platform UI |
| Scaffold a new project | Creates files in the correct dependency order |

## Example Prompts

Once the skill is active, these kinds of requests produce correct Swidux code:

- "Add a Tag feature with CRUD operations"
- "Wire persistence for the new Campaign entity"
- "Add undo support for card editing"
- "Create a controlled text field for renaming items"
- "Scaffold a new macOS app using Swidux"
