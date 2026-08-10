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
	local function outline_for(filetype, lines, cursor_row)
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(bufnr, "/tmp/pi-ide-semantic-outline-" .. filetype)
		vim.bo[bufnr].filetype = filetype
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		if not context.has_treesitter(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
			return nil
		end
		local outline = context.outline(bufnr, cursor_row or 0)
		vim.api.nvim_buf_delete(bufnr, { force = true })
		return outline
	end

	local c_outline = outline_for("c", {
		"typedef struct Widget {",
		"  int value;",
		"} Widget;",
		"int compute(struct Widget *widget) {",
		"  int implementation_noise = widget->value;",
		"  return implementation_noise;",
		"}",
	}, 3)
	if c_outline then
		check(c_outline:find("Widget", 1, true) ~= nil, "C outline omitted a type definition")
		check(c_outline:find("value", 1, true) ~= nil, "C locals query omitted a nested field")
		check(c_outline:find("compute", 1, true) ~= nil, "C outline omitted a function definition")
		check(c_outline:find("implementation_noise", 1, true) == nil, "C outline included a function-local variable")
	end

	local query_cases = {
		lua = {
			lines = { "local function outer()", "  local function inner_query_symbol()", "  end", "end" },
			needle = "inner_query_symbol",
		},
		typescript = {
			lines = {
				"export interface Shape { area(): number }",
				"export class Widget {",
				"  queryMethod(value: number) {",
				"    return value",
				"  }",
				"}",
			},
			needle = "queryMethod",
			extra_needle = "Shape",
		},
		python = {
			lines = { "class Widget:", "    def query_method(self):", "        return 1" },
			needle = "query_method",
		},
		rust = {
			lines = { "struct Widget;", "impl Widget {", "    fn query_method(&self) {}", "}" },
			needle = "query_method",
		},
	}
	for filetype, case in pairs(query_cases) do
		local outline = outline_for(filetype, case.lines, 1)
		if outline then
			check(outline:find(case.needle, 1, true) ~= nil, filetype .. " locals query omitted " .. case.needle)
			if case.extra_needle then
				check(outline:find(case.extra_needle, 1, true) ~= nil,
					filetype .. " generic supplement omitted " .. case.extra_needle)
			end
		end
	end

	-- A parser without a usable locals query still contributes a compact
	-- top-level outline instead of falling back to the old full AST dump.
	local fallback_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(fallback_buf, "/tmp/pi-ide-semantic-outline-fallback.lua")
	vim.bo[fallback_buf].filetype = "lua"
	vim.api.nvim_buf_set_lines(fallback_buf, 0, -1, false, {
		"local function parser_only_fallback()",
		"  local function query_loaded_later()",
		"    return true",
		"  end",
		"  return query_loaded_later()",
		"end",
	})
	local original_query_get = vim.treesitter.query.get
	vim.treesitter.query.get = function(lang, query_name)
		if query_name == "locals" then return nil end
		return original_query_get(lang, query_name)
	end
	context.invalidate(fallback_buf)
	local ok_fallback, fallback_outline = pcall(context.outline, fallback_buf, 2)
	local fallback_scope = context.enclosing_scope(fallback_buf, 2, 4)
	vim.treesitter.query.get = original_query_get
	check(ok_fallback and fallback_outline:find("parser_only_fallback", 1, true) ~= nil,
		"parser-only fallback did not produce a top-level outline")
	check(fallback_scope:find("query_loaded_later", 1, true) ~= nil,
		"parser-only fallback omitted the nested enclosing scope")
	local query_outline = context.outline(fallback_buf, 2)
	check(query_outline:find("query_loaded_later", 1, true) ~= nil,
		"semantic cache did not detect a locals query loaded at runtime")
	vim.api.nvim_buf_delete(fallback_buf, { force = true })

	-- Dense definitions at the top of a file must not consume the capture
	-- budget reserved for declarations and scopes around the cursor.
	local saturation_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(saturation_buf, "/tmp/pi-ide-semantic-outline-saturation.lua")
	vim.bo[saturation_buf].filetype = "lua"
	local saturation_lines = {}
	local function append_dense_definitions(prefix, row)
		local names, values = {}, {}
		for col = 1, 25 do
			names[#names + 1] = string.format("%s_%d_%d", prefix, row, col)
			values[#values + 1] = tostring(col)
		end
		saturation_lines[#saturation_lines + 1] = "local " .. table.concat(names, ", ") .. " = " .. table.concat(values, ", ")
	end
	for row = 1, 200 do append_dense_definitions("header", row) end
	for _ = 201, 600 do saturation_lines[#saturation_lines + 1] = "-- filler" end
	for row = 601, 798 do append_dense_definitions("nearby", row) end
	saturation_lines[#saturation_lines + 1] = "local function saturated_target_outer()"
	saturation_lines[#saturation_lines + 1] = "  local function saturated_target_inner()"
	saturation_lines[#saturation_lines + 1] = "    return true"
	saturation_lines[#saturation_lines + 1] = "  end"
	saturation_lines[#saturation_lines + 1] = "  return saturated_target_inner()"
	saturation_lines[#saturation_lines + 1] = "end"
	vim.api.nvim_buf_set_lines(saturation_buf, 0, -1, false, saturation_lines)
	local saturation_outline = context.outline(saturation_buf, 800)
	local saturation_scope = context.enclosing_scope(saturation_buf, 800, 4)
	check(saturation_outline:find("saturated_target_inner", 1, true) ~= nil,
		"header captures starved query definitions near the cursor")
	check(saturation_scope:find("saturated_target_inner", 1, true) ~= nil,
		"truncated query context did not supplement the enclosing scope")
	vim.api.nvim_buf_delete(saturation_buf, { force = true })

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
