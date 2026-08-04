local M = {}

local ns = vim.api.nvim_create_namespace("ai_explain")
local pair_ns = vim.api.nvim_create_namespace("ai_pair")
local pair_visual_ns = vim.api.nvim_create_namespace("ai_pair_visual")
local buffers = {}
local config = {}
local original_virtual_text_handler
local ignored_buftypes = { help = true, prompt = true, quickfix = true, terminal = true }
local ignored_paths = { "/%.env", "/%.ssh/", "/%.gnupg/", "/secret", "/credential", "%.pem$", "%.key$" }

local function allowed(buf)
	if ignored_buftypes[vim.bo[buf].buftype] or not vim.bo[buf].modifiable or vim.bo[buf].filetype == "" then
		return false
	end
	local path = vim.api.nvim_buf_get_name(buf):lower()
	return not vim.tbl_contains(ignored_paths, path)
		and not vim.iter(ignored_paths):any(function(pattern)
			return path:find(pattern) ~= nil
		end)
end

local function state(buf)
	if not buffers[buf] then
		buffers[buf] = { generation = 0, entries = {}, jobs = {}, pair_seen = {} }
	end
	return buffers[buf]
end

local function explainable(buf, row)
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

local function context(buf, row, col)
	local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col } })
	if not ok or not node or node:has_error() then
		return nil
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
		return nil
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

local function eol_width(buf, row)
	local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
	return math.max(vim.api.nvim_win_get_width(0) - vim.fn.strdisplaywidth(line), 20)
end

