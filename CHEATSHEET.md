# Neovim + Pi + Copilot cheat sheet

`<leader>` is **Space**. Pi mappings work in Neovim; Copilot remains responsible for automatic Insert-mode completion.

## Which tool should I use?

| Goal | Use |
|---|---|
| Ask Pi a question about editor content | Add context with `Space p …`, then write the question in Pi |
| Get a deliberate completion at one cursor position | `Space p c` |
| Rewrite selected text according to an instruction | Visual `Space p r` |
| Accept a fast automatic completion while typing | Copilot `Tab` |
| Whole-file, multi-file, or tool-using work | The normal persistent Pi chat/agent |

## Add context to the Pi chat draft

These mappings append visible, editable text to the selected standalone Pi session. They **do not submit** a turn.

| Mode | Mapping | Action |
|---|---|---|
| Normal | `Space p f` | Add the current file reference |
| Normal | `Space p l` | Add file, cursor location, and current in-memory line |
| Visual | `Space p s` | Add the exact selection and its file/range |
| Normal | `Space p d` | Add current-buffer diagnostics |
| Normal | `Space p b` | Add the complete in-memory buffer, including unsaved edits |
| Normal | `Space p p` | Select or change the target Pi session |
| Normal | `Space p i` | Show bridge and selected-session status |

Repeated additions accumulate in Pi's input. Switch to Pi, type the question after the gathered context, and press Enter normally.

## Direct Pi completions and rewrites

These call the active model directly without changing Pi's chat draft or session history.

| Mode | Mapping | Action |
|---|---|---|
| Normal | `Space p c` | Request a completion **after** the cursor character |
| Visual | `Space p r` | Enter an instruction and request a selection rewrite |
| Normal | `Space p a` | Accept the visible Pi completion or rewrite |
| Normal | `Space p n` | Generate a materially different result |
| Normal | `Space p x` | Cancel an active request or dismiss its result |

### Completion recipe

1. Leave Insert mode with `Esc`.
2. Put the cursor on the last character before the desired insertion.
3. Press `Space p c`.
4. Review the ghost text.
5. Press `Space p a`, `Space p n`, or `Space p x`.

### Rewrite recipe

1. Select the exact text using normal Vim Visual mode.
2. Press `Space p r`.
3. Enter the rewrite instruction and press Enter.
4. Review the diff preview.
5. Press `Space p a`, `Space p n`, or `Space p x`.

After acceptance, `u` undoes the complete Pi edit in one step and `Ctrl-R` redoes it. Nothing is saved until `:write`.

## Copilot

| Mode | Mapping | Action |
|---|---|---|
| Insert | `Tab` | Accept the complete visible Copilot suggestion |
| Insert | `Ctrl-L` | Accept one Copilot word |
| Insert | `Ctrl-K` | Accept one Copilot line |
| Insert | `Option-\` | Explicitly request a Copilot suggestion |
| Normal | `Space c t` | Toggle Copilot globally |

Starting a direct Pi request dismisses the currently visible Copilot ghost text. `Tab` remains Copilot-only; it never accepts a Pi result.

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
:PiRewrite
:PiSuggestAccept
:PiSuggestAgain
:PiSuggestDismiss
```

In Pi itself:

```text
/nvim-context
```

This shows whether that Pi session's bridge is active.

## Important behavior

- Pi must be idle for a direct completion or rewrite. Context gathering still only edits Pi's draft.
- Cursor completion sees up to 12,000 characters before and 6,000 after the cursor.
- A rewrite additionally sees the selected text and your instruction.
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
5. If several Pi sessions are running, press `Space p p` and choose one.
6. Check `:messages` for bridge or model errors.
7. Check `:Copilot status` for Copilot problems.
