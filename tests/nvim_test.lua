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
  },
})
equal(vim.fn.exists(":PiContextPick"), 2, "setup registers commands")
equal(vim.fn.maparg("<F6>", "n") ~= "", true, "setup registers normal mappings")
equal(vim.fn.maparg("<F7>", "x") ~= "", true, "setup registers visual mappings")

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(temp, "rf")
print(string.format("pi-nvim-context: %d Neovim assertions passed", assertions))
