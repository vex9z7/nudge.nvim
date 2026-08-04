local M = {}
local value = {}

function M.setup(opts)
	value = vim.tbl_deep_extend("force", value, opts or {})
	vim.validate({
		endpoint = { value.endpoint, "string" },
		model = { value.model, "string" },
		language = { value.language, "string" },
		languages = { value.languages, "table" },
	})
end

function M.get()
	return value
end

return M
