local M = {}

local context = require("pi-ide.suggestion.context")
local render = require("pi-ide.suggestion.render")
local keys = require("pi-ide.suggestion.keys")
local logger = require("pi-ide.logger")

local DEBOUNCE_MS = 300
local REQUEST_TIMEOUT_MS = 30000

local state = {
	server = nil,
	enabled = true,
	augroup = nil,
	timer = nil,
	notified_request_failed = false,
	session = nil,
	suppressing = false,
	model = nil,
}

-- session = {
--   bufnr,
--   anchor_row, anchor_col,   -- where the next char of suggestion is expected
--   suggestions = { string, ... },
--   index = 1,
--   consumed = N,             -- bytes of suggestions[index] already in buffer
--   request_id = nil OR id,   -- in-flight outbound request id
-- }

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "pi-ide-suggest" })
end

local function cancel_timer()
	if state.timer and not state.timer:is_closing() then
		state.timer:stop()
		state.timer:close()
	end
	state.timer = nil
end

local function dismiss()
	if not state.session then return end
	if state.session.request_id and state.server then
		state.server.cancel_request(state.session.request_id)
	end
	if state.session.timeout_timer and not state.session.timeout_timer:is_closing() then
		state.session.timeout_timer:stop()
		state.session.timeout_timer:close()
	end
	if state.session.bufnr then render.clear(state.session.bufnr) end
	state.session = nil
end

local function remaining_text(session)
	return session.suggestions[session.index]:sub(session.consumed + 1)
end

