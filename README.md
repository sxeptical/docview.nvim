# docview.nvim

Open PDFs, Word documents, spreadsheets and slides in Neovim. In kitty, Ghostty or
WezTerm you see the real pages, with their fonts, layout and images, the way a PDF viewer shows them.
Press `<Tab>` for the text version to search, yank or read anywhere else.

`:e report.docx` (or picking the file from any explorer or picker) just works. The
original file is never modified: `:w` is refused.

## Page view

Each page is rendered to an image and drawn with [snacks.nvim](https://github.com/folke/snacks.nvim)'s
image support, scrolling line by line like any buffer.

- PDFs need [Ghostscript](https://ghostscript.com): `brew install ghostscript`
- Word, PowerPoint, Excel, OpenDocument and RTF files are first converted to PDF by
  LibreOffice, which runs invisibly in the background: `brew install --cask libreoffice`

Converted PDFs and page images are cached (by path, size and modification time), so a
document is only converted once; reopening it is instant. The first pages appear while
the rest are still rendering. `:DocviewClearCache` frees the space.

When page images aren't possible (another terminal, missing tools), documents open as text
and `:DocviewInfo` says why.

## Text view

| Format              | Converters, in order of preference                  |
| ------------------- | --------------------------------------------------- |
| `.pdf`              | `pdftotext` → `mutool` → macOS PDFKit (built in)    |
| `.docx`             | `pandoc` → `textutil` (macOS) → built-in reader     |
| `.doc`              | `textutil` → `antiword` → `catdoc`                  |
| `.odt` `.rtf`       | `pandoc` → `textutil`                               |
| `.epub`             | `pandoc`                                            |
| `.pptx` `.xlsx`     | built-in reader (needs only `unzip`)                |

On macOS everything except `.epub` works with no installs; `brew install pandoc poppler`
gives Markdown output for Word documents and layout-preserving PDF text.

## Install

lazy.nvim (keep it un-lazy; it only registers autocmds at startup):

```lua
{ "sxeptical/docview.nvim", lazy = false, dependencies = { "folke/snacks.nvim" }, opts = {} }
```

Without a plugin manager: `vim.opt.rtp:prepend("~/path/to/docview.nvim")`.

## Usage

| Key / command          | Action                                             |
| ---------------------- | -------------------------------------------------- |
| `<Tab>`                | Switch between pages and text (`:DocviewToggle`)   |
| `]p` / `[p`            | Next / previous page (takes a count)               |
| `+` / `-` / `=`        | Zoom in / out / fit to window (page view)          |
| `gO`                   | Open the file in its default app (`:DocviewOpen`)  |
| `:DocviewReload`       | Re-convert (e.g. after the file changed)           |
| `:DocviewInfo`         | Show which converter was used                      |
| `:DocviewClearCache`   | Delete cached page images and PDFs                 |
| `:checkhealth docview` | See what is installed                              |

## Options

```lua
require("docview").setup({
  extensions = { "pdf", "docx", "doc", "odt", "rtf", "epub", "pptx", "xlsx" },
  view = "pages", -- or "text" to open documents as text by default
  pages = {
    dpi = 180, -- render resolution; higher is sharper but slower
    max_width = 100, -- widest a page is drawn, in columns, at zoom 1
    chunk_size = 6, -- pages rendered per batch
  },
  pdf_layout = true, -- pdftotext -layout keeps columns and tables aligned (text view)
  pandoc_args = { "--to=gfm", "--wrap=auto", "--columns=100" },
  timeout = 60000,
  keymaps = { -- false disables one
    next_page = "]p",
    prev_page = "[p",
    open_external = "gO",
    toggle_view = "<Tab>",
    zoom_in = "+",
    zoom_out = "-",
    zoom_reset = "=",
  },
})
```
