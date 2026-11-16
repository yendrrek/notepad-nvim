-- Notepad-style behaviour for Neovim
--   1. Every file you have open is reopened on the next launch.
--   2. Unsaved edits are backed up continuously and restored (still unsaved)
--      on the next launch. The real file is only changed when you :w.
--
-- Install to ~/.config/notepad and start it with `NVIM_APPNAME=notepad nvim`.
-- Neovim then keeps this config's plugins and state in their own `notepad`
-- directories, apart from any other Neovim configuration.
--
-- State lives in stdpath("state")/notepad:
--   session.json       list of open files and the current one
--   backups/<id>.bak   copy of a buffer's unsaved content
--   backups/<id>.json  path and disk mtime/size the backup was taken against

-- Settings ------------------------------------------------------------------

vim.g.mapleader = " "

vim.o.hidden = true     -- switch buffers without being forced to save
vim.o.swapfile = false  -- the backups below replace swap files (no recovery prompts)
vim.o.undofile = true   -- keep undo history across launches
vim.fn.mkdir(vim.fn.stdpath("state") .. "/undo", "p")
vim.o.clipboard = "unnamedplus" -- y, d and p share the system clipboard (wl-clipboard on Wayland)

-- Ctrl-c / Ctrl-v copy and paste, as in other editors. In kitty, Ctrl-c reaches
-- nvim when kitty has no selection of its own, and Ctrl-v is pasted by kitty.
vim.keymap.set("v", "<C-c>", '"+y', { desc = "Copy selection" })
vim.keymap.set("n", "<C-v>", '"+p', { desc = "Paste" })
vim.keymap.set("i", "<C-v>", "<C-r>+", { desc = "Paste" })
vim.keymap.set("c", "<C-v>", "<C-r>+", { desc = "Paste" })
vim.keymap.set({ "n", "v" }, "<C-q>", "<C-v>", { desc = "Block selection (Ctrl-v is paste)" })

-- Helpers -------------------------------------------------------------------

local IS_WIN = vim.fn.has("win32") == 1
local state_dir = vim.fn.stdpath("state") .. "/notepad"
local backup_dir = state_dir .. "/backups"
local session_file = state_dir .. "/session.json"
vim.fn.mkdir(backup_dir, "p")

local ready = false     -- true once startup restore has finished
local quitting = false  -- true once Neovim is exiting
local pending = {}      -- buffers waiting for their backup to be applied
local shown = {}        -- buffers that have already been displayed in a window

