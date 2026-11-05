# shinny

Search the web with [Tavily](https://tavily.com) for the text you have selected
in micro, and show the results in a split.

## Setup

Give the plugin a Tavily API key once:

    > set shinny.apikey tvly-your-key

The value is written to `settings.json`. Alternatively, export
`TAVILY_API_KEY` before starting micro; the environment variable wins over the
setting.

The plugin shells out to `curl`, so `curl` has to be on your `PATH`.

## Usage

Select some text (mouse drag, or `Shift` + arrow keys) and run the command:

    > shinny

The results open in a vertical split next to your file. A search without a
selection is also possible:

    > shinny lua coroutines

## Keybinding

Bind the command in `bindings.json` (`> help keybindings`):

    "Alt-s": "command:shinny"

## Options

* `shinny.apikey`: Tavily API key. Default: empty.
* `shinny.maxresults`: number of results, 1–20. Default: `5`.
* `shinny.depth`: `basic` or `advanced` search depth. Default: `basic`.
* `shinny.includeanswer`: include Tavily's short answer. Default: `true`.
* `shinny.endpoint`: search endpoint. Default:
  `https://api.tavily.com/search`.

## Notes

* The query, key and endpoint are passed to `curl` through environment
  variables, so selection text never has to be shell-quoted.
* Runs in the background; micro stays responsive while the request is in
  flight.
