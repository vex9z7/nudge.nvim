local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p"), ":h:h")
vim.opt.rtp:append(root)

require("nudge").setup({
	endpoint = "http://localhost",
	model = "test",
	language = "en",
	languages = { en = { name = "English", max_characters = 100, example = "Example." } },
})

assert(vim.fn.exists("#nudge#CursorMoved") == 1, "Nudge CursorMoved handler was not registered")
assert(vim.fn.exists("#nudge#ModeChanged") == 1, "Nudge ModeChanged handler was not registered")
assert(vim.fn.exists("#nudge#TextChanged") == 1, "Nudge TextChanged handler was not registered")

local context = require("nudge.context")
vim.bo.filetype = "lua"
assert(context.allowed(0), "normal file buffer should be allowed")
vim.bo.buftype = "acwrite"
assert(not context.allowed(0), "special buffers such as Oil must be ignored")

local markdown = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(markdown, 0, -1, false, { "```python", "value = 1", "```" })
vim.bo[markdown].filetype = "markdown"
local ok, parser = pcall(vim.treesitter.get_parser, markdown, "markdown")
if ok then
	parser:parse()
	assert(not context.explainable(markdown, 0), "opening code fence must be ignored")
	assert(context.explainable(markdown, 1), "code within a fence must be explainable")
	assert(not context.explainable(markdown, 2), "closing code fence must be ignored")
end
vim.api.nvim_buf_delete(markdown, { force = true })
