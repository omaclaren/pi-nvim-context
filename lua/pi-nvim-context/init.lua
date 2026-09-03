local M = {}

local suggestion = require("pi-nvim-context.suggest")
local uv = vim.uv or vim.loop
local PROTOCOL_VERSION = 1
local MAX_PREFILL_BYTES = 256 * 1024

local defaults = {
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
    prefix = "<leader>p",
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
}

local config = vim.deepcopy(defaults)
local linked_sessions = {}
local link_generations = {}
local scope_epoch = 0
local last_scope_cwd = nil

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Pi context" })
end

local function runtime_directory()
  if vim.env.PI_NVIM_CONTEXT_RUNTIME_DIR and vim.env.PI_NVIM_CONTEXT_RUNTIME_DIR ~= "" then
    return vim.fs.normalize(vim.env.PI_NVIM_CONTEXT_RUNTIME_DIR)
  end

  local uid = "user"
  local ok, passwd = pcall(uv.os_get_passwd)
  if ok and passwd and passwd.uid ~= nil then
    uid = tostring(passwd.uid)
  end
  return "/tmp/pi-nvim-context-" .. uid
end

local function runtime_directory_is_secure()
  local directory = runtime_directory()
  local metadata = uv.fs_lstat(directory)
  if not metadata or metadata.type ~= "directory" then
    return false
  end

  local ok, passwd = pcall(uv.os_get_passwd)
  if ok and passwd and passwd.uid ~= nil and metadata.uid ~= nil and metadata.uid ~= passwd.uid then
    return false
  end

  local bitlib = bit or bit32
  if metadata.mode and bitlib and bitlib.band(metadata.mode, 0x3f) ~= 0 then
    return false
  end
  return true
end

local function canonical_work_path(path)
  return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ":p")))
end

local function cwd_matches(candidate, cwd)
  return type(candidate) == "string"
    and candidate ~= ""
    and canonical_work_path(candidate) == canonical_work_path(cwd)
end

local function current_scope_cwd()
  return canonical_work_path(vim.fn.getcwd())
end

local function current_scope_epoch()
  return scope_epoch
end

local function link_generation(scope_cwd)
  local scope = scope_cwd and canonical_work_path(scope_cwd) or current_scope_cwd()
  return link_generations[scope] or 0
end

local function advance_link_generation(scope_cwd)
  local scope = scope_cwd and canonical_work_path(scope_cwd) or current_scope_cwd()
  link_generations[scope] = link_generation(scope) + 1
end

local function clear_link(scope_cwd)
  local scope = scope_cwd and canonical_work_path(scope_cwd) or current_scope_cwd()
  linked_sessions[scope] = nil
  advance_link_generation(scope)
end

local function linked_session(capability, scope_cwd)
  local scope = scope_cwd and canonical_work_path(scope_cwd) or current_scope_cwd()
  local session = linked_sessions[scope]
  if not session then
    return nil
  end
  if capability
    and (type(session.capabilities) ~= "table"
      or not vim.tbl_contains(session.capabilities, capability))
  then
    return nil
  end
  return session
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function socket_request(socket_path, payload, callback, timeout_ms)
  local pipe = uv.new_pipe(false)
  local timer = uv.new_timer()
  local finished = false
  local response_buffer = ""

  local function finish(err, response)
    if finished then
      return
    end
    finished = true
    if timer and not timer:is_closing() then
      timer:stop()
    end
    close_handle(timer)
    if pipe and not pipe:is_closing() then
      pcall(pipe.read_stop, pipe)
    end
    close_handle(pipe)
    vim.schedule(function()
      callback(err, response)
    end)
  end

  timer:start(timeout_ms or config.timeout_ms, 0, function()
    finish("Timed out waiting for Pi")
  end)

  pipe:connect(socket_path, function(connect_err)
    if finished then
      return
    end
    if connect_err then
      finish("Could not connect to Pi: " .. tostring(connect_err))
      return
    end

    pipe:read_start(function(read_err, data)
      if read_err then
        finish("Could not read Pi response: " .. tostring(read_err))
        return
      end

      if data then
        response_buffer = response_buffer .. data
        if #response_buffer > 1024 * 1024 then
          finish("Pi response is too large")
          return
        end
        local newline = response_buffer:find("\n", 1, true)
        if not newline then
          return
        end
        local line = response_buffer:sub(1, newline - 1)
        local ok, decoded = pcall(vim.json.decode, line)
        if not ok then
          finish("Pi returned invalid JSON")
          return
        end
        finish(nil, decoded)
        return
      end

      if response_buffer ~= "" then
        local ok, decoded = pcall(vim.json.decode, response_buffer)
        if ok then
          finish(nil, decoded)
          return
        end
      end
      finish("Pi closed the connection without a response")
    end)

    local encoded = vim.json.encode(payload) .. "\n"
    pipe:write(encoded, function(write_err)
      if finished then
        return
      end
      if write_err then
        finish("Could not write to Pi: " .. tostring(write_err))
      end
    end)
  end)

  return function()
    finish("Request cancelled")
  end
