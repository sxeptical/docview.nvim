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

vim.api.nvim_create_user_command("DocviewEdit", function()
  require("docview.edit").start(0)
end, { desc = "Edit the current document as Markdown (Word, ODT, RTF) or CSV (Excel)" })

vim.api.nvim_create_user_command("DocviewToggle", function()
  require("docview").toggle()
end, { desc = "Switch between page images and text" })

vim.api.nvim_create_user_command("DocviewClearCache", function()
  local dir = vim.fn.stdpath("cache") .. "/docview"
  vim.fn.delete(dir, "rf")
  vim.notify("docview: cleared " .. dir)
end, { desc = "Delete cached page images and converted PDFs" })
