-----------------------------------------------------------
-- pi chat: orchestration, event dispatch, message logic
-----------------------------------------------------------
local rpc = require("custom.pi_chat.rpc")
local ui = require("custom.pi_chat.ui")

local M = {}

local state = {
	streaming = false,
	initialized = false,
	model_name = nil,
	keymaps_set = false,
}

local function title()
	local t = " pi"
	if state.model_name then t = t .. " (" .. state.model_name .. ")" end
	if state.streaming then t = t .. " ⟳" end
	return t .. " "
end

local function update_title()
	ui.set_title(title())
end

local function handle_event(event)
	local t = event.type
	if not t then return end

	-- Command responses
	if t == "response" then
		if event.command == "get_state" and event.success and event.data then
			if event.data.model then
				state.model_name = event.data.model.name or event.data.model.id
				update_title()
			end
			state.streaming = event.data.isStreaming or false
		end
		if not event.success and event.error then
			ui.append_lines({ "", "**Error**: " .. event.error })
		end
		return
	end

	-- Agent lifecycle
	if t == "agent_start" then
		state.streaming = true
		update_title()
		return
	end
	if t == "agent_end" then
		state.streaming = false
		update_title()
		return
	end

	-- Streaming assistant text
	if t == "message_update" then
		local ame = event.assistantMessageEvent
		if not ame then return end
		if ame.type == "text_start" then
			ui.append_lines({ "", "" })
		elseif ame.type == "text_delta" then
			ui.append(ame.delta)
		end
		return
	end

	-- Tool execution
	if t == "tool_execution_start" then
		local name = event.toolName or "tool"
		local detail = ""
		if event.args then
			if event.toolName == "bash" and event.args.command then
				detail = " `" .. event.args.command .. "`"
			elseif event.args.path then
				detail = " " .. event.args.path
			end
		end
		ui.append_lines({ "", "⚙ " .. name .. detail })
		return
	end
	if t == "tool_execution_end" then
		if event.isError and event.result and event.result.content then
			for _, c in ipairs(event.result.content) do
				if c.type == "text" and c.text then
					ui.append_lines({ "  ✗ " .. c.text:sub(1, 200) })
					break
				end
			end
		end
		return
	end

	-- Compaction
	if t == "compaction_start" then
		ui.append_lines({ "", "⟳ compacting context…" })
	elseif t == "compaction_end" then
		ui.append_lines({ "✓ context compacted" })
	end
end

local function setup_keymaps()
	if state.keymaps_set then return end
	state.keymaps_set = true

	local input = ui.input_buf()
	local response = ui.response_buf()
	if not input then return end

	-- Enter sends message (normal + insert) in input buffer
	vim.keymap.set({ "n", "i" }, "<CR>", function()
		M.send()
	end, { buffer = input, desc = "Send to pi" })

	for _, buf in ipairs({ input, response }) do
		if buf and vim.api.nvim_buf_is_valid(buf) then
			-- Esc in normal mode closes the float
			vim.keymap.set("n", "<Esc>", function()
				ui.close()
			end, { buffer = buf, desc = "Close pi chat" })

			-- Tab switches between response and input panes
			vim.keymap.set("n", "<Tab>", function()
				if not ui.is_open() then return end
				local cur = vim.api.nvim_get_current_win()
				if cur == ui.input_win() then
					local rw = ui.response_win()
					if rw then vim.api.nvim_set_current_win(rw) end
				else
					local iw = ui.input_win()
					if iw then
						vim.api.nvim_set_current_win(iw)
						vim.cmd("startinsert")
					end
				end
			end, { buffer = buf, desc = "Switch pi chat pane" })

			-- Ctrl-C aborts the current agent operation
			vim.keymap.set({ "n", "i" }, "<C-c>", function()
				M.abort()
			end, { buffer = buf, desc = "Abort pi agent" })
		end
	end
end

function M.toggle()
	-- Lazy-start the pi process on first toggle
	if not state.initialized then
		local ok = rpc.spawn({
			on_event = handle_event,
			on_exit = function(code)
				state.initialized = false
				state.streaming = false
				state.keymaps_set = false
				vim.notify("pi exited (" .. (code or "?") .. ")", vim.log.levels.WARN)
			end,
		})
		if not ok then
			vim.notify("Failed to start pi — is it installed?", vim.log.levels.ERROR)
			return
		end
		state.initialized = true
		rpc.send({ type = "get_state" })
	end

	if ui.is_open() then
		ui.close()
	else
		ui.open(title())
		setup_keymaps()
	end
end

function M.send()
	local text = vim.trim(ui.get_input())
	if text == "" then return end

	ui.clear_input()

	-- Echo user message with blank separator (skip if buffer is empty)
	if ui.is_empty() then
		ui.append_lines({ "> " .. text })
	else
		ui.append_lines({ "", "> " .. text })
	end

	if state.streaming then
		rpc.send({ type = "prompt", message = text, streamingBehavior = "steer" })
	else
		rpc.send({ type = "prompt", message = text })
	end

	vim.cmd("startinsert")
end

function M.abort()
	if state.streaming then
		rpc.send({ type = "abort" })
		vim.notify("Aborting pi agent…", vim.log.levels.INFO)
	end
end

function M.cleanup()
	rpc.kill()
	state.initialized = false
	state.streaming = false
	state.keymaps_set = false
end

return M
