local M = {}

M.config = {
  idle_ms = 400,
  accept_key = "<C-l>",
}

local state = {
  ns           = vim.api.nvim_create_namespace("ghost_inline"),
  timer        = nil,
  bufnr        = nil,
  row          = nil,
  col          = nil,
  text         = nil,
  extmark      = nil,
  request_id   = 0,
  initializing = false,
  ready        = false,
  server_url   = "http://127.0.0.1:4097"
}

local function set_status(s)
  vim.g.ghost_inline_status = s
end

local function clear_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function clear_ghost()
  if state.bufnr and state.extmark then
    pcall(vim.api.nvim_buf_del_extmark, state.bufnr, state.ns, state.extmark)
  end
  state.extmark = nil
  state.text = nil
  state.bufnr = nil
  state.row = nil
  state.col = nil
end

local function build_completion_prompt(input)
  local file_path = input.file_path
  local filetype = input.filetype
  local file_text = input.file_text
  local cursor = input.cursor
  
  return {
    "You are an INLINE CODE COMPLETION engine.",
    "",
    "You are given FULL contents of the current file and cursor position.",
    "Your task:",
    "- Predict what user is most likely to type NEXT from this cursor position.",
    "- ONLY continue the code locally from the cursor.",
    "- DO NOT rewrite or reformat existing lines above.",
    "- DO NOT modify or mention other files.",
    "- DO NOT include explanations or commentary.",
    "- DO NOT use markdown or backticks.",
    "- Output ONLY the raw code to insert.",
    "",
    "Constraints:",
    "- At most ~8 lines of code.",
    "- Stay consistent with the existing style and filetype.",
    "",
    "File path: " .. file_path,
    "Filetype: " .. filetype,
    "Cursor (0-based): row=" .. cursor.row .. ", col=" .. cursor.col,
    "",
    "<file>",
    file_text,
    "</file>",
  }
end

local function start_server()
  if state.initializing or state.ready then
    return
  end
  
  state.initializing = true
  set_status("initializing")
  
  local port = state.server_url:match(":(%d+)$") or "4097"
  vim.notify("OpenCode inline: starting server on port " .. port .. "…", vim.log.levels.INFO, { title = "OpenCode" })
  
  -- Use shell command to start server in background without --model flag
  local cmd = string.format("opencode serve --port %s > /tmp/opencode-%s.log 2>&1 &", port, port)
  vim.fn.system(cmd)
  
  local poll_count = 0
  local max_polls = 20
  local poll_interval = 500

  local timer = vim.loop.new_timer()
  timer:start(poll_interval, poll_interval, function()
    vim.schedule(function()
      poll_count = poll_count + 1
      
      if poll_count > max_polls then
        timer:close()
        state.initializing = false
        set_status("error")
        vim.notify("OpenCode server: timeout. Check /tmp/opencode-" .. port .. ".log", vim.log.levels.ERROR, { title = "OpenCode" })
        return
      end

      vim.system(
        { "curl", "-s", "http://127.0.0.1:" .. port .. "/config" },
        { timeout = 1000 },
        function(obj)
          vim.schedule(function()
            if obj.code == 0 then
              timer:close()
              state.initializing = false
              state.ready = true
              set_status("ready")
              local browser_url = "http://localhost:" .. port
              vim.notify(
                "OpenCode inline: ready! Monitor at: " .. browser_url,
                vim.log.levels.INFO,
                { title = "OpenCode" }
              )
            end
          end)
        end
      )
    end)
  end)
end

local function stop_server()
  if state.server_pid then
    vim.fn.system("kill " .. state.server_pid .. " 2>/dev/null")
    state.server_pid = nil
  end
  
  vim.fn.system("pkill -f 'opencode.*--port 4097' 2>/dev/null")
  state.ready = false
  set_status("off")
end

vim.keymap.set("n", "<leader>oi", function()
  start_server()
end, { desc = "Start OpenCode inline server" })

vim.keymap.set("n", "<leader>os", function()
  if state.ready then
    local browser_url = state.server_url:gsub("http://", "https://"):gsub("127%.0%.0%.1", "localhost")
    vim.notify("OpenCode server running! Monitor at: " .. browser_url, vim.log.levels.INFO, { title = "OpenCode" })
  else
    vim.notify("OpenCode server not running. Use <leader>oi to start it.", vim.log.levels.WARN, { title = "OpenCode" })
  end
end, { desc = "Check OpenCode server status" })

vim.keymap.set("n", "<leader>ok", function()
  stop_server()
  vim.notify("OpenCode server stopped", vim.log.levels.INFO, { title = "OpenCode" })
end, { desc = "Stop OpenCode inline server" })

