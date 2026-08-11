# nudge.nvim

Cursor-driven code explanations with concise AI diagnostics for Neovim.

`nudge.nvim` waits while the cursor is idle on a meaningful Tree-sitter node,
then streams one explanation below that line. Existing explanations collapse to
one lightbulb marker. Errors and meaningful warnings first receive a short
**Nudge** diagnostic that states the cause.

The idle delay defaults to 1200 ms and is reset by cursor movement, edits,
buffer switches, and mode changes. Set `idle_ms` in `setup` to tune it.

## Requirements

- Neovim 0.10+ with Tree-sitter parsing
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
      idle_ms = 1200, -- optional
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

- Skip blank, comment, syntax-only lines, and special buffers.
- Keep streams running when the cursor moves; edits cancel in-flight requests.
- Invalidate explanations whose syntax node, or parent node, was changed.
- Preserve ordinary diagnostics. On the focused Nudge line, its advice replaces
  the original diagnostic virtual text; the original diagnostic still exists for
  navigation and lists.

## Health and development

Run `:checkhealth nudge` to verify `curl` and setup. For a local checkout,
`make check` runs formatting and a headless setup smoke test.

Configuration and transport are intentional public surface; keymaps remain the
consuming config's choice.
