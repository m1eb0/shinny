# shinny

A [micro](https://micro-editor.github.io) plugin: select text, hit a key, and
read [Tavily](https://tavily.com) search results in a split next to your
buffer.

```
┌─ notes.md ─────────────────┬─ shinny: Lua coroutines ─────────┐
│ Lua coroutines are …       │ shinny · Lua coroutines          │
│                            │ 5 result(s) · basic              │
│                            │                                  │
│                            │ 1. Lua 5.4 Reference Manual      │
│                            │    https://www.lua.org/manual/   │
│                            │    The reference manual for …    │
└────────────────────────────┴──────────────────────────────────┘
```

## Install

Requirements: micro ≥ 2.0, `curl`, and a Tavily API key.

Link the checkout into micro's plugin directory (or use the plugin manager):

```sh
git clone https://github.com/miebo/shinny
cd shinny
make link          # symlink into ~/.config/micro/plug/shinny
```

Then start micro and store the key:

```
> set shinny.apikey tvly-your-key
```

That writes `"shinny.apikey"` to micro's `settings.json`. You can also export
`TAVILY_API_KEY` in the environment, which takes precedence.

Finally bind the command — `~/.config/micro/bindings.json`:

```json
{
    "Alt-s": "command:shinny"
}
```

## Use

Select text with the mouse or with `Shift` + arrows, press your key (or run
`> shinny`), and the results open in a vertical split. `> shinny some words`
searches without using the selection.

Results are plain text: answer (optional), then title / URL / snippet / score
for each hit, plus a header with the result count and response time.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `shinny.apikey` | empty | Tavily API key |
| `shinny.maxresults` | `5` | number of results (1–20) |
| `shinny.depth` | `basic` | `basic` or `advanced` |
| `shinny.includeanswer` | `true` | include Tavily's answer |
| `shinny.endpoint` | `https://api.tavily.com/search` | API endpoint |

Inside micro: `> help shinny` has the same reference.

## Troubleshooting

Errors are reported in the info bar. `> shinny-raw` opens the last raw
response, which makes it easy to tell an API error from a proxy/network page
that looks like a 200.

## How it works

`shinny.lua` grabs `bp.Cursor:GetSelection()`, builds a Tavily request, and
runs `curl` through `micro/shell.JobStart` so the editor is not blocked. The
query, key and endpoint travel in environment variables (`SHINNY_BODY`,
`SHINNY_KEY`, `SHINNY_ENDPOINT`) so arbitrary selection text never needs shell
quoting. The response is decoded by a small JSON reader (micro's Lua has no
JSON module) and rendered into a scratch buffer opened with `VSplitBuf`.

## Development

```sh
make test     # headless Lua tests + curl round-trip against a local mock
```

The headless harness (`tests/run.lua`) stubs the micro API, so it runs with
plain `lua5.4`. `tests/integration.sh` starts `tests/mock_tavily.py` and runs
the real curl command end to end, including API-key and JSON-body checks.

## License

MIT
