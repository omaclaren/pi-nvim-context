# pi-nvim-context

[![CI](https://github.com/omaclaren/pi-nvim-context/actions/workflows/ci.yml/badge.svg)](https://github.com/omaclaren/pi-nvim-context/actions/workflows/ci.yml)

Connect Neovim to a standalone [Pi coding agent](https://pi.dev) session for two deliberate workflows:

1. Gather visible, editable context in Pi's input without submitting it.
2. Ask the active Pi model for an explicit cursor completion, instruction-guided insertion, or selection rewrite without starting a Pi agent turn.

An inline completion model such as GitHub Copilot can keep owning automatic Insert-mode completion and `Tab`; Pi is invoked only through explicit mappings.

> **Status:** pre-1.0 preview. The core workflow is tested and in daily use, but configuration and protocol details may still change.

![A Neovim visual selection transferred into Pi's editable input](https://raw.githubusercontent.com/omaclaren/pi-nvim-context/main/assets/pi-nvim-context-preview.webp)

## Features

### Context gathering

Repeated mappings accumulate context in Pi's input editor. Switch to Pi when ready, write the question, and press Enter normally.

- current file reference
- current cursor location and in-memory line
- exact visual selection
- current Neovim diagnostics
- complete in-memory buffer, including unsaved edits

### Direct editor suggestions

- short completion at the cursor, shown as Neovim virtual text at the exact insertion boundary
- instruction-guided insertion at the cursor
- instruction-driven visual-selection rewrite
- wrapping full previews for multiline or wide insertions and rewrite diffs
- regenerate, inspect, accept, cancel, and dismiss actions
- exact `changedtick`, target-range, and original-text validation
- one undoable Neovim edit on acceptance
- no automatic save or buffer reload

The Pi extension exposes a private Unix socket. On first use for each Neovim working directory, the plugin asks you to confirm an exact-directory Pi link; a different-directory session is available only through the explicit picker.

## Requirements

- Pi 0.84.4 or newer
- Neovim 0.11 or newer
- macOS or Linux (Unix sockets)

## Installation

This repository contains both halves of the bridge. Install it once as a Pi package and once as a Neovim plugin; neither installation automatically supplies the other half.

### 1. Pi extension

Install the published Pi package from npm:

```sh
pi install npm:pi-nvim-context
```

Alternatively, install the current GitHub branch:

```sh
pi install git:github.com/omaclaren/pi-nvim-context
```

For development from a local checkout instead:

```sh
pi install /absolute/path/to/pi-nvim-context
```

Run `pi list` to verify the source, then fully restart Pi. `/reload` is not enough after installing, updating, or switching package sources.

### 2. Neovim plugin

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "omaclaren/pi-nvim-context",
  config = function()
    require("pi-nvim-context").setup()
  end,
}
```

With [Vim-Plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'omaclaren/pi-nvim-context'
```

Then configure it after `plug#end()`:

```vim
lua require("pi-nvim-context").setup()
```

For local development, give the plugin manager the absolute checkout path instead. Restart existing Neovim processes after installing or changing the plugin.

## First run

1. Start an interactive Pi TUI from the project directory.
2. Start Neovim with the same effective working directory; `:pwd` shows the value used for linking.
3. Run `:PiContextPick` (default: `Space p p`) and confirm the exact-cwd Pi session.
4. Run `:PiContextFile` (default: `Space p f`). The file reference should appear in Pi's editable input without being submitted.
5. With Pi idle, run `:PiSuggest` to try a direct completion, or continue adding context before writing your question in Pi.

Use `/nvim-context` in Pi and `:PiContextStatus` in Neovim to inspect both sides of the bridge.

## Default mappings

For a compact reference covering Pi context, direct edits, and optional Copilot and clipboard examples, see [CHEATSHEET.md](CHEATSHEET.md).

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
| `Space p g` | Enter an instruction and ask Pi to insert text at that position |
| Visual `Space p r` | Enter an instruction and ask Pi to rewrite the selection |
| Normal `Tab` | Accept while a Pi result is visible, when temporary Tab acceptance is enabled and available |
| `Space p a` | Accept the visible Pi completion, insertion, or rewrite |
| `Space p n` | Generate a materially different result |
| `Space p v` | Focus a full preview so it can be scrolled; `q` returns to the source |
| `Space p x` | Cancel or dismiss the Pi request/result |

Bare `Space p` is a harmless prefix mapping. If the sequence times out before a final key, Neovim no longer reinterprets it as native Normal-mode movement and paste commands.

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
:PiSuggestGuided
:PiRewrite
:PiSuggestAccept
:PiSuggestAgain
:PiSuggestDismiss
:PiSuggestPreview
```

## Inline completion coexistence (Copilot example)

No inline completion plugin is required. `pi-nvim-context` leaves Insert-mode `Tab` untouched, allowing a model-backed completion plugin such as GitHub Copilot to retain its normal acceptance mapping. While a Pi result is visible, the plugin temporarily installs a buffer-local **Normal-mode** `Tab` mapping when that feature is enabled and the source buffer does not already own one; accepting or dismissing the result removes it.

As an optional compatibility detail, direct Pi requests make a best-effort call to dismiss a visible `copilot.vim` suggestion, so the previews do not overlap. Nothing happens when `copilot.vim` is absent.

A practical division of labour is:

- **Inline completion model (for example, Copilot):** automatic, low-latency Insert-mode completion and `Tab` acceptance.
- **Pi completion:** explicit, short continuation with the active Pi model and thinking off.
- **Pi guided insertion:** explicit cursor insertion following the instruction you enter, with low thinking when supported.
- **Pi rewrite:** explicit selected-range edit following your instruction, with low thinking when supported.
- **Full Pi agent:** whole-file, multi-file, tool-using, or autonomous work.

## Direct-suggestion context and model use

Cursor completions send up to 12,000 characters before and 6,000 after the cursor. Guided insertions additionally send your instruction; rewrites send the exact selected text and your instruction. Prefix, selection, and suffix are sent as separate strings, avoiding UTF-8 byte versus JavaScript UTF-16 offset errors.

Guided insertions do not use tools or search external sources. If an instruction asks for references, supply the needed bibliographic details or use the full Pi agent to research and verify them.

Direct suggestions:

- use the explicitly linked standalone Pi session's active model and resolved authentication;
- run only while that Pi session is idle;
- do not use tools, submit a Pi turn, append to session history, or automatically inherit the full Pi conversation;
- do not include other project files unless their text is already inside the bounded editor excerpt;
- are discarded if the Neovim buffer changes while generation is running or while a result is visible.

An `openai-codex/...` active model uses subscription-backed authentication. An `openai/...` model uses API-billed OpenAI Platform authentication. Other providers use their configured credentials and billing; direct suggestions can therefore incur model-provider charges.

## Explicit Pi linking

Context and suggestion operations never silently fall back to a Pi session in another directory.

On the first operation for a Neovim working directory:

1. Neovim discovers bridge-enabled Pi sessions with an exact working-directory match.
2. It always asks you to confirm which matching session to link, even when there is only one.
3. If there is no exact match, it sends nothing and explains that Pi may need restarting in that directory.

Use `Space p p` to open the explicit picker at any time. This picker includes every discovered bridge, puts exact matches first, and labels different-directory sessions with a warning. Choosing one there is the deliberate cross-directory override.

Links are scoped per Neovim working directory. Changing directories switches to that directory's independent link and cancels any pending Pi editor suggestion; returning to a directory restores its remembered link. One directory's choice never overrides another's. `Space p i` shows the current Neovim directory, linked Pi name/cwd/PID, and the number of exact matches.

A Pi process that was already running when this package was installed or updated is invisible until it fully restarts and loads the bridge. Suggestion commands also filter out older bridges that do not advertise suggestion support.

## Updating and removing

Update an npm-installed Pi package with `pi update npm:pi-nvim-context`; for a Git-installed package, use `pi update --extensions`. Update the Neovim half through the same plugin manager used for installation—for example, `:Lazy update pi-nvim-context` or `:PlugUpdate pi-nvim-context`. Then fully restart both Pi and Neovim.

For a local checkout, pull the repository yourself and restart both processes. Remove the Pi half using the same source type used to install it:

```sh
pi remove npm:pi-nvim-context
# or
pi remove git:github.com/omaclaren/pi-nvim-context
```

Also remove the Neovim plugin specification and run the plugin manager's cleanup command.

## Troubleshooting

- **No bridge appears:** fully restart an interactive Pi TUI in the intended directory, then run `/nvim-context`. Print/RPC modes do not start the bridge.
- **No exact-cwd session appears:** compare Pi's reported cwd with Neovim's `:pwd`. Run `:PiContextPick` only if a cross-directory link is intentional.
- **A suggestion says Pi is busy:** wait for the current Pi agent turn to finish; direct suggestions run only while the linked session is idle.
- **Model requests fail:** check `:messages`, the active Pi model, its authentication, and its provider billing. Context gathering does not require a model call.
- **A result disappears:** changing the target buffer, text, or working directory invalidates stale work by design.
- **An update seems absent:** update both installed halves and fully restart both processes; do not rely on Pi's `/reload` after a package-source change.

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
  preview_width = 92,
  preview_height = 18,
  accept_with_tab = true,

  keymaps = {
    prefix = "<leader>p", -- harmless exact mapping protects an incomplete prefix
    pick = "<leader>pp",
    file = "<leader>pf",
    location = "<leader>pl",
    selection = "<leader>ps",
    diagnostics = "<leader>pd",
    buffer = "<leader>pb",
    status = "<leader>pi",
    suggest = "<leader>pc",
    guided = "<leader>pg",
    rewrite = "<leader>pr",
    accept = "<leader>pa",
    again = "<leader>pn",
    dismiss = "<leader>px",
    preview = "<leader>pv",
  },
})
```

Set an individual mapping to `false`, or set `keymaps = false` and map the Lua functions yourself. Set `accept_with_tab = false` to keep Normal-mode `Tab` untouched in both the source and preview buffers. If a source buffer already has its own buffer-local Normal `Tab` mapping, the plugin preserves it and `:PiSuggestAccept` remains available.

## Behavior and safety

- Context gathering calls Pi's `ctx.ui.pasteToEditor()` and never submits the draft.
- Direct suggestions call the model independently and never alter Pi's input editor.
- Context and suggestion traffic is sent only after an explicit mapping or command.
- Socket directories are user-specific and mode `0700`; socket and manifest files are mode `0600`.
- The bridge starts only for interactive Pi TUI sessions.
- Request, context, selection, and response sizes are bounded.
- Closing a request from Neovim aborts its in-flight model call.
- Accepting a result calls `nvim_buf_set_text()` once and never writes the file.
- Like any Pi extension or Neovim plugin, the installed code runs with your user account's permissions; review third-party code before installing it.

## Related work and inspirations

- [pi-nvim](https://github.com/carderne/pi-nvim)
- [pi-ide-context](https://github.com/Andy8647/pi-ide-context)
- [sidekick.nvim](https://github.com/folke/sidekick.nvim)

## Release history

See [CHANGELOG.md](CHANGELOG.md).

## Development

```sh
npm ci
npm run typecheck
npm test
npm pack --dry-run
```

Tests cover the private socket lifecycle, completion, guided-insertion and rewrite requests, Pi-input isolation, stale-session cleanup, Unicode-safe Neovim ranges, full previews, temporary acceptance mappings, formatting, truncation, commands, and mappings.
