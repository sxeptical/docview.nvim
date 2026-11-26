# docview.nvim

Open PDFs, Word documents, spreadsheets and slides in Neovim as read-only text.
`:e report.docx` (or picking the file from any file explorer/picker) shows its text
instead of binary noise. The original file is never modified: `:w` is refused.

| Format              | Converters, in order of preference                  |
| ------------------- | --------------------------------------------------- |
| `.pdf`              | `pdftotext` → `mutool` → macOS PDFKit (built in)    |
| `.docx`             | `pandoc` → `textutil` (macOS) → built-in reader     |
| `.doc`              | `textutil` → `antiword` → `catdoc`                  |
| `.odt` `.rtf`       | `pandoc` → `textutil`                               |
| `.epub`             | `pandoc`                                            |
| `.pptx` `.xlsx`     | built-in reader (needs only `unzip`)                |

On macOS everything except `.epub` works with no installs. For better output:

```sh
brew install pandoc poppler   # Markdown output for Word docs, layout-preserving PDFs
```

## Install

lazy.nvim (keep it un-lazy; it only registers autocmds at startup):

```lua
{ "sxeptical/docview.nvim", lazy = false, opts = {} }
```

Without a plugin manager: `vim.opt.rtp:prepend("~/path/to/docview.nvim")`.

## Usage

| Key / command    | Action                                         |
| ---------------- | ---------------------------------------------- |
| `]p` / `[p`      | Next / previous PDF page (takes a count)       |
| `gO`             | Open the file in its default app (`:DocviewOpen`) |
| `:DocviewReload` | Re-convert (e.g. after the file changed)       |
| `:DocviewInfo`   | Show which converter was used                  |
| `:checkhealth docview` | See which converters are installed       |

## Options

```lua
require("docview").setup({
  extensions = { "pdf", "docx", "doc", "odt", "rtf", "epub", "pptx", "xlsx" },
  pdf_layout = true, -- pdftotext -layout keeps columns and tables aligned
  pandoc_args = { "--to=gfm", "--wrap=auto", "--columns=100" },
  timeout = 60000,
  keymaps = { next_page = "]p", prev_page = "[p", open_external = "gO" }, -- false disables one
})
```