local function normalise(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function key(path)
  return IS_WIN and path:lower() or path
end

-- Single instance -----------------------------------------------------------
-- The first Neovim claims a fixed pipe. `nvim file.md` from another terminal
-- hands its files to that instance (each in its own tab) and exits.
-- Only plain `nvim [files]` takes part: any flag (-M, -d, -c, ...) starts a
-- normal standalone instance. NVIM_NOTEPAD_PIPE overrides the pipe name.

local pipe_addr = vim.env.NVIM_NOTEPAD_PIPE
  or (IS_WIN and [[\\.\pipe\nvim-notepad]] or (vim.fn.stdpath("run") .. "/notepad.sock"))

-- The terminal UI runs the editor as an `--embed` child process, so every
-- interactive `nvim` carries that flag even when it was started plainly.
local PLAIN_FLAGS = { ["--headless"] = true, ["--embed"] = true }

local function plain_launch()
  if vim.o.diff or not vim.o.modifiable then
    return false
  end
  for i = 2, #vim.v.argv do
    local arg = vim.v.argv[i]
    if (arg:sub(1, 1) == "-" and not PLAIN_FLAGS[arg]) or arg:sub(1, 1) == "+" then
      return false
    end
  end
  return true
end

-- Runs inside the instance that owns the pipe.
function _G.NotepadOpen(paths)
  for _, p in ipairs(paths) do
    local path = normalise(p)
    local existing
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and key(normalise(name)) == key(path) then
        existing = buf
        break
      end
    end
    local win = existing and vim.fn.win_findbuf(existing)[1]
    if win then
      vim.fn.win_gotoid(win) -- already open: jump to its tab
    else
      vim.cmd.tabedit(vim.fn.fnameescape(path))
    end
  end
end

if plain_launch() then
  local files = {}
  for _, f in ipairs(vim.fn.argv()) do
    table.insert(files, normalise(f))
  end

  local ok_conn, chan = pcall(vim.fn.sockconnect, "pipe", pipe_addr, { rpc = true })
  local alive = ok_conn and chan > 0
  local forwarded = false
  if alive then
    if #files > 0 then
      forwarded = pcall(vim.fn.rpcrequest, chan, "nvim_exec_lua", "return NotepadOpen(...)", { files })
    end
    pcall(vim.fn.chanclose, chan)
  end

  if forwarded then
    vim.cmd("qa!")
    return
  end

  if not alive and not IS_WIN and vim.uv.fs_stat(pipe_addr) then
    vim.uv.fs_unlink(pipe_addr) -- stale socket left by a crashed instance
  end
  pcall(vim.fn.serverstart, pipe_addr)
end

local function backup_paths(path)
  local id = vim.fn.sha256(key(path))
  return backup_dir .. "/" .. id .. ".bak", backup_dir .. "/" .. id .. ".json"
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local ok_decode, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok_decode and type(data) == "table" then
    return data
  end
  return nil
end

local function write_json(path, data)
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

-- A buffer that represents a real file (not help, terminal, directory, etc.)
local function is_file_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= "" or not vim.bo[buf].buflisted then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fn.isdirectory(name) == 0
end

-- Backups -------------------------------------------------------------------

local function remove_backup(path)
  local bak, meta = backup_paths(path)
  vim.fn.delete(bak)
  vim.fn.delete(meta)
end

local function write_backup(buf)
  local path = normalise(vim.api.nvim_buf_get_name(buf))
  local bak, meta = backup_paths(path)
  vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), bak)
  local stat = vim.uv.fs_stat(path)
  write_json(meta, {
    path = path,
    mtime = stat and stat.mtime.sec or nil,
    size = stat and stat.size or nil,
  })
end

-- Backs up every modified buffer and drops backups of buffers that are clean again.
local function flush()
  if not ready then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_file_buf(buf) and vim.api.nvim_buf_is_loaded(buf) and not pending[buf] then
      if vim.bo[buf].modified then
        write_backup(buf)
      else
        remove_backup(normalise(vim.api.nvim_buf_get_name(buf)))
      end
    end
  end
end

local timer = assert(vim.uv.new_timer())

local function schedule_flush()
  if not ready then
    return
  end
  timer:stop()
  timer:start(500, 0, vim.schedule_wrap(flush))
end

-- Replaces a freshly loaded buffer's content with its backup, leaving it unsaved.
local function apply_backup(buf)
  pending[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local path = normalise(vim.api.nvim_buf_get_name(buf))
  local bak, meta = backup_paths(path)
  if vim.fn.filereadable(bak) == 0 then
    return
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(bak))
  vim.bo[buf].modified = true

  local info = read_json(meta)
  local stat = vim.uv.fs_stat(path)
  if info and stat and (stat.mtime.sec ~= info.mtime or stat.size ~= info.size) then
    vim.notify(
      vim.fn.fnamemodify(path, ":t")
        .. " changed on disk after your unsaved edits were backed up. Saving will overwrite it.",
      vim.log.levels.WARN
    )
  end
end

-- Session -------------------------------------------------------------------

local function save_session(exclude)
  if not ready then
    return
  end
  local files, current_path = {}, nil
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= exclude and is_file_buf(buf) then
      local path = normalise(vim.api.nvim_buf_get_name(buf))
      table.insert(files, path)
      if buf == current then
        current_path = path
      end
    end
  end
  write_json(session_file, { files = files, current = current_path })
end

local function is_blank_unnamed(buf)
  return vim.api.nvim_buf_get_name(buf) == ""
    and vim.bo[buf].buftype == ""
    and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

