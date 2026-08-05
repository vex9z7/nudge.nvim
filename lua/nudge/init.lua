local client = require("nudge.client")
local config = require("nudge.config")
local context = require("nudge.context")
local ui = require("nudge.ui")

local M = {}
local buffers = {}

local function state(buf)
	if not buffers[buf] then
		buffers[buf] = { generation = 0, entries = {}, jobs = {}, pair_seen = {}, pair_pending = {} }
	end
	return buffers[buf]
end

local function payload(messages, max_tokens)
	return {
		model = config.get().model,
		stream = true,
		max_tokens = max_tokens,
		chat_template_kwargs = { enable_thinking = false },
		messages = messages,
	}
end

local function request(buf, item)
	local s, generation = state(buf), state(buf).generation
	local language = config.get().languages[config.get().language]
	local output = ""
	local job
	job = client.stream(
		payload({
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
		}, 350),
		{
			on_token = function(token)
				output = output .. token
				item.text, item.streaming = output, true
				if not item.render_scheduled then
					item.render_scheduled = true
					vim.defer_fn(function()
						item.render_scheduled = nil
						if s.generation == generation and vim.api.nvim_buf_is_valid(buf) then
							s.entries[item.row] = item
							ui.render(buf, item)
						end
					end, 60)
				end
			end,
			on_exit = function(stderr)
				s.jobs[job] = nil
				item.streaming = false
				if s.generation == generation and vim.api.nvim_buf_is_valid(buf) and item.text ~= "" then
					s.entries[item.row] = item
					ui.render(buf, item)
					vim.schedule(M.explain)
				elseif s.generation == generation then
					vim.notify("Nudge explanation request failed: " .. stderr, vim.log.levels.WARN)
				end
			end,
		}
	)
	if job > 0 then
		s.jobs[job] = job
	end
end

local function primary_diagnostic(buf, row)
	local diagnostics = vim.tbl_filter(function(diagnostic)
		return not ui.is_pair(diagnostic)
	end, vim.diagnostic.get(buf, { lnum = row }))
	table.sort(diagnostics, function(a, b)
		return a.severity < b.severity
	end)
	return diagnostics[1]
end

local function diagnostic_key(diagnostic)
	return table.concat(
		{ diagnostic.lnum, diagnostic.col, diagnostic.severity, diagnostic.source, diagnostic.message },
		":"
	)
end

local function request_pair(buf, item, diagnostic)
	local s, generation = state(buf), state(buf).generation
	local key = diagnostic_key(diagnostic)
	local output = ""
	local job
	job = client.stream(
		payload({
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
		}, 40),
		{
			on_token = function(token)
				output = output .. token
			end,
			on_exit = function()
				s.jobs[job] = nil
				s.pair_pending[key] = nil
				output = vim.trim(output)
				local current = primary_diagnostic(buf, item.row)
				if s.generation == generation and current and diagnostic_key(current) == key then
					if output ~= "" then
						s.pair_seen[key] = true
					end
					if output ~= "" and output:upper() ~= "SKIP" then
						ui.set_pair(buf, diagnostic, output)
					end
					request(buf, item)
				end
			end,
		}
	)
	if job > 0 then
		s.jobs[job] = job
		return true
	end
	return false
end

local function pair_diagnostic(buf, item)
	local diagnostic = primary_diagnostic(buf, item.row)
	if not diagnostic or diagnostic.severity > vim.diagnostic.severity.WARN then
		return false
	end
	local fingerprint = diagnostic_key(diagnostic)
	local s = state(buf)
	if s.pair_seen[fingerprint] or s.pair_pending[fingerprint] then
		return false
	end
	s.pair_pending[fingerprint] = true
	if request_pair(buf, item, diagnostic) then
		return true
	end
	s.pair_pending[fingerprint] = nil
	return false
end

local function clear_changed(buf, firstline, lastline, new_lastline)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local s = state(buf)
	s.generation = s.generation + 1
	for _, job in pairs(s.jobs) do
		pcall(vim.fn.jobstop, job)
	end
	s.jobs = {}
	s.pair_seen = {}
	s.pair_pending = {}
	local last_changed = math.max(lastline, new_lastline)
	for _, pair in ipairs(ui.pairs(buf)) do
		if pair.lnum >= firstline and pair.lnum < last_changed then
			ui.clear_pair(buf)
			break
		end
	end
	local shift, remaining = new_lastline - lastline, {}
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
	ui.render_all(buf, s.entries)
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
				clear_changed(buf, firstline, lastline, new_lastline)
			end)
		end,
		on_detach = function()
			buffers[buf] = nil
		end,
	})
end

local function prune_pair(buf)
	local pair = ui.pairs(buf)[1]
	if not pair then
		return
	end
	local original = pair.user_data or {}
	local exists = vim.iter(vim.diagnostic.get(buf)):any(function(diagnostic)
		return diagnostic.namespace ~= pair.namespace
			and diagnostic.lnum == pair.lnum
			and diagnostic.source == original.original_source
			and diagnostic.message == original.original_message
	end)
	if not exists then
		ui.clear_pair(buf)
	end
end

function M.explain()
	local buf = vim.api.nvim_get_current_buf()
	if vim.fn.mode() ~= "n" or not context.allowed(buf) then
		return
	end
	attach(buf)
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	row = row - 1
	if not context.explainable(buf, row) then
		return
	end
	local s = state(buf)
	if s.entries[row] then
		pair_diagnostic(buf, s.entries[row])
		return
	end
	if next(s.jobs) then
		local pending_item = context.at(buf, row, col)
		if pending_item then
			pair_diagnostic(buf, pending_item)
		end
		return
	end
	local item = context.at(buf, row, col)
	if not item then
		return
	end
	item.context, item.text = item.text, ""
	if pair_diagnostic(buf, item) then
	else
		request(buf, item)
	end
end

function M.setup(opts)
	config.setup(opts)
	ui.setup()
	local group = vim.api.nvim_create_augroup("nudge", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		callback = function(args)
			ui.render_all(args.buf, state(args.buf).entries)
			ui.render_pair(args.buf)
			ui.refresh_diagnostics(args.buf)
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
					prune_pair(args.buf)
					if vim.api.nvim_get_current_buf() == args.buf then
						M.explain()
					end
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		callback = function(args)
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(args.buf) then
					ui.render_pair(args.buf)
					ui.refresh_diagnostics(args.buf)
				end
			end)
		end,
	})
end

return M
