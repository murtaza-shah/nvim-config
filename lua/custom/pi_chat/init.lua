-----------------------------------------------------------
-- pi agent chat plugin entry point
-----------------------------------------------------------
local M = {}

function M.setup()
	local chat = require("custom.pi_chat.chat")

	vim.keymap.set("n", "<leader>ac", function()
		chat.toggle()
	end, { desc = "Toggle pi agent chat" })

	vim.api.nvim_create_autocmd("VimLeave", {
		callback = function()
			chat.cleanup()
		end,
	})
end

return M
