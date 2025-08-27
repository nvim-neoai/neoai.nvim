# API Call Delay Feature

The NeoAI.nvim plugin now includes a configurable delay mechanism between AI API calls to help handle rate limiting from AI service providers.

## How It Works

The delay is applied before each API call to the AI service, including:

- Initial user message requests
- Follow-up requests after tool execution
- Continued conversation flows

The timeout timer only starts **after** the API call begins, so delays don't cause false timeout errors.

## Configuration Options

### Option 1: API Configuration

```lua
require('neoai').setup({
  api = {
    api_call_delay = 1000, -- 1 second delay between calls
    -- other api settings...
  }
})
```

### Option 2: With Presets

```lua
require('neoai').setup({
  preset = 'openai',
  api = {
    api_call_delay = 500, -- Override preset default
  }
})
```

## Default Behaviour

- **Default delay**: 0 milliseconds (no delay)
- **Backward compatibility**: Existing configurations continue to work unchanged
- **User feedback**: Shows notification during delay periods

## Use Cases

### Rate Limiting

Different AI providers have different rate limits:

- **Free tiers**: Often have strict rate limits (e.g., 3 requests/minute)
- **Paid tiers**: Usually more generous but still have limits
- **Local models**: Generally no rate limits, so can use 0ms delay

### Recommended Settings

- **OpenAI Free tier**: `api_call_delay = 2000` (2 seconds)
- **OpenAI Paid tier**: `api_call_delay = 200` (0.2 seconds)
- **Groq**: `api_call_delay = 100` (0.1 seconds)
- **Anthropic**: `api_call_delay = 300` (0.3 seconds)
- **Local Ollama**: `api_call_delay = 0` (no delay needed)

### Example: OpenAI with Rate Limiting

```lua
require('neoai').setup({
  preset = 'openai',
  api = {
    api_call_delay = 2000, -- 2 seconds between calls
    api_key = os.getenv('OPENAI_API_KEY'),
  }
})
```

## Technical Details

### Implementation

- Uses `vim.defer_fn()` for non-blocking delays
- Respects streaming state to prevent concurrent requests
- Timeout mechanism starts after API call begins, not during delay
- Provides user feedback via vim notifications

### Safety Features

- **Streaming protection**: Prevents multiple concurrent API calls
- **State validation**: Checks if streaming became active during delay
- **User cancellation**: Shows informative messages if requests are cancelled
- **No UI freezing**: Delays are asynchronous and don't block Neovim

### Error Handling

- If streaming becomes active during delay, the request is cancelled
- Clear notifications explain why requests are delayed or cancelled
- Original timeout handling remains intact (60-second stream timeout)

## Troubleshooting

### "Stream timeout" errors

If you were getting stream timeouts with delays, this has been fixed. The timeout timer now only starts when the actual API streaming begins, not during the rate limit delay.

### Delay not working

1. Check your configuration: `lua print(require('neoai.config').values.api.api_call_delay)`
2. Look for delay notification messages in Neovim
3. Ensure you're not setting `api_call_delay = 0` elsewhere

### Too many concurrent requests

If you're still hitting rate limits:

1. Increase the delay value
2. Check if you have multiple Neovim instances running
3. Verify your API key and service tier limits

## Integration with Existing Workflow

This feature is completely backward compatible:

- **Existing configs**: Continue to work without modification
- **Zero delay**: Maintains original plugin performance when delay = 0
- **All tool flows**: Works with read, write, multi_edit, and other AI tools
- **Session management**: Compatible with all session features
