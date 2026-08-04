local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p"), ":h:h")
vim.opt.rtp:append(root)

require("nudge").setup({
	endpoint = "http://localhost",
	model = "test",
	language = "en",
	languages = { en = { name = "English", max_characters = 100, example = "Example." } },
})

assert(vim.fn.exists("#nudge#CursorMoved") == 1, "Nudge CursorMoved handler was not registered")