local function get_suggestion_async(bufnr, row, col, cb)
  if not state.ready then
    cb(nil)
    return
  end

  local fullpath = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local file_text = table.concat(lines, "\n")

  local line = lines[row + 1] or ""
  -- removed heuristic for empty lines to see if it helps
  
  local prompt = table.concat(build_completion_prompt({
    file_path = fullpath,
    filetype = filetype,
    file_text = file_text,
    cursor = { row = row, col = col }
  }), "\n")
  
  local cmd = string.format('unset DISPLAY && unset WAYLAND_DISPLAY && unset XDG_SESSION_TYPE && unset XDG_CURRENT_DESKTOP && opencode run --model opencode/big-pickle --format json --attach %s', state.server_url)
  
  vim.system(
    { "sh", "-c", cmd },
    { 
      stdin = prompt,
      timeout = 15000
    },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          if obj.stderr and obj.stderr ~= "" then
            print("OpenCode error (exit " .. obj.code .. "): " .. obj.stderr)
          end
          cb(nil)
          return
        end

        local completion = ""
        local raw_output = obj.stdout or ""
        for line in raw_output:gmatch("[^\r\n]+") do
          local trimmed = line:match("^%s*(.-)%s*$")
          if trimmed and trimmed ~= "" then
            local ok, data = pcall(vim.json.decode, trimmed)
            if ok and data.type == "text" and data.part and data.part.text then
              completion = completion .. data.part.text
            end
          end
        end

        if completion == "" then
          -- Maybe it's not in JSON format or no text parts?
          -- Check if it's just raw text (though we requested --format json)
          if raw_output ~= "" and not raw_output:match("^{") then
            completion = raw_output
          end
        end

        -- For now, just trim trailing whitespace but keep newlines
        completion = completion:gsub("%s+$", "")
        if completion == "" then
          cb(nil)
          return
        end

        print("Ghost debug: completion: '" .. completion:sub(1, 30):gsub("\n", "\\n") .. "...' (" .. #completion .. " chars)")
        cb(completion)
      end)
    end
  )
end

local function show_ghost(bufnr, row, col, text)
  clear_ghost()

  state.bufnr = bufnr
  state.row = row
  state.col = col
  state.text = text

  -- Strip leading newlines for display so it shows up next to cursor
  local display_text = text:gsub("^\n+", "")
  local lines = vim.split(display_text, "\n", { plain = true })
  
  local opts = {
    virt_text_pos = "inline",
    hl_mode = "combine",
  }

  if #lines > 0 and lines[1] ~= "" then
    opts.virt_text = { { lines[1], "Comment" } }
  end

  if #lines > 1 then
    opts.virt_lines = {}
    for i = 2, #lines do
      table.insert(opts.virt_lines, { { lines[i], "Comment" } })
    end
  end

  local ok, extmark = pcall(vim.api.nvim_buf_set_extmark, bufnr, state.ns, row, col, opts)

  if not ok then
    opts.virt_text_pos = "eol"
    opts.virt_text = { { lines[1] or "...", "Comment" } }
    ok, extmark = pcall(vim.api.nvim_buf_set_extmark, bufnr, state.ns, row, col, opts)
  end

  if ok then
    state.extmark = extmark
  end
end

function M.accept()
  if not (state.bufnr and state.text and state.row and state.col) then
    return false
  end

  local bufnr = state.bufnr
  local row = state.row
  local col = state.col
  local text = state.text

  -- Split text into lines for nvim_buf_set_text
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)

  -- Calculate new cursor position
  local new_row = row + #lines - 1
  local last_line_len = #lines[#lines]
  local new_col = ( #lines > 1 and last_line_len or (col + last_line_len) )
  
  -- Move cursor
  vim.api.nvim_win_set_cursor(0, { new_row + 1, new_col })

  clear_ghost()
  return true
end

local function request_suggestion()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row = pos[1] - 1
  local col = pos[2]

  state.request_id = state.request_id + 1
  local this_id = state.request_id

  get_suggestion_async(bufnr, row, col, function(suggestion)
    vim.schedule(function()
      if this_id ~= state.request_id then
        return
      end

      if vim.api.nvim_get_current_buf() ~= bufnr then
        return
      end

      local cur = vim.api.nvim_win_get_cursor(0)
      local cur_row = cur[1] - 1
      local cur_col = cur[2]
      if cur_row ~= row or cur_col ~= col then
        return
      end

      if not suggestion or suggestion == "" then
        clear_ghost()
        return
      end

      show_ghost(bufnr, row, col, suggestion)
    end)
  end)
end

local function schedule_suggestion()
  clear_timer()
  clear_ghost()

  state.timer = vim.loop.new_timer()
  state.timer:start(
    M.config.idle_ms,
    0,
    vim.schedule_wrap(function()
      request_suggestion()
    end)
  )
end

function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})

  set_status("off")

  vim.keymap.set("i", M.config.accept_key, function()
    M.accept()
  end, { noremap = true, silent = true, desc = "Accept ghost inline completion" })

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "InsertCharPre" }, {
    callback = function()
      schedule_suggestion()
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    callback = function()
      clear_timer()
      clear_ghost()
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    callback = function()
      clear_ghost()
    end,
  })

  vim.api.nvim_create_autocmd("VimLeave", {
    callback = function()
      stop_server()
    end,
  })

  vim.api.nvim_create_autocmd("VimEnter", {
    callback = function()
      start_server()
    end,
  })
end

return M
