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
vim.keymap.set("n", "<leader>lm", ":Mason<CR>", { desc = "Open Mason (LSP manager)" })

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
vim.keymap.set("n", "<leader>la", function()
	enable_installed_lsps()
	print("Enabled installed LSP servers")
end, { desc = "Enable installed LSPs" })

-- Format via LSP
vim.keymap.set("n", "<leader>lf", function()
	vim.lsp.buf.format({ async = true })
end, { desc = "LSP format buffer" })

-- restart lsp
vim.keymap.set("n", "<leader>lr", ":lsp restart<CR>")

-- Show which LSPs are attached to the current buffer
vim.keymap.set("n", "<leader>ll", function()
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

-----------------------------------------------------------
-- Quickfix helper: open item but keep focus in qf window
-----------------------------------------------------------
local function open_qf_item_and_stay()
	-- Simulate pressing <CR> (open item) then <C-w>p (previous window)
	local keys = vim.api.nvim_replace_termcodes("<CR><C-w>p", true, false, true)
	vim.api.nvim_feedkeys(keys, "n", false)
end

vim.api.nvim_create_autocmd("FileType", {
	pattern = { "qf" }, -- quickfix (LSP references usually open here)
	callback = function(args)
		vim.keymap.set("n", "<leader><CR>", open_qf_item_and_stay, {
			buffer = args.buf,
			noremap = true,
			silent = true,
			desc = "Open qf item but keep focus in quickfix window",
		})
	end,
})

-----------------------------------------------------------
-- LSP keymaps via LspAttach
-----------------------------------------------------------
local function lsp_keymaps(bufnr)
	local opts = { buffer = bufnr, silent = true, noremap = true }

	-- Jump / inspect
	vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
	vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
	vim.keymap.set("n", "gi", vim.lsp.buf.implementation, opts)
	vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
	vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)

	-- Refactor / actions
	vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
	vim.keymap.set({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, opts)

	-- Diagnostics navigation
	vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, opts)
	vim.keymap.set("n", "]d", vim.diagnostic.goto_next, opts)
end

vim.api.nvim_create_augroup("UserLspKeymaps", { clear = true })
vim.api.nvim_create_autocmd("LspAttach", {
	group = "UserLspKeymaps",
	callback = function(args)
		lsp_keymaps(args.buf)
	end,
})
