local S = {}

local uv = vim.uv or vim.loop
local namespace = vim.api.nvim_create_namespace("pi-nvim-context-suggestion")
local env = nil
local pending = nil
local preview = nil
local preview_win = nil
local preview_buf = nil
local preview_source_win = nil
local source_tab_buf = nil
local entering_preview = false
local invalidate_and_clear
local serial = 0

local SOURCE_TAB_DESC = "Accept visible Pi editor suggestion"

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
    winid = vim.api.nvim_get_current_win(),
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
    winid = vim.api.nvim_get_current_win(),
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

local function target_window(target)
  if target.winid
    and vim.api.nvim_win_is_valid(target.winid)
    and vim.api.nvim_win_get_buf(target.winid) == target.bufnr
  then
    return target.winid
  end
  local winid = vim.fn.bufwinid(target.bufnr)
  if winid and winid >= 0 and vim.api.nvim_win_is_valid(winid) then
    return winid
  end
  return nil
end

local function remove_source_tab_mapping()
  local bufnr = source_tab_buf
  source_tab_buf = nil
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ok, mapping = pcall(vim.api.nvim_buf_call, bufnr, function()
    return vim.fn.maparg("<Tab>", "n", false, true)
  end)
  if ok and type(mapping) == "table" and mapping.buffer == 1 and mapping.desc == SOURCE_TAB_DESC then
    pcall(vim.keymap.del, "n", "<Tab>", { buffer = bufnr })
  end
end

local function install_source_tab_mapping(bufnr)
  if cfg().accept_with_tab == false or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ok, existing = pcall(vim.api.nvim_buf_call, bufnr, function()
    return vim.fn.maparg("<Tab>", "n", false, true)
  end)
  if ok and type(existing) == "table" and existing.buffer == 1 then
    return
  end
  vim.keymap.set("n", "<Tab>", function()
    S.accept()
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = SOURCE_TAB_DESC,
  })
  source_tab_buf = bufnr
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
  preview_source_win = nil
end

local function clear_preview_ui(bufnr)
  remove_source_tab_mapping()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
  end
  close_preview_window()
end

local function return_to_source()
  local target = preview and preview.base.target
  local winid = preview_source_win
  if (not winid or not vim.api.nvim_win_is_valid(winid)) and target then
    winid = target_window(target)
  end
  if winid and winid >= 0 and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_set_current_win, winid)
  end
end

local function wrapped_line_count(lines, width)
  local count = 0
  for _, line in ipairs(lines) do
    local display_width = math.max(1, vim.fn.strdisplaywidth(line))
    count = count + math.max(1, math.ceil(display_width / math.max(1, width)))
  end
  return count
end

local function preview_position(target, width, height, centered)
  if centered then
    return math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
      math.max(1, math.floor((vim.o.columns - width) / 2))
  end
  local winid = target_window(target)
  if not winid then
    return 1, math.max(1, math.floor((vim.o.columns - width) / 2))
  end
  local position = vim.fn.screenpos(winid, target.start_row + 1, target.start_col + 1)
  if type(position) ~= "table" or not position.row or position.row <= 0 then
    return 1, math.max(1, math.floor((vim.o.columns - width) / 2))
  end
  local col = math.max(1, math.min(position.col - 1, vim.o.columns - width - 2))
  local room_below = vim.o.lines - position.row - 3
  local row = room_below >= height + 2 and position.row or math.max(1, position.row - height - 2)
  return row, col
end

local function open_preview_window(state, lines, options)
  local max_width = math.max(24, vim.o.columns - 4)
  local configured_width = math.max(24, tonumber(cfg().preview_width) or 92)
  local longest = 1
  for _, line in ipairs(lines) do
    longest = math.max(longest, vim.fn.strdisplaywidth(line))
  end
  local width = math.min(max_width, configured_width, math.max(36, longest + 2))
  local max_height = math.max(4, vim.o.lines - 6)
  local configured_height = math.max(4, tonumber(cfg().preview_height) or 18)
  local height = math.min(max_height, configured_height, math.max(4, wrapped_line_count(lines, width)))
  local row, col = preview_position(state.base.target, width, height, options.centered)

  preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].swapfile = false
  vim.bo[preview_buf].filetype = options.filetype or ""
  vim.bo[preview_buf].modifiable = false

  local title = string.format(" Pi %s · Space p v to inspect · Tab to accept ", options.label)
  if vim.fn.strdisplaywidth(title) > width then
    title = " Pi preview · Tab accept "
  end
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
  if not ok then
    pcall(vim.api.nvim_buf_delete, preview_buf, { force = true })
    preview_buf = nil
    return false
  end

  preview_win = win
  preview_source_win = target_window(state.base.target)
  vim.wo[preview_win].wrap = true
  vim.wo[preview_win].linebreak = false
  vim.wo[preview_win].breakindent = true
  vim.wo[preview_win].cursorline = true
  vim.wo[preview_win].number = false
  vim.wo[preview_win].relativenumber = false

  vim.keymap.set("n", "<Tab>", function()
    S.accept()
  end, { buffer = preview_buf, silent = true, nowait = true, desc = SOURCE_TAB_DESC })
  vim.keymap.set("n", "j", "gj", {
    buffer = preview_buf,
    silent = true,
    desc = "Move down one displayed preview line",
  })
  vim.keymap.set("n", "k", "gk", {
    buffer = preview_buf,
    silent = true,
    desc = "Move up one displayed preview line",
  })
  vim.keymap.set("n", "q", return_to_source, {
    buffer = preview_buf,
    silent = true,
    nowait = true,
    desc = "Return to the Pi suggestion source",
  })
  vim.keymap.set("n", "<Esc>", return_to_source, {
    buffer = preview_buf,
    silent = true,
    nowait = true,
    desc = "Return to the Pi suggestion source",
  })
  return true
