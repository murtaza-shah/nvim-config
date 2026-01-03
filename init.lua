-- vim.o is shorthand for vim.opt
vim.o.number = true
vim.o.relativenumber = true
vim.o.wrap = false
vim.o.tabstop = 4
vim.o.swapfile = false

vim.g.mapleader = " "

-- syntax: mode, keybind, command
vim.keymap.set('n', '<leader>o', ':update<CR> :source<CR>')
vim.keymap.set('n', '<leader>w', ':write<CR>')
vim.keymap.set('n', '<leader>q', ':quit<CR>')
vim.keymap.set('n', '<leader>lf', vim.lsp.buf.format)

-- built-in package manager
vim.pack.add({
		{src = "https://github.com/vague2k/vague.nvim"},
		{src = "https://github.com/stevearc/oil.nvim"},
		{src = "https://github.com/echasnovski/mini.pick"},
		{src = "https://github.com/neovim/nvim-lspconfig"},
})

vim.cmd("colorscheme vague")
-- make statusline not have a bg color
vim.cmd(":hi statusline guibg=NONE")

-- lsp stuff
vim.lsp.enable({
		"lua_ls"
})
