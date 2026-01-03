-----------------------------------------------------------
-- Plugin management (built-in vim.pack)
-----------------------------------------------------------
vim.pack.add({
	-- UI / theme / basic tools
	{ src = "https://github.com/vague2k/vague.nvim" },
	{ src = "https://github.com/stevearc/oil.nvim" },
	{ src = "https://github.com/echasnovski/mini.pick" },

	-- LSP server definitions (no direct API use)
	{ src = "https://github.com/neovim/nvim-lspconfig" },

	-- LSP installer / manager
	{ src = "https://github.com/williamboman/mason.nvim" },
	{ src = "https://github.com/williamboman/mason-lspconfig.nvim" },

	-- Completion engine + sources
	{ src = "https://github.com/hrsh7th/nvim-cmp" },
	{ src = "https://github.com/hrsh7th/cmp-nvim-lsp" },
	{ src = "https://github.com/hrsh7th/cmp-buffer" },
	{ src = "https://github.com/hrsh7th/cmp-path" },

	-- Snippets
	{ src = "https://github.com/L3MON4D3/LuaSnip" },
	{ src = "https://github.com/saadparwaiz1/cmp_luasnip" },

	-- git gutter visualizations
	{ src = "https://github.com/lewis6991/gitsigns.nvim" },

	-- Treesitter
	{ src = "https://github.com/nvim-treesitter/nvim-treesitter" },
})

-----------------------------------------------------------
-- Basic plugin setup
-----------------------------------------------------------

-- mini.pick & oil
require("mini.pick").setup()
require("oil").setup()

-- gitsigns
require("gitsigns").setup({
	signs = {
		add          = { text = "+" },
		change       = { text = "│" },
		delete       = { text = "_" },
		topdelete    = { text = "‾" },
		changedelete = { text = "~" },
	},
})

-- Treesitter
local ok_ts, ts_configs = pcall(require, "nvim-treesitter.configs")
if ok_ts then
	ts_configs.setup({
		ensure_installed = {
			"lua",
			"go",
			"typescript",
			"tsx",
			"javascript",
			"python",
			"zig",
		},
		highlight = { enable = true },
		indent = { enable = true },
	})
end

-----------------------------------------------------------
-- Plugin-specific keymaps
-----------------------------------------------------------

-- mini.pick keymaps
vim.keymap.set("n", "<leader>f", ":Pick files<CR>")
vim.keymap.set("n", "<leader>h", ":Pick help<CR>")
vim.keymap.set("n", "<leader>e", ":Oil<CR>")

-- gitsigns keymaps
local gs = require("gitsigns")
vim.keymap.set("n", "]c", function() gs.nav_hunk("next") end, { desc = "Next git hunk" })
vim.keymap.set("n", "[c", function() gs.nav_hunk("prev") end, { desc = "Prev git hunk" })

-----------------------------------------------------------
-- Colorscheme
-----------------------------------------------------------
vim.cmd("colorscheme vague")
-- Make statusline have no background
vim.cmd("hi StatusLine guibg=NONE")
