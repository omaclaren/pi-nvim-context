local S = {}

local uv = vim.uv or vim.loop
local namespace = vim.api.nvim_create_namespace("pi-nvim-context-suggestion")
local env = nil
local pending = nil
local preview = nil
local preview_win = nil
local preview_buf = nil
local serial = 0

local function cfg()
  return env.get_config()
end

local function notify(message, level, always)
  if always or cfg().notify then
    env.notify(message, level)
  end
end

local function current_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  if vim.bo[bufnr].buftype ~= "" then
    notify("The current buffer is not a normal file buffer", vim.log.levels.WARN, true)
    return nil
  end
  return bufnr
end

local function buffer_available(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

local function utf8_character_bytes(text, byte_column)
  local first = text:byte(byte_column + 1)
  if not first then
    return 0
  end
  if first < 0x80 then
    return 1
  elseif first >= 0xC2 and first < 0xE0 then
    return 2
  elseif first >= 0xE0 and first < 0xF0 then
    return 3
  elseif first >= 0xF0 and first <= 0xF4 then
    return 4
  end
  return 1
end

local function position_after(a, b)
  return a[2] > b[2]
    or (a[2] == b[2] and a[3] > b[3])
    or (a[2] == b[2] and a[3] == b[3] and a[4] > b[4])
end

local function get_target_text(target)
  if not buffer_available(target.bufnr) then
    return nil
  end
  local ok, lines = pcall(
    vim.api.nvim_buf_get_text,
    target.bufnr,
    target.start_row,
    target.start_col,
    target.end_row,
    target.end_col,
    {}
  )
  if not ok then
    return nil
  end
  return table.concat(lines, "\n")
end

local function capture_cursor_target(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = math.max(cursor[1], 1)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local col = math.max(0, math.min(cursor[2], #line))
  local mode = vim.fn.mode(1)
  if mode:sub(1, 1) ~= "i" and mode:sub(1, 1) ~= "R" and col < #line then
    col = math.min(#line, col + utf8_character_bytes(line, col))
  end
  return {
    bufnr = bufnr,
    cursor_row = row - 1,
    cursor_col = cursor[2],
    start_row = row - 1,
    start_col = col,
    end_row = row - 1,
    end_col = col,
    original = "",
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
  }
end

local function capture_visual_target(bufnr)
  local mode = vim.fn.mode(1)
  local start_pos, end_pos
  if mode == "v" or mode == "V" or mode == "\22" then
    start_pos = vim.fn.getpos("v")
    end_pos = vim.fn.getpos(".")
  else
    mode = vim.fn.visualmode()
    start_pos = vim.fn.getpos("'<")
    end_pos = vim.fn.getpos("'>")
  end
  if mode == "\22" then
    return nil, "Blockwise Pi rewrites are not supported yet"
  end
  if mode ~= "v" and mode ~= "V" then
    return nil, "No characterwise or linewise visual selection found"
  end
  if not start_pos or not end_pos or start_pos[2] == 0 or end_pos[2] == 0 then
    return nil, "No visual selection found"
  end
  if position_after(start_pos, end_pos) then
    start_pos, end_pos = end_pos, start_pos
  end

  local ok, region_lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = mode })
  if not ok or type(region_lines) ~= "table" or #region_lines == 0 then
    return nil, "Could not read the visual selection"
  end

  local start_row = start_pos[2] - 1
  local start_col
  local end_row
  local end_col
  if mode == "V" then
    start_col = 0
    end_row = end_pos[2] - 1
    local last_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
    end_col = #last_line
  else
    start_col = math.max(start_pos[3] - 1, 0)
    if #region_lines == 1 then
      end_row = start_row
      end_col = start_col + #region_lines[1]
    else
      end_row = start_row + #region_lines - 1
      end_col = #region_lines[#region_lines]
    end
  end

  local target = {
    bufnr = bufnr,
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    linewise = mode == "V",
  }
  target.original = get_target_text(target)
  if target.original == nil or target.original ~= table.concat(region_lines, "\n") then
    return nil, "The visual selection cannot be represented as one contiguous edit"
  end
  return target
end

local function absolute_offset(lines, row, col)
  local offset = 0
  for index = 1, row do
    offset = offset + #lines[index] + 1
  end
  return offset + col
end

local function head_characters(text, count)
  local chars = vim.fn.strchars(text)
  if chars <= count then
    return text
  end
  return vim.fn.strcharpart(text, 0, count)
end

local function tail_characters(text, count)
  local chars = vim.fn.strchars(text)
  if chars <= count then
    return text
  end
  return vim.fn.strcharpart(text, chars - count, count)
end

local function capture_snapshot(target, kind, instruction)
  if not buffer_available(target.bufnr) then
    return nil, "The source buffer is no longer available"
  end
  local lines = vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false)
  if #lines == 0 then
    lines = { "" }
  end
  local full_text = table.concat(lines, "\n")
  local start_offset = absolute_offset(lines, target.start_row, target.start_col)
  local end_offset = absolute_offset(lines, target.end_row, target.end_col)
  local original = full_text:sub(start_offset + 1, end_offset)
  if original ~= target.original then
    return nil, "The target text changed before the request was prepared"
  end
  if kind == "rewrite" and #original > cfg().max_rewrite_bytes then
    return nil, string.format("The selected rewrite range exceeds %d bytes", cfg().max_rewrite_bytes)
  end
  return {
    kind = kind,
    target = target,
    bufnr = target.bufnr,
    prefix = tail_characters(full_text:sub(1, start_offset), cfg().suggest_prefix_chars),
    selection = original,
    suffix = head_characters(full_text:sub(end_offset + 1), cfg().suggest_suffix_chars),
    instruction = instruction,
    language = vim.bo[target.bufnr].filetype or "",
    absolute_path = vim.api.nvim_buf_get_name(target.bufnr),
  }
end

local function target_is_current(target)
  return buffer_available(target.bufnr)
    and vim.api.nvim_buf_get_changedtick(target.bufnr) == target.changedtick
    and get_target_text(target) == target.original
end

local function canonical_path(path)
  return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ":p")))
