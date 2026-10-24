# genja-claudefterm.nvim

Claude Code in a vim-floaterm, one terminal per project root (idea 19). Loaded
from disk by the config's `../../lua/lazyp/new/genja-claudefterm.lua` (`dir =`
spec, `cmd = 'ClaudeFterm'`; the keys in the config's `plugin/claude-fterm.lua`
and genja-ask's claudefterm target load it through `require('genja-claudefterm')`).

How this file is kept: one heading per feature, one bullet per decision.
Unmarked bullets were stated by jaro. `(inferred)` marks Claude's reading of the
code or history: confirm or delete. `Hint:` is a working note for Claude.

## Layout

- `lua/genja-claudefterm/init.lua`: `setup()`, `toggle()`, `list()`, `paste_context()`, `send()`, `complete()`, `kill()`, session markers. The header comment describes the session marker.
- `plugin/genja-claudefterm.lua`: `:ClaudeFterm [flags]`, `:ClaudeFterm!`.
- Moved out of the config's `lua/genja/claude.lua`; `:ClaudeFterm` moved out of `lua/genja/auto-alias.vim`.

## Decisions

- Standalone: requires no `genja.*` module. Needs vim-floaterm; telescope only for `list()`. lazy.nvim is optional (used to load floaterm when its spec is lazy). (inferred)
- Mappings stay in the config (`plugin/claude-fterm.lua`); only the terminal-local keys (`<C-q>`, `<C-Left>`, ...) are set here.
- `setup({ term = ... })` sets the floaterm options for every start. Defaults: a vsplit on the right (`botright`, width 0.45). Before, they came only with `:ClaudeFterm`, so when `<leader>pC` or the ask popup started claude first it opened in floaterm's default centred float.
- `:ClaudeFterm [flags]` flags are kept for later starts until the next `:ClaudeFterm`; `send(text, flags)` flags apply to that start only. A running claude keeps its flags; both warn when flags would be ignored.
- claude starts with floaterm `--autoclose=never` and `on_exit` closes the window itself: floaterm's own close hits E444 when the claude split is the last window. floaterm's `BufHidden,BufWipeout` autocmd (group `floaterm_enter_insertmode`) also closes the window, so `on_exit` clears it before `nvim_win_set_buf`.
- `kill()` runs from the config's session sweep (`lua/genja/abbreviations.vim`) only when the module is already loaded.
