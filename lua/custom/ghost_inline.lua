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
	-- Review mode state
	review       = {
		active = false,
		bufnr = nil,
		changes = {}, -- List of {search=string, replace=string}
		current_idx = 0, -- Current change being reviewed (1-indexed)
		extmarks = {}, -- Extmarks for current preview
	},
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
						vim.notify(
							"OpenCode server exited unexpectedly (code " .. exit_code .. ")",
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
								"OpenCode inline: ready! Monitor at: http://localhost:" ..
								port,
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

local function reset_session()
	state.session_id = nil
	set_status("ready (new session)")
	vim.notify("OpenCode: session reset. Next completion will start a new conversation.",
		vim.log.levels.INFO, { title = "OpenCode" })
	-- Reset status back to just "ready" after a short delay
	vim.defer_fn(function()
		if state.ready then
			set_status("ready")
		end
	end, 2000)
end

-- ============================================================================
-- SEARCH/REPLACE Block Review System
-- ============================================================================

local function parse_search_replace_blocks(text)
	local blocks = {}
	-- Pattern to match SEARCH/REPLACE blocks
	-- Handles empty REPLACE sections (for deletions)
	-- Uses frontier pattern to avoid greediness issues
	local pattern = "<<<<<<<[%s]*SEARCH[^\n]*\n(.-)\n=======[^\n]*\n(.-)>>>>>>>%s*REPLACE"

	for search, replace in text:gmatch(pattern) do
		-- Trim trailing whitespace/newlines from both parts
		search = search:gsub("%s+$", "")
		replace = replace:gsub("^%s*\n", ""):gsub("%s+$", "") -- Also trim leading newline from replace
		table.insert(blocks, {
			search = search,
			replace = replace,
		})
	end

	return blocks
end

local function clear_review_extmarks()
	if state.review.bufnr then
		for _, id in ipairs(state.review.extmarks) do
			pcall(vim.api.nvim_buf_del_extmark, state.review.bufnr, state.ns, id)
		end
	end
	state.review.extmarks = {}
end

local function exit_review_mode(message)
	clear_review_extmarks()
	state.review.active = false
	state.review.changes = {}
	state.review.current_idx = 0
	state.review.bufnr = nil
	set_status(state.ready and "ready" or "off")
	if message then
		vim.notify(message, vim.log.levels.INFO, { title = "OpenCode" })
	end
end

local function find_text_in_buffer(bufnr, search_text)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local search_lines = vim.split(search_text, "\n", { plain = true })

	-- Search line by line for the start of the match
	for i, line in ipairs(lines) do
		local col = line:find(search_lines[1], 1, true)
		if col then
			-- Check if this is a full match (for multi-line search)
			local match = true
			if #search_lines > 1 then
				for j = 2, #search_lines do
					local check_line = lines[i + j - 1]
					if not check_line then
						match = false
						break
					end
					-- For middle lines, must match exactly
					-- For last line, must start with the search text
					if j == #search_lines then
						if not check_line:find(search_lines[j], 1, true) then
							match = false
							break
						end
					else
						if check_line ~= search_lines[j] then
							match = false
							break
						end
					end
				end
			end

			if match then
				local start_row = i - 1 -- 0-indexed
				local start_col = col - 1 -- 0-indexed
				local end_row = start_row + #search_lines - 1
				local end_col
				if #search_lines == 1 then
					end_col = start_col + #search_lines[1]
				else
					end_col = #search_lines[#search_lines]
				end

				-- Clamp end_col to line length
				local end_line = lines[end_row + 1] or ""
				end_col = math.min(end_col, #end_line)

				return {
					start_row = start_row,
					start_col = start_col,
					end_row = end_row,
					end_col = end_col,
				}
			end
		end
	end

	return nil
end

local function show_review_preview()
	clear_review_extmarks()

	local change = state.review.changes[state.review.current_idx]
	if not change then
		exit_review_mode("No more changes to review")
		return
	end

	local bufnr = state.review.bufnr
	local pos = find_text_in_buffer(bufnr, change.search)

	if not pos then
		vim.notify(
			string.format("Change %d/%d: Could not find search text in buffer. Skipping.",
				state.review.current_idx, #state.review.changes),
			vim.log.levels.WARN, { title = "OpenCode" }
		)
		-- Auto-skip to next
		state.review.current_idx = state.review.current_idx + 1
		if state.review.current_idx > #state.review.changes then
			exit_review_mode("Review complete!")
		else
			show_review_preview()
		end
		return
	end

	-- Jump to the location (clamp col to valid range)
	local line = vim.api.nvim_buf_get_lines(bufnr, pos.start_row, pos.start_row + 1, false)[1] or ""
	local safe_col = math.min(pos.start_col, math.max(0, #line - 1))
	vim.api.nvim_win_set_cursor(0, { pos.start_row + 1, safe_col })

	-- Highlight the text being replaced (strikethrough/dim effect)
	local end_line = vim.api.nvim_buf_get_lines(bufnr, pos.end_row, pos.end_row + 1, false)[1] or ""
	local safe_end_col = math.min(pos.end_col, #end_line)
	local dim_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns, pos.start_row, pos.start_col, {
		end_row = pos.end_row,
		end_col = safe_end_col,
		hl_group = "DiffDelete",
	})
	table.insert(state.review.extmarks, dim_id)

	-- Show the replacement as virtual text
	local replace_lines = vim.split(change.replace, "\n", { plain = true })
	local virt_lines = {}
	for _, line in ipairs(replace_lines) do
		table.insert(virt_lines, { { line, "DiffAdd" } })
	end

	local virt_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns, pos.end_row, 0, {
		virt_lines = virt_lines,
		virt_lines_above = false,
	})
	table.insert(state.review.extmarks, virt_id)

	-- Update status
	set_status(string.format("Review %d/%d: <C-l> accept, <C-n> skip, <Esc> cancel",
		state.review.current_idx, #state.review.changes))
end

local function apply_current_change()
	local change = state.review.changes[state.review.current_idx]
	if not change then return end

	local bufnr = state.review.bufnr
	local pos = find_text_in_buffer(bufnr, change.search)

	if not pos then
		vim.notify("Could not find text to replace", vim.log.levels.WARN, { title = "OpenCode" })
		return false
	end

	-- Apply the replacement
	local replace_lines = vim.split(change.replace, "\n", { plain = true })
	-- Clamp end_col to line length
	local end_line = vim.api.nvim_buf_get_lines(bufnr, pos.end_row, pos.end_row + 1, false)[1] or ""
	local safe_end_col = math.min(pos.end_col, #end_line)
	vim.api.nvim_buf_set_text(
		bufnr,
		pos.start_row, pos.start_col,
		pos.end_row, safe_end_col,
		replace_lines
	)

	return true
end

function M.review_accept()
	if not state.review.active then return false end

	local success = apply_current_change()
	if success then
		vim.notify(string.format("Applied change %d/%d",
				state.review.current_idx, #state.review.changes),
			vim.log.levels.INFO, { title = "OpenCode" })
	end

	-- Move to next change
	state.review.current_idx = state.review.current_idx + 1
	if state.review.current_idx > #state.review.changes then
		exit_review_mode("Review complete!")
	else
		show_review_preview()
	end

	return true
end

function M.review_skip()
	if not state.review.active then return false end

	vim.notify(string.format("Skipped change %d/%d",
			state.review.current_idx, #state.review.changes),
		vim.log.levels.INFO, { title = "OpenCode" })

	state.review.current_idx = state.review.current_idx + 1
	if state.review.current_idx > #state.review.changes then
		exit_review_mode("Review complete!")
	else
		show_review_preview()
	end

	return true
end

function M.review_cancel()
	if not state.review.active then return false end
	exit_review_mode("Review cancelled")
	return true
end

local function start_review_mode(bufnr, changes)
	if #changes == 0 then
		vim.notify("No changes to review", vim.log.levels.WARN, { title = "OpenCode" })
		return
	end

	state.review.active = true
	state.review.bufnr = bufnr
	state.review.changes = changes
	state.review.current_idx = 1

	vim.notify(string.format("Starting review of %d change(s). <C-l> accept, <C-n> skip, <Esc> cancel",
		#changes), vim.log.levels.INFO, { title = "OpenCode" })

	show_review_preview()
end

local function build_edit_prompt(file_path, filetype, file_content, user_message)
	return table.concat({
		"You are a code editing engine. Output ONLY SEARCH/REPLACE blocks. NO PROSE. NO EXPLANATIONS.",
		"",
		"FILE: " .. file_path .. " (" .. filetype .. ")",
		"```",
		file_content,
		"```",
		"",
		"REQUEST: " .. user_message,
		"",
		"OUTPUT FORMAT (output NOTHING else, no text before or after):",
		"<<<<<<< SEARCH",
		"exact text from file",
		"=======",
		"replacement text",
		">>>>>>> REPLACE",
		"",
		"CRITICAL RULES:",
		"- Output RAW SEARCH/REPLACE blocks ONLY",
		"- NO explanations, NO commentary, NO markdown outside the blocks",
		"- SEARCH text must match file EXACTLY (same indentation, same whitespace)",
		"- Multiple blocks allowed for multiple changes",
		"- To insert new code: SEARCH for a nearby unique line, REPLACE with that line + new code",
		"- To delete code: SEARCH for the code, REPLACE with empty",
		"- Start your response with <<<<<<< SEARCH",
	}, "\n")
end

local function send_edit_message(user_message, cb)
	if not state.ready then
		vim.notify("OpenCode server not ready. Use <leader>oi to start it.", vim.log.levels.WARN,
			{ title = "OpenCode" })
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local fullpath = vim.api.nvim_buf_get_name(bufnr)
	local filetype = vim.bo[bufnr].filetype
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local file_content = table.concat(lines, "\n")

	local prompt = build_edit_prompt(fullpath, filetype, file_content, user_message)

	set_status("thinking...")

	local cmd_args = {
		"opencode", "run",
		"--model", M.config.model,
		"--format", "json",
		"--attach", state.server_url,
	}

	if state.session_id then
		table.insert(cmd_args, "--session")
		table.insert(cmd_args, state.session_id)
	end

	vim.system(
		cmd_args,
		{
			stdin = prompt,
			timeout = 60000 -- Longer timeout for complex edits
		},
		function(obj)
			vim.schedule(function()
				set_status(state.ready and "ready" or "off")

				if obj.code ~= 0 then
					vim.notify("OpenCode error: " .. (obj.stderr or "unknown error"),
						vim.log.levels.ERROR, { title = "OpenCode" })
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
							if data.sessionID and not state.session_id then
								state.session_id = data.sessionID
							end
							if data.type == "text" and data.part and data.part.text then
								completion = completion .. data.part.text
							end
						end
					end
				end

				if completion == "" then
					vim.notify("OpenCode: no response received", vim.log.levels.WARN,
						{ title = "OpenCode" })
					cb(nil)
					return
				end

				cb(completion, bufnr)
			end)
		end
	)
end

local function prompt_and_edit()
	vim.ui.input({ prompt = "OpenCode Edit > " }, function(input)
		if not input or input == "" then
			return
		end

		send_edit_message(input, function(response, bufnr)
			if not response then
				return
			end

			local changes = parse_search_replace_blocks(response)

			if #changes == 0 then
				-- Fallback: maybe model returned raw code, try to insert at cursor
				vim.notify("No SEARCH/REPLACE blocks found in response. Raw response:\n" ..
					response:sub(1, 200) .. (response:len() > 200 and "..." or ""),
					vim.log.levels.WARN, { title = "OpenCode" })
				return
			end

			start_review_mode(bufnr, changes)
		end)
	end)
end

local function send_message(user_message, cb)
	if not state.ready then
		vim.notify("OpenCode server not ready. Use <leader>oi to start it.", vim.log.levels.WARN,
			{ title = "OpenCode" })
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local fullpath = vim.api.nvim_buf_get_name(bufnr)
	local filetype = vim.bo[bufnr].filetype
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local file_content = table.concat(lines, "\n")

	local prompt = table.concat({
		"You are a code assistant. The user is working on a file and has a request.",
		"",
		"CONTEXT:",
		"File path: " .. fullpath,
		"Filetype: " .. filetype,
		"",
		"CURRENT FILE CONTENT:",
		"```" .. filetype,
		file_content,
		"```",
		"",
		"USER REQUEST:",
		user_message,
		"",
		"INSTRUCTIONS:",
		"- Output ONLY the code that should be inserted at the cursor.",
		"- DO NOT include explanations, commentary, or markdown fences.",
		"- Output RAW code only.",
	}, "\n")

	set_status("thinking...")

	local cmd_args = {
		"opencode", "run",
		"--model", M.config.model,
		"--format", "json",
		"--attach", state.server_url,
	}

	if state.session_id then
		table.insert(cmd_args, "--session")
		table.insert(cmd_args, state.session_id)
	end

	vim.system(
		cmd_args,
		{
			stdin = prompt,
			timeout = 30000
		},
		function(obj)
			vim.schedule(function()
				set_status(state.ready and "ready" or "off")

				if obj.code ~= 0 then
					vim.notify("OpenCode error: " .. (obj.stderr or "unknown error"),
						vim.log.levels.ERROR, { title = "OpenCode" })
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
							if data.sessionID and not state.session_id then
								state.session_id = data.sessionID
							end
							if data.type == "text" and data.part and data.part.text then
								completion = completion .. data.part.text
							end
						end
					end
				end

				completion = completion:gsub("%s+$", "")
				if completion == "" then
					vim.notify("OpenCode: no response received", vim.log.levels.WARN,
						{ title = "OpenCode" })
					cb(nil)
					return
				end

				cb(completion)
			end)
		end
	)
end

local function prompt_and_insert()
	vim.ui.input({ prompt = "OpenCode > " }, function(input)
		if not input or input == "" then
			return
		end

		local bufnr = vim.api.nvim_get_current_buf()
		local pos = vim.api.nvim_win_get_cursor(0)
		local row = pos[1] - 1
		local col = pos[2]

		send_message(input, function(response)
			if not response then
				return
			end

			-- Insert at cursor position
			local lines = vim.split(response, "\n", { plain = true })
			vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)

			-- Move cursor to end of inserted text
			local new_row = row + #lines - 1
			local last_line_len = #lines[#lines]
			local new_col = (#lines > 1 and last_line_len or (col + last_line_len))
			vim.api.nvim_win_set_cursor(0, { new_row + 1, new_col })

			vim.notify("OpenCode: inserted " .. #lines .. " line(s)", vim.log.levels.INFO,
				{ title = "OpenCode" })
		end)
	end)
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

	vim.keymap.set("n", "<leader>or", function()
		reset_session()
	end, { desc = "Reset OpenCode session (start fresh conversation)" })

	vim.keymap.set("n", "<leader>om", function()
		prompt_and_edit()
	end, { desc = "Send edit request to OpenCode (multi-block review)" })

	-- Review mode keymaps (active during change review)
	vim.keymap.set("n", "<C-l>", function()
		if state.review.active then
			M.review_accept()
		end
	end, { desc = "Accept current change (review mode)" })

	vim.keymap.set("n", "<C-n>", function()
		if state.review.active then
			M.review_skip()
		end
	end, { desc = "Skip current change (review mode)" })

	vim.keymap.set("n", "<Esc>", function()
		if state.review.active then
			M.review_cancel()
			return
		end
		-- Fall through to default <Esc> behavior
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
	end, { desc = "Cancel review / normal Esc" })

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