local function render(buf, entry)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, entry.row, entry.row + 1)
	local current = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_win_get_cursor(0)[1] - 1 == entry.row
	if not current then
		local line = vim.api.nvim_buf_get_lines(buf, entry.row, entry.row + 1, false)[1] or ""
		vim.api.nvim_buf_set_extmark(buf, ns, entry.row, #line, {
			virt_text = { { " 󰌵", "AiExplainMarker" } },
			virt_text_pos = "inline",
			priority = 10000,
		})
		return
	end
	local line = vim.api.nvim_buf_get_lines(buf, entry.row, entry.row + 1, false)[1] or ""
	local indent = string.rep(" ", vim.fn.strdisplaywidth(line:match("^%s*") or ""))
	local virtual = {}
	for index, part in ipairs(wrapped(entry.text, vim.api.nvim_win_get_width(0) - #indent - 3)) do
		local prefix = index == 1 and "╰─ " or "   "
		virtual[#virtual + 1] = { { indent .. prefix .. part, "AiExplain" } }
	end
	if entry.streaming then
		virtual[#virtual][1][1] = virtual[#virtual][1][1] .. " ▍"
	end
	vim.api.nvim_buf_set_extmark(buf, ns, entry.row, 0, { priority = 10000, virt_lines = virtual })
end

local function render_all(buf)
	local s = state(buf)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, entry in pairs(s.entries) do
		render(buf, entry)
	end
end

local function refresh_original_diagnostics(buf)
	for namespace in pairs(vim.diagnostic.get_namespaces()) do
		if namespace ~= pair_ns then
			vim.diagnostic.show(namespace, buf)
		end
	end
end

local function current_pair_diagnostic(buf)
	if vim.api.nvim_get_current_buf() ~= buf then
		return
	end
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	return vim.diagnostic.get(buf, { namespace = pair_ns, lnum = row })[1]
end

local function render_pair_visual(buf)
	vim.api.nvim_buf_clear_namespace(buf, pair_visual_ns, 0, -1)
	local diagnostic = current_pair_diagnostic(buf)
	if not diagnostic then
		return
	end
	local line = vim.api.nvim_buf_get_lines(buf, diagnostic.lnum, diagnostic.lnum + 1, false)[1] or ""
	local highlight = "DiagnosticVirtualText"
		.. vim.diagnostic.severity[diagnostic.severity]:gsub("^%l", string.upper):lower():gsub("^%l", string.upper)
	local text, more = viewport("  ● Nudge: " .. diagnostic.message, 0, eol_width(buf, diagnostic.lnum))
	vim.api.nvim_buf_set_extmark(buf, pair_visual_ns, diagnostic.lnum, #line, {
		virt_text = { { text .. (more and " …" or ""), highlight } },
		virt_text_pos = "inline",
		priority = 10000,
	})
end

local function clear_touched_pair_diagnostic(buf, firstline, lastline, new_lastline)
	local last_changed_line = math.max(lastline, new_lastline)
	for _, diagnostic in ipairs(vim.diagnostic.get(buf, { namespace = pair_ns })) do
		if diagnostic.lnum >= firstline and diagnostic.lnum < last_changed_line then
			vim.diagnostic.reset(pair_ns, buf)
			vim.api.nvim_buf_clear_namespace(buf, pair_visual_ns, 0, -1)
			refresh_original_diagnostics(buf)
			return
		end
	end
end

local function prune_pair_diagnostic(buf)
	local pair = vim.diagnostic.get(buf, { namespace = pair_ns })[1]
	if not pair then
		return
	end
	local original = pair.user_data or {}
	local exists = vim.iter(vim.diagnostic.get(buf)):any(function(diagnostic)
		return diagnostic.namespace ~= pair_ns
			and diagnostic.lnum == pair.lnum
			and diagnostic.source == original.original_source
			and diagnostic.message == original.original_message
	end)
	if not exists then
		vim.diagnostic.reset(pair_ns, buf)
		vim.api.nvim_buf_clear_namespace(buf, pair_visual_ns, 0, -1)
		refresh_original_diagnostics(buf)
	end
end

local function clear_changed_entries(buf, firstline, lastline, new_lastline)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local s = state(buf)
	s.generation = s.generation + 1
	for _, job in pairs(s.jobs) do
		pcall(vim.fn.jobstop, job)
	end
	s.jobs = {}
	clear_touched_pair_diagnostic(buf, firstline, lastline, new_lastline)
	local shift = new_lastline - lastline
	local remaining = {}
	for _, entry in pairs(s.entries) do
		local changed = entry.node_start_row <= firstline and entry.node_end_row >= firstline
			or lastline > firstline and entry.node_start_row < lastline and entry.node_end_row > firstline
		if not changed then
			if entry.node_start_row >= lastline then
				entry.row = entry.row + shift
				entry.node_start_row = entry.node_start_row + shift
				entry.node_end_row = entry.node_end_row + shift
			end
			remaining[entry.row] = entry
		end
	end
	s.entries = remaining
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	render_all(buf)
end

local function attach(buf)
	local s = state(buf)
	if s.attached then
		return
	end
	s.attached = true
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, _, _, firstline, lastline, new_lastline)
			vim.schedule(function()
				clear_changed_entries(buf, firstline, lastline, new_lastline)
			end)
		end,
		on_detach = function()
			buffers[buf] = nil
		end,
	})
end

local function post(payload, handlers)
	return vim.fn.jobstart({
		"curl",
		"--no-buffer",
		"--silent",
		"--show-error",
		"-X",
		"POST",
		assert(config.endpoint, "AI explanation endpoint is not configured"),
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. (vim.env[config.api_key_env or "LLAMACPP_API_KEY"] or "local"),
		"-d",
		vim.json.encode(payload),
	}, handlers)
end

