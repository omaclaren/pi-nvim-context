# pi-nvim-context

Gather context in Neovim and append it to the input editor of a **standalone Pi session**. Nothing is submitted, no embedded terminal is opened, and neither application changes focus.

Repeated mappings accumulate visible, editable context in Pi. Switch to Pi when ready, write the question, and press Enter normally.

## What it sends

- current file reference
- current cursor location and in-memory line
- exact visual selection
- current Neovim diagnostics
- complete in-memory buffer, including unsaved edits

The Pi extension exposes a private Unix socket. The Neovim plugin discovers running sessions, chooses an exact working-directory match when unambiguous, and otherwise asks which Pi session to use.

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

Restart Pi after installing or changing the package. A reload is not enough when switching package sources.

### Neovim plugin

With Vim-Plug:

```vim
Plug '/absolute/path/to/pi-nvim-context'
```

Then configure it after `plug#end()`:

```lua
require("pi-nvim-context").setup()
```

## Default mappings

| Mapping | Action |
|---|---|
| `Space p p` | Select the standalone Pi session |
| `Space p f` | Add the current file |
| `Space p l` | Add the current file, cursor location, and current line |
| Visual `Space p s` | Add the exact selection and its file/range |
| `Space p d` | Add current-buffer diagnostics |
| `Space p b` | Add the complete in-memory buffer |
| `Space p i` | Show bridge status |

The mappings assume Space is already configured as `<leader>`.

Corresponding commands are:

```text
:PiContextPick
:PiContextFile
:PiContextLocation
:PiContextSelection
:PiContextDiagnostics
:PiContextBuffer
:PiContextStatus
```

## Session selection

On the first send:

1. If exactly one running Pi session has the same working directory as Neovim, it is selected automatically.
2. If only one Pi bridge exists in total, it is selected automatically.
3. Otherwise, Neovim shows a session picker.

The selection lasts for the current Neovim process. Use `Space p p` to change it. If Pi restarts, the next send discovers its replacement automatically.

## Configuration

```lua
require("pi-nvim-context").setup({
  notify = true,
  timeout_ms = 1500,
  max_payload_bytes = 240 * 1024,
  max_selection_bytes = 100 * 1024,
  max_buffer_bytes = 200 * 1024,
  max_diagnostics = 50,
  keymaps = {
    pick = "<leader>pp",
    file = "<leader>pf",
    location = "<leader>pl",
    selection = "<leader>ps",
    diagnostics = "<leader>pd",
    buffer = "<leader>pb",
    status = "<leader>pi",
  },
})
```

Set an individual mapping to `false`, or set `keymaps = false` and map the Lua functions yourself.

## Behavior and safety

- A context send calls Pi's `ctx.ui.pasteToEditor()`; it never calls `sendUserMessage()` and never starts an agent turn.
- Context is inserted at Pi's current input cursor. Normally that cursor is at the end of the draft.
- Large pastes use Pi's normal paste-collapse behavior.
- Socket directories are user-specific and mode `0700`; socket and manifest files are mode `0600`.
- The bridge starts only for interactive Pi TUI sessions.
- Payloads are bounded and truncated before transmission.
- Context is manual rather than continuously synchronized, so files are not exposed merely by visiting them in Neovim.

## Development

```sh
npm install
npm run typecheck
npm test
```

The tests cover the Pi socket lifecycle and prefill behavior, plus Neovim formatting, truncation, commands, and mappings.
