# notepad-nvim

A Neovim configuration that behaves like a notepad: files and unsaved edits survive a restart,
every file has its own tab, and `nvim file` from another terminal opens in the running instance.
One `init.lua`, plugins installed by Neovim's built-in `vim.pack`.

## Requirements

- Neovim 0.12 or newer
- `git`
- `curl` or `wget` (downloads the markdown preview server)
- A clipboard provider: `wl-clipboard` on Wayland, `xclip` on X11

## Install

```bash
git clone <repository-url> ~/.config/notepad
alias np='NVIM_APPNAME=notepad nvim'
```

`NVIM_APPNAME=notepad` makes Neovim read `~/.config/notepad` and keep its plugins and state in
`notepad` directories. Add the alias to your shell configuration.

The first launch installs the plugins and pins them in `nvim-pack-lock.json`.

## Behaviour

| Feature | Detail |
| --- | --- |
| Reopen files | Every open file returns on the next launch, one tab per file. |
| Unsaved edits | Backed up continuously and restored still unsaved. The file on disk changes only on `:w`. |
| Single instance | `np file` from another terminal opens `file` as a tab in the running instance. Any flag (`-M`, `-d`, `-c`) starts a standalone instance. |
| New files | A file opened with `:e`, `gf` or a picker gets its own tab. |
| Closing | Closing a tab or `:bd` drops the file from the next launch. A tab with unsaved edits stays open in the background. |

## Keymaps

| Keys | Action |
| --- | --- |
| `Space 1` to `Space 9` | Go to tab 1 to 9 |
| `Space y p` / `y r` / `y n` | Copy the full path, relative path or file name |
| `Space m p` | Toggle the markdown preview in the browser |
| `Ctrl-c` (visual) | Copy to the system clipboard |
| `Ctrl-v` | Paste from the system clipboard |
| `Ctrl-q` | Block selection |

`y`, `d` and `p` use the system clipboard.

## Commands

| Command | Action |
| --- | --- |
| `:MdRead` | Read-only rendered view of the current buffer. `q` closes it. |
| `:colorscheme heritage-<Tab>` | Pick a Heritage theme. The choice is remembered. |

Open a file straight in the reading view:

```bash
np -M -c MdRead file.md
```

## Plugins

| Plugin | Purpose |
| --- | --- |
| `heritage-themes.nvim` | Colour schemes. `heritage-holi-night` is the default. |
| `render-markdown.nvim` | Inline markdown rendering in every mode. |
| `markdown-preview.nvim` | Browser preview with live reload and mermaid diagrams. |

Update them with `:lua vim.pack.update()`.

## State

Paths are relative to the state directory, `~/.local/state/notepad` (`:echo stdpath("state")`):

| Path | Content |
| --- | --- |
| `notepad/session.json` | Open files and the current file |
| `notepad/backups/` | Unsaved buffer contents |
| `colorscheme` | Last colour scheme |
| `undo/` | Undo history |

The single-instance socket is `notepad.sock` in `:echo stdpath("run")`. Set `NVIM_NOTEPAD_PIPE` to
use another address.
