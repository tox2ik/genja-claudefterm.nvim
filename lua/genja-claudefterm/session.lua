-- Claude sessions: the transcript, /rename polling for the terminal name.

local M = {}

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

---Transcript of session `id`, in whichever project dir claude put it.
---@param id string
---@return string|nil path
local function transcript_path(id)
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
---@param on_title fun(title: string)
function M.watch(term, id, bufnr, on_title)
	M.stop_watch(term)
	local path = nil
	local offset = 0
	local title = nil

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
		path = path or transcript_path(id)
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
