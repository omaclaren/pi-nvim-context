# pi-nvim-context

Connect Neovim to a **standalone Pi session** for two deliberate workflows:

1. Gather visible, editable context in Pi's input without submitting it.
2. Ask the active Pi model for an explicit cursor completion or selection rewrite without starting a Pi agent turn.

Copilot can keep owning automatic Insert-mode completion and `Tab`; Pi is invoked only through explicit mappings.

## Features

### Context gathering

Repeated mappings accumulate context in Pi's input editor. Switch to Pi when ready, write the question, and press Enter normally.

- current file reference
- current cursor location and in-memory line
- exact visual selection
- current Neovim diagnostics
- complete in-memory buffer, including unsaved edits

### Direct editor suggestions

- short completion at the cursor, shown as Neovim virtual text
- instruction-driven visual-selection rewrite, shown as a non-focused diff
- regenerate, accept, cancel, and dismiss actions
- exact `changedtick`, target-range, and original-text validation
- one undoable Neovim edit on acceptance
- no automatic save or buffer reload

The Pi extension exposes a private Unix socket. On first use for each Neovim working directory, the plugin asks you to confirm an exact-directory Pi link; a different-directory session is available only through the explicit picker.

## Requirements

- Pi 0.84.4 or newer
- Neovim 0.11 or newer
- macOS or Linux (Unix sockets)

## Installation

This repository contains both halves of the bridge.

### Pi extension

```sh
pi install /absolute/path/to/pi-nvim-context
```

Fully restart Pi after installing or updating the package. `/reload` is not enough when switching package sources.

### Neovim plugin

With Vim-Plug:

```vim
Plug '/absolute/path/to/pi-nvim-context'
```

Then configure it after `plug#end()`:

```lua
require("pi-nvim-context").setup()
```

Restart existing Neovim processes after changing the plugin or mappings.

## Default mappings

For a compact one-page reference covering Pi context, direct edits, Copilot, and the system clipboard, see [CHEATSHEET.md](CHEATSHEET.md).

The mappings assume Space is already configured as `<leader>`.

### Context

| Mapping | Action |
|---|---|
| `Space p p` | Explicitly link the current Neovim cwd to a Pi session |
| `Space p f` | Add the current file |
| `Space p l` | Add the current file, cursor location, and current line |
| Visual `Space p s` | Add the exact selection and its file/range |
| `Space p d` | Add current-buffer diagnostics |
| `Space p b` | Add the complete in-memory buffer |
| `Space p i` | Show Neovim cwd, linked Pi, and bridge status |

### Suggestions and edits

| Mapping | Action |
|---|---|
| `Space p c` | Ask Pi for a completion after the Normal-mode cursor character |
| Visual `Space p r` | Enter an instruction and ask Pi to rewrite the selection |
| `Space p a` | Accept the visible Pi completion or rewrite |
| `Space p n` | Generate a materially different result |
| `Space p x` | Cancel or dismiss the Pi request/result |

Corresponding commands are:

```text
:PiContextPick
:PiContextFile
:PiContextLocation
:PiContextSelection
:PiContextDiagnostics
:PiContextBuffer
:PiContextStatus
:PiSuggest
:PiRewrite
:PiSuggestAccept
:PiSuggestAgain
:PiSuggestDismiss
```

## Copilot coexistence

`pi-nvim-context` does not map `Tab` or modify Copilot's acceptance mappings. When an explicit Pi request starts, it asks `copilot.vim` to dismiss any currently visible Copilot suggestion, so the previews do not overlap.

A practical division of labour is:

- **Copilot:** automatic, low-latency Insert-mode completion and `Tab` acceptance.
- **Pi completion:** explicit, short completion with the active Pi model and thinking off.
- **Pi rewrite:** explicit selected-range edit with the instruction you enter and low thinking when the model supports reasoning.
- **Full Pi agent:** whole-file, multi-file, tool-using, or autonomous work.

## Direct-suggestion context and model use

