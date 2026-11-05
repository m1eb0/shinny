-- Headless tests for shinny.lua.
--
-- Run from the repository root:
--   lua5.4 tests/run.lua
--   lua5.4 tests/run.lua --integration <tavily-url> <deepseek-search-url> <deepseek-chat-url>

local args = arg or {}
local integration = nil
if args[1] == "--integration" then
	integration = { tavily = args[2], search = args[3], chat = args[4] }
end

os.execute("rm -rf /tmp/shinny-test-cfg 2>/dev/null")

local state = {
	options = {},
	env = {},
	messages = {},
	commands = {},
	files = {},
	panes = {},
	prompts = {},
	split_count = 0,
	search_output = "",
	chat_sse = "",
	chat_queue = {},
	chat_bodies = {},
	exec_output = nil,
	afters = {},
	mkdirs = {},
	real = integration ~= nil,
}

-- ---------------------------------------------------------------------------
-- fake buffers
-- ---------------------------------------------------------------------------

local Buf = {}
Buf.__index = Buf

local function split_lines(text)
	local out = {}
	local start = 1
	while true do
		local i = text:find("\n", start, true)
		if not i then
			out[#out + 1] = text:sub(start)
			break
		end
		out[#out + 1] = text:sub(start, i - 1)
		start = i + 1
	end
	if #out == 0 then
		out[1] = ""
	end
	return out
end

local Cursor = {}
Cursor.__index = Cursor

local function new_cursor(buf)
	return setmetatable({
		buf = buf,
		X = 0,
		Y = 0,
		sel = { { X = 0, Y = 0 }, { X = 0, Y = 0 } },
	}, Cursor)
end

function Cursor:HasSelection()
	return self.sel[1].X ~= self.sel[2].X or self.sel[1].Y ~= self.sel[2].Y
end

function Cursor:GetSelection()
	local a, b = self.sel[1], self.sel[2]
	if self.buf:less(a, b) then
		return self.buf:text_between(a, b)
	end
	return self.buf:text_between(b, a)
end

function Cursor:DeleteSelection()
	local a, b = self.sel[1], self.sel[2]
	if self.buf:less(b, a) then
		a, b = b, a
	end
	self.buf:Remove(a, b)
	self.X, self.Y = a.X, a.Y
end

function Cursor:ResetSelection()
	self.sel = { { X = 0, Y = 0 }, { X = 0, Y = 0 } }
end

function Cursor:GotoLoc(loc)
	self.X, self.Y = loc.X, loc.Y
end

function Buf:GetActiveCursor()
	return self.cursor
end

function Buf:less(a, b)
	if a.Y ~= b.Y then
		return a.Y < b.Y
	end
	return a.X < b.X
end

function Buf:Line(i)
	return self.lines[i + 1] or ""
end

function Buf:LinesNum()
	return #self.lines
end

function Buf:GetName()
	return self.name
end

function Buf:SetName(name)
	self.name = name
end

function Buf:SetOption(name, value)
	self.options = self.options or {}
	self.options[name] = value
end

function Buf:text()
	return table.concat(self.lines, "\n")
end

function Buf:text_between(a, b)
	if a.Y == b.Y then
		return (self.lines[a.Y + 1] or ""):sub(a.X + 1, b.X)
	end
	local parts = {}
	parts[#parts + 1] = (self.lines[a.Y + 1] or ""):sub(a.X + 1)
	for y = a.Y + 1, b.Y - 1 do
		parts[#parts + 1] = self.lines[y + 1] or ""
	end
	parts[#parts + 1] = (self.lines[b.Y + 1] or ""):sub(1, b.X)
	return table.concat(parts, "\n")
end

function Buf:Insert(loc, text)
	local newlines = split_lines(text)
	local y = loc.Y + 1
	local line = self.lines[y] or ""
	local before = line:sub(1, loc.X)
	local after = line:sub(loc.X + 1)
	if #newlines == 1 then
		self.lines[y] = before .. newlines[1] .. after
		return
	end
	self.lines[y] = before .. newlines[1]
	local at = y + 1
	for i = 2, #newlines - 1 do
		table.insert(self.lines, at, newlines[i])
		at = at + 1
	end
	table.insert(self.lines, at, newlines[#newlines] .. after)
end

function Buf:Remove(start, end_)
	if start.Y == end_.Y then
		local line = self.lines[start.Y + 1] or ""
		self.lines[start.Y + 1] = line:sub(1, start.X) .. line:sub(end_.X + 1)
		return
	end
	local first = (self.lines[start.Y + 1] or ""):sub(1, start.X)
	local last = (self.lines[end_.Y + 1] or ""):sub(end_.X + 1)
	for _ = end_.Y, start.Y + 1, -1 do
		table.remove(self.lines, _ + 1)
	end
	self.lines[start.Y + 1] = first .. last
end

local function new_buffer(text, name)
	local b = setmetatable({ lines = { "" }, name = name or "" }, Buf)
	if text and text ~= "" then
		b.lines = split_lines(text)
	end
	b.cursor = new_cursor(b)
	return b
end

local function new_pane(buf)
	local pane = { Buf = buf, Cursor = buf.cursor }
	function pane:ID()
		return 1
	end
	function pane:VSplitBuf(b)
		local p = new_pane(b)
		state.split_count = state.split_count + 1
		return p
	end
	function pane:VSplitIndex(b, right)
		local p = new_pane(b)
		state.split_count = state.split_count + 1
		return p
	end
	function pane:HSplitIndex(b, bottom)
		local p = new_pane(b)
		state.split_count = state.split_count + 1
		return p
	end
	function pane:ResizePane(size)
		self.last_resize = size
	end
	function pane:Tab()
		return { H = 40 }
	end
	function pane:GotoLoc(loc) end
	state.panes[#state.panes + 1] = pane
	return pane
end

-- ---------------------------------------------------------------------------
-- package stubs
-- ---------------------------------------------------------------------------

local function shell_quote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run_command_stream(cmd, on_stdout)
	local wrapped = string.format(
		"SHINNY_ENDPOINT=%s SHINNY_KEY=%s SHINNY_BODY=%s SHINNY_BODY_FILE=%s sh -c %s 2>&1",
		shell_quote(state.env.SHINNY_ENDPOINT or ""),
		shell_quote(state.env.SHINNY_KEY or ""),
		shell_quote(state.env.SHINNY_BODY or ""),
		shell_quote(state.env.SHINNY_BODY_FILE or ""),
		shell_quote(cmd)
	)
	local pipe = assert(io.popen(wrapped, "r"))
	local parts = {}
	while true do
		local chunk = pipe:read(4096)
		if not chunk then
			break
		end
		parts[#parts + 1] = chunk
		if on_stdout then
			on_stdout(chunk)
		end
	end
	pipe:close()
	return table.concat(parts)
end

local function run_command(cmd)
	local wrapped = string.format(
		"SHINNY_ENDPOINT=%s SHINNY_KEY=%s SHINNY_BODY=%s SHINNY_BODY_FILE=%s sh -c %s 2>&1",
		shell_quote(state.env.SHINNY_ENDPOINT or ""),
		shell_quote(state.env.SHINNY_KEY or ""),
		shell_quote(state.env.SHINNY_BODY or ""),
		shell_quote(state.env.SHINNY_BODY_FILE or ""),
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
				Prompt = function(_, prompt, msg, ptype, _ev, done)
					state.prompts[#state.prompts + 1] = { prompt = prompt, ptype = ptype, done = done }
				end,
			}
		end,
		CurPane = function()
			return state.pane
		end,
		After = function(ms, fn)
			state.afters[#state.afters + 1] = { ms = ms, fn = fn }
		end,
		Tabs = function()
			local tab = { Panes = state.panes }
			function tab:SetActive(i) end
			local tabs = { List = { tab } }
			function tabs:SetActive(i) end
			return tabs
		end,
	}
end

packages["micro/config"] = function()
	return {
		GetGlobalOption = function(name)
			return state.options[name]
		end,
		SetGlobalOption = function(name, value)
			state.options[name] = value
			return nil
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
		TryBindKey = function()
			return true, nil
		end,
		AddRuntimeFile = function() end,
		RTHelp = 0,
		NoComplete = nil,
		ConfigDir = "/tmp/shinny-test-cfg",
	}
end

packages["micro/buffer"] = function()
	local m = {}
	function m.NewBuffer(text, path)
		return new_buffer(text, "")
	end
	function m.Loc(x, y)
		return { X = x, Y = y }
	end
	return m
end

packages["micro/shell"] = function()
	return {
		JobStart = function(cmd, on_stdout, _se, on_exit)
			state.last_cmd = cmd
			local body = state.env.SHINNY_BODY
			if state.env.SHINNY_BODY_FILE and state.files[state.env.SHINNY_BODY_FILE] then
				body = state.files[state.env.SHINNY_BODY_FILE]
			end
			state.job_env = {
				ENDPOINT = state.env.SHINNY_ENDPOINT,
				KEY = state.env.SHINNY_KEY,
				BODY = body,
			}
			state.job_kind = "search"
			if tostring(state.env.SHINNY_ENDPOINT):find("chat", 1, true) then
				state.job_kind = "chat"
				state.chat_bodies[#state.chat_bodies + 1] = body
			end
			state.pending = function()
				if state.real then
					local out = run_command_stream(cmd, on_stdout)
					on_exit(out)
					return
				end
				if state.job_kind == "chat" then
					local sse = table.remove(state.chat_queue, 1)
					if sse == nil then
						sse = state.chat_sse
					end
					for line in (sse .. "\n"):gmatch("(.-\n)") do
						on_stdout(line)
					end
					on_exit(sse .. "\n__SHINNY_STATUS__:200")
				else
					on_exit(state.search_output)
				end
			end
			return {}
		end,
		JobStop = function() end,
		ExecCommand = function(name, ...)
			state.last_exec = { name = name, args = { ... } }
			if state.exec_output ~= nil then
				return state.exec_output, nil
			end
			return "", "not found"
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
		MkdirAll = function(path, mode)
			state.mkdirs[path] = mode
			os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
		end,
		Getpid = function()
			return 4242
		end,
		time = os.time,
		Remove = function(path)
			state.files[path] = nil
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

packages["io/ioutil"] = function()
	return {
		ReadFile = function(path)
			local data = state.files[path]
			if data ~= nil then
				return data
			end
			local f = io.open(path, "rb")
			if not f then
				error("no such file: " .. tostring(path), 0)
			end
			local disk = f:read("*a")
			f:close()
			return disk
		end,
		WriteFile = function(path, data, mode)
			state.files[path] = data
			state.last_written = { path = path, mode = mode }
			local f = io.open(path, "wb")
			if f then
				f:write(data)
				f:close()
			end
		end,
	}
end

packages["fmt"] = function()
	return {
		Sprintf = function(format, ...)
			return tostring((...))
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

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function flush()
	local guard = 0
	while state.pending and guard < 20 do
		local pending = state.pending
		state.pending = nil
		pending()
		guard = guard + 1
	end
end

local function run(fn, ...)
	state.pending = nil
	fn(...)
	flush()
end

local function reset()
	state.messages = {}
	state.prompts = {}
	state.pending = nil
	state.panes = {}
	state.split_count = 0
	state.search_output = ""
	state.chat_sse = ""
	state.chat_queue = {}
	state.chat_bodies = {}
	state.env = {}
	state.pane = nil
	state.real = false
end

local function message_text()
	local t = {}
	for _, m in ipairs(state.messages) do
		t[#t + 1] = m.kind .. ":" .. m.text
	end
	return table.concat(t, "\n")
end

local function last_message()
	local m = state.messages[#state.messages]
	return m and m.text or ""
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
		print("     messages: " .. message_text():gsub("\n", " | "))
	end
end

local function assert_true(cond, msg)
	if not cond then
		error(msg or "assertion failed", 2)
	end
end

local function assert_contains(haystack, needle, msg)
	if not haystack or not tostring(haystack):find(needle, 1, true) then
		error((msg or "missing text") .. ": expected [" .. tostring(needle) .. "] in [" .. tostring(haystack):sub(1, 400) .. "]", 2)
	end
end

local SAMPLE = [[
{
  "query": "什么是NVME集群",
  "answer": "NVMe 集群是……",
  "response_time": 0.42,
  "results": [
    {
      "title": "NVMe 集群入门",
      "url": "https://example.test/nvme",
      "content": "NVMe over Fabrics 把本地的 NVMe 协议扩展到网络上。",
      "score": 0.98
    }
  ]
}
__SHINNY_STATUS__:200
]]

local DS_SAMPLE = [[
{
  "results": [
    {
      "rerank_score": 2.4,
      "title": "DeepSeek result",
      "url": "https://deepseek.example/result",
      "snippet": "A short snippet.",
      "summary": "A longer summary.",
      "site_name": "DeepSeek Docs",
      "authority": 3
    }
  ]
}
__SHINNY_STATUS__:200
]]

local CHAT_EDIT = 'data: {"choices":[{"delta":{"reasoning_content":"想一想。"}}]}\n\n'
	.. 'data: {"choices":[{"delta":{"content":"好的，我改写了选区。\\n<<<SHINNY_EDIT selection>>>\\n重写后的专业表述。\\n<<<SHINNY_EDIT_END>>>"}}]}\n\n'
	.. 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
	.. 'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":12,"prompt_cache_hit_tokens":40,"prompt_cache_miss_tokens":60}}\n\n'
	.. 'data: [DONE]\n\n'

local CHAT_TEXT = 'data: {"choices":[{"delta":{"content":"你好，这是流式回答。"}}]}\n\n'
	.. 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
	.. 'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":12,"prompt_cache_hit_tokens":40,"prompt_cache_miss_tokens":60}}\n\n'
	.. 'data: [DONE]\n\n'

local TOOL_SSE = 'data: {"choices":[{"delta":{"reasoning_content":"需要调用工具。"}}]}\n\n'
	.. 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_mock","type":"function","function":{"name":"replace_selection","arguments":""}}]}}]}\n\n'
	.. 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"text\\":\\"工具改写后的文本\\"}"}}]}}]}\n\n'
	.. 'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n'
	.. 'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":12,"prompt_cache_hit_tokens":40,"prompt_cache_miss_tokens":60}}\n\n'
	.. 'data: [DONE]\n\n'

local FINAL_SSE = 'data: {"choices":[{"delta":{"content":"已完成修改。"}}]}\n\n'
	.. 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
	.. 'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":12,"prompt_cache_hit_tokens":40,"prompt_cache_miss_tokens":60}}\n\n'
	.. 'data: [DONE]\n\n'



local function jesc(text)
	return (tostring(text):gsub("\\", "\\\\"):gsub('"', '\\"')
		:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t"))
end

local function sse_text(text)
	return 'data: {"choices":[{"delta":{"content":"' .. jesc(text) .. '"}}]}\n\n'
		.. 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
		.. 'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":12,"prompt_cache_hit_tokens":40,"prompt_cache_miss_tokens":60}}\n\n'
		.. 'data: [DONE]\n\n'
end

local function setup_search(backend)
	reset()
	state.options["shinny.apikey"] = "tvly-test"
	state.options["shinny.deepseekkey"] = "ds-test"
	state.options["shinny.prefix"] = "什么是"
	state.options["shinny.suffix"] = ""
	state.options["shinny.backend"] = backend or "tavily"
	state.options["shinny.maxresults"] = 5
	state.options["shinny.depth"] = "basic"
	state.options["shinny.includeanswer"] = true
	state.options["shinny.endpoint"] = integration and integration.tavily or "https://api.tavily.com/search"
	state.options["shinny.deepseektoolsurl"] = integration and integration.search or "https://api.deepseek.com/v1/tools/search"
	state.options["shinny.chaturl"] = integration and integration.chat or "https://api.deepseek.com/chat/completions"
	state.options["shinny.chatmodel"] = "deepseek-flash"
	state.options["shinny.thinking"] = true
	state.options["shinny.effort"] = "high"
	local seq = (state.test_seq or 0) + 1
	state.test_seq = seq
	local bp = new_pane(new_buffer("NVME集群\n", "/tmp/notes" .. seq .. ".md"))
	bp.Cursor.sel = { { X = 0, Y = 0 }, { X = 10, Y = 0 } }
	state.pane = bp
	return bp
end

-- ---------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------

test("init registers options and commands", function()
	init()
	assert_true(state.options["shinny.prefix"] == "什么是", "prefix default")
	assert_true(state.options["shinny.backend"] == "tavily", "backend default")
	assert_true(state.commands["shinny"] ~= nil, "shinny command")
	assert_true(state.commands["shinny-chat"] ~= nil, "shinny-chat command")
	assert_true(state.commands["shinny-prefix"] ~= nil, "shinny-prefix command")
	assert_true(state.commands["shinny-backend"] ~= nil, "shinny-backend command")
end)

test("prepends prefix and appends suffix to the search query", function()
	local bp = setup_search("tavily")
	state.options["shinny.suffix"] = " 是什么"
	state.search_output = SAMPLE
	run(shinny, bp, nil)
	assert_contains(state.job_env.BODY, '"query":"什么是NVME集群 是什么"')
	assert_contains(state.last_cmd, "curl")
	local text = state.panes[#state.panes].Buf:text()
	assert_contains(text, "shinny · 什么是NVME集群 是什么")
	assert_contains(text, "前缀「什么是」")
	assert_contains(text, "后缀「 是什么」")
	assert_contains(text, "NVMe 集群入门")
end)

test("reuses one search results tab", function()
	local bp = setup_search("tavily")
	state.search_output = SAMPLE
	run(shinny, bp, nil)
	local count = #state.panes
	assert_true(state.panes[count].Buf:GetName() == "shinny: search results", "unexpected results name")

	run(shinny, bp, nil)
	assert_true(#state.panes == count, "second search created another results pane")
	assert_contains(state.panes[count].Buf:text(), "NVMe 集群入门")
end)

test("shinny-prefix persists and changes later searches", function()
	local bp = setup_search("tavily")
	state.commands["shinny-prefix"](bp, { "请问" })
	assert_true(state.options["shinny.prefix"] == "请问", "option updated")
	assert_contains(state.files["/tmp/shinny-test-cfg/shinny.json"], '"prefix": "请问"')

	state.search_output = SAMPLE
	run(shinny, bp, nil)
	assert_contains(state.job_env.BODY, '"query":"请问NVME集群"')
end)

test("shinny-backend switches to DeepSeek search", function()
	local bp = setup_search("tavily")
	state.commands["shinny-backend"](bp, { "deepseek" })
	assert_true(state.options["shinny.backend"] == "deepseek", "backend option")

	state.search_output = DS_SAMPLE
	run(shinny, bp, nil)

	assert_contains(state.job_env.ENDPOINT, "tools/search")
	assert_contains(state.job_env.BODY, '"count":5')
	assert_true(not state.job_env.BODY:find("max_results", 1, true), "tavily field leaked")
	local text = state.panes[#state.panes].Buf:text()
	assert_contains(text, "deepseek · 1 result(s)")
	assert_contains(text, "DeepSeek Docs")
	assert_contains(text, "score: 2.400")
end)

test("rejects an unknown backend", function()
	local bp = setup_search("tavily")
	state.commands["shinny-backend"](bp, { "bing" })
	assert_true(state.options["shinny.backend"] == "tavily", "backend changed")
	assert_contains(last_message(), "tavily")
end)

local function input_pane()
	return state.panes[#state.panes]
end

local function transcript_pane()
	return state.panes[#state.panes - 1]
end

local function set_input(text)
	local pane = input_pane()
	pane.Buf.lines = { "> " .. text }
	pane.Buf.cursor.X, pane.Buf.cursor.Y = #("> " .. text), 0
	return pane
end

local function ask(text)
	local pane = set_input(text)
	preInsertNewline(pane)
	flush()
end

test("chat opens a TUI split with a transcript and an input pane", function()
	local bp = setup_search("tavily")
	run(shinny_chat, bp, nil)

	assert_true(state.split_count == 2, "expected transcript + input splits")
	local input = input_pane()
	assert_contains(input.Buf:GetName(), "shinny chat input")
	assert_contains(input.Buf:text(), "> ")
	assert_contains(transcript_pane().Buf:text(), "shinny chat")
	assert_true(preInsertNewline(bp) == true, "Enter outside the input must pass through")
end)

test("Enter in the input pane sends the question and applies a rewrite", function()
	local bp = setup_search("tavily")
	state.chat_sse = CHAT_EDIT
	run(shinny_chat, bp, nil)
	assert_true(preInsertNewline(input_pane()) == false, "Enter should be consumed in the input")
	assert_contains(last_message(), "输入问题")

	ask("把选区改写成更专业的语言")

	assert_true(bp.Buf:text():find("重写后的专业表述。", 1, true) ~= nil, "selection not rewritten")
	assert_contains(state.job_env.BODY, "把选区改写成更专业的语言")
	assert_contains(state.job_env.BODY, "当前文件")
	assert_contains(state.job_env.BODY, "NVME集群")

	local chat_text = transcript_pane().Buf:text()
	assert_contains(chat_text, "› you")
	assert_contains(chat_text, "› shinny")
	assert_contains(chat_text, "已应用到文件")
	assert_contains(chat_text, "已替换选区")
	assert_contains(input_pane().Buf:text(), "> ")
end)

test("shift+enter inserts a newline in the chat input", function()
	local bp = setup_search("tavily")
	run(shinny_chat, bp, nil)
	local pane = set_input("abc")
	pane.Cursor.X, pane.Cursor.Y = 5, 0
	state.commands["shinny-chat-newline"](pane, nil)
	assert_contains(pane.Buf:text(), "abc\n")
	assert_true(#state.chat_bodies == 0, "newline must not send the message")
end)

test("alt-enter inserts an indented newline in a normal buffer", function()
	local bp = new_pane(new_buffer("  hello\n", "/tmp/plain.txt"))
	bp.Cursor.X, bp.Cursor.Y = 7, 0
	state.commands["shinny-chat-newline"](bp, nil)
	assert_contains(bp.Buf:text(), "  hello\n  ")
end)

test("split Escape then Enter also inserts a newline", function()
	local bp = setup_search("tavily")
	run(shinny_chat, bp, nil)
	local pane = set_input("abc")
	pane.Cursor.X, pane.Cursor.Y = 5, 0
	preEscape(pane)
	preInsertNewline(pane)
	assert_contains(pane.Buf:text(), "abc\n")
	assert_true(#state.chat_bodies == 0, "newline must not send the message")
end)

test("chat applies cursor insert and line replacement", function()
	local bp = setup_search("tavily")
	bp.Cursor.sel = { { X = 0, Y = 0 }, { X = 0, Y = 0 } }
	bp.Cursor.X, bp.Cursor.Y = 2, 0
	run(shinny_chat, bp, nil)

	state.chat_sse = sse_text("<<<SHINNY_EDIT cursor>>>\n插入的内容\n<<<SHINNY_EDIT_END>>>")
	ask("在光标处插入解释")
	assert_contains(bp.Buf:text(), "NV插入的内容ME集群")

	bp.Cursor.X, bp.Cursor.Y = 0, 1
	state.chat_sse = sse_text("<<<SHINNY_EDIT line>>>\nThis line has been translated.\n<<<SHINNY_EDIT_END>>>")
	ask("把这行改成英文")
	assert_contains(bp.Buf:text(), "This line has been translated.")
end)

test("chat sees other open files", function()
	local bp = setup_search("tavily")
	local other = new_buffer("OTHER FILE CONTENT\n", "/tmp/other.md")
	new_pane(other)
	state.chat_sse = '{"choices":[{"message":{"content":"ok"}}]}\n__SHINNY_STATUS__:200'
	run(shinny_chat, bp, nil)
	ask("看看别的文件")

	assert_contains(state.job_env.BODY, "OTHER FILE CONTENT")
	assert_contains(state.job_env.BODY, "打开的文件")
end)

test("chat keeps the question when no DeepSeek key is configured", function()
	local bp = setup_search("tavily")
	state.options["shinny.deepseekkey"] = ""
	run(shinny_chat, bp, nil)
	ask("你好")
	assert_contains(last_message(), "DeepSeek key")
	assert_contains(input_pane().Buf:text(), "> 你好")
end)

test("Alt-i focuses the input pane on an existing chat", function()
	local bp = setup_search("tavily")
	run(shinny_chat, bp, nil)
	local before = #state.panes
	run(shinny_chat, bp, nil)
	assert_true(#state.panes == before, "Alt-i must not create another chat")
end)

test("sends the model and thinking settings", function()
	local bp = setup_search("tavily")
	state.chat_sse = '{"choices":[{"message":{"content":"ok"}}]}\n__SHINNY_STATUS__:200'
	run(shinny_chat, bp, nil)
	ask("你好")

	assert_contains(state.job_env.BODY, '"model":"deepseek-flash"')
	assert_contains(state.job_env.BODY, '"thinking":{"type":"enabled"}')
	assert_contains(state.job_env.BODY, '"reasoning_effort":"high"')
	assert_contains(transcript_pane().Buf:text(), "deepseek-flash · thinking high")
end)

test("shinny-model switches the model and persists it", function()
	local bp = setup_search("tavily")
	state.commands["shinny-model"](bp, { "deepseek-v4-pro" })
	assert_true(state.options["shinny.chatmodel"] == "deepseek-v4-pro", "model option")
	assert_contains(state.files["/tmp/shinny-test-cfg/shinny.json"], '"model": "deepseek-v4-pro"')

	state.chat_sse = '{"choices":[{"message":{"content":"ok"}}]}\n__SHINNY_STATUS__:200'
	run(shinny_chat, bp, nil)
	ask("你好")
	assert_contains(state.job_env.BODY, '"model":"deepseek-v4-pro"')
end)

test("shinny-thinking off disables thinking and effort", function()
	local bp = setup_search("tavily")
	state.commands["shinny-thinking"](bp, { "off" })
	assert_true(state.options["shinny.thinking"] == "false" or state.options["shinny.thinking"] == false, "thinking option")

	state.chat_sse = '{"choices":[{"message":{"content":"ok"}}]}\n__SHINNY_STATUS__:200'
	run(shinny_chat, bp, nil)
	ask("你好")
	assert_contains(state.job_env.BODY, '"thinking":{"type":"disabled"}')
	assert_true(not state.job_env.BODY:find("reasoning_effort", 1, true), "effort sent while thinking disabled")
	assert_contains(transcript_pane().Buf:text(), "no thinking")
end)

test("shinny-effort validates and switches effort", function()
	local bp = setup_search("tavily")
	state.commands["shinny-effort"](bp, { "max" })
	assert_true(state.options["shinny.effort"] == "max", "effort option")

	state.chat_sse = '{"choices":[{"message":{"content":"ok"}}]}\n__SHINNY_STATUS__:200'
	run(shinny_chat, bp, nil)
	ask("你好")
	assert_contains(state.job_env.BODY, '"reasoning_effort":"max"')

	state.commands["shinny-effort"](bp, { "bogus" })
	assert_true(state.options["shinny.effort"] == "max", "invalid effort changed the option")
	assert_contains(last_message(), "low")
end)

test("shinny-preview renders markdown in a split", function()
	local bp = new_pane(new_buffer("# Hi\n\nbody\n", "/tmp/doc.md"))
	state.exec_output = "  Hi\n\nbody\n"
	state.commands["shinny-preview"](bp, nil)

	assert_true(state.files["/tmp/shinny-test-cfg/shinny/preview.md"] ~= nil, "preview source not written")
	local pane = state.panes[#state.panes]
	assert_contains(pane.Buf:text(), "Hi")
	assert_true(pane.Buf.options.filetype == "markdown", "preview filetype")
end)

test("shinny-help opens a help buffer", function()
	local bp = setup_search("tavily")
	run(state.commands["shinny-help"], bp, nil)
	local text = state.panes[#state.panes].Buf:text()
	assert_contains(text, "shinny 帮助")
	assert_contains(text, "shinny-model")
	assert_contains(text, "Alt-i")
	assert_contains(text, "当前设置")
end)

test("chat buffers get their syntax filetypes", function()
	local bp = setup_search("tavily")
	state.chat_sse = sse_text("ok")
	run(shinny_chat, bp, nil)
	ask("hi")

	local transcript = transcript_pane().Buf
	local input = input_pane().Buf
	assert_true(transcript.options and transcript.options.filetype == "shinnychat", "transcript filetype")
	assert_true(input.options and input.options.filetype == "shinnyinput", "input filetype")
	assert_contains(transcript:text(), "› you")
	assert_contains(transcript:text(), "deepseek-flash")
end)

test("chat executes tool calls and reports usage", function()
	local bp = setup_search("tavily")
	bp.Cursor.sel = { { X = 0, Y = 0 }, { X = 10, Y = 0 } }
	state.chat_queue = { TOOL_SSE, FINAL_SSE }

	run(shinny_chat, bp, nil)
	ask("用工具改写选区")

	assert_contains(bp.Buf:text(), "工具改写后的文本")
	local text = transcript_pane().Buf:text()
	assert_contains(text, "⚙ replace_selection")
	assert_contains(text, "已完成修改。")
	assert_contains(text, "cache 40%")
	assert_true(#state.chat_bodies == 2, "expected two requests, got " .. tostring(#state.chat_bodies) .. " log=" .. tostring(_dbg_log))
	assert_contains(state.chat_bodies[2], '"role":"tool"')
	assert_contains(state.chat_bodies[2], '"tool_calls"')
	assert_contains(state.chat_bodies[2], '"reasoning_content"')
end)

test("attaches an image to the next user message", function()
	local bp = setup_search("tavily")
	state.files["/tmp/pic.png"] = "\137PNG\r\n\26\n" .. string.rep("A", 40)
	run(shinny_chat, bp, nil)
	state.commands["shinny-image"](input_pane(), { "/tmp/pic.png" })
	assert_contains(transcript_pane().Buf:text(), "待发送")

	state.chat_sse = CHAT_TEXT
	ask("描述这张图")
	assert_contains(state.chat_bodies[1], '"type":"image_url"')
	assert_contains(state.chat_bodies[1], "data:image/png;base64,")
	assert_contains(transcript_pane().Buf:text(), "🖼 pic.png")
end)

test("supports external image URLs and detail", function()
	local bp = setup_search("tavily")
	run(shinny_chat, bp, nil)
	state.commands["shinny-image-detail"](input_pane(), { "low" })
	state.commands["shinny-image-url"](input_pane(), { "https://example.com/a.jpg" })
	state.chat_sse = sse_text("ok")
	ask("看图")
	assert_contains(state.chat_bodies[1], "https://example.com/a.jpg")
	assert_contains(state.chat_bodies[1], '"detail":"low"')
end)

test("chat persists the conversation to disk", function()
	local bp = setup_search("tavily")
	state.chat_sse = CHAT_TEXT
	run(shinny_chat, bp, nil)
	ask("你好")

	local found = nil
	for path, data in pairs(state.files) do
		if path:find("/chats/", 1, true) then
			found = { path = path, data = data }
		end
	end
	assert_true(found ~= nil, "no chat file written")
	assert_contains(found.data, '"role":"user"')
	assert_contains(found.data, '"role":"assistant"')
	assert_contains(found.data, '"usage"')
	assert_true(state.mkdirs["/tmp/shinny-test-cfg/shinny/chats"] ~= nil, "chat dir not created")
end)

test("shinny-chat-new clears the session", function()
	local bp = setup_search("tavily")
	state.chat_sse = CHAT_TEXT
	run(shinny_chat, bp, nil)
	ask("你好")
	assert_contains(transcript_pane().Buf:text(), "你好，这是流式回答。")

	local chat_pane = transcript_pane()
	state.commands["shinny-chat-new"](chat_pane, nil)
	local after = transcript_pane().Buf:text()
	assert_true(not after:find("流式回答", 1, true), "messages not cleared: " .. after:sub(1, 200))
	assert_contains(transcript_pane().Buf:text(), "在下方输入栏")
end)

test("tavily HTTP errors are surfaced", function()
	local bp = setup_search("tavily")
	state.search_output = '{"detail":{"error":"Invalid API key."}}\n__SHINNY_STATUS__:401'
	run(shinny, bp, nil)
	assert_contains(last_message(), "Invalid API key.")
end)

if integration then
	test("talks to a Tavily-compatible endpoint end to end", function()
		local bp = setup_search("tavily")
		state.options["shinny.apikey"] = "tvly-test-key"
		state.panes = { bp }
		state.pane = bp
		state.real = true
		run(shinny, bp, { "integration query" })
		local text = state.panes[#state.panes].Buf:text()
		assert_contains(text, "Mock result for 什么是integration query")
		assert_contains(text, "https://example.test/integration")
	end)

	test("talks to a DeepSeek-compatible chat endpoint end to end", function()
		local bp = setup_search("tavily")
		state.options["shinny.deepseekkey"] = "ds-test-key"
		state.panes = { bp }
		state.pane = bp
		state.real = true
		bp.Cursor.sel = { { X = 0, Y = 0 }, { X = 10, Y = 0 } }
		run(shinny_chat, bp, nil)
		ask("用工具改写选区")
		assert_contains(bp.Buf:text(), "工具改写后的文本")
	end)
end

print(string.format("\n%d test(s), %d failure(s)", total, failures))
if failures > 0 then
	os.exit(1)
end
