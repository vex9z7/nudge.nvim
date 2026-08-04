# nudge.nvim

Cursor-driven code explanations with concise AI diagnostics for Neovim.

`nudge.nvim` waits while the cursor is idle on a meaningful Tree-sitter node,
then streams one explanation below that line. Existing explanations collapse to
one lightbulb marker. Errors and meaningful warnings first receive a short
**Nudge** diagnostic that states the cause.

## Requirements

- Neovim with Tree-sitter parsing
- `curl`
- An OpenAI-compatible streaming `/v1/chat/completions` endpoint

## Setup

```lua
{
  "vex9z7/nudge.nvim",
  config = function()
    require("nudge").setup {
      endpoint = "https://example.com/v1/chat/completions",
      model = "your-model",
      api_key_env = "OPENAI_API_KEY", -- optional; defaults to LLAMACPP_API_KEY
      language = "en",
      languages = {
        en = {
          name = "English",
          max_characters = 100,
          example = "Maps characters to integer tokens for later tensor conversion.",
        },
      },
    }
  end,
}
```

The API key is read from `api_key_env`. If the variable is absent, the request
uses `Bearer local`, which works with many local OpenAI-compatible servers.

## Behavior

- Skip blank, comment, and syntax-only lines using Tree-sitter.
- Keep streams running when the cursor moves; edits cancel in-flight requests.
- Invalidate explanations whose syntax node, or parent node, was changed.
- Preserve ordinary diagnostics. On the focused Nudge line, its advice replaces
  the original diagnostic virtual text; the original diagnostic still exists for
  navigation and lists.

This is an initial standalone extraction. Configuration and transport are
intentional public surface; keymaps remain the consuming config's choice.
