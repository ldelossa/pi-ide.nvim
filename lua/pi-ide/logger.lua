local M = {}

local LEVELS = { trace = 0, debug = 1, info = 2, warn = 3, error = 4 }
local NVIM_LEVELS = {
	error = vim.log.levels.ERROR,
	warn = vim.log.levels.WARN,
	info = vim.log.levels.INFO,
	debug = vim.log.levels.DEBUG,
	trace = vim.log.levels.TRACE or vim.log.levels.DEBUG,
}
local current = LEVELS.warn

function M.setup(opts)
	if opts and opts.log_level and LEVELS[opts.log_level] then
		current = LEVELS[opts.log_level]
	end
end

local function emit(level, ctx, ...)
	if LEVELS[level] < current then return end
	local parts = { "[pi-ide:" .. ctx .. "]" }
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		parts[#parts + 1] = type(v) == "string" and v or vim.inspect(v)
	end
	local msg = table.concat(parts, " ")
	local lvl = NVIM_LEVELS[level] or vim.log.levels.DEBUG
	vim.schedule(function() vim.notify(msg, lvl) end)
end

function M.trace(ctx, ...) emit("trace", ctx, ...) end
function M.debug(ctx, ...) emit("debug", ctx, ...) end
function M.info(ctx, ...) emit("info", ctx, ...) end
function M.warn(ctx, ...) emit("warn", ctx, ...) end
function M.error(ctx, ...) emit("error", ctx, ...) end

return M
