# pi-ide.nvim

`pi-ide.nvim` is a Neovim plugin that serves the [`pi-ide`](https://github.com/ldelossa/pi-ide)
protocol over a local WebSocket. External AI agents like `pi` and `claude-code`
connect to the plugin to open diffs in Neovim, read LSP diagnostics, list open
buffers, receive cursor and selection notifications, and request inline code
completions (often called "suggestions") that render as ghost text.

This is the reference editor implementation for the
[`pi-ide`](https://github.com/ldelossa/pi-ide) Pi extension. The `pi-ide`
extension expects an editor that speaks this protocol, and `pi-ide.nvim` implements
this in Neovim.

## Claude Code Compatibility

`pi-ide.nvim` is wire compatible with the `claude-code` IDE integration
protocol. To enable it, set `claude_code_compatibility = true` in your setup
call:

```lua
require("pi-ide").setup({
    claude_code_compatibility = true,
})
```

When enabled, the plugin writes a second lockfile to `~/.claude/ide/<port>.lock`
alongside the usual `~/.pi/ide/<port>.lock`, and the handshake accepts either
the `x-pi-ide-authorization` or `x-claude-code-ide-authorization` header. From
`claude-code`'s perspective the plugin appears as a standard IDE integration
and discovery just works.

## Opinionated Design

`pi-ide.nvim` is opinionated about where the agent runs. The plugin assumes
`pi` or `claude-code` are running as external processes, outside of Neovim.
The plugin does not embed an agent, does not call out to an LLM directly, and
does not hold any prompt state. The inline suggestion feature is the one place
where an LLM is involved, but the model call is made by the connected `pi-ide`
extension running inside `pi`; Neovim only gathers context and renders ghost
text.

If you are looking for an in-editor AI chat experience, this is not the plugin
you want. Look at `avante.nvim`, `codecompanion.nvim`, or one of the many
in-editor agent plugins instead.

## Setup

Install via your favorite plugin manager.

Using [lazy.nvim](https://github.com/folke/lazy.nvim):
```lua
{
    "ldelossa/pi-ide.nvim",
    config = function()
        require("pi-ide").setup()
    end,
}
```

The default configuration is:
```lua
require("pi-ide").setup({
    auto_start = true,                 -- start the server on plugin load
    claude_code_compatibility = false, -- write claude-code lockfile too
    log_level = "warn",                -- trace, debug, info, warn, error
    suggestion = {
        auto_trigger = true,           -- debounced fire on TextChangedI
        default_keys = true,           -- install <M-\>, <M-]>/<M-[>, <Tab>, <C-]>
        model = nil,                   -- optional. preferred model "provider/id"
    },
})
```

## Commands

Five user commands are installed:

`PiStart` - Start the MCP server on a random free port and write the lockfile.

`PiStop` - Stop the server, close all connected clients, and reject any open
diffs.

`PiStatus` - Open a floating window showing the server port, connected client
count, and lockfile path.

`PiSuggest` - Manually trigger an inline suggestion at the cursor. Requires
a connected `pi-ide` extension client, an active LSP client, and a treesitter
parser for the current buffer.

`PiSuggestToggle` - Toggle automatic (debounced) suggestion triggering on or
off for the current session.

## Suggestions

Inline ghost-text suggestions routed through the `pi-ide` extension. Neovim
gathers a treesitter-derived structural outline of the file, the enclosing
function or class, and a window of lines around the cursor; sends the bundle
to the connected `pi-ide` extension; renders the returned alternatives as
ghost text; and lets the user cycle and accept by word, line, or full
suggestion.

Both an active LSP client and a treesitter parser for the buffer are hard
requirements. If either is missing the feature self-disables for that buffer
with a one-time notification.

Default insert-mode keys (set `default_keys = false` to skip):

```
<M-\>         manually trigger a suggestion
<M-]>         cycle to next alternative
<M-[>         cycle to previous alternative
<Tab>         accept the full suggestion
<C-]>         dismiss the active suggestion
```

Accept-line and accept-word are exposed as `<Plug>(PiSuggestAcceptLine)` and
`<Plug>(PiSuggestAcceptWord)` but unbound by default. Bind them yourself to
keys that fit your existing setup.

Display gating: suggestions are suppressed on lines where ghost text would
render in the wrong screen position — specifically when `conceallevel > 0`
on the current window, or when the current line is wide enough to wrap inside
the window. Auto-triggers skip silently; manual `:PiSuggest` emits a warning
so you know why nothing appeared.

Session lifecycle: once a suggestion arrives, typing characters that match
the suggestion advances the ghost text without firing a new LLM call.
Partial acceptance preserves the remaining tail of the suggestion as a new
ghost-text session, so a single LLM call can drive multiple word- or
line-sized accepts.

## Architecture

`pi-ide.nvim` runs a single MCP server per Neovim instance, listening on a
random free port on `127.0.0.1`. The server speaks JSON-RPC 2.0 in WebSocket
text frames using MCP protocol version `2024-11-05`. Tool calls flow from
the connected agent into Neovim; the plugin also initiates its own requests
(currently only `getSuggestions`) back to the agent for the inline
suggestion feature.

On startup the plugin writes a lockfile to `~/.pi/ide/<port>.lock`. Clients
discover the server by reading lockfiles in this directory and matching the
`workspaceFolders` field against their `cwd`. A random per-session auth token
gates access. The token is included in the lockfile and validated on every
connection.

### Tools

Four tools are exposed over `tools/call`:

`openDiff` - Open a diff tab between an existing file and proposed contents.
The JSON-RPC response is held open until the user saves (accept) or closes the
window (reject).

`close_tab` - Close a previously opened diff tab by name.

`getDiagnostics` - Return LSP diagnostics for a single file (by URI) or for
all loaded buffers if no URI is given.

`getOpenEditorTabs` - List the buffers visible in the current tabpage.

### Notifications

The server pushes a single notification, `selection_changed`, on cursor
movement, mode change, buffer entry, and text change. The notification is
debounced at 100ms to avoid flooding the client during rapid editing. The
payload includes the current file, cursor position, and selected range and
text if any.

### Diff Flow

A diff opens in a new tabpage with the existing file on the left and the
proposed contents on the right. Edit the right buffer freely, then save with
`:w` to accept the change (optionally with your own edits applied), or close
either window to reject. The plugin tears down the tabpage after the diff
resolves.
