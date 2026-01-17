# Beads Task System Architecture

## Overview

Beads is a **work queue and session memory system** for agents. It lets agents wake up knowing what they were working on and what's next. This is NOT a planning tool like Jira—high-level planning happens elsewhere. Beads manages immediate execution work.

**Core principle:** SQLite provides crash-safe local persistence. JSONL files in `.tasks/` are the git-friendly format for sharing and collaboration.

## System Boundaries

```
┌─────────────────────┬───────────────────────────────────────────┐
│   GIT TOOLS         │   BEADS (this system)                     │
│   (code VCS)        │   (agent work queue + memory)             │
├─────────────────────┼───────────────────────────────────────────┤
│ git_add             │ get_current_task    ← "what am I doing?"  │
│ git_commit          │ get_ready_tasks     ← "what's next?"      │
│ git_diff            │ complete_task       ← "I finished"        │
│ git_status          │ add_task            ← "new work item"     │
│ ...                 │ add_subtask         ← "needs breakdown"   │
│                     │ block_task          ← "I'm stuck"         │
│                     │ get_session_context ← cold start recovery │
│                     │ land_the_plane      ← session end ritual  │
├─────────────────────┴───────────────────────────────────────────┤
│   TODOS (scratch notes, ephemeral, NOT git-tracked)             │
│   add_todo, list_todos, complete_todo — separate concern        │
└─────────────────────────────────────────────────────────────────┘
```

## Data Model

### Task

| Field | Type | Description |
|-------|------|-------------|
| id | 8-char hex | SHA256-based unique identifier |
| title | string | Required |
| description | string? | Optional details |
| status | enum | `pending`, `in_progress`, `completed`, `blocked`, `cancelled` |
| priority | enum | `critical`(0), `high`(1), `medium`(2), `low`(3), `wishlist`(4) |
| task_type | enum | `task`, `bug`, `feature`, `research`, `wisp`, `molecule` |
| parent_id | TaskId? | For subtasks under molecules |
| labels | []string | Tags for categorization |
| blocked_by_count | int | Cached count of blocking dependencies |
| created_at | i64 | Unix timestamp of creation |
| updated_at | i64 | Unix timestamp of last modification |
| completed_at | i64? | Unix timestamp when completed |

### Task Types

- **task** — Default single action item
- **bug** — Fix something broken
- **feature** — New capability
- **research** — Investigation/exploration
- **wisp** — Ephemeral, in-memory only (not persisted)
- **molecule** — Epic container with child tasks

### Dependencies

Each dependency links a source task to a destination task with a type:

| Type | Meaning |
|------|---------|
| `blocks` | Hard dependency—destination cannot start until source completes |
| `parent` | Hierarchical—child belongs to parent molecule |
| `related` | Soft reference—no execution impact |
| `discovered` | Provenance—where task originated |

Dependencies also have a `weight: f32` field (reserved for future semantic weighting, currently unused).

## Storage Architecture

```
.tasks/                      # Per-project, in git root
├── tasks.jsonl             # Git-tracked (for sharing/collaboration)
├── dependencies.jsonl      # Git-tracked
├── SESSION_STATE.md        # Git-tracked (cold start context)
└── tasks.db                # SQLite (gitignored, crash recovery)
```

### Write Flow
Tool → TaskStore (memory) → TaskDB (SQLite, immediate)
                         → [on land_the_plane] → JSONL + git commit

### Read Flow (Cold Start)
1. SQLite exists with data? → Load from SQLite (preserves unsaved work)
2. No SQLite but JSONL exists? → Load from JSONL (fresh clone) → Populate SQLite
3. Neither? → Fresh start

### Crash Recovery
If app crashes before `land_the_plane`, work is preserved in SQLite.
On restart, tasks load from SQLite automatically.

### Collaboration Flow
```
User A: work → land_the_plane → git push
User B: git pull → app loads from JSONL (no local SQLite) → SQLite populated
```

## Tool Reference

### Workflow
| Tool | Purpose |
|------|---------|
| `get_current_task` | What am I working on? Auto-assigns from ready queue if none. |
| `get_ready_tasks` | Unblocked pending tasks, sorted by priority |
| `complete_task` | Mark done, auto-unblock dependents, advance to next |
| `start_task` | Explicitly assign a task as current |

### Creation
| Tool | Purpose |
|------|---------|
| `add_task` | Create new task with priority, type, labels, dependencies |
| `add_subtask` | Create child task under a parent (defaults to current) |
| `add_dependency` | Create relationship between tasks |

### Query
| Tool | Purpose |
|------|---------|
| `list_tasks` | Query tasks with filters (status, priority, type, parent, labels) |
| `get_children` | List subtasks of a molecule |
| `get_siblings` | List tasks with same parent |
| `get_epic_summary` | Molecule completion stats |

### State Management
| Tool | Purpose |
|------|---------|
| `block_task` | Mark task as blocked, optionally specify blocker |
| `update_task` | Modify task properties |
| `get_session_context` | Cold start recovery: current task, ready queue, recent history. Optional `depth` param controls how many completed tasks to include (default 3). |

### Sync
| Tool | Purpose |
|------|---------|
| `sync_to_git` | Export to JSONL, commit .tasks/ directory |
| `land_the_plane` | Session end: export tasks, generate SESSION_STATE.md, commit .tasks/. Warns if code is uncommitted but does not auto-commit code. |

## Session Flow

### Cold Start
1. Load `.tasks/SESSION_STATE.md`
2. Call `get_session_context()` → current task, ready queue, recent completions
3. Resume work

### Active Work Loop
1. `get_current_task()` → returns active task (or auto-assigns highest priority ready)
2. Work on task
3. `complete_task()` → marks done, unblocks dependents, returns next task
4. Repeat

### Session End
1. `land_the_plane()` → warns about uncommitted code, exports JSONL, generates SESSION_STATE.md, commits .tasks/

## Key Algorithms

**Ready Queue:** Tasks where `status == pending && blocked_by_count == 0 && type != molecule`, sorted by priority (lower number = higher).

**Completion Cascade:** When task completes, all `blocks` dependencies with this task as source are removed. Destinations have `blocked_by_count` decremented. If count reaches 0 and status was `blocked`, status becomes `pending`.

**Circular Prevention:** Adding a blocking dependency checks for direct reverse edges (A→B and B→A). Note: does not detect longer cycles (A→B→C→A).

### Advanced Query Functions (TaskStore)

These are available in the store but not exposed as tools:

| Function | Purpose |
|----------|---------|
| `getBlockedBy(task_id)` | Get tasks that block a given task |
| `getBlocking(task_id)` | Get tasks blocked by a given task |
| `traverseDependencies()` | BFS traversal with depth and edge type filtering |
| `getOpenAtDepth(depth)` | Get tasks at specific hierarchy depth |

## Notes

**SQLite Comments Table:** The database schema includes a `task_comments` table for attaching comments to tasks. This is persisted but not yet exposed via tools.

**Wisp Behavior:** Wisps are not persisted to SQLite or JSONL, and cannot be updated after creation.

## Source Files

| File | Purpose |
|------|---------|
| `task_store.zig` | In-memory task state, dependency graph, ready queue |
| `task_db.zig` | SQLite persistence layer |
| `git_sync.zig` | JSONL export/import, SESSION_STATE.md, git integration |
| `tools/*.zig` | Individual tool implementations |
