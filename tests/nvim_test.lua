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

local original_cwd = vim.fn.getcwd()
local exact_session = {
  cwd = original_cwd,
  sessionId = "exact-session",
  pid = 101,
  socketPath = "/tmp/exact-session.sock",
  capabilities = { "prefill", "suggest", "guided-insertion" },
}
local other_session = {
  cwd = project,
  sessionId = "other-session",
  pid = 202,
  socketPath = "/tmp/other-session.sock",
  capabilities = { "prefill" },
}
local automatic_candidates = test.candidate_sessions({ other_session, exact_session }, false)
equal(#automatic_candidates, 1, "automatic linking offers exact-cwd sessions only")
equal(automatic_candidates[1], exact_session, "automatic linking keeps the exact-cwd candidate")
equal(#test.candidate_sessions({ other_session }, false), 0, "automatic linking never falls back across directories")
equal(#test.candidate_sessions({ other_session, exact_session }, true), 2, "the explicit picker offers cross-directory sessions")
equal(#test.candidate_sessions({ other_session, exact_session }, true, "suggest"), 1, "capability filtering excludes outdated bridges")
equal(#test.candidate_sessions({ other_session, exact_session }, true, "guided-insertion"), 1, "guided insertion requires a current bridge")
matches(test.session_label(exact_session), "✓ exact cwd", "picker labels exact-cwd sessions")
matches(test.session_label(other_session), "⚠ different cwd", "picker warns about cross-directory sessions")
matches(test.session_label(other_session, project), "✓ exact cwd", "async labels stay relative to their captured cwd")
test.set_selected_session(exact_session, original_cwd)
equal(test.get_linked_session(), exact_session, "an explicit Pi link is available in its Neovim cwd")
local stale_generation = test.link_generation(original_cwd)
test.set_selected_session(exact_session, original_cwd)
local stale_linked, stale_reason = test.link_session(other_session, original_cwd, stale_generation)
equal(stale_linked, false, "an older same-cwd picker cannot overwrite a newer link choice")
equal(stale_reason, "superseded", "stale same-cwd pickers report why they were rejected")
equal(test.get_linked_session(), exact_session, "rejecting a stale picker preserves the newer cwd link")
vim.api.nvim_set_current_dir(project)
equal(test.get_linked_session(), nil, "a Pi link cannot leak into another Neovim cwd")
equal(test.link_session(exact_session, original_cwd), false, "a stale picker cannot link after Neovim changes cwd")
equal(test.get_linked_session(), nil, "a rejected stale picker leaves Neovim unlinked")
vim.api.nvim_set_current_dir(original_cwd)
equal(test.get_linked_session(), exact_session, "returning to a Neovim cwd restores its scoped Pi link")
test.set_selected_session(other_session, project)
vim.api.nvim_set_current_dir(project)
equal(test.get_linked_session(), other_session, "a second Neovim cwd keeps an independent Pi link")
vim.api.nvim_set_current_dir(original_cwd)
equal(test.get_linked_session(), exact_session, "linking a second cwd does not override the first cwd's link")
test.set_selected_session(exact_session, project)
test.invalidate_session(exact_session)
equal(test.get_linked_session(), nil, "a dead Pi socket is removed from the current cwd link")
vim.api.nvim_set_current_dir(project)
equal(test.get_linked_session(), nil, "a dead Pi socket is removed from every cwd link")
vim.api.nvim_set_current_dir(original_cwd)
test.set_selected_session(exact_session, original_cwd)
test.clear_link(project)

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
    prefix = "<F5>",
    pick = "<F6>",
    file = false,
    location = false,
    selection = "<F7>",
    diagnostics = false,
    buffer = false,
    status = false,
    suggest = "<F8>",
    rewrite = "<F9>",
    guided = "<F10>",
    preview = "<F11>",
    accept = false,
    again = false,
    dismiss = false,
  },
})
equal(vim.fn.exists(":PiContextPick"), 2, "setup registers commands")
equal(vim.fn.exists(":PiSuggest"), 2, "setup registers Pi suggestion commands")
equal(vim.fn.exists(":PiSuggestGuided"), 2, "setup registers guided-insertion commands")
equal(vim.fn.exists(":PiSuggestPreview"), 2, "setup registers full-preview commands")
equal(vim.fn.exists(":PiRewrite"), 2, "setup registers Pi rewrite commands")
equal(vim.fn.maparg("<F5>", "n"), "<Nop>", "setup protects an incomplete Pi mapping prefix")
equal(vim.fn.maparg("<F5>", "x"), "<Nop>", "visual-mode Pi prefixes are protected too")
equal(vim.fn.maparg("<F6>", "n") ~= "", true, "setup registers normal mappings")
equal(vim.fn.maparg("<F7>", "x") ~= "", true, "setup registers visual mappings")
equal(vim.fn.maparg("<F8>", "n") ~= "", true, "setup registers cursor-suggestion mappings")
equal(vim.fn.maparg("<F9>", "x") ~= "", true, "setup registers rewrite mappings")
equal(vim.fn.maparg("<F10>", "n") ~= "", true, "setup registers guided-insertion mappings")
equal(vim.fn.maparg("<F11>", "n") ~= "", true, "setup registers full-preview mappings")
test.set_selected_session(exact_session, original_cwd)
local original_notify = vim.notify
vim.notify = function() end
vim.api.nvim_set_current_dir(project)
equal(test.get_linked_session(), nil, "DirChanged activates the new working directory's independent link scope")
vim.api.nvim_set_current_dir(original_cwd)
equal(test.get_linked_session(), exact_session, "DirChanged restores a remembered link when returning to its cwd")
vim.notify = original_notify

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
local test_scope_epoch = 0
local suggestion_config = {
  notify = false,
  suggest_timeout_ms = 1000,
  rewrite_timeout_ms = 1000,
  suggest_prefix_chars = 12000,
  suggest_suffix_chars = 6000,
  max_rewrite_bytes = 100 * 1024,
  preview_width = 80,
  preview_height = 12,
  accept_with_tab = true,
}
suggest_module.configure({
  protocol = 1,
  get_config = function()
    return suggestion_config
  end,
  current_scope_cwd = function()
    return vim.fn.getcwd()
  end,
  current_scope_epoch = function()
    return test_scope_epoch
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
    local response_text
    if payload.kind == "insertion" then
      response_text = " with a reference to the book.\nA second sentence explains why it matters."
    elseif payload.prefix:match("Wide preview$") then
      response_text = string.rep("long suggestion text ", 20)
    else
      response_text = #sent_requests == 1 and " now" or " instead"
    end
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
local short_ui = suggest_module._test.get_ui_state()
equal(short_ui.preview_win, nil, "short one-line suggestions remain inline at the insertion target")
local short_marks = vim.api.nvim_buf_get_extmarks(edit_buf, short_ui.namespace, 0, -1, { details = true })
equal(#short_marks, 1, "an inline suggestion uses one insertion extmark")
equal({ short_marks[1][2], short_marks[1][3] }, { 0, #"Complete this" }, "the ghost text starts at the accepted insertion byte")
local short_virtual_text = short_marks[1][4].virt_text
equal(short_virtual_text[1][2], "PiNvimContextInsertionPoint", "the first inserted cell marks the exact boundary")
equal(short_virtual_text[1][1] .. short_virtual_text[2][1], " now", "inline controls do not obscure the suggested text")
local tab_mapping = vim.fn.maparg("<Tab>", "n", false, true)
equal(tab_mapping.buffer, 1, "a visible Pi result temporarily installs a buffer-local Normal Tab mapping")
equal(tab_mapping.desc, "Accept visible Pi editor suggestion", "the temporary Tab mapping is identifiable")
equal(sent_requests[1].prefix, "Complete this", "cursor suggestion sends context through the cursor")
suggest_module.again()
equal(vim.wait(1000, function()
  local state = suggest_module._test.get_state()
  return #sent_requests == 2 and state.preview and state.preview.suggestion == " instead"
end, 10), true, "suggestion regeneration replaces the preview")
equal(sent_requests[2].previousSuggestion, " now", "regeneration sends the previous result")
suggest_module.accept()
equal(vim.api.nvim_get_current_line(), "Complete this instead", "accept applies the visible suggestion")
equal(vim.fn.maparg("<Tab>", "n"), "", "accepting a Pi result restores normal Tab behavior")
vim.cmd("undo")
equal(vim.api.nvim_get_current_line(), "Complete this", "an accepted suggestion is one undoable Neovim change")
vim.cmd("redo")
equal(vim.api.nvim_get_current_line(), "Complete this instead", "an accepted suggestion can be redone as one change")

local guided_input_callback
local guided_original_ui_input = vim.ui.input
vim.ui.input = function(options, callback)
  equal(options.prompt, "Pi insertion instruction: ", "guided insertion uses a dedicated instruction prompt")
  guided_input_callback = callback
end
vim.api.nvim_win_set_cursor(0, { 1, #vim.api.nvim_get_current_line() - 1 })
local guided_source_win = vim.api.nvim_get_current_win()
suggest_module.suggest_guided()
guided_input_callback("add references to the book")
equal(vim.wait(1000, function()
  local state = suggest_module._test.get_state()
  return #sent_requests == 3 and state.preview and state.preview.base.kind == "insertion"
end, 10), true, "guided insertions reach preview state asynchronously")
equal(sent_requests[3].kind, "insertion", "guided insertion uses its distinct request kind")
equal(sent_requests[3].instruction, "add references to the book", "guided insertion sends the entered instruction")
local guided_ui = suggest_module._test.get_ui_state()
equal(vim.api.nvim_win_is_valid(guided_ui.preview_win), true, "multiline insertions get a full preview window")
equal(vim.wo[guided_ui.preview_win].wrap, true, "full suggestion previews wrap long lines")
equal(vim.api.nvim_win_get_config(guided_ui.preview_win).focusable, false, "the preview does not steal focus when it opens")
equal(vim.api.nvim_buf_get_lines(guided_ui.preview_buf, 0, -1, false), {
  " with a reference to the book.",
  "A second sentence explains why it matters.",
}, "the full preview retains every suggestion line")
suggest_module.focus_preview()
equal(vim.api.nvim_get_current_buf(), guided_ui.preview_buf, "the full preview can be focused explicitly for scrolling")
vim.api.nvim_set_current_win(guided_source_win)
equal(suggest_module._test.get_state().preview ~= nil, true, "returning from the full preview keeps the suggestion active")
suggest_module.accept()
equal(vim.api.nvim_buf_get_lines(edit_buf, 0, 2, false), {
  "Complete this instead with a reference to the book.",
  "A second sentence explains why it matters.",
}, "accepting a guided insertion applies its complete multiline result")
vim.cmd("undo")
equal(vim.api.nvim_get_current_line(), "Complete this instead", "a guided insertion is one undoable edit")
vim.ui.input = guided_original_ui_input

vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, { "Wide preview" })
vim.api.nvim_win_set_cursor(0, { 1, #"Wide preview" - 1 })
suggest_module.suggest()
equal(vim.wait(1000, function()
  local state = suggest_module._test.get_state()
  return #sent_requests == 4 and state.preview ~= nil
end, 10), true, "wide single-line suggestions reach preview state")
local wide_ui = suggest_module._test.get_ui_state()
equal(vim.api.nvim_win_is_valid(wide_ui.preview_win), true, "wide single-line suggestions use a wrapping full preview")
equal(vim.api.nvim_buf_get_lines(wide_ui.preview_buf, 0, -1, false)[1], string.rep("long suggestion text ", 20), "wide previews retain unclipped text")
suggest_module.dismiss()

vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, { "Existing Tab" })
vim.api.nvim_win_set_cursor(0, { 1, #"Existing Tab" - 1 })
vim.keymap.set("n", "<Tab>", "<Nop>", { buffer = edit_buf, desc = "Existing buffer Tab" })
suggest_module.suggest()
equal(vim.wait(1000, function()
  return #sent_requests == 5 and suggest_module._test.get_state().preview ~= nil
end, 10), true, "suggestions still render when the source buffer owns Normal Tab")
local existing_tab = vim.fn.maparg("<Tab>", "n", false, true)
equal(existing_tab.desc, "Existing buffer Tab", "Pi preserves an existing buffer-local Normal Tab mapping")
suggest_module.dismiss()
equal(vim.fn.maparg("<Tab>", "n", false, true).desc, "Existing buffer Tab", "dismissing Pi leaves the existing Tab mapping intact")
vim.keymap.del("n", "<Tab>", { buffer = edit_buf })

suggestion_config.accept_with_tab = false
vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, { "Wide preview" })
vim.api.nvim_win_set_cursor(0, { 1, #"Wide preview" - 1 })
suggest_module.suggest()
equal(vim.wait(1000, function()
  return #sent_requests == 6 and suggest_module._test.get_state().preview ~= nil
end, 10), true, "suggestions render when Tab acceptance is disabled")
local no_tab_ui = suggest_module._test.get_ui_state()
equal(vim.fn.maparg("<Tab>", "n"), "", "disabling Tab acceptance leaves the source mapping untouched")
local preview_tab = vim.api.nvim_buf_call(no_tab_ui.preview_buf, function()
  return vim.fn.maparg("<Tab>", "n")
end)
equal(preview_tab, "", "disabling Tab acceptance also leaves the preview-buffer mapping untouched")
suggest_module.dismiss()
suggestion_config.accept_with_tab = true

local rewrite_input_callback
local original_ui_input = vim.ui.input
local original_rewrite_notify = vim.notify
vim.ui.input = function(_, callback)
  rewrite_input_callback = callback
end
vim.notify = function() end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! v$")
local request_count_before_rewrite = #sent_requests
suggest_module.rewrite()
vim.api.nvim_set_current_dir(project)
vim.api.nvim_set_current_dir(original_cwd)
test_scope_epoch = test_scope_epoch + 1
rewrite_input_callback("tighten")
equal(#sent_requests, request_count_before_rewrite, "a rewrite prompt cannot survive a cwd switch away and back")
vim.cmd("normal! \027")
vim.ui.input = original_ui_input
vim.notify = original_rewrite_notify

local cancel_count = 0
suggest_module.configure({
  protocol = 1,
  get_config = function()
    return suggestion_config
  end,
  current_scope_cwd = function()
    return vim.fn.getcwd()
  end,
  current_scope_epoch = function()
    return test_scope_epoch
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
