-----------------------------------------------------------
-- Core keymaps (no plugin dependencies)
-----------------------------------------------------------

-- Reload current config file
vim.keymap.set("n", "<leader>so", ":update<CR>:source<CR>")

-- Save / quit
vim.keymap.set("n", "<leader>w", ":write<CR>")
vim.keymap.set("n", "<leader>q", ":quit<CR>")

-- Clipboard in visual mode
vim.keymap.set("v", "<leader>y", '"+y')
vim.keymap.set("v", "<leader>p", '"+P')