local function restore_session()
  if vim.o.diff then
    return
  end
  local data = read_json(session_file)
  if not data or type(data.files) ~= "table" then
    return
  end

  -- Re-list every saved file. Files are loaded lazily when first shown,
  -- which is when their unsaved backup (if any) is applied.
  local by_path = {}
  for _, path in ipairs(data.files) do
    local _, meta = backup_paths(path)
    if vim.fn.filereadable(path) == 1 or vim.fn.filereadable(meta) == 1 then
      local buf = vim.fn.bufadd(path)
      vim.bo[buf].buflisted = true
      by_path[key(path)] = buf
    end
  end

  -- Plain `nvim`: reopen the file you were last looking at.
  -- `nvim file`: leave the requested file in front.
  if #vim.fn.argv() == 0 and type(data.current) == "string" then
    local target = by_path[key(data.current)]
    local blank = vim.api.nvim_get_current_buf()
    if target then
      vim.api.nvim_set_current_buf(target)
      if blank ~= target and is_blank_unnamed(blank) then
        vim.api.nvim_buf_delete(blank, {})
      end
    end
  end

  -- Give every other saved file its own tab (skipped in read-only `nvim -M`).
  if vim.o.modifiable then
    for _, path in ipairs(data.files) do
      local buf = by_path[key(path)]
      if buf and #vim.fn.win_findbuf(buf) == 0 then -- all tabs, not just the current one
        vim.cmd.tabedit(vim.fn.fnameescape(path))
      end
    end
    vim.cmd.tabfirst()
  end
end

-- Autocommands --------------------------------------------------------------

local group = vim.api.nvim_create_augroup("NotepadRestore", { clear = true })

-- A file has just been read (or is new): on its first load, put its unsaved
-- backup back, and jump to the last cursor position. Later reloads (:e!) are
-- deliberate and must not resurrect discarded edits.
local first_load_done = {}

vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = group,
  callback = function(args)
    if not is_file_buf(args.buf) then
      return
    end
    local first_load = not first_load_done[args.buf]
    first_load_done[args.buf] = true
    local bak = backup_paths(normalise(vim.api.nvim_buf_get_name(args.buf)))
    if first_load and vim.fn.filereadable(bak) == 1 then
      pending[args.buf] = true
      vim.schedule(function()
        apply_backup(args.buf)
      end)
    end
    local mark = vim.api.nvim_buf_get_mark(args.buf, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(args.buf) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- A file opened for the first time (:e, gf, a picker, ...) gets its own tab
-- instead of replacing the file already in the window. Switching to an
-- already-open buffer (:b, :bnext) behaves as normal.
-- The last real file each window showed. Going file -> directory listing -> file
-- (`:e folder`, then Enter) leaves the listing as the alternate buffer, so the
-- displaced file is looked up here instead.
local last_file = {}

vim.api.nvim_create_autocmd("BufLeave", {
  group = group,
  callback = function(args)
    if is_file_buf(args.buf) then
      last_file[vim.api.nvim_get_current_win()] = args.buf
    end
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    last_file[tonumber(args.match)] = nil
  end,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  callback = function(args)
    local buf = args.buf
    local first_show = not shown[buf]
    shown[buf] = true
    if not (ready and first_show and is_file_buf(buf)) then
      return
    end
    -- Only when this file displaced another one: after `:e` the previous file
    -- is no longer in any window, after `:tabedit` / `:split` it still is.
    local prev = last_file[vim.api.nvim_get_current_win()] or vim.fn.bufnr("#")
    if prev < 1 or prev == buf or not is_file_buf(prev) or #vim.fn.win_findbuf(prev) > 0 then
      return
    end
    vim.schedule(function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) ~= buf or not vim.api.nvim_buf_is_valid(prev) then
        return
      end
      vim.api.nvim_win_set_buf(win, prev)
      vim.cmd("tab sbuffer " .. buf)
    end)
  end,
})

vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "InsertLeave" }, {
  group = group,
  callback = schedule_flush,
})

vim.api.nvim_create_autocmd({ "BufLeave", "FocusLost" }, {
  group = group,
  callback = flush,
})

