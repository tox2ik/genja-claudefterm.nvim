-- Claude sessions: the marker comment in a file, the transcript, /rename polling.
-- The marker format and the start/resume flow are in init.lua's header.

local SRC = 'genja-claudefterm/session.lua: '

local M = {}

local MARKER = 'claude%-session: (%x+%-%x+%-%x+%-%x+%-%x+)'
-- a marker with this word is switched off: claude starts fresh and /rename leaves it alone
local MARKER_OFF = ' enabled:false'
M.MARKER_SCAN = 5 -- lines at the top and at the bottom searched for the marker
local POLL_MS = 2000

---True while the terminal job in `bufnr` runs.
---@param bufnr integer
---@return boolean
function M.job_running(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local chan = vim.bo[bufnr].channel
	return chan > 0 and vim.fn.jobwait({ chan }, 0)[1] == -1
end

---Claude's config dir: $CLAUDE_CONFIG_DIR or ~/.claude.
---@return string
local function claude_dir()
	local dir = vim.env.CLAUDE_CONFIG_DIR
	if dir == nil or dir == '' then
		dir = '~/.claude'
	end
	return vim.fs.normalize(dir)
end

---Marker in lines [start, stop) of `buf`.
---@return string|nil id, integer|nil lnum, boolean off
local function scan(buf, start, stop)
	for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, start, stop, false)) do
		local id = line:match(MARKER)
		if id then
			return id, start + i - 1, line:find(MARKER_OFF, 1, true) ~= nil
		end
	end
	return nil, nil, false
end

---Session id in the marker of `buf`, the marker's 0-based line, and whether it is switched off.
---@param buf integer
---@return string|nil id, integer|nil lnum, boolean off
function M.find_marker(buf)
	local count = vim.api.nvim_buf_line_count(buf)
	local id, lnum, off = scan(buf, 0, M.MARKER_SCAN)
	if id then
		return id, lnum, off
	end
	return scan(buf, math.max(M.MARKER_SCAN, count - M.MARKER_SCAN), count)
end

---Transcript of session `id`, in whichever project dir claude put it.
---@param id string
---@return string|nil path
function M.transcript_path(id)
	return vim.fn.glob(claude_dir() .. '/projects/*/' .. id .. '.jsonl', true, true)[1]
end

---`customTitle` of a transcript line from /rename, else nil.
---@param line string
---@return string|nil
local function custom_title(line)
	if not line:find('"type":"custom-title"', 1, true) then
		return nil
	end
	local ok, entry = pcall(vim.json.decode, line)
	if ok and type(entry) == 'table' and type(entry.customTitle) == 'string' then
		return entry.customTitle
	end
	return nil
end

---Last /rename title in a transcript, if any.
---@param path string transcript
---@return string|nil
function M.transcript_title(path)
	local fd = io.open(path, 'r')
	if not fd then
		return nil
	end
	local title = nil
	for line in fd:lines() do
		title = custom_title(line) or title
	end
	fd:close()
	return title
end

---Directory a session was started in: the first existing "cwd" in its transcript,
---else the parent of `file` that encodes to the transcript's project dir name.
---@param path string transcript
---@param file string file the marker is in
---@return string|nil
function M.cwd(path, file)
	local fd = io.open(path, 'r')
	if fd then
		for line in fd:lines() do
			local raw = line:match('"cwd":("[^"]*")')
			local ok, cwd = pcall(vim.json.decode, raw or '')
			if ok and type(cwd) == 'string' and vim.fn.isdirectory(cwd) == 1 then
				fd:close()
				return cwd
			end
		end
		fd:close()
	end
	-- claude names project dirs after the cwd with every non-alphanumeric char as '-'
	local project = vim.fs.basename(vim.fs.dirname(path)):lower()
	for dir in vim.fs.parents(file) do
		if dir:gsub('[^%w]', '-'):lower() == project then
			return dir
		end
	end
	return nil
end