end

local function read_manifest(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then
    return nil
  end

  local decoded_ok, manifest = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(manifest) ~= "table" then
    return nil
  end
  if manifest.protocol ~= PROTOCOL_VERSION or type(manifest.socketPath) ~= "string" then
    return nil
  end
  if vim.fs.dirname(vim.fs.normalize(manifest.socketPath)) ~= runtime_directory() then
    return nil
  end

  local socket_stat = uv.fs_stat(manifest.socketPath)
  if not socket_stat or socket_stat.type ~= "socket" then
    return nil
  end

  manifest._manifest_path = path
  return manifest
end

local function scan_sessions()
  if not runtime_directory_is_secure() then
    return {}
  end
  local directory = runtime_directory()
  local paths = vim.fn.glob(directory .. "/*.json", false, true)
  local sessions = {}
  for _, path in ipairs(paths) do
    local manifest = read_manifest(path)
    if manifest then
      table.insert(sessions, manifest)
    end
  end

  local cwd = vim.fn.getcwd()
  table.sort(sessions, function(a, b)
    local a_match = cwd_matches(a.cwd, cwd)
    local b_match = cwd_matches(b.cwd, cwd)
    if a_match ~= b_match then
      return a_match
    end
    return (a.startedAt or "") > (b.startedAt or "")
  end)
  return sessions
end

local function ping_sessions(sessions, callback)
  if #sessions == 0 then
    callback({})
    return
  end

  local pending = #sessions
  local responsive = {}
  for _, session in ipairs(sessions) do
    socket_request(session.socketPath, {
      protocol = PROTOCOL_VERSION,
      type = "ping",
    }, function(err, response)
      if not err and response and response.ok then
        local info = type(response.info) == "table" and response.info or {}
        local current = vim.tbl_extend("force", {}, session, info)
        current.socketPath = session.socketPath
        table.insert(responsive, current)
      end
      pending = pending - 1
      if pending == 0 then
        local cwd = vim.fn.getcwd()
        table.sort(responsive, function(a, b)
          local a_match = cwd_matches(a.cwd, cwd)
          local b_match = cwd_matches(b.cwd, cwd)
          if a_match ~= b_match then
            return a_match
          end
          return (a.startedAt or "") > (b.startedAt or "")
        end)
        callback(responsive)
      end
    end, math.min(config.timeout_ms, 750))
  end
end

local function short_session_id(session)
  if type(session.sessionId) ~= "string" then
    return "unknown"
  end
  return session.sessionId:sub(1, 8)
end

local function session_label(session, target_cwd)
  local name = session.sessionName
  if type(name) ~= "string" or name == "" then
    name = "Pi " .. short_session_id(session)
  end
  local cwd = type(session.cwd) == "string" and session.cwd or "unknown cwd"
  local relationship = cwd_matches(session.cwd, target_cwd or current_scope_cwd()) and "✓ exact cwd"
    or "⚠ different cwd"
  return string.format("%s · %s — %s (PID %s)", relationship, name, cwd, tostring(session.pid or "?"))
end

local function session_has_capability(session, capability)
  if not capability then
    return true
  end
  return type(session.capabilities) == "table" and vim.tbl_contains(session.capabilities, capability)
end

local same_session

local function link_session(session, scope_cwd, expected_generation, preserve_suggestion, expected_scope_epoch)
  local scope = scope_cwd and canonical_work_path(scope_cwd) or current_scope_cwd()
  if current_scope_cwd() ~= scope or (expected_scope_epoch ~= nil and scope_epoch ~= expected_scope_epoch) then
    return false, "cwd"
  end
  if expected_generation ~= nil and link_generation(scope) ~= expected_generation then
    return false, "superseded"
  end
  local previous = linked_sessions[scope]
  if previous and not same_session(previous, session) and not preserve_suggestion then
    suggestion.reset()
  end
  linked_sessions[scope] = session
  advance_link_generation(scope)
  notify(
    "Linked this Neovim working directory to Pi:\n"
      .. scope
      .. "\n→ "
      .. session_label(session, scope)
  )
  return true
end

local function select_from(
  sessions,
  callback,
  prompt,
  scope_cwd,
  expected_generation,
  preserve_suggestion,
  expected_scope_epoch
)
  vim.ui.select(sessions, {
    prompt = prompt or "Link this Neovim working directory to which Pi session?",
    format_item = function(session)
      return session_label(session, scope_cwd)
    end,
  }, function(choice)
    if not choice then
      callback(nil)
      return
    end
    local linked, reason = link_session(
      choice,
      scope_cwd,
      expected_generation,
      preserve_suggestion,
      expected_scope_epoch
    )
    if linked then
      callback(choice)
    else
      notify(
        reason == "cwd" and "Pi linking was cancelled because Neovim's working directory changed."
          or "Pi linking was cancelled because this Neovim cwd's Pi link changed while the picker was open.",
        vim.log.levels.WARN
      )
      callback(nil)
    end
  end)
end

local function candidate_sessions(sessions, force_picker, capability, scope_cwd)
  local candidates = sessions
  if capability then
    candidates = vim.tbl_filter(function(session)
      return session_has_capability(session, capability)
    end, candidates)
  end
  if not force_picker then
    local cwd = scope_cwd or current_scope_cwd()
    candidates = vim.tbl_filter(function(session)
      return cwd_matches(session.cwd, cwd)
    end, candidates)
  end
  return candidates
end

local function choose_session(force_picker, callback, capability)
  local requested_scope = current_scope_cwd()
  local requested_generation = link_generation(requested_scope)
  local requested_scope_epoch = scope_epoch
  ping_sessions(scan_sessions(), function(sessions)
    if current_scope_cwd() ~= requested_scope or scope_epoch ~= requested_scope_epoch then
      notify("Pi linking was cancelled because Neovim's working directory changed.", vim.log.levels.WARN)
      callback(nil)
      return
    end
    if link_generation(requested_scope) ~= requested_generation then
      notify("Pi linking was cancelled because this Neovim cwd's Pi link changed.", vim.log.levels.WARN)
      callback(nil)
      return
    end

    local candidates = candidate_sessions(sessions, force_picker, capability, requested_scope)
    if #candidates == 0 then
      if force_picker then
        local message = "No running Pi context bridge was found. Restart Pi after installing pi-nvim-context."
        if capability == "suggest" then
          message = "No running Pi session with suggestion support was found. Restart Pi after updating pi-nvim-context."
        elseif capability == "guided-insertion" then
          message = "No running Pi session with guided-insertion support was found. Restart Pi after updating pi-nvim-context."
        end
        notify(message, vim.log.levels.WARN)
      elseif capability == "suggest" or capability == "guided-insertion" then
        local feature = capability == "guided-insertion" and "guided-insertion" or "suggestion"
        notify(
          "No bridge-enabled Pi session with " .. feature .. " support matches this Neovim working directory:\n"
            .. requested_scope
            .. "\nRestart Pi there after updating pi-nvim-context, or run :PiContextPick to explicitly link a different session.",
          vim.log.levels.WARN
        )
      else
        notify(
          "No bridge-enabled Pi session matches this Neovim working directory:\n"
            .. requested_scope
            .. "\nRestart Pi in that directory, or run :PiContextPick to explicitly link a different-directory session.",
          vim.log.levels.WARN
        )
      end
      callback(nil)
      return
    end

    local prompt = force_picker
        and ("Link Neovim cwd " .. requested_scope .. " to which Pi session?")
      or ("Confirm the Pi link for Neovim cwd " .. requested_scope .. ":")
    select_from(
      candidates,
      callback,
      prompt,
      requested_scope,
      requested_generation,
      capability ~= nil,
      requested_scope_epoch
    )
  end)
end

local function choose_suggestion_session(callback, capability)
  capability = capability or "suggest"
  local current = linked_session(capability)
  if current then
    callback(current)
    return
  end
  choose_session(false, callback, capability)
end

same_session = function(first, second)
  return first
    and second
    and type(first.socketPath) == "string"
    and first.socketPath == second.socketPath
end

local function invalidate_session(session, scope_cwd, expected_generation)
  if scope_cwd then
    local scope = canonical_work_path(scope_cwd)
    if expected_generation ~= nil and link_generation(scope) ~= expected_generation then
      return false
    end
    if same_session(linked_sessions[scope], session) then
      linked_sessions[scope] = nil
      advance_link_generation(scope)
      return true
    end
    return false
  end

  local stale_scopes = {}
  for scope, linked in pairs(linked_sessions) do
    if same_session(linked, session) then
      table.insert(stale_scopes, scope)
    end
  end
  for _, scope in ipairs(stale_scopes) do
    linked_sessions[scope] = nil
    advance_link_generation(scope)
  end
  return #stale_scopes > 0
end

local function truncate_utf8(text, max_bytes)
  if #text <= max_bytes then
    return text, false
  end

  local total_chars = vim.fn.strchars(text)
  local low, high = 0, total_chars
  while low < high do
    local middle = math.ceil((low + high) / 2)
    local candidate = vim.fn.strcharpart(text, 0, middle)
    if #candidate <= max_bytes then
      low = middle
    else
      high = middle - 1
    end
  end
  return vim.fn.strcharpart(text, 0, low), true
end

local function trim_payload(text)
  local marker = "\n\n… [context truncated by pi-nvim-context]"
  local max_bytes = math.min(config.max_payload_bytes, MAX_PREFILL_BYTES)
  if #text <= max_bytes then
    return text
  end
  local prefix = truncate_utf8(text, math.max(max_bytes - #marker, 0))
  return prefix .. marker
end

local function send_context(text, summary, retried, scope_cwd)
  local origin_scope = scope_cwd and canonical_work_path(scope_cwd) or current_scope_cwd()
  local function send(session)
    if not session then
      return
    end
    local request_generation = link_generation(origin_scope)
    local request_scope_epoch = scope_epoch
    socket_request(session.socketPath, {
      protocol = PROTOCOL_VERSION,
      type = "prefill",
      text = trim_payload(text),
      summary = summary,
    }, function(err, response)
      if err or not response or not response.ok then
        local failed_link_is_origin = scope_epoch == request_scope_epoch
          and link_generation(origin_scope) == request_generation
          and same_session(linked_session(nil, origin_scope), session)
        invalidate_session(session, origin_scope, request_generation)
        if not retried and failed_link_is_origin and current_scope_cwd() == origin_scope then
          choose_session(false, function(replacement)
            if replacement then
              send_context(text, summary, true, origin_scope)
            end
          end)
          return
        end
        local reason = err or (response and response.error) or "unknown error"
        notify(
          "Could not add context to Pi for Neovim cwd " .. origin_scope .. ": " .. tostring(reason),
          vim.log.levels.ERROR
        )
        return
      end
      if config.notify then
        notify("Added " .. summary .. " to " .. session_label(session, origin_scope))
      end
    end)
  end

  if current_scope_cwd() ~= origin_scope then
    notify("Context sending was cancelled because Neovim's working directory changed.", vim.log.levels.WARN)
    return
  end
  local current = linked_session(nil, origin_scope)
  if current then
    send(current)
  else
    choose_session(false, send)
  end
end

local function current_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if vim.bo[bufnr].buftype ~= "" then
    notify("The current buffer is not a normal file buffer", vim.log.levels.WARN)
    return nil
  end
  return bufnr
end

local function buffer_is_available(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    return true
  end
  notify("The source Neovim buffer is no longer available", vim.log.levels.WARN)
  return false
end

local function display_path(bufnr, session)
  local absolute = vim.api.nvim_buf_get_name(bufnr)
  if absolute == "" then
    return nil
  end
  absolute = canonical_work_path(absolute)

  if session and type(session.cwd) == "string" and vim.fs.relpath then
    local relative = vim.fs.relpath(canonical_work_path(session.cwd), absolute)
    if relative and relative ~= "" and relative ~= ".." and not relative:match("^%.%.[/\\]") then
      return relative
    end
  end
  return absolute
end

local function quote_path(path)
  return "`" .. path:gsub("`", "\\`") .. "`"
end

local function buffer_label(bufnr, session)
  local path = display_path(bufnr, session)
  return path and quote_path(path) or "the unnamed Neovim buffer"
end

local function language_tag(bufnr)
  return (vim.bo[bufnr].filetype or ""):gsub("[^%w_+%-]", "")
end

local function fenced(text, language)
  local longest = 0
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  local fence = string.rep("`", math.max(3, longest + 1))
  return fence .. language .. "\n" .. text .. "\n" .. fence
end

local function format_file(bufnr, session)
  local modified = vim.bo[bufnr].modified and " (modified in Neovim; disk contents may differ)" or ""
  return "Neovim file: " .. buffer_label(bufnr, session) .. modified
end

local function format_location_at(bufnr, session, cursor, line)
  local location = string.format(
    "Neovim location: %s, line %d, column %d",
    buffer_label(bufnr, session),
    cursor[1],
    cursor[2] + 1
  )
  return location .. "\n\nCurrent line:\n" .. fenced(line, language_tag(bufnr))
end

local function current_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return { math.max(cursor[1], 1), math.max(cursor[2], 0) }
end

local function format_location(bufnr, session)
  local cursor = current_cursor()
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  return format_location_at(bufnr, session, cursor, line)
end

local function visual_region(bufnr)
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

  if not start_pos or not end_pos or start_pos[2] == 0 or end_pos[2] == 0 then
    return nil
  end

  local start_after_end = start_pos[2] > end_pos[2]
    or (start_pos[2] == end_pos[2] and start_pos[3] > end_pos[3])
    or (start_pos[2] == end_pos[2] and start_pos[3] == end_pos[3] and start_pos[4] > end_pos[4])
  if start_after_end then
    start_pos, end_pos = end_pos, start_pos
  end

  local ok, lines
  if vim.fn.exists("*getregion") == 1 then
    ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = mode })
  else
    ok = true
    local first = math.min(start_pos[2], end_pos[2])
    local last = math.max(start_pos[2], end_pos[2])
    lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  end
  if not ok or not lines or #lines == 0 then
    return nil
  end

  return {
    text = table.concat(lines, "\n"),
    start_line = math.min(start_pos[2], end_pos[2]),
    end_line = math.max(start_pos[2], end_pos[2]),
  }
end

local function format_selection(bufnr, session, region)
  local text, truncated = truncate_utf8(region.text, config.max_selection_bytes)
  if truncated then
    text = text .. "\n… [selection truncated]"
  end
  local range = region.start_line == region.end_line and ("line " .. region.start_line)
    or string.format("lines %d–%d", region.start_line, region.end_line)
  return string.format(
    "Neovim selection from %s (%s):\n\n%s",
    buffer_label(bufnr, session),
    range,
    fenced(text, language_tag(bufnr))
  )
end

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

local function format_diagnostics(bufnr, session, diagnostics)
  table.sort(diagnostics, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    if a.col ~= b.col then
      return a.col < b.col
    end
    return (a.severity or 99) < (b.severity or 99)
  end)

  local lines = { "Neovim diagnostics for " .. buffer_label(bufnr, session) .. ":" }
  local limit = math.min(#diagnostics, config.max_diagnostics)
  for index = 1, limit do
    local diagnostic = diagnostics[index]
    local message = tostring(diagnostic.message or ""):gsub("[\r\n]+", " "):gsub("%s+", " ")
    local origin_parts = {}
    if diagnostic.source then
      table.insert(origin_parts, tostring(diagnostic.source))
    end
    if diagnostic.code then
      table.insert(origin_parts, tostring(diagnostic.code))
    end
    local origin = #origin_parts > 0 and (" [" .. table.concat(origin_parts, "/") .. "]") or ""
    table.insert(lines, string.format(
      "- %s L%d:C%d%s: %s",
      severity_names[diagnostic.severity] or "DIAGNOSTIC",
      (diagnostic.lnum or 0) + 1,
      (diagnostic.col or 0) + 1,
      origin,
      message
    ))
  end
  if #diagnostics > limit then
    table.insert(lines, string.format("- … %d more diagnostics omitted", #diagnostics - limit))
  end
  return table.concat(lines, "\n")
end

local function format_buffer(bufnr, session)
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local truncated
  text, truncated = truncate_utf8(text, config.max_buffer_bytes)
  if truncated then
    text = text .. "\n… [buffer truncated]"
  end
  local state = vim.bo[bufnr].modified and "modified" or "current"
  return string.format(
    "Neovim %s buffer for %s (%d lines):\n\n%s",
    state,
    buffer_label(bufnr, session),
    vim.api.nvim_buf_line_count(bufnr),
    fenced(text, language_tag(bufnr))
  )
end

local function with_linked_session(callback)
  local scope_cwd = current_scope_cwd()
  local current = linked_session(nil, scope_cwd)
  if current then
    callback(current, scope_cwd)
  else
    choose_session(false, function(session)
      if session then
        callback(session, scope_cwd)
      end
    end)
  end
end

local function with_selected_formatter(formatter, summary)
  local bufnr = current_buffer()
  if not bufnr then
    return
  end

  local function build(session, scope_cwd)
    if not buffer_is_available(bufnr) then
      return
    end
    send_context(formatter(bufnr, session), summary, false, scope_cwd)
  end
  with_linked_session(build)
end

function M.pick()
  choose_session(true, function() end)
end

function M.add_file()
  local bufnr = current_buffer()
  if not bufnr then
    return
  end
  if vim.api.nvim_buf_get_name(bufnr) == "" then
    notify("Save the buffer first, or run :PiContextBuffer to send its contents", vim.log.levels.WARN)
    return
  end
  with_selected_formatter(format_file, "current file")
end

function M.add_location()
  local bufnr = current_buffer()
  if not bufnr then
    return
  end
  local cursor = current_cursor()
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""

  local function build(session, scope_cwd)
    if not buffer_is_available(bufnr) then
      return
    end
    send_context(format_location_at(bufnr, session, cursor, line), "current location", false, scope_cwd)
  end
  with_linked_session(build)
end

function M.add_selection()
  local bufnr = current_buffer()
  if not bufnr then
    return
  end
  local region = visual_region(bufnr)
  if not region or region.text == "" then
    notify("No visual selection found", vim.log.levels.WARN)
    return
  end

  local function build(session, scope_cwd)
    if not buffer_is_available(bufnr) then
      return
    end
    local line_count = region.end_line - region.start_line + 1
    send_context(
      format_selection(bufnr, session, region),
      string.format("selection (%d lines)", line_count),
      false,
      scope_cwd
    )
  end
  with_linked_session(build)
end

function M.add_diagnostics()
  local bufnr = current_buffer()
  if not bufnr then
    return
  end
  local diagnostics = vim.diagnostic.get(bufnr)
  if #diagnostics == 0 then
    notify("No diagnostics in the current buffer")
    return
  end

  local function build(session, scope_cwd)
    if not buffer_is_available(bufnr) then
      return
    end
    send_context(
      format_diagnostics(bufnr, session, diagnostics),
      string.format("%d diagnostics", #diagnostics),
      false,
      scope_cwd
    )
  end
  with_linked_session(build)
end

function M.add_buffer()
  with_selected_formatter(format_buffer, "current buffer")
end

M.suggest = suggestion.suggest
M.suggest_guided = suggestion.suggest_guided
M.rewrite = suggestion.rewrite
M.accept_suggestion = suggestion.accept
M.suggest_again = suggestion.again
M.dismiss_suggestion = suggestion.dismiss
M.focus_suggestion_preview = suggestion.focus_preview

function M.status()
  local sessions = scan_sessions()
  local cwd = current_scope_cwd()
  local exact_count = #vim.tbl_filter(function(session)
    return cwd_matches(session.cwd, cwd)
  end, sessions)
  local current = linked_session(nil, cwd)
  if current then
    local request_generation = link_generation(cwd)
    socket_request(current.socketPath, {
      protocol = PROTOCOL_VERSION,
      type = "info",
    }, function(err, response)
      if err or not response or not response.ok then
        if link_generation(cwd) == request_generation and same_session(linked_session(nil, cwd), current) then
          invalidate_session(current, cwd, request_generation)
          notify(
            "The Pi session linked for this Neovim working directory is no longer available:\n"
              .. cwd
              .. "\nRun :PiContextPick to link again.",
            vim.log.levels.WARN
          )
        end
        return
      end
      if link_generation(cwd) ~= request_generation or not same_session(linked_session(nil, cwd), current) then
        return
      end
      local info = type(response.info) == "table" and response.info or {}
      linked_sessions[cwd] = vim.tbl_extend("force", {}, current, info)
      linked_sessions[cwd].socketPath = current.socketPath
      notify(
        "Neovim working directory:\n"
          .. cwd
          .. "\nLinked Pi:\n"
          .. session_label(linked_sessions[cwd], cwd)
          .. string.format("\n%d bridge(s) discovered; %d exact cwd match(es)", #sessions, exact_count)
      )
    end)
    return
  end
  notify(
    "This Neovim working directory is not linked to Pi:\n"
      .. cwd
      .. string.format("\n%d bridge(s) discovered; %d exact cwd match(es)\nRun :PiContextPick to link explicitly.", #sessions, exact_count)
  )
end

local command_definitions = {
  PiContextPick = { M.pick, "Select a standalone Pi session" },
  PiContextFile = { M.add_file, "Add the current file to Pi's input" },
  PiContextLocation = { M.add_location, "Add the current location to Pi's input" },
  PiContextSelection = { M.add_selection, "Add the visual selection to Pi's input" },
  PiContextDiagnostics = { M.add_diagnostics, "Add current diagnostics to Pi's input" },
  PiContextBuffer = { M.add_buffer, "Add the current buffer to Pi's input" },
  PiContextStatus = { M.status, "Show Pi context bridge status" },
  PiSuggest = { M.suggest, "Ask Pi for an explicit completion at the cursor" },
  PiSuggestGuided = { M.suggest_guided, "Ask Pi for an instruction-guided insertion at the cursor" },
  PiRewrite = { M.rewrite, "Ask Pi to rewrite the visual selection" },
  PiSuggestAccept = { M.accept_suggestion, "Accept the pending Pi editor suggestion" },
  PiSuggestAgain = { M.suggest_again, "Generate another Pi editor suggestion" },
  PiSuggestDismiss = { M.dismiss_suggestion, "Cancel or dismiss the Pi editor suggestion" },
  PiSuggestPreview = { M.focus_suggestion_preview, "Focus the full Pi editor suggestion preview" },
}

local function register_commands()
  for name, definition in pairs(command_definitions) do
    vim.api.nvim_create_user_command(name, definition[1], {
      desc = definition[2],
      force = true,
      range = name == "PiContextSelection" or name == "PiRewrite",
    })
  end
end

local function register_keymaps()
  if config.keymaps == false then
    return
  end
  local keymaps = config.keymaps or {}
  local function mapping_extends_prefix(lhs)
    local prefix = keymaps.prefix
    if type(lhs) ~= "string" or type(prefix) ~= "string" or prefix == "" then
      return false
    end
    local leader = type(vim.g.mapleader) == "string" and vim.g.mapleader or "\\"
    local function expand(value)
      local with_leader = value:gsub("<[Ll][Ee][Aa][Dd][Ee][Rr]>", function()
        return leader
      end)
      return vim.api.nvim_replace_termcodes(with_leader, true, true, true)
    end
    local expanded_lhs = expand(lhs)
    local expanded_prefix = expand(prefix)
    return #expanded_lhs > #expanded_prefix
      and expanded_lhs:sub(1, #expanded_prefix) == expanded_prefix
  end

  if keymaps.prefix and keymaps.prefix ~= false then
    vim.keymap.set({ "n", "x" }, keymaps.prefix, "<Nop>", {
      silent = true,
      desc = "Pi context mapping prefix",
    })
  end
  local normal = {
    pick = { M.pick, "Select Pi context target" },
    file = { M.add_file, "Add current file to Pi" },
    location = { M.add_location, "Add current location to Pi" },
    diagnostics = { M.add_diagnostics, "Add diagnostics to Pi" },
    buffer = { M.add_buffer, "Add current buffer to Pi" },
    status = { M.status, "Show Pi context status" },
    suggest = { M.suggest, "Request Pi completion at cursor" },
    guided = { M.suggest_guided, "Request guided Pi insertion at cursor" },
    accept = { M.accept_suggestion, "Accept Pi editor suggestion" },
    again = { M.suggest_again, "Try another Pi editor suggestion" },
    dismiss = { M.dismiss_suggestion, "Dismiss Pi editor suggestion" },
    preview = { M.focus_suggestion_preview, "Focus full Pi suggestion preview" },
  }
  local function visual_mode_guard(lhs)
    return function()
      notify(
        "Pi mapping " .. lhs .. " is available only in Normal mode; press <Esc> first.",
        vim.log.levels.WARN
      )
    end
  end

  for name, mapping in pairs(normal) do
    local lhs = keymaps[name]
    if lhs and lhs ~= false then
      vim.keymap.set("n", lhs, mapping[1], { silent = true, desc = mapping[2] })
      if name == "pick" then
        vim.keymap.set("x", lhs, mapping[1], { silent = true, desc = mapping[2] })
      elseif mapping_extends_prefix(lhs) then
        local existing = vim.fn.maparg(lhs, "x", false, true)
        if type(existing) ~= "table" or vim.tbl_isempty(existing) then
          vim.keymap.set("x", lhs, visual_mode_guard(lhs), {
            silent = true,
            desc = mapping[2] .. " (Normal mode only)",
          })
        end
      end
    end
  end
  if keymaps.selection and keymaps.selection ~= false then
    vim.keymap.set("x", keymaps.selection, M.add_selection, { silent = true, desc = "Add selection to Pi" })
  end
  if keymaps.rewrite and keymaps.rewrite ~= false then
    vim.keymap.set("x", keymaps.rewrite, M.rewrite, { silent = true, desc = "Rewrite selection with Pi" })
  end
end

local function register_link_autocommands()
  local group = vim.api.nvim_create_augroup("PiNvimContextLink", { clear = true })
  last_scope_cwd = current_scope_cwd()
  scope_epoch = scope_epoch + 1
  vim.api.nvim_create_autocmd({ "DirChanged", "WinEnter", "TabEnter" }, {
    group = group,
    callback = function()
      local current_scope = current_scope_cwd()
      if last_scope_cwd == current_scope then
        return
      end
      local previous_scope = last_scope_cwd
      last_scope_cwd = current_scope
      scope_epoch = scope_epoch + 1
      suggestion.reset()
      local current = linked_session()
      if current then
        notify(
          "Neovim working directory changed:\n"
            .. tostring(previous_scope)
            .. "\n→ "
            .. current_scope
            .. "\nUsing its remembered Pi link:\n"
            .. session_label(current)
        )
      else
        notify(
          "Neovim working directory changed:\n"
            .. tostring(previous_scope)
            .. "\n→ "
            .. current_scope
            .. "\nThis directory is not linked to Pi. Run :PiContextPick to link it."
        )
      end
    end,
  })
end

function M.setup(options)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  suggestion.configure({
    protocol = PROTOCOL_VERSION,
    get_config = function()
      return config
    end,
    current_scope_cwd = current_scope_cwd,
    current_scope_epoch = current_scope_epoch,
    notify = notify,
    socket_request = socket_request,
    choose_suggestion_session = choose_suggestion_session,
    invalidate_session = invalidate_session,
    session_label = session_label,
  })
  register_commands()
  register_keymaps()
  register_link_autocommands()
end

M._test = {
  runtime_directory = runtime_directory,
  runtime_directory_is_secure = runtime_directory_is_secure,
  truncate_utf8 = truncate_utf8,
  fenced = fenced,
  format_file = format_file,
  format_location = format_location,
  visual_region = visual_region,
  format_selection = format_selection,
  format_diagnostics = format_diagnostics,
  format_buffer = format_buffer,
  suggestion = suggestion._test,
  candidate_sessions = candidate_sessions,
  session_label = session_label,
  link_session = link_session,
  link_generation = link_generation,
  current_scope_epoch = current_scope_epoch,
  get_linked_session = linked_session,
  invalidate_session = invalidate_session,
  set_selected_session = function(session, scope_cwd)
    local scope = canonical_work_path(scope_cwd or vim.fn.getcwd())
    linked_sessions[scope] = session
    advance_link_generation(scope)
  end,
  clear_link = clear_link,
  reset = function()
    suggestion.reset()
    config = vim.deepcopy(defaults)
    linked_sessions = {}
    link_generations = {}
    scope_epoch = scope_epoch + 1
    last_scope_cwd = current_scope_cwd()
  end,
}

return M
