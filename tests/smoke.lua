local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p"), ":h:h")
vim.opt.rtp:append(root)

require("nudge").setup({
	endpoint = "http://localhost",
	model = "test",
	language = "en",
	languages = { en = { name = "English", max_characters = 100, example = "Example." } },
})

assert(vim.fn.exists("#nudge#CursorMoved") == 1, "Nudge CursorMoved handler was not registered")

local context = require("nudge.context")
vim.bo.filetype = "lua"
assert(context.allowed(0), "normal file buffer should be allowed")
vim.bo.buftype = "acwrite"
assert(not context.allowed(0), "special buffers such as Oil must be ignored")
