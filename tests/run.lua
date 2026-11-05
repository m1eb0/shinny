-- Headless tests for shinny.lua.
--
-- Run from the repository root:
--   lua5.4 tests/run.lua
--   lua5.4 tests/run.lua --integration http://127.0.0.1:8765/search

local args = arg or {}
local integration_url = nil
if args[1] == "--integration" then
	integration_url = args[2]
end

local state = {
	options = {},
	env = {},
	messages = {},
	commands = {},
	selection = "",
	output = "",
	split = false,
	run_real = integration_url ~= nil,
}

local function shell_quote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run_command(cmd)
	local wrapped = string.format(
		"SHINNY_ENDPOINT=%s SHINNY_KEY=%s SHINNY_BODY=%s sh -c %s 2>&1",
		shell_quote(state.env.SHINNY_ENDPOINT or ""),
		shell_quote(state.env.SHINNY_KEY or ""),
		shell_quote(state.env.SHINNY_BODY or ""),
		shell_quote(cmd)
	)
	local pipe = assert(io.popen(wrapped, "r"))
	local out = pipe:read("*a")
	pipe:close()
	return out
end

local packages = {}

packages["micro"] = function()
	return {
		InfoBar = function()
			return {
				Message = function(_, msg)
					state.messages[#state.messages + 1] = { kind = "info", text = tostring(msg) }
				end,
				Error = function(_, msg)
					state.messages[#state.messages + 1] = { kind = "error", text = tostring(msg) }
				end,
			}
		end,
		CurPane = function()
			return state.pane
		end,
	}
end

packages["micro/config"] = function()
	return {
		GetGlobalOption = function(name)
			return state.options[name]
		end,
		RegisterGlobalOption = function(plugin, name, default)
			local key = plugin .. "." .. name
			if state.options[key] == nil then
				state.options[key] = default
			end
		end,
		MakeCommand = function(name, fn)
			state.commands[name] = fn
		end,
		AddRuntimeFile = function() end,
		RTHelp = 0,
		NoComplete = nil,
	}
end

packages["micro/buffer"] = function()
	local m = {}
	function m.NewBuffer(text, path)
		local b = { text = text, path = path, name = "" }
		function b:SetName(name)
			self.name = name
		end
		return b
	end
	return m
end

packages["micro/shell"] = function()
	return {
		JobStart = function(cmd, _on_stdout, _on_stderr, on_exit)
			state.last_cmd = cmd
			state.job_env = {
				KEY = state.env.SHINNY_KEY,
				BODY = state.env.SHINNY_BODY,
				ENDPOINT = state.env.SHINNY_ENDPOINT,
			}
			-- micro runs the callback from the main loop, after the command
			-- has returned; defer it so tests see the same ordering.
			state.pending = function()
				if state.real_job then
					on_exit(run_command(cmd))
				else
					on_exit(state.output)
				end
			end
			return {}
		end,
	}
end

packages["micro/util"] = function()
	return {
		String = function(b)
			if type(b) == "string" then
				return b
			end
			return tostring(b)
		end,
	}
end

packages["os"] = function()
	return {
		Getenv = function(name)
			return state.env[name]
		end,
		Setenv = function(name, value)
			state.env[name] = value
		end,
	}
end

packages["strings"] = function()
	return {
		TrimSpace = function(s)
			s = tostring(s)
			return (s:gsub("^%s+", ""):gsub("%s+$", ""))
		end,
	}
end

import = function(name)
	local f = packages[name]
	if not f then
		error("unexpected import: " .. tostring(name))
	end
	return f()
end

dofile("shinny.lua")

local function new_bp(selection)
	local bp = { Cursor = {} }
	function bp.Cursor:GetSelection()
		return selection or state.selection
	end
	function bp.VSplitBuf(self, buf)
		state.split = true
		state.buffer_text = buf.text
		state.buffer_name = buf.name
		return self
	end
	return bp
end

local function run_shinny(bp, argv)
	state.pending = nil
	shinny(bp, argv)
	local pending = state.pending
	state.pending = nil
	if pending then
		pending()
	end
end

local function reset()
	state.messages = {}
	state.selection = ""
	state.output = ""
	state.split = false
	state.buffer_text = nil
	state.buffer_name = nil
	state.last_cmd = nil
	state.env = {}
end

local failures, total = 0, 0

local function test(name, fn)
	total = total + 1
	local ok, err = pcall(fn)
	if ok then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
		for _, m in ipairs(state.messages) do
			print("     [" .. m.kind .. "] " .. m.text)
		end
	end
end

local function assert_true(cond, msg)
	if not cond then
		error(msg or "assertion failed", 2)
	end
end

local function assert_contains(haystack, needle, msg)
	if not haystack or not tostring(haystack):find(needle, 1, true) then
		error((msg or "missing text") .. ": expected to find [" .. tostring(needle) .. "] in [" .. tostring(haystack) .. "]", 2)
	end
end

local function last_message()
	local m = state.messages[#state.messages]
	return m and m.text or ""
end

local SAMPLE = [[
{
  "query": "lua coroutine",
  "answer": "Coroutines let a function pause and resume.",
  "response_time": 0.42,
  "results": [
    {
      "title": "Lua 5.4 Reference Manual",
      "url": "https://www.lua.org/manual/5.4/",
      "content": "The reference manual for Lua.\n\tIt calls them \"coroutines\".",
      "score": 0.98
    },
    {
      "title": "Coroutine \u2014 Wikipedia",
      "url": "https://en.wikipedia.org/wiki/Coroutine",
      "content": "Caf\u00e9 na\u00efve \ud83d\ude00",
      "score": 0.5
    }
  ]
}
__SHINNY_STATUS__:200
]]

test("init registers options and the command", function()
	init()
	assert_true(state.options["shinny.maxresults"] == 5, "maxresults default")
	assert_true(state.options["shinny.includeanswer"] == true, "includeanswer default")
	assert_true(state.commands.shinny ~= nil, "shinny command")
end)

test("searches the selection and opens a split", function()
	reset()
	state.options["shinny.apikey"] = "tvly-test"
	state.selection = "lua coroutine"
	state.output = SAMPLE
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	assert_true(state.split, "expected a split")
	assert_contains(state.buffer_text, "Lua 5.4 Reference Manual")
	assert_contains(state.buffer_text, "https://www.lua.org/manual/5.4/")
	assert_contains(state.buffer_text, "The reference manual for Lua.")
	assert_contains(state.buffer_text, 'It calls them "coroutines".')
	assert_contains(state.buffer_text, "Coroutine — Wikipedia")
	assert_contains(state.buffer_text, "Café naïve 😀")
	assert_contains(state.buffer_text, "score: 0.980")
	assert_contains(state.buffer_text, "Answer")
	assert_contains(state.buffer_text, "0.42s")
	assert_contains(state.buffer_name, "shinny: lua coroutine")
	assert_contains(state.last_cmd, "curl")
	assert_contains(state.job_env.BODY, '"query":"lua coroutine"')
	assert_contains(state.job_env.BODY, '"max_results":5')
end)

test("explicit arguments override the selection", function()
	reset()
	state.options["shinny.apikey"] = "tvly-test"
	state.selection = "ignored selection"
	state.output = SAMPLE
	state.pane = new_bp()

	run_shinny(state.pane, { "hello", "world" })

	assert_contains(state.job_env.BODY, '"query":"hello world"')
	assert_true(not state.job_env.BODY:find("ignored selection", 1, true), "selection leaked into body")
end)

test("reports a missing selection", function()
	reset()
	state.options["shinny.apikey"] = "tvly-test"
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	assert_true(not state.split, "should not open a split")
	assert_contains(last_message(), "select some text")
end)

test("reports a missing API key", function()
	reset()
	state.options["shinny.apikey"] = ""
	state.selection = "anything"
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	assert_true(not state.split, "should not open a split")
	assert_contains(last_message(), "no Tavily API key")
end)

test("env var TAVILY_API_KEY wins over the option", function()
	reset()
	state.options["shinny.apikey"] = "from-settings"
	state.env.TAVILY_API_KEY = "from-env"
	state.selection = "x"
	state.output = SAMPLE
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	assert_true(state.job_env.KEY == "from-env", "expected env key, got " .. tostring(state.job_env.KEY))
end)

test("surfaces HTTP errors from Tavily", function()
	reset()
	state.options["shinny.apikey"] = "bad-key"
	state.selection = "x"
	state.output = '{"detail":{"error":"Invalid API key."}}\n__SHINNY_STATUS__:401'
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	assert_true(not state.split, "should not open a split")
	assert_contains(last_message(), "Invalid API key.")
end)

test("handles a 200 response that carries an error field", function()
	reset()
	state.options["shinny.apikey"] = "tvly-test"
	state.selection = "x"
	state.output = '{"error":"usage limit reached"}\n__SHINNY_STATUS__:200'
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	assert_true(not state.split, "should not open a split")
	assert_contains(last_message(), "usage limit reached")
end)

test("rejects a malformed response", function()
	reset()
	state.options["shinny.apikey"] = "tvly-test"
	state.selection = "x"
	state.output = 'not json at all\n__SHINNY_STATUS__:200'
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	assert_true(not state.split, "should not open a split")
	assert_contains(last_message(), "unexpected response")
end)

test("escapes quotes and control characters in the query body", function()
	reset()
	state.options["shinny.apikey"] = "tvly-test"
	state.selection = 'say "hi"\n\tand \\ bye'
	state.output = SAMPLE
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	local body = state.job_env.BODY
	assert_contains(body, '\\"hi\\"')
	assert_contains(body, "\\n")
	assert_contains(body, "\\\\")
	-- write it out so the shell wrapper can validate it with Python
	os.execute("mkdir -p tests/tmp")
	local f = assert(io.open("tests/tmp/body.json", "w"))
	f:write(body)
	f:close()
end)

test("clamps very long multibyte queries without splitting a character", function()
	reset()
	state.options["shinny.apikey"] = "tvly-test"
	state.selection = string.rep("中文", 400)
	state.output = SAMPLE
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	local body = state.job_env.BODY
	assert_true(#body < 1200, "body should be clamped")
	local f = assert(io.open("tests/tmp/body-long.json", "w"))
	f:write(body)
	f:close()
end)

test("includes the answer only when enabled", function()
	reset()
	state.options["shinny.apikey"] = "tvly-test"
	state.options["shinny.includeanswer"] = false
	state.selection = "x"
	state.output = SAMPLE
	state.pane = new_bp()

	run_shinny(state.pane, nil)

	assert_contains(state.job_env.BODY, '"include_answer":false')
	assert_true(not state.buffer_text:find("Coroutines let a function pause", 1, true), "answer rendered while disabled")
	state.options["shinny.includeanswer"] = true
end)

if integration_url then
	test("talks to a Tavily-compatible endpoint end to end", function()
		reset()
		state.options["shinny.endpoint"] = integration_url
		state.options["shinny.apikey"] = "tvly-test-key"
		state.selection = "integration query"
		state.pane = new_bp()
		state.real_job = true

		run_shinny(state.pane, nil)
		state.real_job = false

		assert_true(state.split, "expected a split: " .. last_message())
		assert_contains(state.buffer_text, "Mock result for integration query")
		assert_contains(state.buffer_text, "https://example.test/integration")
		assert_true(state.env.SHINNY_KEY == "", "key should be cleared from the environment")
	end)
end

print(string.format("\n%d test(s), %d failure(s)", total, failures))
if failures > 0 then
	os.exit(1)
end
