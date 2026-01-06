-- Entry point: just wire the pieces together in order.

require("config.options")  -- basic vim options, leader
require("config.keymaps")  -- global (non-plugin) keymaps
require("config.plugins")  -- plugin definitions & setup
require("config.lsp")      -- mason, cmp, lsp config & keymaps

require("custom.ghost_inline").setup({
		idle_ms = 400,
		accept_key = "<C-l>",
})