end

local function inline_available_width(target)
  local winid = target_window(target)
  if not winid then
    return math.max(0, vim.o.columns - 8)
  end
  local position = vim.fn.screenpos(winid, target.start_row + 1, target.start_col + 1)
  if type(position) ~= "table" or not position.col or position.col <= 0 then
    return math.max(0, vim.api.nvim_win_get_width(winid) - 4)
  end
  local window_position = vim.api.nvim_win_get_position(winid)
  local window_right = window_position[2] + vim.api.nvim_win_get_width(winid)
  return math.max(0, window_right - position.col - 1)
end

local function inline_chunks(text)
  if text == "" then
    return { { "▏", "PiNvimContextInsertionPoint" } }
  end
  local first_bytes = utf8_character_bytes(text, 0)
  return {
    { text:sub(1, first_bytes), "PiNvimContextInsertionPoint" },
    { text:sub(first_bytes + 1), "Comment" },
  }
end

local function render_completion(state)
  local target = state.base.target
  local lines = vim.split(state.suggestion, "\n", { plain = true, trimempty = false })
  if #lines == 0 then
    lines = { state.suggestion }
  end
  local needs_window = #lines > 1 or vim.fn.strdisplaywidth(lines[1] or "") > inline_available_width(target)
  if not needs_window then
    vim.api.nvim_buf_set_extmark(target.bufnr, namespace, target.start_row, target.start_col, {
      virt_text = inline_chunks(lines[1] or ""),
      virt_text_pos = "inline",
      right_gravity = false,
      priority = 200,
    })
    return false
  end

  vim.api.nvim_buf_set_extmark(target.bufnr, namespace, target.start_row, target.start_col, {
    virt_text = {
      { "▏", "PiNvimContextInsertionPoint" },
      { " Pi insertion preview", "DiagnosticHint" },
    },
    virt_text_pos = "inline",
    right_gravity = false,
    priority = 200,
  })
  local opened = open_preview_window(state, lines, {
    centered = false,
    filetype = vim.bo[target.bufnr].filetype,
    label = state.base.kind == "insertion" and "guided insertion" or "completion",
  })
  if not opened then
    vim.api.nvim_buf_clear_namespace(target.bufnr, namespace, 0, -1)
    local virtual_lines = {}
    for index = 2, #lines do
      table.insert(virtual_lines, { { lines[index], "Comment" } })
    end
    vim.api.nvim_buf_set_extmark(target.bufnr, namespace, target.start_row, target.start_col, {
      virt_text = inline_chunks(lines[1] or ""),
      virt_text_pos = "inline",
      virt_lines = virtual_lines,
      right_gravity = false,
      priority = 200,
    })
  end
  return opened
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

  local diff_lines = vim.split(rewrite_diff(target.original, state.suggestion), "\n", {
    plain = true,
    trimempty = false,
  })
  return open_preview_window(state, diff_lines, {
    centered = true,
    filetype = "diff",
    label = "rewrite diff",
  })
end

local function dismiss_copilot()
  pcall(function()
    vim.fn["copilot#Dismiss"]()
  end)
end

local function suggestion_kind_label(kind)
  if kind == "rewrite" then
    return "rewrite"
  elseif kind == "insertion" then
    return "guided insertion"
  end
  return "completion"
end

local function render_preview(state)
  clear_preview_ui(state.base.bufnr)
  dismiss_copilot()
  local has_window
  if state.base.kind == "rewrite" then
    has_window = render_rewrite(state)
  else
    has_window = render_completion(state)
  end
  install_source_tab_mapping(state.base.bufnr)
  notify(string.format(
    "Pi %s ready (%s, thinking %s). Use Normal Tab or Space p a to accept, Space p n for another, or Space p x to dismiss.%s",
    suggestion_kind_label(state.base.kind),
    state.model_label,
    state.thinking,
    has_window and " Space p v opens the full scrollable preview." or ""
  ))
end

