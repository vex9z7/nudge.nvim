local M = {}

local explain_ns = vim.api.nvim_create_namespace("nudge_explain")
local pair_ns = vim.api.nvim_create_namespace("nudge_pair")
local pair_visual_ns = vim.api.nvim_create_namespace("nudge_pair_visual")
local original_virtual_text_handler

local function viewport(text, offset, width)
	local result, display, index = {}, 0, offset
	local limit = math.max(width - 14, 20)
	while index < vim.fn.strchars(text) and display < limit do
		local char = vim.fn.strcharpart(text, index, 1)
		local char_width = vim.fn.strdisplaywidth(char)
		if display + char_width > limit then
			break
		end
		result[#result + 1], display, index = char, display + char_width, index + 1
	end
	return table.concat(result), index < vim.fn.strchars(text)
end

local function wrapped(text, width)
	local parts, offset, more = {}, 0, true
	while more do
		local part
		part, more = viewport(text, offset, width)
		parts[#parts + 1] = part
		offset = offset + vim.fn.strchars(part)
	end
	return parts
end

local function current_pair(buf)
	if vim.api.nvim_get_current_buf() ~= buf then
		return
	end
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	return vim.diagnostic.get(buf, { namespace = pair_ns, lnum = row })[1]
end

local function refresh_diagnostics(buf)
	for namespace in pairs(vim.diagnostic.get_namespaces()) do
		if namespace ~= pair_ns then
			vim.diagnostic.show(namespace, buf)
		end
	end
end

function M.render(buf, entry)
	vim.api.nvim_buf_clear_namespace(buf, explain_ns, entry.row, entry.row + 1)
	local current = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_win_get_cursor(0)[1] - 1 == entry.row
	if not current then
		local line = vim.api.nvim_buf_get_lines(buf, entry.row, entry.row + 1, false)[1] or ""
		vim.api.nvim_buf_set_extmark(buf, explain_ns, entry.row, #line, {
			virt_text = { { " 󰌵", "NudgeMarker" } },
			virt_text_pos = "inline",
			priority = 10000,
		})
		return
	end
	local line = vim.api.nvim_buf_get_lines(buf, entry.row, entry.row + 1, false)[1] or ""
	local indent = string.rep(" ", vim.fn.strdisplaywidth(line:match("^%s*") or ""))
	local virtual = {}
	for index, part in ipairs(wrapped(entry.text, vim.api.nvim_win_get_width(0) - #indent - 3)) do
		virtual[#virtual + 1] = { { indent .. (index == 1 and "╰─ " or "   ") .. part, "NudgeExplain" } }
	end
	if entry.streaming then
		virtual[#virtual][1][1] = virtual[#virtual][1][1] .. " ▍"
	end
	vim.api.nvim_buf_set_extmark(buf, explain_ns, entry.row, 0, { priority = 10000, virt_lines = virtual })
end

function M.render_all(buf, entries)
	vim.api.nvim_buf_clear_namespace(buf, explain_ns, 0, -1)
	for _, entry in pairs(entries) do
		M.render(buf, entry)
	end
end

function M.render_pair(buf)
	vim.api.nvim_buf_clear_namespace(buf, pair_visual_ns, 0, -1)
	local diagnostic = current_pair(buf)
	if not diagnostic then
		return
	end
	local line = vim.api.nvim_buf_get_lines(buf, diagnostic.lnum, diagnostic.lnum + 1, false)[1] or ""
	local highlight = "DiagnosticVirtualText"
		.. vim.diagnostic.severity[diagnostic.severity]:gsub("^%l", string.upper):lower():gsub("^%l", string.upper)
	local width = math.max(vim.api.nvim_win_get_width(0) - vim.fn.strdisplaywidth(line), 20)
	local text, more = viewport("  ● Nudge: " .. diagnostic.message, 0, width)
	vim.api.nvim_buf_set_extmark(buf, pair_visual_ns, diagnostic.lnum, #line, {
		virt_text = { { text .. (more and " …" or ""), highlight } },
		virt_text_pos = "inline",
		priority = 10000,
	})
end

function M.clear_pair(buf)
	vim.diagnostic.reset(pair_ns, buf)
	vim.api.nvim_buf_clear_namespace(buf, pair_visual_ns, 0, -1)
	refresh_diagnostics(buf)
end

function M.refresh_diagnostics(buf)
	refresh_diagnostics(buf)
end

function M.pairs(buf)
	return vim.diagnostic.get(buf, { namespace = pair_ns })
end

function M.set_pair(buf, diagnostic, message)
	vim.diagnostic.set(pair_ns, buf, {
		{
			lnum = diagnostic.lnum,
			col = diagnostic.col,
			end_lnum = diagnostic.end_lnum,
			end_col = diagnostic.end_col,
			severity = diagnostic.severity,
			source = "Nudge",
			message = message,
			user_data = { original_source = diagnostic.source, original_message = diagnostic.message },
		},
	})
	M.render_pair(buf)
	refresh_diagnostics(buf)
end

function M.setup()
	vim.api.nvim_set_hl(0, "NudgeExplain", { link = "DiagnosticVirtualTextHint" })
	vim.api.nvim_set_hl(0, "NudgeMarker", { link = "DiagnosticSignHint" })
	vim.diagnostic.config({ signs = { priority = 1000 }, severity_sort = true, virtual_text = false }, pair_ns)
	if original_virtual_text_handler then
		return
	end
	original_virtual_text_handler = vim.diagnostic.handlers.virtual_text
	vim.diagnostic.handlers.virtual_text = {
		show = function(namespace, buf, diagnostics, options)
			if namespace == pair_ns then
				return
			end
			local pair = current_pair(buf)
			original_virtual_text_handler.show(
				namespace,
				buf,
				vim.tbl_filter(function(diagnostic)
					return not pair or diagnostic.lnum ~= pair.lnum
				end, diagnostics),
				options
			)
		end,
		hide = original_virtual_text_handler.hide,
	}
end

return M
