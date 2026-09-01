# Neovim + Pi cheat sheet (with an optional Copilot example)

`<leader>` is **Space**. Pi does not require Copilot or another inline completion plugin. This example leaves automatic Insert-mode completion to Copilot while Pi handles deliberate requests.

## Which tool should I use?

| Goal | Use |
|---|---|
| Ask Pi a question about editor content | Use `Space p f/l/s/d/b`, then write the question in Pi |
| Get a deliberate completion at one cursor position | `Space p c` |
| Insert something specific at the cursor | `Space p g`, then enter the instruction |
| Rewrite selected text according to an instruction | Visual `Space p r` |
| Accept a fast automatic completion while typing | Inline completion plugin (for example, Copilot): `Tab` |
| Whole-file, multi-file, or tool-using work | The normal persistent Pi chat/agent |

## Add context to the Pi chat draft

These mappings append visible, editable text to the explicitly linked standalone Pi session. They **do not submit** a turn.

| Mode | Mapping | Action |
|---|---|---|
| Normal | `Space p f` | Add the current file reference |
| Normal | `Space p l` | Add file, cursor location, and current in-memory line |
| Visual | `Space p s` | Add the exact selection and its file/range |
| Normal | `Space p d` | Add current-buffer diagnostics |
| Normal | `Space p b` | Add the complete in-memory buffer, including unsaved edits |
| Normal | `Space p p` | Explicitly link or change the target Pi session |
| Normal | `Space p i` | Show Neovim cwd, linked Pi cwd/PID, and bridge status |

Repeated additions accumulate in Pi's input. Switch to Pi, type the question after the gathered context, and press Enter normally.

On the first operation, Neovim always asks you to confirm an exact-cwd Pi link. It never silently falls back to another directory. If no exact bridge exists, restart Pi in that directory or use `Space p p` for a deliberate cross-directory link. Each Neovim cwd keeps an independent remembered link; switching cwd switches links and cancels any pending suggestion. Bare `Space p` is protected: if you pause until the mapping times out, it does nothing instead of becoming native movement plus paste.

## Direct Pi completions, insertions, and rewrites

These call the active model directly without changing Pi's chat draft or session history.

| Mode | Mapping | Action |
|---|---|---|
| Normal | `Space p c` | Request a completion **after** the cursor character |
| Normal | `Space p g` | Enter an instruction and request an insertion there |
| Visual | `Space p r` | Enter an instruction and request a selection rewrite |
| Normal | `Tab` | Accept while a Pi result is visible |
| Normal | `Space p a` | Alternative explicit accept mapping |
| Normal | `Space p n` | Generate a materially different result |
| Normal | `Space p v` | Focus the full preview; scroll normally and press `q` to return |
| Normal | `Space p x` | Cancel an active request or dismiss its result |

### Completion recipe

1. Leave Insert mode with `Esc`.
2. Put the cursor on the last character before the desired insertion.
3. Press `Space p c`.
4. Review the ghost text. Its highlighted first cell is the exact insertion boundary.
5. Press Normal `Tab` to accept, or use `Space p n` / `Space p x`.

### Guided-insertion recipe

1. Put the cursor on the last character before the desired insertion.
2. Press `Space p g`.
3. Enter an instruction such as `add references to Kuhn's book`.
4. Review the result. Multiline or wide results get a wrapping full preview.
5. Press Normal `Tab` to accept. Use `Space p v` first if you need to focus and scroll the preview.

This direct request cannot search for or verify references. Supply exact bibliographic details when accuracy matters, or use the normal Pi agent for research.

### Rewrite recipe

1. Select the exact text using normal Vim Visual mode.
2. Press `Space p r`.
3. Enter the rewrite instruction and press Enter.
4. Review the wrapping diff preview; use `Space p v` to focus and scroll it.
5. Press Normal `Tab` to accept, or use `Space p n` / `Space p x`.

After acceptance, `u` undoes the complete Pi edit in one step and `Ctrl-R` redoes it. Nothing is saved until `:write`.

## Optional inline completion example: Copilot

These mappings illustrate one complementary Copilot setup; `pi-nvim-context` does not install or require them.

| Mode | Mapping | Action |
|---|---|---|
| Insert | `Tab` | Accept the complete visible Copilot suggestion |
| Insert | `Ctrl-L` | Accept one Copilot word |
| Insert | `Ctrl-K` | Accept one Copilot line |
| Insert | `Option-\` | Explicitly request a Copilot suggestion |
| Normal | `Space c t` | Toggle Copilot globally |

When `copilot.vim` is installed, starting a direct Pi request makes a best-effort attempt to dismiss its visible ghost text. Insert-mode `Tab` remains available to the inline completion plugin. A visible Pi result temporarily gives **Normal-mode** `Tab` to Pi; the mapping disappears when the result is accepted or dismissed.

## System clipboard

Normal Vim yanks and deletes still use ordinary Vim registers.

| Mode | Mapping | Action |
|---|---|---|
| Normal | `Space y` followed by a motion | Yank that motion to the system clipboard |
| Normal | `Space y y` | Yank the current line to the system clipboard |
| Visual | `Space y` | Copy the selection to the system clipboard |

## Equivalent Neovim commands

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

In Pi itself:

```text
/nvim-context
```

This shows whether that Pi session's bridge is active.

## Important behavior

- Pi must be idle for a direct completion, guided insertion, or rewrite. Context gathering still only edits Pi's draft.
- Context and direct edits share the same explicit, cwd-scoped Pi link.
- Cursor completion sees up to 12,000 characters before and 6,000 after the cursor.
- A guided insertion additionally sees your instruction; a rewrite sees the selected text and your instruction.
- Direct requests do not use tools, the full Pi conversation, or other project files automatically.
- If the Neovim buffer or target changes while Pi is working, the result is cancelled or discarded.
- Leaving the source buffer dismisses its pending request or preview.
- Blockwise Visual rewrites are not supported; use characterwise or linewise selection.
- `openai-codex/...` uses subscription-backed authentication. `openai/...` uses API-billed authentication.

## Troubleshooting

1. Fully restart Pi with `pi --continue`; do not rely on `/reload` after updating the package.
2. Restart Neovim so it loads the latest Lua plugin.
3. In Pi, run `/nvim-context`.
4. In Neovim, run `:PiContextStatus` or press `Space p i`.
5. Press `Space p p` to inspect and explicitly choose among discovered Pi bridges.
6. Check `:messages` for bridge or model errors.
7. If using Copilot, check `:Copilot status` for Copilot problems.
