# genja-claudefterm.nvim

Claude Code in a vim-floaterm, one terminal per project root (idea 19). Loaded
from disk by the config's `../../lua/lazyp/new/genja-claudefterm.lua` (`dir =`
spec, `cmd = 'ClaudeFterm'`; the keys in the config's `plugin/claude-fterm.lua`
and genja-ask's claudefterm target load it through `require('genja-claudefterm')`).

How this file is kept: one heading per feature, one bullet per decision.
Unmarked bullets were stated by jaro. `(inferred)` marks Claude's reading of the
code or history: confirm or delete. `Hint:` is a working note for Claude.

## Layout

- `lua/genja-claudefterm/init.lua`: `setup()`, `toggle()`, `list()`, `running()` / `show(name)` (for pickers outside, e.g. the config's `<F2>`), `paste_context()`, `send()`, `complete()`, `kill()`, terminals.
- `lua/genja-claudefterm/session.lua`: transcript path, /rename polling for the terminal name.
- UUIDs, the code fence and the visual range come from `genja-util.text` (`plug-wip/genja-util.nvim`, a spec dependency; the tests prepend it).
- `plugin/genja-claudefterm.lua`: `:ClaudeFterm [flags]`, `:ClaudeFterm!`.
- Tests: the config's `tests/claudefterm/` (`make test D=claudefterm` in `tests/`); claude is a fake script that logs its cwd and args.
- Moved out of the config's `lua/genja/claude.lua`; `:ClaudeFterm` moved out of `lua/genja/auto-alias.vim`.

## Decisions

- Standalone: requires no `genja.*` module. Needs vim-floaterm; telescope only for `list()`. lazy.nvim is optional (used to load floaterm when its spec is lazy). (inferred)
- Mappings stay in the config (`plugin/claude-fterm.lua`); only the terminal-local keys (`<C-q>`, `<C-Left>`, ...) are set here.
- `setup({ term = ... })` sets the floaterm options for every start. Defaults: a vsplit on the right (`botright`, width 0.45). Before, they came only with `:ClaudeFterm`, so when `<leader>pC` or the ask popup started claude first it opened in floaterm's default centred float.
- `:ClaudeFterm [flags]` flags are kept for later starts until the next `:ClaudeFterm`; `send(text, flags)` flags apply to that start only. A running claude keeps its flags; both warn when flags would be ignored.
- claude starts with floaterm `--autoclose=never` and `on_exit` closes the window itself: floaterm's own close hits E444 when the claude split is the last window. floaterm's `BufHidden,BufWipeout` autocmd (group `floaterm_enter_insertmode`) also closes the window, so `on_exit` clears it before `nvim_win_set_buf`.
- `:ClaudeFterm -1` / `-one` starts claude in the current window, replacing its buffer; `:ClaudeFterm` again puts that buffer back, and so does claude's exit. Only for that start (not kept like flags, so `send()` never takes the user's window); not passed to claude. (inferred)
- -one: floaterm opens its split, then the plugin moves the buffer into the origin window, closes the split and sets floaterm's `winid` to -1, because floaterm's BufHidden hook closes the window in `winid`. A later `FloatermShow` (from `send()`, `paste_context()`, `show()`) opens floaterm's normal split again. (inferred)
- `:ClaudeFterm -ax` passes `--ax-screen-reader` to claude: short flags live in `SHORT_FLAGS` (init.lua), expanded with the other flags and kept like them.
- Session markers (a `claude-session: <uuid> <title>` comment written into the origin file on `/rename`, resumed by `:ClaudeFterm`, `:ClaudeFtermMarkerToggle`) were removed 2026-11-07 (not liked). `/rename` still renames the terminal buffer.
- `paste_context()` in visual mode pastes from a buffer without a file too, labelled `no file`.
- `kill()` runs from the config's session sweep (`lua/genja/abbreviations.vim`) only when the module is already loaded.
- `kill()` waits 200 ms between `FloatermKill`s: back to back they crashed the headless test child on Windows about one run in three (`kill() stops every terminal`); with the wait, 6 of 6 passed. It stays synchronous because `s:` runs `:qa` right after. (inferred)
