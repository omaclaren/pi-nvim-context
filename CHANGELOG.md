# Changelog

Notable changes to `pi-nvim-context` are recorded here.

## [0.3.1] - 2026-09-03

Documentation-only patch.

### Changed

- Document default mappings with `<leader>` notation instead of assuming Space.
- Clarify that the plugin does not set `mapleader`, whose Vim and Neovim default is backslash (`\`).
- Label Space as the optional leader used in the gallery preview.

## [0.3.0] - 2026-09-02

Initial public preview.

### Added

- Visible, unsubmitted accumulation of Neovim file, location, selection, diagnostic, and buffer context in a standalone Pi session.
- Explicit per-working-directory Pi links, including deliberate cross-directory selection and stale asynchronous-work protection.
- Direct cursor completions, instruction-guided insertions, and visual-selection rewrites using the linked Pi session's active model.
- Inline and scrollable previews, regeneration, cancellation, configuration-safe acceptance mappings, and one-step undo for accepted edits.
- Private same-host Unix-socket discovery with bounded payloads, ownership and permission checks, stale-process cleanup, and request cancellation.
- Neovim 0.11 and current-stable CI coverage on Linux and macOS.

[0.3.1]: https://github.com/omaclaren/pi-nvim-context/releases/tag/v0.3.1
[0.3.0]: https://github.com/omaclaren/pi-nvim-context/releases/tag/v0.3.0