local function request(buf, item)
	local s, generation = state(buf), state(buf).generation
	local language = assert(config.languages[config.language], "Unknown AI explanation language: " .. config.language)
	local payload = {
		model = assert(config.model, "AI explanation model is not configured"),
		stream = true,
		max_tokens = 350,
		chat_template_kwargs = { enable_thinking = false },
		messages = {
			{
				role = "system",
				content = string.format(
					"Reply in %s only with one natural inline annotation of at most %d characters. Start with the statement's concrete action, then add its immediate purpose only when useful. Never use labels, headings, colons, cursor, line, code, or speculation. No Markdown or code fences. Example style: %s",
					language.name,
					language.max_characters,
					language.example
				),
			},
			{
				role = "user",
				content = "Target statement:\n" .. item.focus .. "\n\nSurrounding context:\n" .. item.context,
			},
		},
	}
	local partial = ""
	local stderr = {}
	local function publish()
		if s.generation == generation and vim.api.nvim_buf_is_valid(buf) then
			s.entries[item.row] = item
			render(buf, item)
		end
	end
	local function schedule_publish()
		if item.render_scheduled then
			return
		end
		item.render_scheduled = true
		vim.defer_fn(function()
			item.render_scheduled = nil
			publish()
		end, 60)
	end
	local function consume(chunk)
		partial = partial .. chunk
		for line in partial:gmatch("(.-)\n") do
			if line:sub(1, 6) == "data: " then
				local ok, data = pcall(vim.json.decode, line:sub(7))
				local token = ok
					and data.choices
					and data.choices[1]
					and data.choices[1].delta
					and (data.choices[1].delta.content or data.choices[1].delta.reasoning_content)
				if type(token) == "string" then
					item.text = item.text .. token
					schedule_publish()
				end
			end
		end
		partial = partial:match("[^\n]*$") or ""
	end
	local job
	job = post(payload, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			consume(table.concat(data, "\n"))
		end,
		on_stderr = function(_, data)
			stderr[#stderr + 1] = table.concat(data, "\n")
		end,
		on_exit = function()
			s.jobs[job] = nil
			item.streaming = false
			if s.generation == generation and vim.api.nvim_buf_is_valid(buf) and item.text ~= "" then
				publish()
				vim.schedule(M.explain)
			elseif s.generation == generation then
				vim.notify("AI explanation request failed: " .. table.concat(stderr, " "), vim.log.levels.WARN)
			end
		end,
	})
	if job <= 0 then
		return
	end
	item.streaming = true
	s.jobs[job] = job
end

local function request_pair_diagnostic(buf, item, diagnostic)
	local s, generation = state(buf), state(buf).generation
	local output, partial = "", ""
	local payload = {
		model = assert(config.model, "AI explanation model is not configured"),
		stream = true,
		max_tokens = 40,
		chat_template_kwargs = { enable_thinking = false },
		messages = {
			{
				role = "system",
				content = "You are a concise coding nudge. For an ERROR, state only its root cause. For a WARN, output SKIP unless it has a meaningful correctness, runtime, security, or maintenance impact; if it does, state only the issue. Reply in English only: one direct sentence of at most 12 words; no Markdown, labels, fixes, or speculation.",
			},
			{
				role = "user",
				content = string.format(
					"Diagnostic (%s, %s): %s\n\nTarget statement:\n%s\n\nSurrounding context:\n%s",
					diagnostic.source or "LSP",
					vim.diagnostic.severity[diagnostic.severity],
					diagnostic.message,
					item.focus,
					item.context
				),
			},
		},
	}
	local function consume(chunk)
		partial = partial .. chunk
		for line in partial:gmatch("(.-)\n") do
			if line:sub(1, 6) == "data: " then
				local ok, data = pcall(vim.json.decode, line:sub(7))
				local token = ok
					and data.choices
					and data.choices[1]
					and data.choices[1].delta
					and (data.choices[1].delta.content or data.choices[1].delta.reasoning_content)
				if type(token) == "string" then
					output = output .. token
				end
			end
		end
		partial = partial:match("[^\n]*$") or ""
	end
	local job
	job = post(payload, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			consume(table.concat(data, "\n"))
		end,
		on_exit = function()
			s.jobs[job] = nil
			output = vim.trim(output)
			if s.generation == generation then
				if output ~= "" and output:upper() ~= "SKIP" then
					vim.diagnostic.set(pair_ns, buf, {
						{
							lnum = diagnostic.lnum,
							col = diagnostic.col,
							end_lnum = diagnostic.end_lnum,
							end_col = diagnostic.end_col,
							severity = diagnostic.severity,
							source = "Nudge",
							message = output,
							user_data = { original_source = diagnostic.source, original_message = diagnostic.message },
						},
					})
					render_pair_visual(buf)
					refresh_original_diagnostics(buf)
				end
				request(buf, item)
			end
		end,
	})
	if job > 0 then
		s.jobs[job] = job
		return true
	end
	return false
