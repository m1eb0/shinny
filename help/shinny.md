# shinny

用 Tavily 或 DeepSeek 搜索选中的文字，结果集中在一个固定的 `shinny: search results` tab 里；还可以在正在编辑的文件旁打开一个专属的 LLM 对话分屏，让它帮你解释、改写选中的内容。

## 搜索

选中文字，按 `Alt-s`（或运行 `> shinny`）。结果会在 `shinny: search results` tab 里更新，不会每次新开分屏；用 `Alt-,` / `Alt-.` 在源文件和结果 tab 之间切换。

实际查询 = 前缀 + 选中文字 + 后缀。默认前缀是「什么是」，所以选中 `NVME集群` 会搜索 `什么是NVME集群`。每次搜索都会在结果顶部和信息栏显示当前的前缀与后缀。

修改前缀/后缀（会保存到 `shinny.json`，重启后仍然生效）：

    > shinny-prefix 请问
    > shinny-suffix 是什么
    > shinny-prefix -          清除前缀

不带参数时只显示当前值。

### 切换搜索后端

    > shinny-backend deepseek
    > shinny-backend tavily

默认是 Tavily。DeepSeek 搜索使用官方 Search API
（`https://api.deepseek.com/v1/tools/search`），需要 DeepSeek key：

    > set shinny.deepseekkey sk-...

也可以使用环境变量 `DEEPSEEK_API_KEY`（优先于设置）。

## LLM Chat

在任意文件里按 `Alt-i`：在**右侧打开 chat 分屏**，上方是对话记录，下方是输入栏（`>`，随内容自动增高/变矮，最多 8 行）。直接输入问题，按 Enter 发送，`Shift+Enter` 换行；再按 `Alt-i` 会把焦点带回输入栏。

**使用哪个会话，取决于按快捷键时光标所在的文件**：在 A 文件按 `Alt-i` 显示 A 的会话；在 B 文件按 `Alt-i` 会把同一个右侧分屏切换成 B 的会话。每个文件的历史、图片、用量独立保存；同一 tab 内始终只有一个 chat 分屏。

> `Shift+Enter` 在普通编辑区和 chat 输入栏都可用（普通编辑区会沿用当前行缩进）；它需要终端把它映射成 `Alt-Enter`。Ghostty 在 `~/.config/ghostty/config.ghostty` 写 `keybind = shift+enter=text:\x1b\r`，然后 `ctrl+shift+,` 重载配置。原因：micro 2.0.15 的 tcell 还不认识 Ghostty 默认发的 `CSI 27;2;13~`，会把 `ESC [` 当成 `Alt-[` 从而跳到 buffer 开头。插件已把 `Alt-Enter` 绑定到输入栏换行。

Chat **每轮自动注入**：

* 当前文件路径、光标行列、**整个光标所在行**
* 如果发送前有选区，注入**整个选区**
* 所有打开文件的路径列表（不注入内容）
* 最近一次 Tavily / DeepSeek 搜索的结果

文件全文不会每轮注入。需要时模型调用 `read_current_file`、`read_open_file(path)`、`read_file(path)` 或 `list_open_files` 按需读取。除首轮外，每条 user 消息开头会注入 `妈妈加油。`（不显示在对话记录里）。

可以直接让它改文件，例如：

* `解释光标处的代码`
* `把选区改写成更专业的语言`
* `把这行改成英文`

模型通过 **function calling** 调用 `replace_selection` / `insert_at_cursor` / `replace_line` / `read_file` 直接操作文件（`Ctrl-Z` 可撤销），不再需要手工粘贴补丁。

Chat 的行为：

* **流式输出**：回答边生成边显示；收到 `[DONE]` 立即收尾；单次请求最长 30 分钟；首字/思考阶段静默会先自动改用非流式重试一次（`shinny.streamfallback`），正文中途静默才保留部分内容并结束；`finish_reason=length` 或连接中断会标注“回答可能不完整”；`Esc` 可随时停止
* **调试日志**：默认记录 `last-stream.log`（带 tick 的原始 SSE）和 `last-network.log`（chunk/等待/gap 事件 + curl HTTP/DNS/TLS/TTFB/耗时/速度指标），用 `> shinny-log` / `> shinny-netlog` 打开；可用 `shinny.debug` 关闭
* 流式固定 HTTP/1.1，`shinny.streamtimeout` 控制无数据超时（默认 120 秒）；等待时状态栏显示已等待秒数
* **思考模式**：`reasoning_content` 单独保存，`shinny.showthinking` 打开后显示
* **会话持久化**：每个文件的会话保存在 `~/.config/micro/shinny/chats/`，重启 micro 可恢复
* **用量可见**：顶部显示 token 用量与 cache 命中率；`> shinny-usage` 查看累计值；`> shinny-chat-new` 清空会话
* 上下文按 token 预算裁剪（`shinny.chattokenbudget`），system prompt 固定、易变上下文放在最新一条消息里，尽量提高前缀缓存命中

### Markdown 预览

编辑文件时按 **`Alt-r`**（等同于 `> shinny-preview`）会把当前 buffer（含未保存修改）写到临时 `.md`，用 `python3 -m rich.markdown` 渲染到**新 tab**；再按一次刷新。用 `Alt-,` / `Alt-.` 切换回源文件 tab。在 chat 里按 `Alt-r` 则渲染最后一条 assistant 回答。没有 `rich` 时退回显示 Markdown 原文。

也可以直接用 micro 的终端分屏：`> vsplit` 后在空白 pane 里 `> term python3 -m rich.markdown 文件.md`。

### 图片输入