-- A full save makes the backup redundant.
vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  callback = function(args)
    if is_file_buf(args.buf) and not vim.bo[args.buf].modified then
      remove_backup(normalise(vim.api.nvim_buf_get_name(args.buf)))
    end
  end,
})

vim.api.nvim_create_autocmd({ "BufAdd", "BufEnter", "BufFilePost" }, {
  group = group,
  callback = function()
    save_session()
  end,
})

-- Closing a buffer on purpose (:bd, :bd!) discards its backup and removes it from the session.
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = group,
  callback = function(args)
    if quitting or not ready then
      return
    end
    local name = vim.api.nvim_buf_get_name(args.buf)
    if name ~= "" and vim.bo[args.buf].buftype == "" then
      remove_backup(normalise(name))
    end
    save_session(args.buf)
  end,
})

-- Closing a tab (or split) closes its file too: once no window shows a file
-- any more it leaves the buffer list, so it is not reopened on the next launch.
-- A buffer with unsaved edits is kept hidden instead, so nothing is lost.
vim.api.nvim_create_autocmd("WinClosed", {
  group = group,
  callback = function(args)
    if quitting or not ready then
      return
    end
    local win = tonumber(args.match)
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    vim.schedule(function()
      if quitting or not is_file_buf(buf) or vim.bo[buf].modified then
        return
      end
      if #vim.fn.win_findbuf(buf) == 0 then
        pcall(vim.api.nvim_buf_delete, buf, {})
      end
    end)
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    flush()
    save_session()
    quitting = true
  end,
})

vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  nested = true, -- let BufReadPost fire for the buffer we switch to
  callback = function()
    restore_session()
    ready = true
    save_session()
  end,
})

-- Tabs ----------------------------------------------------------------------
-- Tab bar always visible, each tab labelled "<number> <file>" (+ when unsaved).
-- <Space>1 .. <Space>9 jump to that tab (normal mode); clicking a tab also works.
-- Built in as well: gt / gT, {n}gt (e.g. 3gt), Ctrl+PageUp / Ctrl+PageDown.

vim.o.showtabline = 2

function _G.NotepadTabline()
  local parts = {}
  local current = vim.fn.tabpagenr()
  for i = 1, vim.fn.tabpagenr("$") do
    local buf = vim.fn.tabpagebuflist(i)[vim.fn.tabpagewinnr(i)]
    local name = vim.fn.fnamemodify(vim.fn.bufname(buf), ":t")
    if name == "" then
      name = "[No Name]"
    end
    local modified = vim.fn.getbufvar(buf, "&modified") == 1 and " +" or ""
    table.insert(parts, table.concat({
      i == current and "%#TabLineSel#" or "%#TabLine#",
      "%", i, "T ", i, " ", (name:gsub("%%", "%%%%")), modified, " ",
    }))
  end
  table.insert(parts, "%#TabLineFill#%T")
  return table.concat(parts)
end

vim.o.tabline = "%!v:lua.NotepadTabline()"

for n = 1, 9 do
  vim.keymap.set("n", "<leader>" .. n, function()
    if n <= vim.fn.tabpagenr("$") then
      vim.cmd.tabnext(n)
    end
  end, { desc = "Go to tab " .. n })
end

-- Copy the current file's path to the system clipboard.
-- <Space>yp full path, <Space>yr relative path, <Space>yn file name.
local function copy_path(modifier, label)
  return function()
    local value = vim.fn.expand(modifier)
    if value == "" then
      vim.notify("No file in this buffer", vim.log.levels.WARN)
      return
    end
    vim.fn.setreg("+", value)
    vim.notify("Copied " .. label .. ": " .. value)
  end
end

vim.keymap.set("n", "<leader>yp", copy_path("%:p", "full path"), { desc = "Copy full file path" })
vim.keymap.set("n", "<leader>yr", copy_path("%:.", "relative path"), { desc = "Copy relative file path" })
vim.keymap.set("n", "<leader>yn", copy_path("%:t", "file name"), { desc = "Copy file name" })