end

local function request_path(base, session)
  if base.absolute_path == "" then
    return "[No Name]"
  end
  local absolute = canonical_path(base.absolute_path)
  if session and type(session.cwd) == "string" and vim.fs.relpath then
    local relative = vim.fs.relpath(canonical_path(session.cwd), absolute)
    if relative and relative ~= "" and relative ~= ".." and not relative:match("^%.%.[/\\]") then
      return relative
    end
  end
  return absolute
end

local function close_preview_window()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    pcall(vim.api.nvim_win_close, preview_win, true)
  end
  if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
    pcall(vim.api.nvim_buf_delete, preview_buf, { force = true })
  end
  preview_win = nil
  preview_buf = nil
end

local function clear_preview_ui(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
  end
  close_preview_window()
end

local function render_completion(state)
  local target = state.base.target
  local lines = vim.split(state.suggestion, "\n", { plain = true, trimempty = false })
  if #lines == 0 then
    lines = { state.suggestion }
  end
  local shown = math.min(#lines, cfg().max_preview_lines)
  local virtual_lines = {}
  for index = 2, shown do
    table.insert(virtual_lines, { { lines[index], "Comment" } })
  end
  if #lines > shown then
    table.insert(virtual_lines, { { string.format("… %d more Pi suggestion lines", #lines - shown), "DiagnosticHint" } })
  end
  vim.api.nvim_buf_set_extmark(target.bufnr, namespace, target.start_row, target.start_col, {
    virt_text = {
      { lines[1] or "", "Comment" },
      { "  [Pi · <leader>pa accept · <leader>pn another · <leader>px dismiss]", "DiagnosticHint" },
    },
    virt_text_pos = "inline",
    virt_lines = virtual_lines,
    right_gravity = false,
  })
end

local function rewrite_diff(original, suggestion)
  local ok, diff = pcall(vim.diff, original, suggestion, {
    result_type = "unified",
    algorithm = "histogram",
    ctxlen = 3,
  })
  if ok and type(diff) == "string" and diff ~= "" then
    return diff
  end
  return "--- selected text\n+++ Pi replacement\n@@\n-" .. original:gsub("\n", "\n-") .. "\n+" .. suggestion:gsub("\n", "\n+")
end

local function render_rewrite(state)
  local target = state.base.target
  vim.api.nvim_buf_set_extmark(target.bufnr, namespace, target.start_row, target.start_col, {
    end_row = target.end_row,
    end_col = target.end_col,
    hl_group = "DiffChange",
    hl_eol = target.linewise == true,
    right_gravity = false,
    end_right_gravity = true,
  })

  preview_buf = vim.api.nvim_create_buf(false, true)
  local diff_lines = vim.split(rewrite_diff(target.original, state.suggestion), "\n", {
    plain = true,
    trimempty = false,
  })
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, diff_lines)
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].swapfile = false
  vim.bo[preview_buf].filetype = "diff"
  vim.bo[preview_buf].modifiable = false

  local width = math.max(30, math.min(cfg().rewrite_preview_width, vim.o.columns - 4))
  local height = math.max(4, math.min(cfg().rewrite_preview_height, #diff_lines, vim.o.lines - 6))
  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(1, math.floor((vim.o.columns - width) / 2))
  local title = string.format(" Pi rewrite · %s · <leader>pa accept · <leader>px dismiss ", state.model_label)
  local ok, win = pcall(vim.api.nvim_open_win, preview_buf, false, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    width = width,
    height = height,
    row = row,
    col = col,
    focusable = false,
    noautocmd = true,
  })
  if ok then
    preview_win = win
    vim.wo[preview_win].wrap = false
    vim.wo[preview_win].cursorline = false
  else
    pcall(vim.api.nvim_buf_delete, preview_buf, { force = true })
    preview_buf = nil
  end
end

local function dismiss_copilot()
  pcall(function()
    vim.fn["copilot#Dismiss"]()
  end)
end

local function render_preview(state)
  clear_preview_ui(state.base.bufnr)
  dismiss_copilot()
  if state.base.kind == "rewrite" then
    render_rewrite(state)
  else
    render_completion(state)
  end
  notify(string.format(
    "Pi %s ready (%s, thinking %s). Use <leader>pa to accept, <leader>pn for another, or <leader>px to dismiss.",
    state.base.kind == "rewrite" and "rewrite" or "completion",
    state.model_label,
    state.thinking
  ))
end

local function replace_target(target, suggestion)
  if not target_is_current(target) then
    return nil, "The buffer changed; the Pi suggestion is stale"
  end
  local replacement = vim.split(suggestion, "\n", { plain = true, trimempty = false })
  if #replacement == 0 then
    replacement = { "" }
  end
  local ok, error_message = pcall(
    vim.api.nvim_buf_set_text,
    target.bufnr,
    target.start_row,
    target.start_col,
    target.end_row,
    target.end_col,
    replacement
  )
  if not ok then
    return nil, tostring(error_message)
  end
  local end_row = target.start_row + #replacement - 1
  local end_col = #replacement == 1 and target.start_col + #replacement[1] or #replacement[#replacement]
  local winid = vim.fn.bufwinid(target.bufnr)
  if winid and winid >= 0 and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_set_cursor, winid, { end_row + 1, end_col })
  end
  return { row = end_row, col = end_col }
end

local function invalidate_and_clear(silent)
  serial = serial + 1
  local had_state = pending ~= nil or preview ~= nil
  local bufnr = preview and preview.base.bufnr or (pending and pending.base.bufnr)
  local cancel = pending and pending.cancel
  pending = nil
  preview = nil
  clear_preview_ui(bufnr)
  if cancel then
    cancel()
  end
  if had_state and not silent then
    notify("Pi editor suggestion dismissed")
  end
end

function S.dismiss()
  invalidate_and_clear(false)
end

function S.reset()
  invalidate_and_clear(true)
end

local function transport_can_retry(err)
  return type(err) == "string"
    and (err:match("^Could not connect to Pi") or err:match("closed the connection without a response"))
end

local function send_base(base, previous_suggestion, request_serial, retried)
  if request_serial ~= serial then
    return
  end
  if not target_is_current(base.target) then
    pending = nil
    notify("The buffer changed before Pi could generate the edit", vim.log.levels.WARN, true)
    return
  end

  env.choose_suggestion_session(function(session)
    if request_serial ~= serial then
      return
    end
    if not session then
      pending = nil
      return
    end
    if not target_is_current(base.target) then
      pending = nil
      notify("The buffer changed before Pi could generate the edit", vim.log.levels.WARN, true)
      return
    end

    local path = request_path(base, session)
    local request_id = string.format("%x-%d", uv.hrtime(), request_serial)
    local payload = {
      protocol = env.protocol,
      type = "suggest",
      requestId = request_id,
      kind = base.kind,
      prefix = base.prefix,
      selection = base.selection,
      suffix = base.suffix,
      instruction = base.instruction,
      language = base.language,
      label = path,
      path = base.absolute_path ~= "" and base.absolute_path or nil,
      previousSuggestion = previous_suggestion,
    }
    local timeout = base.kind == "rewrite" and cfg().rewrite_timeout_ms or cfg().suggest_timeout_ms
    notify(string.format("Generating Pi %s with %s…", base.kind == "rewrite" and "rewrite" or "completion", env.session_label(session)))

    pending.session = session
    pending.cancel = nil
    local cancel = env.socket_request(session.socketPath, payload, function(err, response)
      if request_serial ~= serial or not pending or pending.serial ~= request_serial then
        return
      end
      pending.cancel = nil
      if err then
        if not retried and transport_can_retry(err) then
          env.invalidate_session(session)
          send_base(base, previous_suggestion, request_serial, true)
          return
        end
        pending = nil
        notify("Pi editor suggestion failed: " .. tostring(err), vim.log.levels.ERROR, true)
        return
      end
      if not response or not response.ok then
        pending = nil
        notify(
          "Pi editor suggestion failed: " .. tostring(response and response.error or "unknown error"),
          vim.log.levels.ERROR,
          true
        )
        return
      end
      if response.requestId and response.requestId ~= request_id then
        pending = nil
        notify("Pi returned a mismatched suggestion response", vim.log.levels.ERROR, true)
        return
      end
      if not target_is_current(base.target) then
        pending = nil
        notify("The buffer changed while Pi was generating; the result was discarded", vim.log.levels.WARN, true)
        return
      end
      if type(response.suggestion) ~= "string" or response.suggestion:match("^%s*$") then
        pending = nil
        notify("Pi returned an empty editor suggestion", vim.log.levels.WARN, true)
        return
      end
      pending = nil
      preview = {
        base = base,
        suggestion = response.suggestion,
        model_label = type(response.modelLabel) == "string" and response.modelLabel or "Pi model",
        thinking = response.thinking == "low" and "low" or "off",
      }
      render_preview(preview)
    end, timeout)
    if request_serial == serial and pending and pending.serial == request_serial then
      pending.cancel = cancel
      pending.session = session
    end
  end)
end

local function begin_request(base, previous_suggestion)
  invalidate_and_clear(true)
  local request_serial = serial
  pending = { serial = request_serial, base = base }
  dismiss_copilot()
  send_base(base, previous_suggestion, request_serial, false)
end

function S.suggest()
  local bufnr = current_buffer()
  if not bufnr then
    return
  end
  local target = capture_cursor_target(bufnr)
  local base, error_message = capture_snapshot(target, "completion")
  if not base then
    notify(error_message, vim.log.levels.WARN, true)
    return
  end
  begin_request(base)
end

function S.rewrite()
  local bufnr = current_buffer()
  if not bufnr then
    return
  end
  local scope_cwd = env.current_scope_cwd()
  local scope_epoch = env.current_scope_epoch()
  local target, target_error = capture_visual_target(bufnr)
  if not target then
    notify(target_error, vim.log.levels.WARN, true)
    return
  end
  vim.ui.input({ prompt = "Pi rewrite instruction: " }, function(instruction)
    instruction = type(instruction) == "string" and vim.trim(instruction) or ""
    if instruction == "" then
      notify("Pi rewrite cancelled: no instruction was provided", vim.log.levels.WARN, true)
      return
    end
    if env.current_scope_cwd() ~= scope_cwd or env.current_scope_epoch() ~= scope_epoch then
      notify("Pi rewrite cancelled because Neovim's working directory changed", vim.log.levels.WARN, true)
      return
    end
    if not target_is_current(target) then
      notify("The visual selection changed before the rewrite was requested", vim.log.levels.WARN, true)
      return
    end
    local base, error_message = capture_snapshot(target, "rewrite", instruction)
    if not base then
      notify(error_message, vim.log.levels.WARN, true)
      return
    end
    begin_request(base)
  end)
end

function S.again()
  if not preview then
    notify("There is no Pi editor suggestion to regenerate", vim.log.levels.WARN, true)
    return
  end
  if not target_is_current(preview.base.target) then
    invalidate_and_clear(true)
    notify("The buffer changed; request a fresh Pi suggestion", vim.log.levels.WARN, true)
    return
  end
  local base = preview.base
  local previous_suggestion = preview.suggestion
  begin_request(base, previous_suggestion)
end

function S.accept()
  if not preview then
    notify("There is no Pi editor suggestion to accept", vim.log.levels.WARN, true)
    return
  end
  local state = preview
  preview = nil
  pending = nil
  serial = serial + 1
  clear_preview_ui(state.base.bufnr)
  local position, error_message = replace_target(state.base.target, state.suggestion)
  if not position then
    notify(error_message, vim.log.levels.WARN, true)
    return
  end
  notify(string.format("Applied Pi %s as one Neovim edit", state.base.kind == "rewrite" and "rewrite" or "completion"))
end

local function register_autocommands()
  local group = vim.api.nvim_create_augroup("PiNvimContextSuggestion", { clear = true })
  vim.api.nvim_create_autocmd({
    "TextChanged",
    "TextChangedI",
    "CursorMoved",
    "CursorMovedI",
    "BufLeave",
    "BufUnload",
    "BufWipeout",
  }, {
    group = group,
    callback = function(args)
      local base = preview and preview.base or (pending and pending.base)
      if not base or args.buf ~= base.bufnr then
        return
      end
      local cursor_departed = (args.event == "CursorMoved" or args.event == "CursorMovedI")
        and base.kind == "completion"
      if cursor_departed
        or args.event == "BufLeave"
        or args.event == "BufUnload"
        or args.event == "BufWipeout"
        or not target_is_current(base.target)
      then
        invalidate_and_clear(true)
      end
    end,
  })
end

function S.configure(dependencies)
  env = dependencies
  register_autocommands()
end

S._test = {
  capture_cursor_target = capture_cursor_target,
  capture_visual_target = capture_visual_target,
  capture_snapshot = capture_snapshot,
  target_is_current = target_is_current,
  head_characters = head_characters,
  tail_characters = tail_characters,
  replace_target = replace_target,
  get_state = function()
    return { pending = pending, preview = preview }
  end,
  reset = S.reset,
}

return S
