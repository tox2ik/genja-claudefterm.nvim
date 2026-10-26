-- Idea #19 A (and #16): Claude Code in floaterms, one per project, fed from the editor.
--   Project root of the current buffer: the cwd of its session marker (see below), else the
--   git root of its file (oil: its dir), else :pwd. Terminal name: `claude-<root basename>`.
--   :ClaudeFterm   toggle this project's terminal; started on first use in the root (or resumed)
--   :ClaudeFterm!, list()   pick a running claude terminal: <CR> shows it, <M-d> kills it
--   :ClaudeFterm [flags]   flags go to claude when it starts, e.g. --chrome, --model opus,
--                  --effort high, --permission-mode plan, --add-dir <dir>; <Tab> completes.
--                  Ignored (with a warning) while claude runs.
--   :ClaudeFterm -1 / -one   no split: claude replaces the current window's buffer; :ClaudeFterm
--                  again puts that buffer back. Only for this start, not kept like flags.
--   paste_context()   paste context into this project's claude: normal = @file mention,
--                  visual = path:lines + code. Jumps into the terminal to type the question.
--   send(text, flags)   type text into claude and submit it (genja-ask's claudefterm target).
--   setup({ term = ... })   floaterm options for every start, whoever starts claude first.
--   <C-q>, <C-j>, <C-Space>   in the claude terminal: back to the previous window
--   <C-Left>                  in the claude terminal: to the window on the left
--   <C-Right>                 in the claude terminal: to the next tab
--   <C-Up>                    in the claude terminal: to normal mode
-- Pasting into the running session avoids `claude -p` startup time and keeps context.
--
-- Session marker (session.lua): :ClaudeFterm resumes the session named in the file.
--   Marker: one comment line in the file, made with 'commentstring':
--     -- claude-session: <uuid> <title>
--   Start: a new claude gets `--session-id <new uuid>`, so its transcript is known:
--     ~/.claude/projects/<cwd, non-alnum -> '-'>/<uuid>.jsonl
--   Write: /rename in claude appends {"type":"custom-title","customTitle":...} to that
--     transcript. A timer reads what was appended; on a new title the marker goes into
--     the buffer claude was started from (term.origin_buf), replacing an older marker.
--     The buffer is changed but not saved.
--   Read: when claude starts, the first and last MARKER_SCAN lines of the current buffer
--     are searched. Found: `--resume <uuid>` in the session's cwd.
--   Off: ` enabled:false` after the id (:ClaudeFtermMarkerToggle) -> claude starts a new
--     session and /rename leaves the marker alone.
--   Text files (filetype text, no 'commentstring'): `!! claude-session: <uuid> <title>`,
--     appended at the bottom.
--   Cwd: glob ~/.claude/projects/*/<uuid>.jsonl and read its "cwd" field.
--     The dir name can't be decoded (the '-' encoding is lossy). Fallback: the parent
--     of the file whose encoded name is that dir.
--
-- Terminal buffer name: `claude-ft «<title>»`, title capped at TITLE_MAX chars with '…';
--   no title yet: `claude-ft «<basename of cwd>»`. Shown in the tabline and winbar.
--   b:claude_session_id holds the session id, b:claude_term the floaterm name.

local M = {}

local SRC = 'genja-claudefterm/init.lua: '

local session = require('genja-claudefterm.session')
local txt = require('genja-util.text')

local TERM_PREFIX = 'claude-'
local TITLE_MAX = 16 -- chars of the session title in the terminal buffer name, '…' included

---:FloatermNew options as { option = value }, plus `cmd` for the command to run.
---From setup({ term = ... }); --name is set here.
---@alias genja-claudefterm.TermOpts table<string, string|number>

---One claude floaterm, per project root.
---@class genja-claudefterm.Term
---@field name string floaterm name, `claude-<root basename>`
---@field root string project root, also claude's cwd; paths are made relative to it
---@field origin_buf integer|nil buffer claude was started from; gets the session marker
---@field watch_timer uv.uv_timer_t|nil polls the transcript for /rename
---@field autoclose string|nil floaterm's --autoclose, done here (see on_exit)
---@field flags string[]|nil extra claude flags it was started with (M.send)
---@field here boolean|nil started with -one: shown in an editor window, not floaterm's split
---@field prev_buf integer|nil -one: the buffer it replaced; shown again on hide and on exit

---Which claude terminal the current buffer belongs to.
---@class genja-claudefterm.Target
---@field root string project root, claude's cwd
---@field name string floaterm name
---@field resume_id string|nil session id from the buffer's marker
---@field title string|nil /rename title of that session

-- Without these, floaterm opens claude in its default centred float.
---@type genja-claudefterm.TermOpts
local DEFAULT_TERM = { title = 'claude', wintype = 'vsplit', position = 'botright', width = 0.45, autoclose = 'smart', cmd = 'claude' }

local state = {
	---@type genja-claudefterm.TermOpts from setup()
	base_opts = vim.deepcopy(DEFAULT_TERM),
	---@type genja-claudefterm.TermOpts base_opts plus the flags of the last :ClaudeFterm
	term_opts = vim.deepcopy(DEFAULT_TERM),
	---@type table<string, genja-claudefterm.Term> by floaterm name
	terms = {},
}

-- {{{ target

---Name the claude terminal buffer `claude-ft «title»`, or after claude's cwd without a title.
---@param bufnr integer
---@param title string|nil
---@param cwd string claude's cwd
local function set_term_name(bufnr, title, cwd)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local label = vim.fs.basename(cwd)
	if title and vim.trim(title) ~= '' then
		-- slashes would split the name for :t in the tabline
		label = vim.trim(title):gsub('%s+', ' '):gsub('[/\\]', '-')
		if vim.fn.strchars(label) > TITLE_MAX then
			label = vim.fn.strcharpart(label, 0, TITLE_MAX - 1) .. '…'
		end
	end
	local name = 'claude-ft «' .. label .. '»'

	local old = vim.api.nvim_buf_get_name(bufnr)
	if vim.fn.fnamemodify(old, ':t') == name then
		return
	end
	if not pcall(vim.api.nvim_buf_set_name, bufnr, name) then
		-- E95: another buffer has that name
		pcall(vim.api.nvim_buf_set_name, bufnr, name .. ' ' .. bufnr)
	end
	-- renaming leaves an unlisted buffer with the old name; a term:// one would start a shell
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if b ~= bufnr and not vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == old then
			vim.api.nvim_buf_delete(b, { force = true })
		end
	end
end

---The current buffer's file, nil for oil://, term:// and unnamed buffers.
---@return string|nil
local function buffer_file()
	local file = vim.api.nvim_buf_get_name(0)
	if file == '' or vim.bo.buftype ~= '' then
		return nil
	end
	return file
end

---Directory of the current buffer: its file's dir, oil's dir, else :pwd.
---@return string
local function buffer_dir()
	if vim.bo.filetype == 'oil' then
		local ok, oil = pcall(require, 'oil')
		local dir = ok and oil.get_current_dir()
		if dir then
			return dir
		end
	end
	local file = buffer_file()
	if file then
		return vim.fs.dirname(file)
	end
	return vim.fn.getcwd()
end

---Floaterm name for `root`: `claude-<basename>`; a short hash is added when another root has it.
---@param root string
---@return string
local function term_name(root)
	local name = TERM_PREFIX .. vim.fs.basename(root):gsub('[^%w%-_.]', '-')
	local term = state.terms[name]
	if term and term.root:lower() ~= root:lower() then
		name = name .. '-' .. vim.fn.sha256(root:lower()):sub(1, 6)
	end
	return name
end

---Target of the current buffer: a claude terminal itself, the session in its marker,
---else the git root of its dir, else :pwd.
---@return genja-claudefterm.Target
local function target()
	local own = vim.b.claude_term
	if own and state.terms[own] then
		return { root = state.terms[own].root, name = own }
	end

	local file = buffer_file()
	local id, _, off = session.find_marker(0)
	if file and id and not off then
		local path = session.transcript_path(id)
		local cwd = path and session.cwd(path, file)
		if cwd then
			local root = vim.fs.normalize(cwd)
			return { root = root, name = term_name(root), resume_id = id, title = session.transcript_title(path) }
		end
		vim.notify(SRC .. 'no transcript or cwd for session ' .. id .. '; starting a new one', vim.log.levels.WARN)
	end

	local root = vim.fs.normalize(vim.fs.root(buffer_dir(), '.git') or vim.fn.getcwd())
	return { root = root, name = term_name(root) }
end

---Floaterm options to start claude for `t`: resume its session, else a new one with a known id.
---@param t genja-claudefterm.Target
---@param flags? string[] extra claude flags, e.g. { '--model', 'opus' }
---@return genja-claudefterm.TermOpts opts, string id
local function start_opts(t, flags)
	local opts = vim.deepcopy(state.term_opts)
	local cmd = table.concat(vim.list_extend({ opts.cmd or 'claude' }, flags or {}), ' ')
	local id = t.resume_id
	if id then
		opts.cmd = cmd .. ' --resume ' .. id
	else
		id = txt.uuid()
		opts.cmd = cmd .. ' --session-id ' .. id
	end
	-- floaterm splits its options on unescaped spaces
	opts.cwd = (t.root:gsub(' ', '\\ '))
	return opts, id
end
-- }}}

-- {{{ terminal

---Make sure vim-floaterm is loaded; under lazy.nvim its spec may load on commands only.
local function load_floaterm()
	if vim.g.loaded_floaterm ~= nil then
		return
	end
	local ok, lazy = pcall(require, 'lazy')
	if ok then
		lazy.load({ plugins = { 'vim-floaterm' } })
	end
end

---Forget the term `name` (its job is gone).
---@param name string
local function forget(name)
	local term = state.terms[name]
	if term then
		session.stop_watch(term)
		state.terms[name] = nil
	end
end

---Buffer of the running floaterm `name`; a dead job is killed and counts as none.
---@param name string
---@return integer|nil bufnr
local function term_bufnr(name)
	load_floaterm()
	local bufnr = vim.fn['floaterm#terminal#get_bufnr'](name)
	if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	if not session.job_running(bufnr) then
		vim.cmd('FloatermKill ' .. name)
		forget(name)
		return nil
	end
	return bufnr
end

---Window showing `bufnr`, in any tab, if any.
---@param bufnr integer
---@return integer|nil win
local function term_win(bufnr)
	return vim.fn.win_findbuf(bufnr)[1]
end

---Window floaterm opened for `bufnr` (its split); nil when shown in an editor window (-one).
---@param bufnr integer
---@return integer|nil win
local function floaterm_win(bufnr)
	local win = vim.b[bufnr].floaterm_winid
	if type(win) == 'number' and win > 0 and vim.api.nvim_win_is_valid(win) then
		return win
	end
	return nil
end

---The first of `a`, `b` that is still valid, else a new empty buffer.
---@param a integer|nil
---@param b? integer|nil
---@return integer
local function valid_or_new(a, b)
	for _, buf in ipairs({ a or -1, b or -1 }) do
		if vim.api.nvim_buf_is_valid(buf) then
			return buf
		end
	end
	return vim.api.nvim_create_buf(true, false)
end

---With -one: show `bufnr` in window `win` and remember the buffer it replaces.
---floaterm's winid is cleared: its BufHidden hook closes that window, and this one is the user's.
---@param term genja-claudefterm.Term
---@param bufnr integer terminal buffer
---@param win integer
local function show_here(term, bufnr, win)
	local prev = vim.api.nvim_win_get_buf(win)
	if prev ~= bufnr then
		term.prev_buf = prev
	end
	vim.api.nvim_win_set_buf(win, bufnr)
	vim.fn['floaterm#config#set'](bufnr, 'winid', -1)
end

---With -one: put the replaced buffer back into `win` (a new empty one when it is gone).
---@param term genja-claudefterm.Term
---@param win integer window showing claude
local function restore_here(term, win)
	vim.api.nvim_win_set_buf(win, valid_or_new(term.prev_buf, term.origin_buf))
end

---When claude's job ends: close its windows like floaterm's --autoclose would.
---floaterm's own close fails with E444 when a split is the last window,
---so floaterm gets --autoclose=never and this keeps the last window open on another buffer.
---@param term genja-claudefterm.Term
---@param bufnr integer terminal buffer
local function on_exit(term, bufnr)
	vim.api.nvim_create_autocmd('TermClose', {
		buffer = bufnr,
		once = true,
		callback = function()
			local status = vim.v.event.status
			local ac = tostring(term.autoclose or 'smart')
			if state.terms[term.name] == term then
				forget(term.name)
			end
			if not (ac == 'always' or (ac == 'smart' and status == 0)) then
				return
			end
			-- after floaterm's exit callback, which still reads the buffer
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end
				-- floaterm's BufHidden/BufWipeout autocmd would close the window again (E444)
				pcall(vim.api.nvim_clear_autocmds, { group = 'floaterm_enter_insertmode', buffer = bufnr })
				local split = floaterm_win(bufnr)
				for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
					local last = #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) == 1
						and #vim.api.nvim_list_tabpages() == 1
					if term.here and win ~= split then
						-- -one: the user's window; give it its buffer back instead of closing it
						restore_here(term, win)
					elseif last then
						-- E444 otherwise: show some other buffer in the last window
						vim.api.nvim_win_set_buf(win, valid_or_new(term.origin_buf))
					else
						pcall(vim.api.nvim_win_close, win, true)
					end
				end
				pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
			end)
		end,
	})
end

---Wait until a freshly started claude has drawn its UI, then run `cb`.
---A guess: first output + 800 ms. The folder-trust question or a slow MCP start
---can still be on screen then, and the paste lands there instead of the prompt.
---@param bufnr integer terminal buffer
---@param cb fun()
local function when_ready(bufnr, cb)
	local waited = 0
	local function poll()
		local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '')
		if vim.trim(text) ~= '' then
			vim.defer_fn(cb, 800) -- the input box comes a moment after the first output
			return
		end
		if waited >= 15000 then
			vim.notify(SRC .. 'claude did not start within 15 s', vim.log.levels.WARN)
			return
		end
		waited = waited + 200
		vim.defer_fn(poll, 200)
	end
	poll()
end

local BACK = '<C-\\><C-n><C-w>p'
-- Terminal-mode keys in the claude buffer: { lhs, rhs, desc }.
-- Buffer-local: a global <C-w> map would break claude's delete-word.
local TERM_KEYS = {
	{ '<C-q>', BACK, 'back to previous window' },
	-- replaces claude's own <C-j> newline; <S-CR> or \<CR> still add one
	-- check this: does nvim's terminal pass <S-CR> to claude as Shift+Enter, or as plain Enter?
	{ '<C-j>', BACK, 'back to previous window' },
	-- a terminal (e.g. Windows Terminal) may send <C-Space> as <C-@>; map that too if this doesn't fire
	{ '<C-Space>', BACK, 'back to previous window' },
	-- these replace claude's own <C-Left> word-left, <C-Right> word-right, <C-Up>
	{ '<C-Left>', '<C-\\><C-n><C-w>h', 'to the window on the left' },
	{ '<C-Right>', '<Cmd>tabnext<CR>', 'to the next tab' },
	{ '<C-Up>', '<C-\\><C-n>', 'to normal mode' },
	-- same keys as the tab maps in map-zero.lua, which don't cover terminal mode
	{ '<M-]>', '<Cmd>tabnext<CR>', 'to the next tab' },
	{ '<M-[>', '<Cmd>tabprev<CR>', 'to the previous tab' },
	-- <M-S-[> arrives as <M-{>
	{ '<M-{>', BACK, 'back to previous window' },
}

---@param bufnr integer terminal buffer
local function set_term_keys(bufnr)
	for _, k in ipairs(TERM_KEYS) do
		vim.keymap.set('t', k[1], k[2], { buffer = bufnr, desc = 'Claude: ' .. k[3] })
	end
end

---:FloatermNew arguments from `opts`: sorted `--option=value`, then the command.
---@param name string floaterm name
---@param opts genja-claudefterm.TermOpts
---@return string
local function fterm_args(name, opts)
	local keys = vim.tbl_keys(opts)
	table.sort(keys)
	local args = { '--name=' .. name }
	for _, key in ipairs(keys) do
		if key ~= 'cmd' and key ~= 'name' then
			table.insert(args, '--' .. key .. '=' .. tostring(opts[key]))
		end
	end
	table.insert(args, opts.cmd or 'claude')
	return table.concat(args, ' ')
end

---Start claude for `t` with a new floaterm; nil when that failed.
---@param t genja-claudefterm.Target
---@param flags? string[]
---@param here? boolean -one: move it into window `origin`
---@param origin integer
---@return integer|nil bufnr
local function start(t, flags, here, origin)
	---@type genja-claudefterm.Term
	local term = { name = t.name, root = t.root, flags = flags }
	if buffer_file() then
		term.origin_buf = vim.api.nvim_get_current_buf()
	end
	state.terms[t.name] = term
	local opts, id = start_opts(t, flags)
	term.autoclose = opts.autoclose
	opts.autoclose = 'never' -- on_exit closes the window instead
	-- claude's title updates make the mouse cursor flicker between normal and hourglass;
	-- related: "terminalProgressBarEnabled": false in claude's settings.json.
	-- Set only while the job starts, so other terminals keep their titles.
	local old_title_env = vim.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE
	vim.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'
	vim.cmd('FloatermNew ' .. fterm_args(t.name, opts))
	vim.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE = old_title_env

	local bufnr = term_bufnr(t.name)
	if not bufnr then
		return nil
	end
	if here then
		-- floaterm opened its split; move claude into the window it was started from
		term.here = true
		local split = term_win(bufnr)
		show_here(term, bufnr, origin)
		if split and split ~= origin then
			vim.api.nvim_win_close(split, true)
		end
	end
	set_term_keys(bufnr)
	on_exit(term, bufnr)
	vim.b[bufnr].claude_session_id = id
	vim.b[bufnr].claude_term = t.name
	set_term_name(bufnr, t.title, t.root)
	session.watch(term, id, bufnr, t.resume_id ~= nil, t.title, function(title)
		session.write_marker(term.origin_buf, id, title)
		set_term_name(bufnr, title, term.root)
	end)
	return bufnr
end

---Start claude for `t` or show it, then call `cb(bufnr)` once it can take input.
---@param focus boolean true: stay in the terminal (terminal mode); false: back to the editor
---@param cb? fun(bufnr: integer)
---@param t? genja-claudefterm.Target default: the current buffer's
---@param flags? string[] extra claude flags; only used when claude starts
---@param here? boolean -one: a new claude takes the current window instead of a split
local function open(focus, cb, t, flags, here)
	t = t or target()
	local origin = vim.api.nvim_get_current_win()
	local bufnr = term_bufnr(t.name)
	local is_new = (bufnr == nil)
	if is_new then
		bufnr = start(t, flags, here, origin)
	elseif not term_win(bufnr) then
		vim.cmd('FloatermShow ' .. t.name)
	end
	if not bufnr then
		forget(t.name)
		vim.notify(SRC .. 'could not start claude', vim.log.levels.ERROR)
		return
	end

	if focus then
		local win = term_win(bufnr)
		if win then
			vim.api.nvim_set_current_win(win)
			vim.cmd.startinsert()
		end
	elseif vim.api.nvim_win_is_valid(origin) then
		vim.cmd.stopinsert()
		vim.api.nvim_set_current_win(origin)
	end

	if not cb then
		return
	end
	if is_new then
		when_ready(bufnr, function() cb(bufnr) end)
	else
		cb(bufnr)
	end
end

---Type `text` into claude as one bracketed paste (newlines don't submit), optionally submit.
---@param bufnr integer terminal buffer
---@param text string
---@param submit boolean true: press Enter after the paste
local function paste(bufnr, text, submit)
	local chan = vim.bo[bufnr].channel
	vim.api.nvim_chan_send(chan, '\27[200~' .. text .. '\27[201~')
	if submit then
		-- a short gap, so the paste is taken in before Enter
		vim.defer_fn(function() vim.api.nvim_chan_send(chan, '\r') end, 100)
	end
end

---Warn that `flags` are ignored by the running claude `name`.
---@param name string
---@param flags string
local function warn_running(name, flags)
	-- flags only apply at start; a running claude keeps its own
	vim.notify(SRC .. 'claude already runs; ' .. flags .. ' ignored (:FloatermKill ' .. name .. ', then retry)', vim.log.levels.WARN)
end

---Floaterm options for every start; `term` is merged over the defaults (a vsplit on the right).
---@param opts? { term?: genja-claudefterm.TermOpts }
function M.setup(opts)
	opts = opts or {}
	state.base_opts = vim.tbl_extend('force', vim.deepcopy(DEFAULT_TERM), opts.term or {})
	state.term_opts = vim.deepcopy(state.base_opts)
end

---Split `-1` / `-one` off the :ClaudeFterm args.
---@param args? string
---@return string args the claude flags left over
---@return boolean one true: start claude in the current window
local function take_one_switch(args)
	local rest = {}
	local one = false
	for _, word in ipairs(vim.split(vim.trim(args or ''), '%s+', { trimempty = true })) do
		if word == '-1' or word == '-one' then
			one = true
		else
			table.insert(rest, word)
		end
	end
	return table.concat(rest, ' '), one
end

---:ClaudeFterm: hide this project's claude when shown, else show (start) it and jump in.
---:ClaudeFterm!: pick a running claude terminal (M.list).
---@param args? string extra claude flags from :ClaudeFterm, e.g. '--chrome'; kept for later starts
---@param pick? boolean true for :ClaudeFterm!
function M.toggle(args, pick)
	local flags, one = take_one_switch(args)
	state.term_opts = vim.deepcopy(state.base_opts)
	if flags ~= '' then
		state.term_opts.cmd = (state.base_opts.cmd or 'claude') .. ' ' .. flags
	end
	if pick then
		M.list()
		return
	end
	local t = target()
	local bufnr = term_bufnr(t.name)
	if not bufnr then
		open(true, nil, t, nil, one)
		return
	end
	if flags ~= '' then
		warn_running(t.name, flags)
	end
	local term = state.terms[t.name]
	local here = (term and term.here)
	local win = term_win(bufnr)
	if win and here and win ~= floaterm_win(bufnr) then
		restore_here(term, win)
	elseif win then
		vim.cmd('FloatermHide ' .. t.name)
	elseif here then
		show_here(term, bufnr, vim.api.nvim_get_current_win())
		vim.cmd.startinsert()
	else
		open(true, nil, t)
	end
end

---@class genja-claudefterm.Running
---@field name string floaterm name
---@field root string project root
---@field label string terminal buffer name, e.g. `claude-ft «<title>»`

---Running claude terminals, sorted by name; for pickers outside this plugin (e.g. <F2>).
---@return genja-claudefterm.Running[]
function M.running()
	local items = {}
	for name, term in pairs(state.terms) do
		local bufnr = term_bufnr(name)
		if bufnr then
			local label = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':t')
			table.insert(items, { name = name, root = term.root, label = label })
		end
	end
	table.sort(items, function(a, b) return a.name < b.name end)
	return items
end

---Show the running terminal `name` and jump in.
---@param name string floaterm name, from M.running()
function M.show(name)
	local term = state.terms[name]
	if not term then
		vim.notify(SRC .. name .. ' is not running', vim.log.levels.WARN)
		return
	end
	open(true, nil, { root = term.root, name = name })
end

---:ClaudeFterm!: running claude terminals in a dropdown; <CR> shows one, <M-d> kills it.
function M.list()
	local items = M.running()
	if #items == 0 then
		vim.notify(SRC .. 'no claude terminal runs; :ClaudeFterm starts one for this project')
		return
	end

	local actions = require('telescope.actions')
	local action_state = require('telescope.actions.state')
	---Close the picker, then `fn(item)` for the selected one.
	local function with_selected(prompt_bufnr, fn)
		return function()
			local entry = action_state.get_selected_entry()
			actions.close(prompt_bufnr)
			if entry then
				fn(entry.value)
			end
		end
	end
	require('telescope.pickers').new(require('telescope.themes').get_dropdown({}), {
		prompt_title = 'Claude terminals  <CR> show  <M-d> kill',
		finder = require('telescope.finders').new_table({
			results = items,
			entry_maker = function(item)
				return {
					value = item,
					display = item.name .. '  ' .. item.label .. '  ' .. item.root,
					ordinal = item.name .. ' ' .. item.label .. ' ' .. item.root,
				}
			end,
		}),
		sorter = require('telescope.config').values.generic_sorter({}),
		attach_mappings = function(prompt_bufnr, map)
			actions.select_default:replace(with_selected(prompt_bufnr, function(item)
				open(true, nil, { root = item.root, name = item.name })
			end))
			map({ 'i', 'n' }, '<M-d>', with_selected(prompt_bufnr, function(item)
				vim.cmd('FloatermKill ' .. item.name)
				forget(item.name)
				vim.schedule(M.list)
			end), { desc = 'Claude: kill this terminal' })
			return true
		end,
	}):find()
end

-- Flags offered by :ClaudeFterm <Tab>. Session flags (--resume, --session-id, --continue)
-- are left out: this plugin sets those itself.
local FLAGS = {
	'-one', -- this plugin's: no split, claude replaces the current buffer
	'--chrome',
	'--no-chrome',
	'--model',
	'--effort',
	'--permission-mode',
	'--add-dir',
	'--ide',
	'--verbose',
	'--fork-session',
	'--dangerously-skip-permissions',
}
-- Values offered after a flag that takes one.
local FLAG_VALUES = {
	['--model'] = { 'fable', 'opus', 'sonnet', 'haiku' },
	['--effort'] = { 'low', 'medium', 'high', 'xhigh', 'max' },
	['--permission-mode'] = { 'acceptEdits', 'auto', 'bypassPermissions', 'manual', 'dontAsk', 'plan' },
}

---:ClaudeFterm completion: a value after --model/--effort/--permission-mode, else a flag.
---@param arglead string word being completed
---@param cmdline string command line up to the cursor
---@return string[]
function M.complete(arglead, cmdline)
	local words = vim.split(vim.trim(cmdline), '%s+')
	local prev = words[#words - (arglead ~= '' and 1 or 0)]
	if prev == '--add-dir' then
		return vim.fn.getcompletion(arglead, 'dir')
	end
	return vim.tbl_filter(function(choice)
		return vim.startswith(choice, arglead)
	end, FLAG_VALUES[prev] or FLAGS)
end

---Kill every claude terminal; used by `:s:` before :qa (a running job blocks :qa).
---Doesn't load floaterm just for this.
function M.kill()
	local first = true
	for name, term in pairs(state.terms) do
		session.stop_watch(term)
		if vim.g.loaded_floaterm ~= nil and vim.fn['floaterm#terminal#get_bufnr'](name) ~= -1 then
			-- let the previous job's exit run first: FloatermKills back to back sometimes crash a
			-- headless nvim on Windows. Still synchronous: the s: abbreviation runs :qa right after.
			if not first then
				vim.wait(200)
			end
			first = false
			vim.cmd('FloatermKill ' .. name)
		end
	end
	state.terms = {}
end

---Switch the current buffer's session marker off (` enabled:false` after the id) or back on.
---Off: :ClaudeFterm starts a new session and /rename leaves the marker alone.
function M.toggle_marker()
	session.toggle_marker(vim.api.nvim_get_current_buf())
end
-- }}}

-- {{{ context

---`file` relative to claude's start dir (the project root), forward slashes; absolute when outside.
---@param file string
---@param base string project root
---@return string
local function rel_path(file, base)
	return vim.fs.relpath(base, file) or vim.fs.normalize(file)
end

---Paste the file (@mention) or the selection into claude, then jump in to ask.
function M.paste_context()
	local t = target()
	local file = buffer_file()
	local text = nil
	if vim.fn.mode():match('^[vV\22]') then
		local first, last = txt.visual_lines()
		if file then
			local code = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), '\n')
			local label = rel_path(file, t.root) .. ':' .. first .. '-' .. last
			text = label .. '\n' .. txt.fenced(code, vim.bo.filetype) .. '\n\n'
		end
	elseif file then
		text = '@' .. rel_path(file, t.root) .. ' '
	end
	if not text then
		vim.notify(SRC .. 'nothing to paste: this buffer has no file', vim.log.levels.WARN)
		return
	end
	open(true, function(bufnr) paste(bufnr, text, false) end, t)
end
-- }}}

-- {{{ send

---Type `text` into this project's claude and submit it; claude starts when needed.
---The cursor stays in the editor. Used by the ask popup's claudefterm backend.
---@param text string
---@param flags? string[] extra claude flags, e.g. { '--model', 'opus' }; only used when claude starts
function M.send(text, flags)
	local t = target()
	local term = state.terms[t.name]
	if flags and term and term_bufnr(t.name) then
		local want = table.concat(flags, ' ')
		if want ~= table.concat(term.flags or {}, ' ') then
			warn_running(t.name, want)
		end
	end
	open(false, function(bufnr) paste(bufnr, text, true) end, t, flags)
end
-- }}}

-- Drops the cached module; the next require (e.g. :ClaudeFterm) loads it fresh.
-- `state` (terminals, term opts) is lost with it; running terminals stay
-- but are no longer listed by :ClaudeFterm!.
vim.api.nvim_create_user_command('DevReloadClaude', function()
	package.loaded['genja-claudefterm'] = nil
	package.loaded['genja-claudefterm.session'] = nil
	vim.notify(SRC .. 'module unloaded, next require reloads it')
end, { desc = 'Claude: unload genja-claudefterm' })

return M
