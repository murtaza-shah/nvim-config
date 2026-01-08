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
vim.keymap.set("v", "<leader>p", '"+P"')

-- Buffer navigation
vim.keymap.set("n", "<leader>bb", "<C-^>")
vim.keymap.set("n", "<leader>bl", function()
  local ok, mini_pick = pcall(require, "mini.pick")
  if not ok then
    return
  end

  -- Builtin picker correctly restores the original window after selection.
  if type(mini_pick.builtin) == "table" and type(mini_pick.builtin.buffers) == "function" then
    mini_pick.builtin.buffers()
    return
  end

  -- Fallback picker for older/different mini.pick versions.
  local target_win = vim.api.nvim_get_current_win()
  mini_pick.start({
    source = {
      items = vim.tbl_map(function(buf)
        local name = vim.api.nvim_buf_get_name(buf)
        local display = name == "" and ("[No Name] (" .. buf .. ")")
          or vim.fn.fnamemodify(name, ":t")

        return { text = display, buf = buf }
      end, vim.tbl_filter(function(buf)
        return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted
      end, vim.api.nvim_list_bufs())),
      choose = function(item)
        vim.schedule(function()
          if not item or not item.buf or not vim.api.nvim_buf_is_valid(item.buf) then
            return
          end
          if vim.api.nvim_win_is_valid(target_win) then
            vim.api.nvim_set_current_win(target_win)
          end
          vim.api.nvim_set_current_buf(item.buf)
        end)
      end,
    },
  })
end, { desc = "List buffers" })
