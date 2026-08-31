vim.opt.runtimepath:prepend(vim.fn.getcwd())

local context = require("pi-nvim-context")
local test = context._test
local assertions = 0

local function equal(actual, expected, message)
  assertions = assertions + 1
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function matches(value, pattern, message)
  assertions = assertions + 1
  if not tostring(value):match(pattern) then
    error(string.format("%s\npattern: %s\nvalue:   %s", message, pattern, tostring(value)))
  end
end

local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
local project = temp .. "/project"
vim.fn.mkdir(project, "p")

local original_runtime_override = vim.env.PI_NVIM_CONTEXT_RUNTIME_DIR
local security_directory = temp .. "/runtime"
vim.fn.mkdir(security_directory, "p")
vim.env.PI_NVIM_CONTEXT_RUNTIME_DIR = security_directory
assert((vim.uv or vim.loop).fs_chmod(security_directory, 0x1ed))
equal(test.runtime_directory_is_secure(), false, "world-accessible runtime directories are rejected")
assert((vim.uv or vim.loop).fs_chmod(security_directory, 0x1c0))
equal(test.runtime_directory_is_secure(), true, "private runtime directories are accepted")
local secure_target = temp .. "/runtime-target"
local runtime_link = temp .. "/runtime-link"
vim.fn.mkdir(secure_target, "p")
assert((vim.uv or vim.loop).fs_chmod(secure_target, 0x1c0))
assert((vim.uv or vim.loop).fs_symlink(secure_target, runtime_link))
vim.env.PI_NVIM_CONTEXT_RUNTIME_DIR = runtime_link
equal(test.runtime_directory_is_secure(), false, "symlinked runtime directories are rejected")
vim.env.PI_NVIM_CONTEXT_RUNTIME_DIR = original_runtime_override

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_name(bufnr, project .. "/notes.md")
vim.bo[bufnr].filetype = "markdown"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "# Notes",
  "The current line has useful context.",
  "A final line.",
})