Cursor completions send up to 12,000 characters before and 6,000 after the cursor. Rewrites additionally send the exact selected text and your instruction. Prefix, selection, and suffix are sent as separate strings, avoiding UTF-8 byte versus JavaScript UTF-16 offset errors.

Direct suggestions:

- use the explicitly linked standalone Pi session's active model and resolved authentication;
- run only while that Pi session is idle;
- do not use tools, submit a Pi turn, append to session history, or automatically inherit the full Pi conversation;
- do not include other project files unless their text is already inside the bounded editor excerpt;
- are discarded if the Neovim buffer changes while generation is running or while a result is visible.

An `openai-codex/...` active model uses subscription-backed authentication. An `openai/...` model uses API-billed OpenAI Platform authentication.

## Explicit Pi linking

Context and suggestion operations never silently fall back to a Pi session in another directory.

On the first operation for a Neovim working directory:

1. Neovim discovers bridge-enabled Pi sessions with an exact working-directory match.
2. It always asks you to confirm which matching session to link, even when there is only one.
3. If there is no exact match, it sends nothing and explains that Pi may need restarting in that directory.

Use `Space p p` to open the explicit picker at any time. This picker includes every discovered bridge, puts exact matches first, and labels different-directory sessions with a warning. Choosing one there is the deliberate cross-directory override.

Links are scoped per Neovim working directory. Changing directories switches to that directory's independent link and cancels any pending Pi editor suggestion; returning to a directory restores its remembered link. One directory's choice never overrides another's. `Space p i` shows the current Neovim directory, linked Pi name/cwd/PID, and the number of exact matches.

A Pi process that was already running when this package was installed or updated is invisible until it fully restarts and loads the bridge. Suggestion commands also filter out older bridges that do not advertise suggestion support.

## Configuration

```lua
require("pi-nvim-context").setup({
  notify = true,
  timeout_ms = 1500,
  max_payload_bytes = 240 * 1024,
  max_selection_bytes = 100 * 1024,
  max_buffer_bytes = 200 * 1024,
  max_diagnostics = 50,

  suggest_timeout_ms = 70 * 1000,
  rewrite_timeout_ms = 130 * 1000,
  suggest_prefix_chars = 12 * 1000,
  suggest_suffix_chars = 6 * 1000,
  max_rewrite_bytes = 100 * 1024,
  max_preview_lines = 12,
  rewrite_preview_width = 92,
  rewrite_preview_height = 18,

  keymaps = {
    pick = "<leader>pp",
    file = "<leader>pf",
    location = "<leader>pl",
    selection = "<leader>ps",
    diagnostics = "<leader>pd",
    buffer = "<leader>pb",
    status = "<leader>pi",
    suggest = "<leader>pc",
    rewrite = "<leader>pr",
    accept = "<leader>pa",
    again = "<leader>pn",
    dismiss = "<leader>px",
  },
})
```

Set an individual mapping to `false`, or set `keymaps = false` and map the Lua functions yourself.

## Behavior and safety

- Context gathering calls Pi's `ctx.ui.pasteToEditor()` and never submits the draft.
- Direct suggestions call the model independently and never alter Pi's input editor.
- Context and suggestion traffic is sent only after an explicit mapping or command.
- Socket directories are user-specific and mode `0700`; socket and manifest files are mode `0600`.
- The bridge starts only for interactive Pi TUI sessions.
- Request, context, selection, and response sizes are bounded.
- Closing a request from Neovim aborts its in-flight model call.
- Accepting a result calls `nvim_buf_set_text()` once and never writes the file.

## Related work and inspirations

- [pi-nvim](https://github.com/carderne/pi-nvim)
- [pi-ide-context](https://github.com/Andy8647/pi-ide-context)
- [sidekick.nvim](https://github.com/folke/sidekick.nvim)

## Development

```sh
npm install
npm run typecheck
npm test
```

Tests cover the private socket lifecycle, direct completion and rewrite requests, Pi-input isolation, stale-session cleanup, Unicode-safe Neovim ranges, formatting, truncation, commands, and mappings.
