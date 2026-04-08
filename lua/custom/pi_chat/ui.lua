-----------------------------------------------------------
-- pi chat UI: floating windows + buffer management
-----------------------------------------------------------
local M = {}

local INPUT_HEIGHT = 3

local state = {
	response_buf = nil,
	input_buf = nil,
	response_win = nil,
	input_win = nil,
}

local function buf_valid(b) return b and vim.api.nvim_buf_is_valid(b) end
local function win_valid(w) return w and vim.api.nvim_win_is_valid(w) end

local function ensure_buffers()
	if not buf_valid(state.response_buf) then
		state.response_buf = vim.api.nvim_create_buf(false, true)
		vim.bo[state.response_buf].buftype = "nofile"
		vim.bo[state.response_buf].filetype = "markdown"
		vim.bo[state.response_buf].swapfile = false
		vim.bo[state.response_buf].bufhidden = "hide"
		vim.api.nvim_buf_set_name(state.response_buf, "pi://chat")
	end
	if not buf_valid(state.input_buf) then
		state.input_buf = vim.api.nvim_create_buf(false, true)
		vim.bo[state.input_buf].buftype = "nofile"
		vim.bo[state.input_buf].swapfile = false
		vim.bo[state.input_buf].bufhidden = "hide"
		vim.api.nvim_buf_set_name(state.input_buf, "pi://input")
	end
end

function M.open(title)
	ensure_buffers()

	-- If already open, just focus input
	if M.is_open() then
		vim.api.nvim_set_current_win(state.input_win)
		vim.cmd("startinsert")
		return
	end

	local width = math.floor(vim.o.columns * 0.8)
	local total_h = math.floor(vim.o.lines * 0.8)
	local response_h = total_h - INPUT_HEIGHT - 2
	local row = math.floor((vim.o.lines - total_h) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	state.response_win = vim.api.nvim_open_win(state.response_buf, false, {
		relative = "editor",
		width = width,
		height = response_h,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = title or " pi ",
		title_pos = "center",
	})
	vim.wo[state.response_win].wrap = true
	vim.wo[state.response_win].linebreak = true
	vim.wo[state.response_win].cursorline = false

	state.input_win = vim.api.nvim_open_win(state.input_buf, true, {
		relative = "editor",
		width = width,
		height = INPUT_HEIGHT,
		row = row + response_h + 2,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " message ",
		title_pos = "left",
	})
	vim.wo[state.input_win].wrap = true

	M.scroll_to_bottom()
	vim.cmd("startinsert")
end

function M.close()
	if win_valid(state.response_win) then
		vim.api.nvim_win_close(state.response_win, true)
	end
	if win_valid(state.input_win) then
		vim.api.nvim_win_close(state.input_win, true)
	end
	state.response_win = nil
	state.input_win = nil
end

function M.is_open()
	return win_valid(state.response_win) and win_valid(state.input_win)
end

function M.is_empty()
	if not buf_valid(state.response_buf) then return true end
	local count = vim.api.nvim_buf_line_count(state.response_buf)
	local last = vim.api.nvim_buf_get_lines(state.response_buf, count - 1, count, false)[1] or ""
	return count == 1 and last == ""
end

function M.scroll_to_bottom()
	if not win_valid(state.response_win) or not buf_valid(state.response_buf) then return end
	local count = vim.api.nvim_buf_line_count(state.response_buf)
	pcall(vim.api.nvim_win_set_cursor, state.response_win, { count, 0 })
end

--- Append streaming text (continues from last line, handles embedded newlines)
function M.append(text)
	if not buf_valid(state.response_buf) or text == "" then return end
	local count = vim.api.nvim_buf_line_count(state.response_buf)
	local last = vim.api.nvim_buf_get_lines(state.response_buf, count - 1, count, false)[1] or ""
	local new_lines = vim.split(last .. text, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(state.response_buf, count - 1, count, false, new_lines)
	M.scroll_to_bottom()
end

--- Append complete lines after current content.
--- Each entry is split on newlines so callers don't have to worry about it.
function M.append_lines(lines)
	if not buf_valid(state.response_buf) or #lines == 0 then return end
	-- Flatten: split any element that contains embedded newlines
	local flat = {}
	for _, l in ipairs(lines) do
		for _, part in ipairs(vim.split(l, "\n", { plain = true })) do
			flat[#flat + 1] = part
		end
	end
	local count = vim.api.nvim_buf_line_count(state.response_buf)
	local last = vim.api.nvim_buf_get_lines(state.response_buf, count - 1, count, false)[1] or ""
	if count == 1 and last == "" then
		vim.api.nvim_buf_set_lines(state.response_buf, 0, -1, false, flat)
	else
		vim.api.nvim_buf_set_lines(state.response_buf, count, count, false, flat)
	end
	M.scroll_to_bottom()
end

function M.get_input()
	if not buf_valid(state.input_buf) then return "" end
	local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
	return table.concat(lines, "\n")
end

function M.clear_input()
	if not buf_valid(state.input_buf) then return end
	vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })
end

function M.set_title(title)
	if win_valid(state.response_win) then
		vim.api.nvim_win_set_config(state.response_win, { title = title, title_pos = "center" })
	end
end

function M.response_buf() return state.response_buf end
function M.input_buf() return state.input_buf end
function M.response_win() return state.response_win end
function M.input_win() return state.input_win end

-- If either window is closed externally, close the other too
vim.api.nvim_create_autocmd("WinClosed", {
	callback = function(args)
		local win = tonumber(args.match)
		if win and (win == state.response_win or win == state.input_win) then
			vim.schedule(function() M.close() end)
		end
	end,
})

return M