-- Plugin hooks -------------------------------------------------------------
-- Registered before the first vim.pack.add(), which also installs every plugin
-- missing from nvim-pack-lock.json (e.g. on a fresh machine).
--
-- markdown-preview.nvim: after every install or update, the plugin's own
-- installer downloads the prebuilt preview server matching the plugin version
-- (needs curl or wget).

vim.api.nvim_create_autocmd("PackChanged", {
  group = vim.api.nvim_create_augroup("MarkdownPreviewBuild", { clear = true }),
  callback = function(ev)
    local data = ev.data
    if data.spec.name ~= "markdown-preview.nvim" or (data.kind ~= "install" and data.kind ~= "update") then
      return
    end
    local version = read_json(data.path .. "/package.json")
    version = version and version.version
    local cmd = IS_WIN and { "cmd", "/c", "install.cmd" } or { "./install.sh" }
    if version then
      table.insert(cmd, "v" .. version)
    end
    local result = vim.system(cmd, { cwd = data.path .. "/app" }):wait()
    if result.code ~= 0 then
      vim.notify("markdown-preview.nvim: installer failed\n" .. (result.stderr or ""), vim.log.levels.ERROR)
    end
  end,
})

-- Colour scheme -------------------------------------------------------------
-- Heritage Themes. `:colorscheme heritage-<Tab>` lists every variant.
-- The last scheme you pick is saved to stdpath("state")/colorscheme and
-- restored on the next launch. heritage-holi-night is the default.

vim.o.termguicolors = true

local default_scheme = "heritage-holi-night"
local scheme_file = vim.fn.stdpath("state") .. "/colorscheme"

local function saved_scheme()
  local ok, lines = pcall(vim.fn.readfile, scheme_file)
  local name = ok and lines[1] or nil
  return (name and name ~= "") and name or nil
end

pcall(vim.pack.add, { "https://github.com/heritage-themes/heritage-themes.nvim" })

local saved = saved_scheme()
if not (saved and pcall(vim.cmd.colorscheme, saved)) then
  pcall(vim.cmd.colorscheme, default_scheme)
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("NotepadColorscheme", { clear = true }),
  callback = function()
    if vim.g.colors_name and vim.g.colors_name ~= "" then
      pcall(vim.fn.writefile, { vim.g.colors_name }, scheme_file)
    end
  end,
})

-- Markdown reading view -----------------------------------------------------
-- Renders markdown inline (headings, tables, code blocks, checkboxes).
-- `:MdRead` turns the current buffer into a clean read-only view; `q` closes it.
-- From the shell: nvim -M -c MdRead file.md

local ok_pack = pcall(vim.pack.add, { "https://github.com/MeanderingProgrammer/render-markdown.nvim" })
if ok_pack then
  require("render-markdown").setup({
    render_modes = true, -- stay rendered in every mode, not only away from the cursor line
  })
end

-- Markdown browser preview --------------------------------------------------
-- `:MarkdownPreview` opens the current file in the browser with live reload and
-- renders mermaid diagrams. `:MarkdownPreviewStop` / `:MarkdownPreviewToggle` also exist.

pcall(vim.pack.add, { "https://github.com/iamcco/markdown-preview.nvim" })

-- <Space>mp toggles the preview (the command only exists in markdown buffers).
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("MarkdownPreviewKeymap", { clear = true }),
  pattern = "markdown",
  callback = function(ev)
    vim.keymap.set("n", "<leader>mp", "<cmd>MarkdownPreviewToggle<cr>", {
      buffer = ev.buf,
      desc = "Toggle markdown preview",
    })
  end,
})

vim.api.nvim_create_user_command("MdRead", function()
  vim.opt_local.modifiable = false
  vim.opt_local.readonly = true
  vim.opt_local.wrap = true
  vim.opt_local.linebreak = true
  vim.opt_local.number = false
  vim.opt_local.relativenumber = false
  vim.opt_local.signcolumn = "no"
  vim.keymap.set("n", "q", "<cmd>q<cr>", { buffer = true })
end, {})
