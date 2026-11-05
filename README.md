# shinny

一个 [micro](https://micro-editor.github.io) 插件：

- **搜索**：选中文字按 `Alt-s`，用 Tavily 或 DeepSeek 搜索它，结果开在右侧分屏；查询会自动加上可配置的前缀/后缀（默认 `什么是`），前后缀每次都会显示出来。
- **Chat**：在正在编辑的文件里按 `Alt-i`，打开这个文件专属的 LLM 对话分屏。它能看见所有打开的文件、光标位置、选中文本和最近的搜索结果，并且可以直接改写文件（`Ctrl-Z` 可撤销）。

```
┌─ notes.md ─────────────────┬─ shinny: 什么是NVMe集群 ─────────┐
│ NVMe集群 是一种……          │ shinny · 什么是NVMe集群          │
│                            │ tavily · 5 result(s) · 0.42s     │
│                            │ 前缀「什么是」 · 后缀「无」      │
└────────────────────────────┴──────────────────────────────────┘
```

## 安装

需要 micro ≥ 2.0、`curl`，以及 Tavily（和/或 DeepSeek）的 API key。

```sh
git clone https://github.com/m1eb0/shinny
cd shinny
make link          # 软链到 ~/.config/micro/plug/shinny
```

启动 micro，配置 key：

```
> set shinny.apikey tvly-...          # Tavily
> set shinny.deepseekkey sk-...       # DeepSeek（搜索 + chat）
```

也可以用环境变量 `TAVILY_API_KEY`、`DEEPSEEK_API_KEY`。

绑定搜索键（`~/.config/micro/bindings.json`）：

```json
{
    "Alt-s": "command:shinny"
}
```

`Alt-i` 由插件在首次加载时自动绑定（如果没被占用）。

## 使用

### 搜索

选中文字按 `Alt-s`，或者 `> shinny 关键词`。查询 = 前缀 + 文字 + 后缀，例如选中 `NVMe集群` 搜索的是 `什么是NVMe集群`。

```
> shinny-prefix 请问          # 查看/设置前缀；`-` 清除
> shinny-suffix 是什么        # 查看/设置后缀
> shinny-backend deepseek     # 切换到 DeepSeek Search
> shinny-backend tavily       # 切回 Tavily
```

前缀/后缀/后端会保存到 `~/.config/micro/shinny.json`，重启后仍然生效。每次搜索时，信息栏和结果头部都会显示当前的前缀与后缀。

DeepSeek 搜索走官方 `POST /v1/tools/search`，需要 DeepSeek key；两个后端都支持分页数量、结果标题/URL/摘要/评分。

### Chat

在文件里按 `Alt-i`：右侧出现这个文件专属的聊天分屏——上方是对话记录，下方是输入栏（`>`）。直接输入问题，Enter 发送；再按 `Alt-i` 把焦点带回输入栏。

Chat 的上下文包括：

- 当前文件和其他所有打开的文件（按 `shinny.chatcontext` 字符预算截断）
- 光标所在行/列、选中文本
- 最近一次搜索的完整结果

可以直接说「解释光标处的代码」「把选区改写成更专业的语言」「把这行改成英文」。

默认模型 `deepseek-flash`、开启思考模式（effort `high`）；用 `shinny-model` / `shinny-thinking` / `shinny-effort` 调整，当前配置显示在 chat 顶部。模型用 `<<<SHINNY_EDIT selection>>>…<<<SHINNY_EDIT_END>>>` 描述修改，插件立即写入文件：

- `selection`：替换当前选区
- `cursor`：插入到光标处
- `line`：替换光标所在行

修改通过 micro 的 buffer 事件写入，所以 `Ctrl-Z` 可以撤销。

## 命令与选项

| 命令 | 说明 |
| --- | --- |
| `shinny [query]` | 搜索选区或指定文字 |
| `shinny-prefix [text]` | 查看/设置前缀 |
| `shinny-suffix [text]` | 查看/设置后缀 |
| `shinny-backend [tavily\|deepseek]` | 查看/切换搜索后端 |
| `shinny-chat` | 打开当前文件的 chat，等同于 `Alt-i` |
| `shinny-model [name]` | 查看/切换模型 |
| `shinny-thinking [on\|off]` | 查看/切换思考模式 |
| `shinny-effort [low\|high\|max]` | 查看/设置思考强度 |
| `shinny-raw` | 查看上一次请求的原始响应 |

| 选项 | 默认值 |
| --- | --- |
| `shinny.apikey` / `shinny.deepseekkey` | 空 |
| `shinny.prefix` / `shinny.suffix` | `什么是` / 空 |
| `shinny.backend` | `tavily` |
| `shinny.maxresults` | `5` |
| `shinny.depth` / `shinny.includeanswer` | `basic` / `true` |
| `shinny.chatmodel` | `deepseek-flash` |
| `shinny.thinking` / `shinny.effort` | `true` / `high` |
| `shinny.chatcontext` | `24000` |
| `shinny.endpoint` / `shinny.deepseektoolsurl` / `shinny.chaturl` | 官方地址 |

## 实现说明

- 搜索和 chat 都通过 `micro/shell.JobStart` 在后台跑 `curl`，micro 不会卡住；query 和请求体通过环境变量传递，选区文字不需要 shell 转义。
- 响应由插件自带的小型 JSON 解码器解析（micro 的 Lua 没有 JSON 库），并针对 gopher-lua 的 `table.concat` 限制做了分批拼接。
- Chat 上下文从 `micro.Tabs()` 枚举所有 pane 的 buffer 拼装，写入则调用 `Buffer:Insert`/`Buffer:Remove`，因此进入 micro 的 undo 栈。

## 开发

```sh
make test    # 10 个 headless 测试 + 2 个走本地 mock 的端到端测试
```

`tests/run.lua` 用假的 micro API 跑逻辑；`tests/integration.sh` 启动
`tests/mock_tavily.py` 和 `tests/mock_deepseek.py`，用真 `curl` 走一遍搜索、DeepSeek 搜索和 chat 改写。

## License

MIT
