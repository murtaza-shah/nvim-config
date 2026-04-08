-----------------------------------------------------------
-- pi RPC subprocess: spawn, JSONL framing, send/receive
-----------------------------------------------------------
local M = {}

local state = {
	job_id = nil,
	buffer = "",
	on_event = nil,
	on_exit = nil,
}

function M.spawn(opts)
	if state.job_id then return true end

	state.on_event = opts.on_event
	state.on_exit = opts.on_exit
	state.buffer = ""

	state.job_id = vim.fn.jobstart({ "pi", "--mode", "rpc", "--no-session" }, {
		on_stdout = function(_, data)
			if not data then return end
			-- JSONL framing: prepend leftover from previous chunk
			data[1] = state.buffer .. data[1]
			-- Last element is always the incomplete tail
			state.buffer = data[#data]

			for i = 1, #data - 1 do
				local line = data[i]
				-- Strip optional trailing \r per RPC spec
				if line:sub(-1) == "\r" then line = line:sub(1, -2) end
				if line ~= "" then
					local ok, parsed = pcall(vim.json.decode, line)
					if ok and state.on_event then
						state.on_event(parsed)
					end
				end
			end
		end,
		on_stderr = function() end,
		on_exit = function(_, code)
			state.job_id = nil
			state.buffer = ""
			if state.on_exit then state.on_exit(code) end
		end,
		stdin = "pipe",
	})

	return state.job_id ~= nil and state.job_id > 0
end

function M.send(cmd)
	if not state.job_id then return false end
	vim.fn.chansend(state.job_id, vim.json.encode(cmd) .. "\n")
	return true
end

function M.is_alive()
	return state.job_id ~= nil and state.job_id > 0
end

function M.kill()
	if state.job_id then
		vim.fn.jobstop(state.job_id)
		state.job_id = nil
		state.buffer = ""
	end
end

return M
