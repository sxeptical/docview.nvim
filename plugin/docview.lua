if vim.g.loaded_docview then
  return
end
vim.g.loaded_docview = true

-- Autocmds are cheap; the converters are only required when a document is opened.
require("docview").register()

vim.api.nvim_create_user_command("DocviewOpen", function()
  require("docview").open_external()
end, { desc = "Open the current document in its default application" })

vim.api.nvim_create_user_command("DocviewReload", function()
  require("docview").reload()
end, { desc = "Re-convert the current document" })

vim.api.nvim_create_user_command("DocviewInfo", function()
  require("docview").info()
end, { desc = "Show which converter rendered the current document" })
