local M = {}

M.config = {
	idle_ms = 400,
	accept_key = "<C-l>",
	model = "opencode/big-pickle"
}

local state = {
	ns           = vim.api.nvim_create_namespace("ghost_inline"),
	timer        = nil,
	bufnr        = nil,
	row          = nil,
	col          = nil,
	text         = nil,
	extmark      = nil,
	dim_extmark  = nil,
	request_id   = 0,
	initializing = false,
	ready        = false,
	server_url   = "http://127.0.0.1:4097",
	server_job   = nil,
	session_id   = nil,
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
	if state.bufnr then
		if state.extmark then
			pcall(vim.api.nvim_buf_del_extmark, state.bufnr, state.ns, state.extmark)
		end
		if state.dim_extmark then
			pcall(vim.api.nvim_buf_del_extmark, state.bufnr, state.ns, state.dim_extmark)
		end
	end
	state.extmark = nil
	state.dim_extmark = nil
	state.text = nil
	state.bufnr = nil
	state.row = nil
	state.col = nil
end

local function build_completion_prompt(input)
	return {
		"You are an INLINE CODE COMPLETION engine.",
		"Your task is to predict the code that should be inserted at the cursor position.",
		"",
		"CONTEXT:",
		"File path: " .. input.file_path,
		"Filetype: " .. input.filetype,
		"",
		"CODE BEFORE CURSOR (PREFIX):",
		"<prefix>",
		input.prefix,
		"</prefix>",
		"",
		"CODE AFTER CURSOR (SUFFIX):",
		"<suffix>",
		input.suffix,
		"</suffix>",
		"",
		"INSTRUCTIONS:",
		"- Predict what the user is likely to type at the cursor.",
		"- You can replace parts of the SUFFIX if needed to maintain consistency (e.g., if you are updating a function signature and the body needs to change).",
		"- Output ONLY the code to be inserted at the cursor position.",
		"- If your code replaces parts of the SUFFIX, ensure it blends perfectly.",
		"- DO NOT include explanations, commentary, or markdown.",
		"- Output RAW code only.",
		"- If the suggestion would be >20 lines, respond with 20 lines at a time until the full suggestion has been added.",
	}
end

local function get_port()
	return state.server_url:match(":(%d+)$") or "4097"
end

local function start_server()
	if state.initializing or state.ready then
		return
	end

	state.initializing = true
	set_status("initializing")

	local port = get_port()
	vim.notify("OpenCode inline: starting server on port " .. port .. "...", vim.log.levels.INFO,
		{ title = "OpenCode" })

	-- Use jobstart for proper process management
	state.server_job = vim.fn.jobstart(
		{ "opencode", "serve", "--port", port },
		{
			on_exit = function(_, exit_code)
				vim.schedule(function()
					if exit_code ~= 0 and state.ready then
						vim.notify("OpenCode server exited unexpectedly (code " .. exit_code .. ")",
							vim.log.levels.WARN, { title = "OpenCode" })
					end
					state.ready = false
					state.server_job = nil
					state.session_id = nil
					set_status("off")
				end)
			end,
			-- Detach stdout/stderr to avoid blocking
			detach = true,
		}
	)

	if state.server_job <= 0 then
		state.initializing = false
		set_status("error")
		vim.notify("OpenCode: failed to start server", vim.log.levels.ERROR, { title = "OpenCode" })
		return
	end

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
				vim.notify("OpenCode server: timeout waiting for server to be ready",
					vim.log.levels.ERROR, { title = "OpenCode" })
				return
			end

			vim.system(
				{ "curl", "-s", "http://127.0.0.1:" .. port .. "/config" },
				{ timeout = 1000 },
				function(obj)
					vim.schedule(function()
						if obj.code == 0 and state.initializing then
							timer:close()
							state.initializing = false
							state.ready = true
							set_status("ready")
							vim.notify(
								"OpenCode inline: ready! Monitor at: http://localhost:" .. port,
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
	if state.server_job then
		vim.fn.jobstop(state.server_job)
		state.server_job = nil
	end
	state.ready = false
	state.session_id = nil
	set_status("off")
end

local function get_suggestion_async(bufnr, row, col, cb)
	if not state.ready then
		cb(nil)
		return
	end

	local fullpath = vim.api.nvim_buf_get_name(bufnr)
	local filetype = vim.bo[bufnr].filetype

	-- Split buffer into prefix and suffix
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local prefix_lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
	local current_line = lines[row + 1] or ""
	table.insert(prefix_lines, current_line:sub(1, col))
	local prefix = table.concat(prefix_lines, "\n")

	local suffix_lines = { current_line:sub(col + 1) }
	local remaining_lines = vim.api.nvim_buf_get_lines(bufnr, row + 1, -1, false)
	for _, l in ipairs(remaining_lines) do table.insert(suffix_lines, l) end
	local suffix = table.concat(suffix_lines, "\n")

	local prompt = table.concat(build_completion_prompt({
		file_path = fullpath,
		filetype = filetype,
		prefix = prefix,
		suffix = suffix,
	}), "\n")

	-- Build command args
	local cmd_args = {
		"opencode", "run",
		"--model", M.config.model,
		"--format", "json",
		"--attach", state.server_url,
	}

	-- Reuse session if we have one (avoids creating new conversations)
	if state.session_id then
		table.insert(cmd_args, "--session")
		table.insert(cmd_args, state.session_id)
	end

	vim.system(
		cmd_args,
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
						if ok then
							-- Capture session ID from any event (they all include it)
							if data.sessionID and not state.session_id then
								state.session_id = data.sessionID
							end
							-- Extract text content
							if data.type == "text" and data.part and data.part.text then
								completion = completion .. data.part.text
							end
						end
					end
				end

				if completion == "" then
					if raw_output ~= "" and not raw_output:match("^{") then
						completion = raw_output
					end
				end

				completion = completion:gsub("%s+$", "")
				if completion == "" then
					cb(nil)
					return
				end

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

	-- Dim the existing text that might be replaced
	-- We'll dim the next 10 lines or until end of buffer
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local end_row = math.min(row + 10, line_count - 1)

	state.dim_extmark = vim.api.nvim_buf_set_extmark(bufnr, state.ns, row, col, {
		end_row = end_row,
		end_col = #vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or 0,
		hl_group = "Comment", -- Dimming effect
	})

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
	local new_col = (#lines > 1 and last_line_len or (col + last_line_len))

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

	-- Accept completion keymap
	vim.keymap.set("i", M.config.accept_key, function()
		M.accept()
	end, { noremap = true, silent = true, desc = "Accept ghost inline completion" })

	-- Server control keymaps
	vim.keymap.set("n", "<leader>oi", function()
		start_server()
	end, { desc = "Start OpenCode inline server" })

	vim.keymap.set("n", "<leader>os", function()
		if state.ready then
			local port = get_port()
			vim.notify("OpenCode server running! Monitor at: http://localhost:" .. port, vim.log.levels.INFO,
				{ title = "OpenCode" })
		else
			vim.notify("OpenCode server not running. Use <leader>oi to start it.", vim.log.levels.WARN,
				{ title = "OpenCode" })
		end
	end, { desc = "Check OpenCode server status" })

	vim.keymap.set("n", "<leader>ok", function()
		stop_server()
		vim.notify("OpenCode server stopped", vim.log.levels.INFO, { title = "OpenCode" })
	end, { desc = "Stop OpenCode inline server" })

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
