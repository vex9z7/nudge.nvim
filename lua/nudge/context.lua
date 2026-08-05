local M = {}

local ignored_paths = { "/%.env", "/%.ssh/", "/%.gnupg/", "/secret", "/credential", "%.pem$", "%.key$" }

function M.allowed(buf)
	if ignored_buftypes[vim.bo[buf].buftype] or not vim.bo[buf].modifiable or vim.bo[buf].filetype == "" then
		return false
	end
	local path = vim.api.nvim_buf_get_name(buf):lower()
	return not vim.tbl_contains(ignored_paths, path)
		and not vim.iter(ignored_paths):any(function(pattern)
			return path:find(pattern) ~= nil
		end)
end

function M.explainable(buf, row)
	local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
	local first = line:find("%S")
	if not first then
		return false
	end
	local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, first - 1 } })
	while ok and node do
		local start_row = node:range()
		if node:named() and start_row == row then
			return not node:type():lower():find("comment", 1, true)
		end
		node = node:parent()
	end
	return false
end

local function explanation_node(node)
	while node:parent() do
		local kind = node:type()
		if kind:find("statement") or kind:find("declaration") or kind:find("definition") or kind == "assignment" then
			break
		end
		node = node:parent()
	end
	return node
end

function M.at(buf, row, col)
	local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col } })
	if not ok or not node or node:has_error() then
		return
	end
	local best = node
	while best:parent() do
		local parent = best:parent()
		if vim.tbl_contains({ "function_definition", "class_definition", "method_definition" }, parent:type()) then
			best = parent
			break
		end
		best = parent
	end
	local text = vim.treesitter.get_node_text(best, buf)
	if best:type() == "module" or best:type() == "program" or #text > 24000 then
		local start_row = math.max(0, row - 8)
		local end_row = math.min(vim.api.nvim_buf_line_count(buf), row + 9)
		text = table.concat(vim.api.nvim_buf_get_lines(buf, start_row, end_row, false), "\n")
	end
	if not text or #text > 24000 then
		return
	end
	local subject = explanation_node(node)
	local node_start_row, _, node_end_row = subject:range()
	return {
		row = row,
		node_start_row = node_start_row,
		node_end_row = node_end_row,
		focus = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1],
		text = text,
	}
end

return M
