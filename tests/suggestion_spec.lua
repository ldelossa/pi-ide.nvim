vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd("filetype on")
vim.opt.wrap = false
vim.opt.conceallevel = 0
vim.notify = function() end

local failures = {}
local function check(condition, message)
	if not condition then failures[#failures + 1] = message end
end

local function test_semantic_outline()
	local context = require("pi-ide.suggestion.context")
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "/tmp/pi-ide-semantic-outline.lua")
	vim.bo[bufnr].filetype = "lua"
	local lines = {}
	for i = 1, 180 do
		lines[#lines + 1] = string.format("local function before_%03d()", i)
		lines[#lines + 1] = string.format("\tlocal implementation_noise_%03d = %d", i, i)
		lines[#lines + 1] = "end"
	end
	local target_row = #lines
	lines[#lines + 1] = "local function target_completion(first, second)"
	lines[#lines + 1] = "\treturn first + second"
	lines[#lines + 1] = "end"
	for i = 1, 180 do
		lines[#lines + 1] = string.format("local function after_%03d()", i)
		lines[#lines + 1] = string.format("\tlocal trailing_noise_%03d = %d", i, i)
		lines[#lines + 1] = "end"
	end
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	local outline = context.outline(bufnr, target_row)
	check(outline:find("target_completion", 1, true) ~= nil, "semantic outline omitted the declaration at the cursor")
	check(outline:find("implementation_noise", 1, true) == nil, "semantic outline included function-body implementation noise")
	check(#outline <= 6500, "semantic outline exceeded its context budget: " .. #outline)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

test_semantic_outline()

local function test_additional_outline_grammars()
	local context = require("pi-ide.suggestion.context")
	local cbuf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(cbuf, "/tmp/pi-ide-semantic-outline.c")
	vim.bo[cbuf].filetype = "c"
	vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, {
		"typedef struct Widget {",
		"  int value;",
		"} Widget;",
		"",
		"int compute(struct Widget *widget) {",
		"  int implementation_noise = widget->value;",
		"  return implementation_noise;",
		"}",
	})
	if context.has_treesitter(cbuf) then
		local outline = context.outline(cbuf, 4)
		check(outline:find("Widget", 1, true) ~= nil, "C semantic outline omitted a struct/type declaration")
		check(outline:find("compute", 1, true) ~= nil, "C semantic outline omitted a function declaration")
		check(outline:find("implementation_noise", 1, true) == nil, "C semantic outline traversed a function body")
	end
	vim.api.nvim_buf_delete(cbuf, { force = true })

	local unicode_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(unicode_buf, "/tmp/pi-ide-semantic-outline-unicode.lua")
	vim.bo[unicode_buf].filetype = "lua"
	vim.api.nvim_buf_set_lines(unicode_buf, 0, -1, false, {
		'local description = "' .. string.rep("é", 180) .. '"',
	})
	local outline = context.outline(unicode_buf, 0)
	check(pcall(vim.json.encode, outline), "semantic outline truncated a UTF-8 codepoint")
	vim.api.nvim_buf_delete(unicode_buf, { force = true })
end

test_additional_outline_grammars()

local suggestion = require("pi-ide.suggestion")
local callbacks = {}
local cancelled = {}
local next_id = 0
local events = {}
local server = {
	first_client = function() return { id = "mock-client" } end,
	request_client = function(_, method, _, callback)
		check(method == "getSuggestions", "unexpected request method: " .. tostring(method))
		next_id = next_id + 1
		callbacks[next_id] = callback
		return next_id
	end,
	cancel_request = function(id) cancelled[id] = true end,
}

suggestion.setup(server, { auto_trigger = false, default_keys = false })
vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
	callback = function(args) events[#events + 1] = args.event end,
})

local function reset_line(text, col)
	suggestion.dismiss()
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
	vim.api.nvim_win_set_cursor(0, { 1, col or #text })
end

local function rendered_insertion()
	local namespace = vim.api.nvim_get_namespaces()["pi-ide-suggestion"]
	if not namespace then return nil end
	local marks = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
	if #marks == 0 then return nil end
	local details = marks[1][4]
	local parts = {}
	for _, chunk in ipairs(details.virt_text or {}) do parts[#parts + 1] = chunk[1] end
	local text = table.concat(parts)
	for _, virtual_line in ipairs(details.virt_lines or {}) do
		local line = {}
		for _, chunk in ipairs(virtual_line) do line[#line + 1] = chunk[1] end
		text = text .. "\n" .. table.concat(line)
	end
	return text
end

local function finish()
	vim.api.nvim_input(vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
	suggestion.disable()
	if #failures == 0 then
		print("PASS: suggestion context, rendering, and lifecycle regressions")
		vim.cmd("qa!")
	else
		print("FAIL: " .. table.concat(failures, " | "))
		vim.cmd("cquit 1")
	end
end

reset_line("local value = ")
vim.api.nvim_input("i")

vim.defer_fn(function()
	-- A rendered suggestion survives matching typing.
	suggestion.trigger()
	check(callbacks[1] ~= nil, "rendered typing case did not create a request")
	callbacks[1](nil, { suggestions = { "foobar" } })
	vim.defer_fn(function()
		check(suggestion.has_active_suggestion(), "initial suggestion was not rendered")
		check(rendered_insertion() == "foobar", "initial rendered text mismatch: " .. tostring(rendered_insertion()))
		events = {}
		vim.api.nvim_input("f")
		vim.defer_fn(function()
			check(events[1] == "CursorMovedI" and events[2] == "TextChangedI", "typing event order changed: " .. vim.inspect(events))
			check(suggestion.has_active_suggestion(), "matching typing dismissed a rendered suggestion")
			check(rendered_insertion() == "oobar", "rendered remainder mismatch: " .. tostring(rendered_insertion()))

			-- Matching typing while the request is in flight remains reconcilable.
			reset_line("local value = ")
			events = {}
			suggestion.trigger()
			check(callbacks[2] ~= nil, "in-flight typing case did not create a request")
			vim.api.nvim_input("f")
			vim.defer_fn(function()
				check(not cancelled[2], "matching typing cancelled the in-flight request")
				callbacks[2](nil, { suggestions = { "foobar" } })
				vim.defer_fn(function()
					check(suggestion.has_active_suggestion(), "matching in-flight response was dropped")
					check(rendered_insertion() == "oobar", "in-flight rendered remainder mismatch: " .. tostring(rendered_insertion()))

					-- A multiline candidate cannot be previewed exactly when visible
					-- text remains on the cursor line, so the driver drops it.
					reset_line("foo suffix", 3)
					vim.defer_fn(function()
						suggestion.trigger()
						check(callbacks[3] ~= nil, "same-line suffix case did not create a request")
						callbacks[3](nil, { suggestions = { "\nwork()" } })
						vim.defer_fn(function()
							check(not suggestion.has_active_suggestion(), "multiline suggestion relocated a visible same-line suffix")

							-- Leading newlines are meaningful at an end-of-line anchor.
							reset_line("if ready then")
							vim.defer_fn(function()
								suggestion.trigger()
								check(callbacks[4] ~= nil, "multiline rendering case did not create a request")
								callbacks[4](nil, { suggestions = { "\n\twork()\nend" } })
								vim.defer_fn(function()
									check(rendered_insertion() == "\n\twork()\nend", "renderer discarded meaningful leading newline: " .. vim.inspect(rendered_insertion()))

									-- Explicit navigation away from a pristine anchor cancels.
									reset_line("abcdef", 3)
									vim.defer_fn(function()
										suggestion.trigger()
										check(callbacks[5] ~= nil, "cursor movement case did not create a request")
										vim.api.nvim_win_set_cursor(0, { 1, 4 })
										vim.api.nvim_exec_autocmds("CursorMovedI", {})
										vim.defer_fn(function()
											check(cancelled[5] == true, "explicit cursor movement did not cancel the in-flight request")

											-- Typing followed by navigation back to the request anchor
											-- must not leave a stale request alive.
											reset_line("abc")
											vim.defer_fn(function()
												suggestion.trigger()
												check(callbacks[6] ~= nil, "return-to-anchor case did not create a request")
												vim.api.nvim_input("d")
												vim.defer_fn(function()
													check(not cancelled[6], "matching edit prematurely cancelled return-to-anchor request")
													vim.api.nvim_win_set_cursor(0, { 1, 3 })
													vim.api.nvim_exec_autocmds("CursorMovedI", {})
													vim.defer_fn(function()
														check(cancelled[6] == true, "navigation back to request anchor did not cancel")
														finish()
													end, 40)
												end, 40)
											end, 40)
										end, 40)
									end, 40)
								end, 40)
							end, 40)
						end, 40)
					end, 40)
				end, 40)
			end, 40)
		end, 40)
	end, 40)
end, 40)
