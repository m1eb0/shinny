# shinny

一个 [micro](https://micro-editor.github.io) 插件：

- **搜索**：选中文字按 `Alt-s`，用 Tavily 或 DeepSeek 搜索它；所有结果集中在一个固定的 `shinny: search results` tab 里，每次搜索更新它。查询会自动加上可配置的前缀/后缀（默认 `什么是`），前后缀每次都会显示出来。
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

在文件里按 `Alt-i`：在**右侧打开 chat 分屏**——上方是对话记录，下方是输入栏（`>`，随内容自动增高/变矮，最多 8 行）。直接输入问题，Enter 发送，`Shift+Enter` 换行；再按 `Alt-i` 把焦点带回输入栏。

**用哪个会话由按快捷键时光标所在的文件决定**：在 A 文件按 `Alt-i` 显示 A 的会话；在 B 文件按 `Alt-i` 会把同一个右侧分屏切换成 B 的会话，各自的历史、图片、用量独立保存。同一个 tab 里始终只有一个 chat 分屏；切换文件后再按 `Alt-i` 即可换回。

### Shift+Enter 换行（终端设置）

micro 2.0.15 的 tcell 还无法解码 Ghostty 默认发送的 `CSI 27;2;13~`：`ESC [` 会被当成 `Alt-[`，触发 `DiffPrevious|CursorStart` 并插入残余字符。所以需要让终端把 `Shift+Enter` 发成 micro 认识的 `ESC` + `Enter`（即 `Alt-Enter`），插件再把 `Alt-Enter` 绑定到输入栏换行：

    # ~/.config/ghostty/config.ghostty
    keybind = shift+enter=text:\x1b\r

改完在 Ghostty 里按 `ctrl+shift+,` 重载配置（或重启 Ghostty），再重启 micro 让插件重新注册绑定。之后：

- 输入栏里 `Enter` 发送
- `Shift+Enter` 在当前光标处换行
- 普通编辑区里 `Shift+Enter` 也换行，并沿用当前行的缩进

其他终端也可以把 `Shift+Enter` 映射为 `ESC` + `CR`；对应地，插件的 `shinny-chat-newline` 命令也可以手动绑定。插件同时兼容 `ESC` 与 `CR` 被拆成两次按键事件的情况（300ms 内视为一次 `Shift+Enter`）。

Chat 的上下文包括：

- 当前文件和其他所有打开的文件（按 `shinny.chatcontext` 字符预算截断）
- 光标所在行/列、选中文本
- 最近一次搜索的完整结果

可以直接说「解释光标处的代码」「把选区改写成更专业的语言」「把这行改成英文」。

默认模型 `deepseek-flash`、开启思考模式（effort `high`）；用 `shinny-model` / `shinny-thinking` / `shinny-effort` 调整，当前配置显示在 chat 顶部。

Chat 是流式的：回答边生成边显示，`Esc` 停止；思考内容单独保存（`shinny.showthinking` 可显示）。模型通过 function calling 调用 `replace_selection` / `insert_at_cursor` / `replace_line` / `read_file` 修改文件，写入走 micro 的 buffer 事件，`Ctrl-Z` 可撤销。

流式收到 `[DONE]` 会立即收尾，不再等 curl 连接关闭；单次请求最长 30 分钟（避免长回答被原来的 3 分钟上限截断）；如果 60 秒没有任何数据，会保留已收到的部分内容并结束（信息栏提示超时）。`finish_reason=length` 或连接中途断开时，回答末尾会标注“回答可能不完整”。会话按文件持久化在 `~/.config/micro/shinny/chats/`，重启 micro 能恢复；顶部显示 token 用量和 cache 命中率，`> shinny-usage` 查看累计值，`> shinny-chat-new` 清空会话。上下文按 `shinny.chattokenbudget`（token 估算）裁剪；system prompt 固定、易变上下文注入最新一条 user 消息，以尽量命中 DeepSeek 的前缀缓存。

### Markdown 预览

micro 本身只做 Markdown 语法高亮，不渲染排版。编辑文件时按 **`Alt-r`**（或 `> shinny-preview`）会在**新 tab** 里打开当前 buffer（含未保存修改）的渲染预览；再按一次刷新。在 chat 里按 `Alt-r` 则渲染最后一条 assistant 回答。

渲染用 `python3 -m rich.markdown`，写到 `shinny/preview.md`；没有 `rich` 时显示原文。

也可以手动开终端分屏：`> vsplit`，在新 pane 里 `> term python3 -m rich.markdown 文件.md`。

### 图片

`deepseek-flash` 支持图片。附到下一问的图片用 OpenAI 兼容的 `image_url` block 发送（文件转 base64 data URL）：

    > shinny-image ~/Pictures/shot.png     # PNG / JPEG / GIF / WebP
    > shinny-image                        # 剪贴板（wl-paste / xclip）
    > shinny-image-url https://…/a.jpg
    > shinny-image-detail low             # low | high | original | auto
    > shinny-image-clear

单张默认上限 `shinny.imagemaxmb` = 12 MB；对话记录里会显示 `🖼` 缩略标记。图片只出现在 user 消息中（API 限制），每张按约 1024 tokens 计入预算。

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
| `shinny-help` | 显示命令、快捷键、选项和当前设置 |
| `shinny-chat-new` | 清空当前文件的会话 |
| `shinny-usage` | 显示 token / cache 用量 |
| `shinny-preview` | 在新 tab 渲染当前 Markdown 或最后一条回答（`Alt-r`） |
| `shinny-chat-stop` | 停止生成（同 `Esc`） |
| `shinny-chat-newline` | 输入栏换行（`Alt-Enter`） |
| `shinny-image [path]` | 附加图片到下一问；不带参数读剪贴板 |
| `shinny-image-url <url>` | 附加公网图片 URL |
| `shinny-image-detail <level>` | 设置图片 detail |
| `shinny-image-clear` | 清空待发送图片 |

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
| `shinny.chattokenbudget` | `24000` |
| `shinny.showthinking` | `false` |
| `shinny.imagedetail` | `auto` |
| `shinny.imagemaxmb` | `12` |

| `shinny.endpoint` / `shinny.deepseektoolsurl` / `shinny.chaturl` | 官方地址 |

## 外观

chat 分屏、输入栏、搜索结果 tab 和帮助页都带语法高亮（角色、分隔线、模型/思考状态、URL、修改提示），颜色取自当前 colorscheme，并自动启用 softwrap。

## 实现说明

- 搜索和 chat 都通过 `micro/shell.JobStart` 在后台跑 `curl`；chat 用 SSE 流式读取，`content` / `reasoning_content` / `tool_calls` 增量拼装。
- Chat 使用 DeepSeek 的 function calling：多轮 tool loop 直到模型给出最终回答；带 `tools` 时按文档回传历史 `reasoning_content`。
- 响应由插件自带的小型 JSON 解码器解析（micro 的 Lua 没有 JSON 库），并针对 gopher-lua 的 `table.concat` 限制做了分批拼接；会话 JSON 由插件自己编码。
- 带图片的请求体可能很大，chat 请求会写到 `shinny/chats/request-*.json` 再由 `curl --data-binary @file` 读取，避免环境变量/命令行长度限制；请求结束即删除。
- 上下文从 `micro.Tabs()` 枚举所有 pane 的 buffer 拼装，并做 token 估算（CJK 感知）与历史裁剪；写入调用 `Buffer:Insert`/`Buffer:Remove`，进入 micro 的 undo 栈。

## 开发

```sh
make test    # 30 个 headless 测试 + 2 个走本地 mock 的端到端测试
```

`tests/run.lua` 用假的 micro API 跑逻辑；`tests/integration.sh` 启动
`tests/mock_tavily.py` 和 `tests/mock_deepseek.py`，用真 `curl` 走一遍搜索、DeepSeek 搜索和 chat 改写。

## License

MIT