`deepseek-flash` 支持图片。图片会随**下一条** user 消息发送（每张约 1024 tokens，按尺寸计费）：

    > shinny-image ~/Pictures/shot.png     # 文件（PNG / JPEG / GIF / WebP）
    > shinny-image                        # 从剪贴板读（wl-paste / xclip）
    > shinny-image-url https://…/a.jpg    # 公网 URL
    > shinny-image-detail low             # low | high | original | auto
    > shinny-image-clear                  # 取消待发送图片

文件会转成 base64 data URL 内联发送；单张默认上限 12 MB（`shinny.imagemaxmb`），base64 后仍远低于 API 的 48 MiB 请求体限制。图片只放在 user 消息里（API 限制）。

Chat 使用 DeepSeek Chat API，与搜索共用同一个 key。默认模型是 `deepseek-flash`，默认开启思考模式（effort = `high`）。可以随时切换：

    > shinny-model deepseek-v4-pro
    > shinny-thinking off
    > shinny-effort max            # low | high | max

模型和思考设置会保存在 `shinny.json`，当前配置显示在 chat 分屏顶部。

## 快捷键

* `Alt-s`：搜索选区
* `Alt-i`：打开/继续当前文件的 chat

`Alt-s` 需要在 `bindings.json` 里绑定（`> help keybindings`）：

    "Alt-s": "command:shinny"

插件首次加载时会自动绑定 `Alt-i`（如果该键未被占用）。

## 命令

| 命令 | 说明 |
| --- | --- |
| `shinny [query]` | 搜索选区或给定文字 |
| `shinny-prefix [text]` | 查看/设置搜索前缀（`-` 清除） |
| `shinny-suffix [text]` | 查看/设置搜索后缀（`-` 清除） |
| `shinny-backend [tavily\|deepseek]` | 查看/切换搜索后端 |
| `shinny-chat` | 打开当前文件的 chat 分屏 |
| `shinny-model [name]` | 查看/切换 chat 模型（`deepseek-flash`、`deepseek-v4-pro`） |
| `shinny-thinking [on\|off]` | 查看/切换思考模式 |
| `shinny-effort [low\|high\|max]` | 查看/设置思考强度 |
| `shinny-raw` | 打开上一次请求的原始响应 |
| `shinny-help` | 显示所有命令、快捷键、选项和当前设置 |
| `shinny-chat-new` | 清空当前文件的会话 |
| `shinny-usage` | 显示本次会话的 token / cache 用量 |
| `shinny-preview` | 在新 tab 渲染当前 Markdown（或最后一条回答）（`Alt-r`） |
| `shinny-log` | 在新 tab 打开上一次请求的流日志 |
| `shinny-netlog` | 在新 tab 打开上一次请求的网络日志 |
| `shinny-chat-stop` | 停止正在生成的回复（同 `Esc`） |
| `shinny-chat-newline` | 在输入栏插入换行（`Alt-Enter` 绑定） |
| `shinny-image [path]` | 附加图片到下一问；不带参数读剪贴板 |
| `shinny-image-url <url>` | 附加公网图片 URL |
| `shinny-image-detail <level>` | 设置图片 detail |
| `shinny-image-clear` | 清空待发送图片 |

## 选项

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `shinny.apikey` | 空 | Tavily key |
| `shinny.deepseekkey` | 空 | DeepSeek key（搜索 + chat） |
| `shinny.prefix` / `shinny.suffix` | `什么是` / 空 | 搜索前后缀 |
| `shinny.backend` | `tavily` | `tavily` 或 `deepseek` |
| `shinny.maxresults` | `5` | 结果数量（Tavily ≤20，DeepSeek ≤50） |
| `shinny.depth` | `basic` | Tavily 搜索深度 |
| `shinny.includeanswer` | `true` | Tavily 是否附带 answer |
| `shinny.endpoint` | Tavily 地址 | 自定义 Tavily 端点 |
| `shinny.deepseektoolsurl` | DeepSeek Search 地址 | 自定义 DeepSeek 搜索端点 |
| `shinny.chaturl` | DeepSeek Chat 地址 | 自定义 chat 端点 |
| `shinny.chatmodel` | `deepseek-flash` | chat 模型 |
| `shinny.thinking` | `true` | 是否开启思考模式 |
| `shinny.effort` | `high` | 思考强度（low/high/max） |
| `shinny.chattokenbudget` | `24000` | 历史消息的 token 预算 |
| `shinny.showthinking` | `false` | 是否在对话里显示思考内容 |
| `shinny.imagedetail` | `auto` | 图片 detail：`low` / `high` / `original` / `auto` |
| `shinny.imagemaxmb` | `12` | 单张图片大小上限（MB） |
| `shinny.maxtokens` | `65536` | 单次回答最大输出 tokens |
| `shinny.debug` | `true` | 记录流式调试日志 |
| `shinny.streamtimeout` | `120` | 正文中途无数据多少秒后结束 |
| `shinny.streamfallback` | `true` | 首字/思考静默时自动非流式重试 |
| `shinny.firstbyttimeout` | `15` | 首字超时（秒） |
| `shinny.stalltimeout` | `45` | thinking 阶段 chunk 间隔超时（秒） |


## 外观

chat 分屏、输入栏、搜索结果和帮助页都带语法高亮：角色标签、分隔线、模型/思考状态、URL、`▸ 已应用` 提示等使用当前 colorscheme 的颜色，并自动开启 softwrap。换 colorscheme 后颜色会跟着变。

## 排错

搜索或 chat 出错时，信息栏会显示原因；`> shinny-raw` 可以打开上一次请求的原始响应，方便判断是 API 报错、代理页面还是网络问题。
