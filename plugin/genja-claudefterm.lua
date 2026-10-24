-- :ClaudeFterm [flags]   toggle this project's claude; flags apply when claude starts, <Tab> completes
-- :ClaudeFterm -1 [flags], :ClaudeFterm -one [flags]   no split: claude replaces the current buffer
-- :ClaudeFterm!          pick a running claude terminal
vim.api.nvim_create_user_command('ClaudeFterm', function(cmd)
	require('genja-claudefterm').toggle(cmd.args, cmd.bang)
end, {
	bang = true,
	nargs = '*',
	complete = function(arglead, cmdline, cursorpos)
		return require('genja-claudefterm').complete(arglead, cmdline:sub(1, cursorpos))
	end,
	desc = "Claude: toggle this project's claude terminal (!: pick a running one)",
})