vim.api.nvim_win_set_cursor(0, { 3, #"A final line." - 1 })
vim.cmd("normal! v2k0")
local backward_region = test.visual_region(bufnr)
equal(backward_region.start_line, 1, "backward visual selections normalize their start")
equal(backward_region.end_line, 3, "backward visual selections normalize their end")
matches(backward_region.text, "^# Notes", "backward visual selections retain their text")
vim.cmd("normal! \027")

local session = { cwd = project }
local file_context = test.format_file(bufnr, session)
matches(file_context, "Neovim file: `notes%.md`", "file context uses a target-relative path")
matches(file_context, "modified in Neovim", "file context identifies modified buffers")

vim.api.nvim_win_set_cursor(0, { 2, 4 })
local location = test.format_location(bufnr, session)
matches(location, "line 2, column 5", "location uses one-based rows and columns")
matches(location, "The current line has useful context", "location includes the in-memory line")

local selection = test.format_selection(bufnr, session, {
  text = "selected **Markdown**",
  start_line = 2,
  end_line = 2,
})
matches(selection, "line 2", "selection includes its line range")
matches(selection, "selected %*%*Markdown%*%*", "selection includes exact text")

local tricky_fence = test.fenced("before ``` after", "markdown")
matches(tricky_fence, "^````markdown", "fence expands around embedded backticks")
matches(tricky_fence, "\n````$", "expanded fence closes correctly")

local unicode_prefix, was_truncated = test.truncate_utf8("αβγδε", 5)
equal(was_truncated, true, "UTF-8 content reports truncation")
equal(unicode_prefix, "αβ", "UTF-8 truncation does not split a codepoint")

local diagnostics = test.format_diagnostics(bufnr, session, {
  { lnum = 4, col = 2, severity = vim.diagnostic.severity.WARN, message = "later warning", source = "ltex" },
  { lnum = 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = "first\nerror", source = "test", code = "E1" },
})
matches(diagnostics, "ERROR L2:C1 %[test/E1%]: first error", "diagnostics normalize and label messages")
local error_position = assert(diagnostics:find("ERROR", 1, true))
local warning_position = assert(diagnostics:find("WARN", 1, true))
equal(error_position < warning_position, true, "diagnostics are sorted by location")

local buffer_context = test.format_buffer(bufnr, session)
matches(buffer_context, "Neovim modified buffer", "buffer context describes its state")
matches(buffer_context, "# Notes", "buffer context includes in-memory contents")

context.setup({
  notify = false,
  keymaps = {
    pick = "<F6>",
    file = false,
    location = false,
    selection = "<F7>",
    diagnostics = false,
    buffer = false,
    status = false,
    suggest = "<F8>",
    rewrite = "<F9>",
    accept = false,
    again = false,
    dismiss = false,
  },
})
equal(vim.fn.exists(":PiContextPick"), 2, "setup registers commands")
equal(vim.fn.exists(":PiSuggest"), 2, "setup registers Pi suggestion commands")
equal(vim.fn.exists(":PiRewrite"), 2, "setup registers Pi rewrite commands")
equal(vim.fn.maparg("<F6>", "n") ~= "", true, "setup registers normal mappings")
equal(vim.fn.maparg("<F7>", "x") ~= "", true, "setup registers visual mappings")
equal(vim.fn.maparg("<F8>", "n") ~= "", true, "setup registers cursor-suggestion mappings")
equal(vim.fn.maparg("<F9>", "x") ~= "", true, "setup registers rewrite mappings")

local edit_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(edit_buf)
vim.api.nvim_buf_set_name(edit_buf, project .. "/edit.md")
vim.bo[edit_buf].filetype = "markdown"
vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, { "αβ", "second line", "third line" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local unicode_target = test.suggestion.capture_cursor_target(edit_buf)
equal(unicode_target.start_col, #"α", "normal-mode completion targets follow a multibyte cursor character")
local unicode_snapshot = test.suggestion.capture_snapshot(unicode_target, "completion")
equal(unicode_snapshot.prefix, "α", "completion snapshots preserve Unicode prefix boundaries")
equal(unicode_snapshot.suffix:sub(1, #"β"), "β", "completion snapshots preserve Unicode suffix boundaries")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! $v0")
local backward_edit_target = test.suggestion.capture_visual_target(edit_buf)
equal(backward_edit_target.original, "αβ", "backward characterwise rewrite targets are exact")
vim.cmd("normal! \027")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! Vj")
local line_target = test.suggestion.capture_visual_target(edit_buf)
equal(line_target.original, "αβ\nsecond line", "linewise rewrite targets capture exact selected text")
vim.cmd("normal! \027")
local applied = test.suggestion.replace_target(line_target, "replacement")
equal(type(applied), "table", "rewrite targets apply through one buffer edit")
equal(vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false), { "replacement", "third line" }, "rewrite replacement preserves text outside the target")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
local stale_target = test.suggestion.capture_cursor_target(edit_buf)
vim.api.nvim_buf_set_text(edit_buf, 0, 0, 0, 0, { "changed " })
equal(test.suggestion.target_is_current(stale_target), false, "changedtick validation rejects stale suggestions")
equal(test.suggestion.tail_characters("αβγ", 2), "βγ", "suggestion prefix trimming is Unicode safe")

local undolevels = vim.bo[edit_buf].undolevels
vim.bo[edit_buf].undolevels = -1
vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, { "Complete this" })
vim.bo[edit_buf].undolevels = undolevels
vim.api.nvim_win_set_cursor(0, { 1, #"Complete this" - 1 })
local suggest_module = require("pi-nvim-context.suggest")
local sent_requests = {}
local suggestion_config = {
  notify = false,
  suggest_timeout_ms = 1000,
  rewrite_timeout_ms = 1000,
  suggest_prefix_chars = 12000,
  suggest_suffix_chars = 6000,
  max_rewrite_bytes = 100 * 1024,
  max_preview_lines = 12,
  rewrite_preview_width = 80,
  rewrite_preview_height = 12,
}
suggest_module.configure({
  protocol = 1,
  get_config = function()
    return suggestion_config
  end,
  notify = function() end,
  choose_suggestion_session = function(callback)
    callback({ socketPath = "/tmp/mock.sock", cwd = project, sessionName = "Mock Pi" })
  end,
  invalidate_session = function() end,
  session_label = function()
    return "Mock Pi"
  end,
  socket_request = function(_, payload, callback)
    table.insert(sent_requests, payload)
    local response_text = #sent_requests == 1 and " now" or " instead"
    vim.schedule(function()
      callback(nil, {
        ok = true,
        type = "suggestion",
        requestId = payload.requestId,
        suggestion = response_text,
        modelLabel = "mock/model",
        thinking = "off",
      })
    end)
    return function() end
  end,
})
suggest_module.suggest()
equal(vim.wait(1000, function()
  return suggest_module._test.get_state().preview ~= nil
end, 10), true, "cursor suggestions reach preview state asynchronously")
equal(sent_requests[1].prefix, "Complete this", "cursor suggestion sends context through the cursor")
suggest_module.again()
equal(vim.wait(1000, function()
  local state = suggest_module._test.get_state()
  return #sent_requests == 2 and state.preview and state.preview.suggestion == " instead"
end, 10), true, "suggestion regeneration replaces the preview")
equal(sent_requests[2].previousSuggestion, " now", "regeneration sends the previous result")
suggest_module.accept()
equal(vim.api.nvim_get_current_line(), "Complete this instead", "accept applies the visible suggestion")
vim.cmd("undo")
equal(vim.api.nvim_get_current_line(), "Complete this", "an accepted suggestion is one undoable Neovim change")
vim.cmd("redo")
equal(vim.api.nvim_get_current_line(), "Complete this instead", "an accepted suggestion can be redone as one change")

local cancel_count = 0
suggest_module.configure({
  protocol = 1,
  get_config = function()
    return suggestion_config
  end,
  notify = function() end,
  choose_suggestion_session = function(callback)
    callback({ socketPath = "/tmp/mock.sock", cwd = project, sessionName = "Mock Pi" })
  end,
  invalidate_session = function() end,
  session_label = function()
    return "Mock Pi"
  end,
  socket_request = function()
    return function()
      cancel_count = cancel_count + 1
    end
  end,
})
vim.api.nvim_win_set_cursor(0, { 1, #vim.api.nvim_get_current_line() - 1 })
suggest_module.suggest()
suggest_module.dismiss()
equal(cancel_count, 1, "dismissing a pending suggestion closes and cancels its socket request")

vim.api.nvim_buf_delete(edit_buf, { force = true })
vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(temp, "rf")
print(string.format("pi-nvim-context: %d Neovim assertions passed", assertions))
