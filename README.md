# genja-claudefterm.nvim

Claude Code in a [vim-floaterm](https://github.com/voldikss/vim-floaterm)
terminal, one per project, fed from the editor.

- One terminal per project root: the git root of the current file (oil: its
  directory), else `:pwd`. Named `claude-<root basename>`.
- Session markers: after `/rename` in claude, a comment line
  `claude-session: <uuid> <title>` goes into the file you started from;
  `:ClaudeFterm` in that file resumes the session later.
- Paste context: the current file as an `@file` mention, or a selection as
  `path:lines` plus the code.
- `send(text)` types text into claude and submits it (used by
  [genja-ask.nvim](https://github.com/tox2ik/genja-ask.nvim)).

## Requirements

- Neovim 0.11+
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` on PATH)
- [vim-floaterm](https://github.com/voldikss/vim-floaterm)
- [genja-util.nvim](https://github.com/tox2ik/genja-util.nvim) (uuid, code fence, visual range)
- telescope.nvim, only for picking a running terminal (`:ClaudeFterm!`)

## Install (lazy.nvim)

```lua
{
    'tox2ik/genja-claudefterm.nvim',
    dependencies = { 'tox2ik/genja-util.nvim', 'voldikss/vim-floaterm' },
    cmd = 'ClaudeFterm',
    keys = {
        { '<leader>pC', function() require('genja-claudefterm').paste_context() end, mode = { 'n', 'x' }, desc = 'Claude: paste context' },
    },
    opts = {
        -- floaterm options for every start; default: a vsplit on the right
        term = { wintype = 'vsplit', position = 'botright', width = 0.45 },
    },
}
```

## Commands

| Command | Action |
|---|---|
| `:ClaudeFterm` | show or hide this project's claude; starts it (or resumes the file's session) on first use |
| `:ClaudeFterm [flags]` | flags go to claude when it starts, e.g. `--model opus`, `--permission-mode plan`; `<Tab>` completes |
| `:ClaudeFterm -ax` | claude with `--ax-screen-reader` |
| `:ClaudeFterm -1`, `-one` | no split: claude replaces the current window's buffer; again puts the buffer back |
| `:ClaudeFterm!` | pick a running claude terminal: `<CR>` shows it, `<M-d>` kills it |
| `:ClaudeFtermMarkerToggle` | switch the file's session marker off (new sessions) or on (resume) |

Flags only apply when claude starts; a running claude keeps its own and you get a warning.

## Keys in the claude terminal

| Key | Action |
|---|---|
| `<C-q>`, `<C-j>`, `<C-Space>` | back to the previous window |
| `<C-Left>` | to the window on the left |
| `<C-Right>` | to the next tab |
| `<C-Up>` | normal mode |

## Lua API

`toggle(args, pick)`, `paste_context()`, `send(text, flags)`, `running()`,
`show(name)`, `list()`, `kill()`, `toggle_marker()`.

## License

MIT