---Marker line for session `id` in `buf`'s comment syntax; nil when it has none.
---@param buf integer
---@param id string
---@param title string
---@return string|nil
local function marker_line(buf, id, title)
	local text = 'claude-session: ' .. id .. ' ' .. title:gsub('%s+', ' ')
	local cs = vim.bo[buf].commentstring
	local at = cs:find('%s', 1, true)
	if at then
		return cs:sub(1, at - 1) .. text .. cs:sub(at + 2)
	end
	if vim.bo[buf].filetype == 'text' then
		return '!! ' .. text -- text files have no comments: a `!!` line, appended at the bottom
	end
	return nil
end

---Put the marker for session `id` into `buf`, replacing an older marker.
---@param buf integer|nil the buffer claude was started from
---@param id string
---@param title string
function M.write_marker(buf, id, title)
	if not buf or not vim.api.nvim_buf_is_loaded(buf) or not vim.bo[buf].modifiable then
		vim.notify(SRC .. 'session renamed, but the buffer claude was started from is gone', vim.log.levels.WARN)
		return
	end
	local _, lnum, off = M.find_marker(buf)
	if off then
		vim.notify(SRC .. 'session renamed; the marker is switched off (enabled:false), left as is')
		return
	end
	local line = marker_line(buf, id, title)
	if not line then
		vim.notify(SRC .. "no 'commentstring' for this filetype; marker not written", vim.log.levels.WARN)
		return
	end
	if lnum then
		if vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] == line then
			return
		end
		vim.api.nvim_buf_set_lines(buf, lnum, lnum + 1, false, { line })
	else
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { line })
	end
	local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':~:.')
	vim.notify(SRC .. 'session marker written to ' .. name .. ' (not saved)')
end

---Switch the marker of `buf` off (` enabled:false` after the id) or back on.
---@param buf integer
function M.toggle_marker(buf)
	local id, lnum, off = M.find_marker(buf)
	if not id or not lnum then
		vim.notify(SRC .. 'no claude-session marker in the first or last ' .. M.MARKER_SCAN .. ' lines')
		return
	end
	local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
	if off then
		line = line:gsub(vim.pesc(MARKER_OFF), '', 1)
		vim.notify(SRC .. 'session marker on: :ClaudeFterm resumes ' .. id)
	else
		line = line:gsub(vim.pesc(id), id .. MARKER_OFF, 1)
		vim.notify(SRC .. 'session marker off: :ClaudeFterm starts a new session')
	end
	vim.api.nvim_buf_set_lines(buf, lnum, lnum + 1, false, { line })
end

---Stop polling the term's transcript.
---@param term genja-claudefterm.Term
function M.stop_watch(term)
	if term.watch_timer then
		term.watch_timer:stop()
		term.watch_timer:close()
		term.watch_timer = nil
	end
end

---Poll session `id`'s transcript for /rename (custom-title lines) while claude runs;
---`on_title(title)` for each new title.
---Polled, not watched: a new session's transcript appears only once claude writes it.
---@param term genja-claudefterm.Term
---@param id string
---@param bufnr integer claude terminal
---@param from_end boolean skip what the transcript holds now (resumed session)
---@param title string|nil current title, from the transcript of a resumed session
---@param on_title fun(title: string)
function M.watch(term, id, bufnr, from_end, title, on_title)
	M.stop_watch(term)
	local path = nil
	local offset = 0
	if from_end then
		path = M.transcript_path(id)
		if path then
			offset = math.max(vim.fn.getfsize(path), 0)
		end
	end

	local timer = assert(vim.uv.new_timer())
	term.watch_timer = timer
	timer:start(POLL_MS, POLL_MS, vim.schedule_wrap(function()
		if term.watch_timer ~= timer then
			return
		end
		if not M.job_running(bufnr) then
			M.stop_watch(term)
			return
		end
		path = path or M.transcript_path(id)
		local fd = path and io.open(path, 'rb')
		if not fd then
			return
		end
		fd:seek('set', offset)
		local data = fd:read('*a') or ''
		fd:close()
		-- only whole lines; a half-written one is read next time
		local cut = data:find('\n[^\n]*$')
		if not cut then
			return
		end
		offset = offset + cut
		for line in data:sub(1, cut):gmatch('[^\n]+') do
			local new = custom_title(line)
			if new and new ~= title then
				title = new
				on_title(title)
			end
		end
	end))
end

return M