local function render_current()
	if not state.session then return end
	local s = state.session
	if #s.suggestions == 0 then return end
	if not vim.api.nvim_buf_is_valid(s.bufnr) then dismiss() return end
	-- Buffer could have been truncated under us (LSP autoformat, external edit);
	-- bail rather than throw on an out-of-range extmark.
	if s.anchor_row >= vim.api.nvim_buf_line_count(s.bufnr) then dismiss() return end
	local text = remaining_text(s)
	if text == "" then dismiss() return end
	local ok, err = pcall(render.show, s.bufnr, s.anchor_row, s.anchor_col, text, s.index, #s.suggestions)
	if not ok then
		logger.debug("suggestion", "render failed:", tostring(err))
		if s.manual then notify("pi-ide suggestion: render failed (" .. tostring(err) .. ")", vim.log.levels.WARN) end
		dismiss()
	end
end

local function cycle_to_matching(prefix_text)
	local s = state.session
	for i, sug in ipairs(s.suggestions) do
		if sug:sub(1, #prefix_text) == prefix_text then
			s.index = i
			s.consumed = #prefix_text
			return true
		end
	end
	return false
end

local function get_typed_text(bufnr, start_row, start_col, end_row, end_col)
	if start_row == end_row then
		local line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1] or ""
		return line:sub(start_col + 1, end_col)
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
	if #lines == 0 then return "" end
	lines[1] = lines[1]:sub(start_col + 1)
	lines[#lines] = lines[#lines]:sub(1, end_col)
	return table.concat(lines, "\n")
end

-- Walk through `typed` and `remaining` in parallel, allowing whitespace
-- divergence: characters that indentexpr / auto-format insert (or that the
-- user types as extra indent) are tolerated as long as the non-whitespace
-- characters still line up. Returns the number of bytes of `remaining` that
-- are now considered consumed, or nil if there is a real divergence.
local function consume_tolerant(typed, remaining)
	local ti, ri = 1, 1
	while ti <= #typed and ri <= #remaining do
		local tc = typed:sub(ti, ti)
		local rc = remaining:sub(ri, ri)
		if tc == rc then
			ti = ti + 1
			ri = ri + 1
		elseif tc:match("%s") then
			ti = ti + 1
		elseif rc:match("%s") then
			ri = ri + 1
		else
			return nil
		end
	end
	if ti <= #typed then return nil end
	return ri - 1
end

local function with_suppression(fn)
	-- TextChangedI / CursorMovedI fire on the next event-loop tick, not
	-- synchronously inside nvim_buf_set_text / nvim_win_set_cursor. Reset
	-- via vim.schedule so the flag survives until those autocmds drain.
	state.suppressing = true
	local ok, err = pcall(fn)
	vim.schedule(function() state.suppressing = false end)
	if not ok then error(err) end
end

local function insert_text(bufnr, text)
	local cur = vim.api.nvim_win_get_cursor(0)
	local row = cur[1] - 1
	local col = cur[2]
	local lines = vim.split(text, "\n", { plain = true })
	vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)
	local new_row, new_col
	if #lines == 1 then
		new_row = row
		new_col = col + #lines[1]
	else
		new_row = row + #lines - 1
		new_col = #lines[#lines]
	end
	vim.api.nvim_win_set_cursor(0, { new_row + 1, new_col })
	return new_row, new_col
end

local function reconcile(bufnr)
	if not state.session or state.session.bufnr ~= bufnr then return end
	local s = state.session
	-- Response not back yet: the start_session callback will reconcile any
	-- chars typed during the in-flight window when it runs.
	if #s.suggestions == 0 then return end
	local cur = vim.api.nvim_win_get_cursor(0)
	local cur_row = cur[1] - 1
	local cur_col = cur[2]
	if cur_row < s.anchor_row or (cur_row == s.anchor_row and cur_col < s.anchor_col) then
		dismiss()
		return
	end
	if cur_row == s.anchor_row and cur_col == s.anchor_col then
		render_current()
		return
	end
	local typed = get_typed_text(bufnr, s.anchor_row, s.anchor_col, cur_row, cur_col)
	local current = s.suggestions[s.index]
	local consumed_delta = consume_tolerant(typed, current:sub(s.consumed + 1))
	if consumed_delta then
		s.consumed = s.consumed + consumed_delta
		s.anchor_row = cur_row
		s.anchor_col = cur_col
		render_current()
		return
	end
	local prefix = current:sub(1, s.consumed) .. typed
	if cycle_to_matching(prefix) then
		s.anchor_row = cur_row
		s.anchor_col = cur_col
		render_current()
	else
		dismiss()
	end
end

local function start_session(bufnr, anchor_row, anchor_col, manual)
	dismiss()
	local client = state.server and state.server.first_client() or nil
	if not client then
		-- Silent on auto-trigger: this is a transient startup race that
		-- resolves itself once the user runs /ide in pi. Only the explicit
		-- manual trigger reports it, since the user is actively asking.
		if manual then
			notify("pi-ide suggestion: no extension client connected (run /ide in pi)", vim.log.levels.WARN)
		end
		return
	end
	-- Inline virt_text uses byte columns and virt_lines anchor to buffer rows,
	-- both of which render in the wrong screen position on lines with
	-- concealed syntax or on lines wrapped past the window edge. Decline
	-- rather than show ghost text at the wrong spot.
	if vim.wo.conceallevel > 0 then
		if manual then notify("pi-ide suggestion: skipped (conceallevel > 0 — ghost text would misalign)", vim.log.levels.WARN) end
		return
	end
	if vim.wo.wrap then
		local line_len = vim.api.nvim_strwidth(vim.api.nvim_get_current_line())
		if line_len >= vim.api.nvim_win_get_width(0) then
			if manual then notify("pi-ide suggestion: skipped (current line wraps — ghost text would misalign)", vim.log.levels.WARN) end
			return
		end
	end
	local params = context.gather(bufnr, anchor_row, anchor_col, { model = state.model })
	local session = {
		bufnr = bufnr,
		anchor_row = anchor_row,
		anchor_col = anchor_col,
		suggestions = {},
		index = 1,
		consumed = 0,
		request_id = nil,
		manual = manual or false,
	}
	state.session = session
	local id = state.server.request_client(client, "getSuggestions", params, function(err, result)
		vim.schedule(function()
			if state.session ~= session then return end
			session.request_id = nil
			if session.timeout_timer and not session.timeout_timer:is_closing() then
				session.timeout_timer:stop()
				session.timeout_timer:close()
			end
			session.timeout_timer = nil
			if err then
				logger.debug("suggestion", "request failed:", err.message or "")
				if session.manual or not state.notified_request_failed then
					notify("pi-ide suggestion: request failed (" .. (err.message or "?") .. ")", vim.log.levels.WARN)
					state.notified_request_failed = true
				end
				state.session = nil
				return
			end
			state.notified_request_failed = false
			local sugs = (result and result.suggestions) or {}
			if #sugs == 0 then
				state.session = nil
				if session.manual then notify("pi-ide suggestion: no completions returned") end
				return
			end
			session.suggestions = sugs
			local cur = vim.api.nvim_win_get_cursor(0)
			local cur_row = cur[1] - 1
			local cur_col = cur[2]
			if vim.api.nvim_get_current_buf() ~= session.bufnr then
				if session.manual then notify("pi-ide suggestion: dropped (buffer changed during request)") end
				state.session = nil
				return
			end
			if cur_row < session.anchor_row or (cur_row == session.anchor_row and cur_col < session.anchor_col) then
				if session.manual then notify("pi-ide suggestion: dropped (cursor moved backward during request)") end
				state.session = nil
				return
			end
			if cur_row > session.anchor_row or cur_col > session.anchor_col then
				local typed = get_typed_text(session.bufnr, session.anchor_row, session.anchor_col, cur_row, cur_col)
				local match_idx, match_consumed = nil, nil
				for i, sug in ipairs(sugs) do
					local delta = consume_tolerant(typed, sug)
					if delta then match_idx, match_consumed = i, delta; break end
				end
				if not match_idx then
					if session.manual then notify("pi-ide suggestion: dropped (typed text diverged from all alternatives)") end
					state.session = nil
					return
				end
				session.index = match_idx
				session.consumed = match_consumed
				session.anchor_row = cur_row
				session.anchor_col = cur_col
			end
			render_current()
		end)
	end)
	session.request_id = id
	session.timeout_timer = vim.defer_fn(function()
		if state.session ~= session or not session.request_id then return end
		notify("pi-ide suggestion: request timed out", vim.log.levels.WARN)
		dismiss()
	end, REQUEST_TIMEOUT_MS)
end

function M.trigger()
	local bufnr = vim.api.nvim_get_current_buf()
	local cur = vim.api.nvim_win_get_cursor(0)
	start_session(bufnr, cur[1] - 1, cur[2], true)
end

function M.toggle()
	state.enabled = not state.enabled
	notify("pi-ide auto suggestions: " .. (state.enabled and "on" or "off"))
end

function M.select_model()
	local client = state.server and state.server.first_client() or nil
	if not client then
		notify("pi-ide suggestion: no extension client connected (run /ide in pi)", vim.log.levels.WARN)
		return
	end
	state.server.request_client(client, "listSuggestionModels", {}, function(err, result)
		vim.schedule(function()
			if err then
				notify("pi-ide suggestion: model list failed (" .. (err.message or "?") .. ")", vim.log.levels.WARN)
				return
			end
			local models = (result and result.models) or {}
			if #models == 0 then
				notify("pi-ide suggestion: no available models returned", vim.log.levels.WARN)
				return
			end
			local cli_override = result and result.cliOverride
			if cli_override and cli_override ~= "" then
				notify("pi-ide suggestion: CLI model override active (" .. cli_override .. "); editor selection will not take effect", vim.log.levels.WARN)
			end
			vim.ui.select(models, {
				prompt = "Pi suggestion model",
				format_item = function(item)
					local label = item.model or ((item.provider or "?") .. "/" .. (item.id or "?"))
					if item.name and item.name ~= item.id then label = label .. " · " .. item.name end
					if state.model == item.model then label = label .. " · current" end
					return label
				end,
			}, function(item)
				if not item then return end
				state.model = item.model
				notify("pi-ide suggestion model: " .. state.model)
			end)
		end)
	end)
end

local function cycle_in_direction(delta)
	if not state.session or #state.session.suggestions <= 1 then return end
	local s = state.session
	local consumed_text = s.suggestions[s.index]:sub(1, s.consumed)
	local n = #s.suggestions
	for off = 1, n - 1 do
		local idx = ((s.index - 1 + delta * off) % n + n) % n + 1
		if s.suggestions[idx]:sub(1, #consumed_text) == consumed_text then
			s.index = idx
			render_current()
			return
		end
	end
end

function M.cycle_next() cycle_in_direction(1) end
function M.cycle_prev() cycle_in_direction(-1) end

local function accept_chunk(chunk_fn)
	if not state.session then return end
	local s = state.session
	if #s.suggestions == 0 then return end
	-- Insert mode keymaps may fire after the user switched buffers via
	-- <C-O>:b... or a window jump; insert_text would then write to
	-- s.bufnr but use the current window's cursor.
	if vim.api.nvim_get_current_buf() ~= s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then
		dismiss()
		return
	end
	local text = remaining_text(s)
	if text == "" then dismiss() return end
	local chunk = chunk_fn(text)
	if not chunk or chunk == "" then return end
	with_suppression(function()
		local new_row, new_col = insert_text(s.bufnr, chunk)
		s.consumed = s.consumed + #chunk
		s.anchor_row = new_row
		s.anchor_col = new_col
	end)
	if s.consumed >= #s.suggestions[s.index] then
		dismiss()
	else
		render_current()
	end
end

function M.accept_all()
	accept_chunk(function(text) return text end)
end

function M.accept_line()
	accept_chunk(function(text)
		local nl = text:find("\n", 1, true)
		return nl and text:sub(1, nl) or text
	end)
end

function M.accept_word()
	accept_chunk(function(text)
		-- If the remaining suggestion starts with a newline, advance past it
		-- and any leading indent on the next line so the cursor lands on the
		-- first meaningful column. Otherwise the word match would return "".
		if text:sub(1, 1) == "\n" then
			return text:match("^(\n%s*)") or "\n"
		end
		local nl = text:find("\n", 1, true)
		local body = nl and text:sub(1, nl - 1) or text
		return body:match("^(%s*[%w_]+%s*)")
			or body:match("^(%s*[^%w_%s]+%s*)")
			or body:match("^(%s+)")
			or body:sub(1, 1)
	end)
end

function M.dismiss() dismiss() end

-- Returns true when a suggestion is currently displayed (response back,
-- not yet accepted or dismissed). Use this in tab-handler logic to decide
-- whether <Tab> should accept the suggestion or fall through.
function M.has_active_suggestion()
	return state.session ~= nil and #state.session.suggestions > 0
end

local function on_text_changed()
	if state.suppressing then return end
	local bufnr = vim.api.nvim_get_current_buf()
	if state.session and state.session.bufnr == bufnr then
		reconcile(bufnr)
		if state.session then return end
	end
	if not state.enabled then return end
	cancel_timer()
	state.timer = vim.defer_fn(function()
		if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then return end
		local b = vim.api.nvim_get_current_buf()
		local c = vim.api.nvim_win_get_cursor(0)
		start_session(b, c[1] - 1, c[2], false)
	end, DEBOUNCE_MS)
end

local function on_cursor_moved()
	if state.suppressing or not state.session then return end
	local bufnr = vim.api.nvim_get_current_buf()
	if state.session.bufnr ~= bufnr then dismiss() return end
	local s = state.session
	local cur = vim.api.nvim_win_get_cursor(0)
	if cur[1] - 1 ~= s.anchor_row or cur[2] ~= s.anchor_col then
		-- TextChangedI may also be firing this tick; defer to let it reconcile first.
		vim.schedule(function()
			if not state.session then return end
			local c = vim.api.nvim_win_get_cursor(0)
			if c[1] - 1 ~= state.session.anchor_row or c[2] ~= state.session.anchor_col then
				dismiss()
			end
		end)
	end
end

function M.setup(server, config)
	if state.augroup then return end
	config = config or {}
	state.server = server
	state.enabled = config.auto_trigger ~= false
	state.model = config.model
	state.augroup = vim.api.nvim_create_augroup("PiIdeSuggestion", { clear = true })

	vim.api.nvim_create_autocmd("TextChangedI", {
		group = state.augroup,
		callback = on_text_changed,
	})
	vim.api.nvim_create_autocmd("CursorMovedI", {
		group = state.augroup,
		callback = on_cursor_moved,
	})
	vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
		group = state.augroup,
		callback = function() dismiss(); cancel_timer() end,
	})
	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		group = state.augroup,
		callback = function(args)
			context.invalidate(args.buf)
			if state.session and state.session.bufnr == args.buf then dismiss() end
		end,
	})

	keys.setup({
		trigger = M.trigger,
		cycle_next = M.cycle_next,
		cycle_prev = M.cycle_prev,
		accept_all = M.accept_all,
		accept_line = M.accept_line,
		accept_word = M.accept_word,
		dismiss = M.dismiss,
	}, config)
end

function M.disable()
	if state.augroup then pcall(vim.api.nvim_del_augroup_by_id, state.augroup) end
	state.augroup = nil
	cancel_timer()
	dismiss()
	state.server = nil
end

return M