end

local function pair_diagnostic(buf, item)
	local diagnostics = vim.diagnostic.get(buf, { lnum = item.row })
	table.sort(diagnostics, function(a, b)
		return a.severity < b.severity
	end)
	local diagnostic = diagnostics[1]
	if not diagnostic or diagnostic.severity > vim.diagnostic.severity.WARN then
		return false
	end
	local fingerprint = table.concat({ diagnostic.lnum, diagnostic.col, diagnostic.severity, diagnostic.message }, ":")
	if state(buf).pair_seen[fingerprint] then
		return false
	end
	state(buf).pair_seen[fingerprint] = true
	return request_pair_diagnostic(buf, item, diagnostic)
end

function M.explain()
	local buf = vim.api.nvim_get_current_buf()
	if vim.fn.mode() ~= "n" or not allowed(buf) then
		return
	end
	attach(buf)
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	row = row - 1
	if not explainable(buf, row) then
		return
	end
	local s = state(buf)
	if s.entries[row] then
		pair_diagnostic(buf, s.entries[row])
		return
	end
	if next(s.jobs) then
		return
	end
	local item = context(buf, row, col)
	if not item then
		return
	end
	item.context, item.text = item.text, ""
	if not pair_diagnostic(buf, item) then
		request(buf, item)
	end
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
	vim.validate({
		endpoint = { config.endpoint, "string" },
		model = { config.model, "string" },
		language = { config.language, "string" },
		languages = { config.languages, "table" },
	})
	vim.api.nvim_set_hl(0, "AiExplain", { link = "DiagnosticVirtualTextHint" })
	vim.api.nvim_set_hl(0, "AiExplainMarker", { link = "DiagnosticSignHint" })
	vim.diagnostic.config({ signs = { priority = 1000 }, severity_sort = true, virtual_text = false }, pair_ns)
	if not original_virtual_text_handler then
		original_virtual_text_handler = vim.diagnostic.handlers.virtual_text
		vim.diagnostic.handlers.virtual_text = {
			show = function(namespace, buf, diagnostics, options)
				if namespace == pair_ns then
					return
				end
				local paired = current_pair_diagnostic(buf)
				original_virtual_text_handler.show(
					namespace,
					buf,
					vim.tbl_filter(function(diagnostic)
						return not paired or diagnostic.lnum ~= paired.lnum
					end, diagnostics),
					options
				)
			end,
			hide = original_virtual_text_handler.hide,
		}
	end
	local group = vim.api.nvim_create_augroup("ai_explain", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		callback = function(args)
			render_all(args.buf)
			render_pair_visual(args.buf)
			refresh_original_diagnostics(args.buf)
			vim.defer_fn(function()
				if vim.api.nvim_buf_is_valid(args.buf) and vim.api.nvim_get_current_buf() == args.buf then
					M.explain()
				end
			end, 1200)
		end,
	})
	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = group,
		callback = function(args)
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(args.buf) then
					prune_pair_diagnostic(args.buf)
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		callback = function(args)
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(args.buf) then
					vim.api.nvim_buf_clear_namespace(args.buf, pair_visual_ns, 0, -1)
					refresh_original_diagnostics(args.buf)
				end
			end)
		end,
	})
end

return M
