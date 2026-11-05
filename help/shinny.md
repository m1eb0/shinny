# shinny

用 Tavily 或 DeepSeek 搜索选中的文字，并在分屏里查看结果；还可以在正在编辑的文件旁打开一个专属的 LLM 对话分屏，让它帮你解释、改写选中的内容。

## 搜索

选中文字，按 `Alt-s`（或运行 `> shinny`）。

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

在任意文件里按 `Alt-i`：右侧打开这个文件专属的 chat 分屏，上方是对话记录，下方是输入栏（`>`）。直接输入问题，按 Enter 发送；再按 `Alt-i` 会把焦点带回输入栏。

Chat 能看到：

* 当前文件和其他所有打开的文件（内容按预算截断）
* 光标所在行/列、选中的文本
* 最近一次 Tavily / DeepSeek 搜索的结果

可以直接让它改文件，例如：

* `解释光标处的代码`
* `把选区改写成更专业的语言`
* `把这行改成英文`

模型会用下面的块描述修改，shinny 立即写入文件（`Ctrl-Z` 可撤销）：

    <<<SHINNY_EDIT selection>>>
    新的选区内容
    <<<SHINNY_EDIT_END>>>

target 支持 `selection`（替换选区）、`cursor`（插入到光标处）、`line`（替换光标所在行）。

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
| `shinny.chatcontext` | `24000` | 发给 chat 的文件上下文字符预算 |

## 排错

搜索或 chat 出错时，信息栏会显示原因；`> shinny-raw` 可以打开上一次请求的原始响应，方便判断是 API 报错、代理页面还是网络问题。
