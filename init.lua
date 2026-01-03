-----------------------------------------------------------
-- Basic options
-----------------------------------------------------------
vim.o.number = true
vim.o.relativenumber = true
vim.o.wrap = false
vim.o.tabstop = 4
vim.o.swapfile = false
vim.o.signcolumn = "yes"
vim.o.winborder = "rounded"
vim.g.mapleader = " "

-----------------------------------------------------------
-- Keymaps (core)
-----------------------------------------------------------
-- Reload current config file
vim.keymap.set('n', '<leader>o', ':update<CR>:source<CR>')

-- Save / quit
vim.keymap.set('n', '<leader>w', ':write<CR>')
vim.keymap.set('n', '<leader>q', ':quit<CR>')

-- Clipboard in visual
vim.keymap.set('v', '<leader>y', '"+y')
vim.keymap.set('v', '<leader>p', '"+P')

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

})

-----------------------------------------------------------
-- Basic plugin setup
-----------------------------------------------------------
require("mini.pick").setup()
require("oil").setup()
require("gitsigns").setup({
	signs = {
		add          = { text = "+" },
		change       = { text = "│" },
		delete       = { text = "_" },
		topdelete    = { text = "‾" },
		changedelete = { text = "~" },
	},
})

-- mini.pick keymaps
vim.keymap.set('n', '<leader>f', ":Pick files<CR>")
vim.keymap.set('n', '<leader>h', ":Pick help<CR>")
vim.keymap.set('n', '<leader>e', ":Oil<CR>")

-- gitsigns keymaps
local gs = require("gitsigns")
vim.keymap.set('n', ']c', function() gs.nav_hunk('next') end, { desc = "Next git hunk" })
vim.keymap.set('n', '[c', function() gs.nav_hunk('prev') end, { desc = "Prev git hunk" })


-- Colorscheme
vim.cmd("colorscheme vague")
-- Make statusline have no background
vim.cmd("hi StatusLine guibg=NONE")

-----------------------------------------------------------
-- Mason: LSP installer / manager
-----------------------------------------------------------
require("mason").setup()

local mason_lspconfig = require("mason-lspconfig")

mason_lspconfig.setup({
	-- Install whatever you want from the Mason UI, no fixed list.
	automatic_installation = true,
})

-- Open Mason UI to see installed / installable LSPs
vim.keymap.set('n', '<leader>lm', ':Mason<CR>', { desc = "Open Mason (LSP manager)" })

-----------------------------------------------------------
-- Completion: nvim-cmp + LuaSnip
-----------------------------------------------------------
vim.o.completeopt = "menu,menuone,noselect"

local cmp = require("cmp")
local luasnip = require("luasnip")

cmp.setup({
	snippet = {
		expand = function(args)
			luasnip.lsp_expand(args.body)
		end,
	},
	mapping = cmp.mapping.preset.insert({
		["<C-Space>"] = cmp.mapping.complete(),
		["<CR>"] = cmp.mapping.confirm({ select = true }),
		["<C-e>"] = cmp.mapping.abort(),

		["<Tab>"] = cmp.mapping(function(fallback)
			if cmp.visible() then
				cmp.select_next_item()
			elseif luasnip.expand_or_locally_jumpable() then
				luasnip.expand_or_jump()
			else
				fallback()
			end
		end, { "i", "s" }),

		["<S-Tab>"] = cmp.mapping(function(fallback)
			if cmp.visible() then
				cmp.select_prev_item()
			elseif luasnip.locally_jumpable(-1) then
				luasnip.jump(-1)
			else
				fallback()
			end
		end, { "i", "s" }),
	}),
	sources = cmp.config.sources({
		{ name = "nvim_lsp" }, -- LSP completion
		{ name = "luasnip" }, -- snippets
	}, {
		{ name = "buffer" }, -- words already in this buffer
		{ name = "path" }, -- filesystem paths
	}),
})

-----------------------------------------------------------
-- LSP configuration (terse / auto style)
-----------------------------------------------------------
-- Load lspconfig so server definitions are registered.
pcall(require, "lspconfig")

-- Global defaults for all LSPs
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities = require("cmp_nvim_lsp").default_capabilities(capabilities)

vim.lsp.config("*", {
	capabilities = capabilities,
})

-- Extra config for specific servers (optional)
-- Example: Lua LS – don't warn about `vim` and skip 3rd party checks.
vim.lsp.config("lua_ls", {
	settings = {
		Lua = {
			diagnostics = {
				globals = { "vim" },
			},
			workspace = {
				checkThirdParty = false,
			},
		},
	},
})

-- Function to enable all LSPs that Mason has installed
local function enable_installed_lsps()
	local servers = mason_lspconfig.get_installed_servers()
	for _, server_name in ipairs(servers) do
		vim.lsp.enable(server_name)
	end
end

-- Enable any already-installed servers at startup
enable_installed_lsps()

-- Keymap to re-run that after installing new servers in Mason
vim.keymap.set('n', '<leader>la', function()
	enable_installed_lsps()
	print("Enabled installed LSP servers")
end, { desc = "Enable installed LSPs" })

-- Format via LSP
vim.keymap.set('n', '<leader>lf', function()
	vim.lsp.buf.format({ async = true })
end, { desc = "LSP format buffer" })

-- Show which LSPs are attached to the current buffer
vim.keymap.set('n', '<leader>ll', function()
	local clients = vim.lsp.get_clients({ bufnr = 0 })
	if vim.tbl_isempty(clients) then
		print("No LSP attached to this buffer")
		return
	end
	local names = {}
	for _, c in ipairs(clients) do
		table.insert(names, c.name)
	end
	print("LSP clients: " .. table.concat(names, ", "))
end, { desc = "List LSP clients for current buffer" })
