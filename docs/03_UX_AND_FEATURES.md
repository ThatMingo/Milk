# Milk — UX and Features

## Overall layout

Use a flexible native macOS coding-environment layout.

Conceptually:

```text
┌────────────────────────────────────────────────────────────────────┐
│ Native toolbar / workspace / session tabs / actions                │
├───────────────┬──────────────────────────────────┬─────────────────┤
│ Sidebar       │ Main area                        │ Inspector       │
│ Files         │ Chat / Editor / Preview          │ Changes / Git   │
│ Search        │                                  │ Preview / Info  │
│ Git           │                                  │                 │
│ Extensions    │                                  │                 │
├───────────────┴──────────────────────────────────┴─────────────────┤
│ Optional integrated terminal                                       │
├────────────────────────────────────────────────────────────────────┤
│ Pi/model/branch/permission/status                                  │
└────────────────────────────────────────────────────────────────────┘
```

Panels should be resizable/collapsible and their state should persist.

## Workspaces

- Open Folder
- recent workspaces
- persisted workspace access
- workspace-specific UI state
- workspace-specific sessions
- reveal in Finder
- remove from recent

## Session tabs

- new session
- independent context
- rename
- close
- reorder
- resume/reopen where Pi supports it
- restore useful metadata after relaunch
- running/idle/error state

## Chat

- native multiline prompt editor
- normal macOS editing
- copy/paste
- undo/redo
- drag/drop
- file references
- image references where supported
- Markdown
- code blocks
- streamed response
- tool-call cards
- command/output cards
- errors
- stop/abort
- retry/follow-up where Pi supports it

## Full editor

Required direction:

- syntax highlighting
- line numbers
- current-line highlight
- tabs/spaces settings
- configurable tab width
- auto-indent
- bracket matching/insertion
- indentation guides
- code folding architecture
- multiple selections/cursors
- find/replace
- regex search
- go to line
- quick open
- file tabs
- tab reordering
- unsaved indicators
- horizontal/vertical splits
- multiple files
- comment/uncomment
- duplicate/move line
- save/save all
- autosave option
- external-change detection
- conflict handling when Pi edits open files
- large-file awareness

## Language intelligence

Architecture should support LSP.

Desired when a language server exists:

- completion
- hover
- diagnostics
- go to definition
- references
- document symbols
- rename
- signature help
- code actions

Syntax highlighting should work independently of LSP.

## File browser

- native tree
- create file/folder
- rename
- delete
- duplicate
- drag/drop move
- reveal in Finder
- copy path
- relative path
- quick open/filter
- Git decorations
- filesystem observation

## Search

- filename search
- text search
- regex
- case sensitivity
- whole word
- include/exclude patterns
- grouped results
- line previews
- open result at exact location

## Changes / diffs

Show:

- modified
- added
- deleted
- renamed
- untracked
- staged/unstaged
- additions/deletions counts

Diff modes:

- unified
- side-by-side
- syntax highlighting
- line numbers

Actions:

- open
- stage
- unstage
- revert/discard
- copy diff

## Git

Core features:

- repo detection/init
- status
- branch display
- create/switch branch
- stage/unstage
- commit
- amend where appropriate
- fetch
- pull
- push
- history/log
- diff
- stash
- merge/conflict state
- remotes
- background refresh

## GitHub

Desired:

- auth status
- clone
- repo information
- branches
- pull requests
- create/view PR
- PR diff
- issues
- Actions/build status
- open resources in browser

Prefer existing authenticated `gh` session where practical.

## Terminal

Optional integrated terminal for manual commands.

Keep it separate from Pi's own programmatic process.

## Preview

Built-in preview:

- static HTML
- localhost URL
- Markdown
- images
- SVG
- PDF
- JSON
- text/code

Use native frameworks where practical.

## Settings

Eventually:

- General
- Pi
- Editor
- Agent/permissions
- Git
- GitHub
- Terminal
- Extensions
- Updates
- Advanced/diagnostics