function S.focus_preview()
  if not preview or not preview_win or not vim.api.nvim_win_is_valid(preview_win) then
    notify("This Pi suggestion has no separate full preview", vim.log.levels.WARN, true)
    return
  end
  if not target_is_current(preview.base.target) then
    invalidate_and_clear(true)
    notify("The buffer changed; request a fresh Pi suggestion", vim.log.levels.WARN, true)
    return
  end
  entering_preview = true
  local ok = pcall(vim.api.nvim_set_current_win, preview_win)
  entering_preview = false
  if not ok then
    notify("The Pi suggestion preview is no longer available", vim.log.levels.WARN, true)
    return
  end
  notify("Pi preview focused. Scroll normally; press Tab to accept or q to return to the source.")
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
  local winid = target_window(target)
  if winid then
    pcall(vim.api.nvim_win_set_cursor, winid, { end_row + 1, end_col })
  end
  return { row = end_row, col = end_col }
end

invalidate_and_clear = function(silent)
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

  local capability = base.kind == "insertion" and "guided-insertion" or "suggest"
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
    local timeout = base.kind == "completion" and cfg().suggest_timeout_ms or cfg().rewrite_timeout_ms
    notify(string.format("Generating Pi %s with %s…", suggestion_kind_label(base.kind), env.session_label(session)))

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
  end, capability)
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

function S.suggest_guided()
  local bufnr = current_buffer()
  if not bufnr then
    return
  end
  local scope_cwd = env.current_scope_cwd()
  local scope_epoch = env.current_scope_epoch()
  local prompt_serial = serial
  local target = capture_cursor_target(bufnr)
  vim.ui.input({ prompt = "Pi insertion instruction: " }, function(instruction)
    instruction = type(instruction) == "string" and vim.trim(instruction) or ""
    if instruction == "" then
      notify("Pi guided insertion cancelled: no instruction was provided", vim.log.levels.WARN, true)
      return
    end
    if env.current_scope_cwd() ~= scope_cwd or env.current_scope_epoch() ~= scope_epoch then
      notify("Pi guided insertion cancelled because Neovim's working directory changed", vim.log.levels.WARN, true)
      return
    end
    if serial ~= prompt_serial then
      notify("Pi guided insertion cancelled because another suggestion superseded it", vim.log.levels.WARN, true)
      return
    end
    if vim.api.nvim_get_current_buf() ~= bufnr or not target_is_current(target) then
      notify("The insertion target changed before the request was prepared", vim.log.levels.WARN, true)
      return
    end
    local current_target = capture_cursor_target(bufnr)
    if current_target.start_row ~= target.start_row or current_target.start_col ~= target.start_col then
      notify("The cursor moved before the guided insertion was requested", vim.log.levels.WARN, true)
      return
    end
    local base, error_message = capture_snapshot(target, "insertion", instruction)
    if not base then
      notify(error_message, vim.log.levels.WARN, true)
      return
    end
    begin_request(base)
  end)
end

function S.rewrite()
  local bufnr = current_buffer()
  if not bufnr then
    return
  end
  local scope_cwd = env.current_scope_cwd()
  local scope_epoch = env.current_scope_epoch()
  local prompt_serial = serial
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
    if serial ~= prompt_serial then
      notify("Pi rewrite cancelled because another suggestion superseded it", vim.log.levels.WARN, true)
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
  notify(string.format("Applied Pi %s as one Neovim edit", suggestion_kind_label(state.base.kind)))
end

local function define_highlights()
  pcall(vim.api.nvim_set_hl, 0, "PiNvimContextInsertionPoint", {
    default = true,
    link = "IncSearch",
  })
end

local function register_autocommands()
  local group = vim.api.nvim_create_augroup("PiNvimContextSuggestion", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_highlights,
  })
  vim.api.nvim_create_autocmd({
    "TextChanged",
    "TextChangedI",
    "CursorMoved",
    "CursorMovedI",
    "BufEnter",
    "BufLeave",
    "BufUnload",
    "BufWipeout",
  }, {
    group = group,
    callback = function(args)
      local base = preview and preview.base or (pending and pending.base)
      if not base then
        return
      end
      if args.event == "BufEnter" then
        if args.buf ~= base.bufnr and args.buf ~= preview_buf then
          invalidate_and_clear(true)
        end
        return
      end
      if args.buf == preview_buf and (args.event == "BufUnload" or args.event == "BufWipeout") then
        invalidate_and_clear(true)
        return
      end
      if args.buf ~= base.bufnr then
        return
      end
      if args.event == "BufLeave" and entering_preview then
        return
      end
      local cursor_departed = (args.event == "CursorMoved" or args.event == "CursorMovedI")
        and base.kind ~= "rewrite"
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
  define_highlights()
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
  get_ui_state = function()
    return {
      namespace = namespace,
      preview_win = preview_win,
      preview_buf = preview_buf,
      preview_source_win = preview_source_win,
      source_tab_buf = source_tab_buf,
    }
  end,
  reset = S.reset,
}

return S
