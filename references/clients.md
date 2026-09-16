# MCP 客户端接入细节

端点信息（所有客户端通用）：

```
URL       https://laws.sg/api/mcp
Transport Streamable HTTP
Auth      Authorization: Bearer laws_sg_...
Server 名 laws-sg
环境变量  LAWS_SG_MCP_TOKEN
```

## 支持矩阵

脚本对客户端分三类处理。**格式没有权威来源的一律只出片段，不猜、不写。**

| 客户端 | 脚本行为 | 格式来源 | 配置位置 |
| --- | --- | --- | --- |
| `kimi-code` | JSON 合并写 | kimi-code 官方文档 | `~/.kimi-code/mcp.json`（项目级 `./.kimi-code/mcp.json`） |
| `cursor` | JSON 合并写 | laws.sg `/legal-ai` 官方 snippet | `~/.cursor/mcp.json`（项目级 `./.cursor/mcp.json`） |
| `vscode` | JSON 合并写 | laws.sg `/legal-ai` 官方 snippet | `./.vscode/mcp.json`（工作区级，无 user/project 之分） |
| `generic` | JSON 合并写 | laws.sg `/legal-ai` 官方通用片段 | `--path` 指定，默认 `./.mcp.json` |
| `claude` | 调用官方 CLI | laws.sg 官方命令 | 由 `claude mcp add` 自己管理 |
| `codex` | 调用官方 CLI | laws.sg 官方命令 | 由 `codex mcp add` 自己管理 |
| 其他 | **只出片段** | —— | —— |

`configure --client auto`（默认）只写**探测到已安装**的客户端。探测依据：

| 客户端 | 判定条件 |
| --- | --- |
| kimi-code | `$KIMI_CODE_HOME`/`~/.kimi-code` 目录存在，或 `kimi` 在 PATH |
| claude | `claude` 在 PATH，或 `~/.claude.json` / `~/.claude` 存在 |
| codex | `codex` 在 PATH，或 `~/.codex` 存在 |
| cursor | `~/.cursor` 或 `/Applications/Cursor.app` 存在 |
| vscode | `code` 在 PATH，或 `/Applications/Visual Studio Code.app` 存在 |

CLI 型客户端若二进制不在 PATH，脚本会**打印官方命令**让你手工执行，而不是失败。

---

## token 的两种落盘方式

默认用**环境变量间接引用**，配置文件里不出现明文 token：

- kimi-code：专用字段 `bearerTokenEnvVar: "LAWS_SG_MCP_TOKEN"`
- codex：`--bearer-token-env-var LAWS_SG_MCP_TOKEN`
- cursor / generic / claude：`headers.Authorization = "Bearer ${LAWS_SG_MCP_TOKEN}"`
- vscode：`${input:laws-sg-mcp-token}`，首次使用时弹窗索取，token 根本不落文件

前提是 `LAWS_SG_MCP_TOKEN` 在 agent 进程的环境里 —— 所以要先跑 `env-install`，
且**从已 source 过 profile 的 shell 启动 agent**。

客户端不支持 env 展开时，加 `--token-inline` 写字面 token（脚本会警告明文风险）。
在 env 引用与明文之间来回切换是安全的：脚本会删掉另一种方式的残留键，不会留下明文。
用户自己加的字段（如 `startupTimeoutMs`、`enabledTools`）在合并写时会保留。

---

## kimi-code

两级配置，**项目级覆盖用户级**：

| 级别 | 路径 |
| --- | --- |
| 用户级 | `~/.kimi-code/mcp.json`（或 `$KIMI_CODE_HOME/mcp.json`） |
| 项目级 | `<工作目录>/.kimi-code/mcp.json` |

写入的条目：

```json
{
  "mcpServers": {
    "laws-sg": {
      "url": "https://laws.sg/api/mcp",
      "bearerTokenEnvVar": "LAWS_SG_MCP_TOKEN",
      "enabled": true
    }
  }
}
```

要点：

- 有 `url`、无 `transport` 即 HTTP server。
- **会话中途新增的 MCP server 不会注册到已开启的会话** → 必须重启 kimi-code 会话，
  然后用 `/mcp` 查看连接状态。也可以不用脚本，在 TUI 里跑 `/mcp-config` 交互式添加。
- 在不受信任的目录里，项目级 MCP server 需要先在 workspace trust 提示里确认。

可选：`configure --client kimi-code --allow-tools` 向 `~/.kimi-code/config.toml` 追加免审批规则：

```toml
[[permission.rules]]
decision = "allow"
pattern = "mcp__laws-sg__*"
```

⚠ **放行前注意**：15 个工具里有 14 个是只读检索，但 `report_issue` 是**写操作**
（服务端自述 `writes to public.correction_events`）。通配放行会连它一起放行，
等于允许 agent 向 laws.sg 提交数据纠错记录。要收紧就再加一条 deny：

```toml
[[permission.rules]]
decision = "deny"
pattern = "mcp__laws-sg__report_issue"
```

这条规则是 kimi-code 专属；其他 agent 有各自的权限机制，脚本不代劳。

---

## Claude Code / Claude CLI

```bash
export LAWS_SG_MCP_TOKEN=laws_sg_REPLACE_WITH_YOUR_TOKEN
claude mcp add --transport http laws-sg https://laws.sg/api/mcp \
  --header "Authorization: Bearer ${LAWS_SG_MCP_TOKEN}"
```

官方说明：「Adds the remote server with an Authorization header — works in Claude Code and the Claude CLI.」

脚本执行时会按 `--scope` 追加 `-s user` / `-s project`；若 `laws-sg` 条目已存在则**跳过**，
加 `--force` 才覆盖（先 remove 再 add）。

---

## Codex CLI

```bash
export LAWS_SG_MCP_TOKEN=laws_sg_REPLACE_WITH_YOUR_TOKEN
codex mcp add laws-sg --url https://laws.sg/api/mcp --bearer-token-env-var LAWS_SG_MCP_TOKEN
```

官方说明：「An environment-backed bearer token keeps the token out of the config file.」
条目已存在时 `codex mcp add` 会失败，需先 `codex mcp remove laws-sg`。

---

## Cursor

`~/.cursor/mcp.json`（项目级 `./.cursor/mcp.json`）：

```json
{
  "mcpServers": {
    "laws-sg": {
      "type": "streamable-http",
      "url": "https://laws.sg/api/mcp",
      "headers": { "Authorization": "Bearer ${LAWS_SG_MCP_TOKEN}" }
    }
  }
}
```

官方注记：保留 `${LAWS_SG_MCP_TOKEN}` 引用并在环境里 export，或直接替换为 token 本身（`--token-inline`）。

---

## VS Code

`.vscode/mcp.json`。VS Code 首次使用时弹窗索取 token，token 不落文件：

```json
{
  "inputs": [
    {
      "type": "promptString",
      "id": "laws-sg-mcp-token",
      "description": "laws.sg MCP token",
      "password": true
    }
  ],
  "servers": {
    "laws-sg": {
      "type": "http",
      "url": "https://laws.sg/api/mcp",
      "headers": { "Authorization": "Bearer ${input:laws-sg-mcp-token}" }
    }
  }
}
```

注意根键是 `servers`（不是 `mcpServers`），脚本已按此处理；
`inputs` 数组按 `id` 去重追加，不会覆盖你已有的 input。

---

## 任意其他客户端

```bash
python3 scripts/laws_sg_mcp.py snippet --client json     # 通用 streamable-http 片段
python3 scripts/laws_sg_mcp.py snippet --client all      # 全部客户端的片段一次打印
python3 scripts/laws_sg_mcp.py configure --client generic --path <你的配置文件>
```

通用片段：

```json
{
  "mcpServers": {
    "laws-sg": {
      "type": "streamable-http",
      "url": "https://laws.sg/api/mcp",
      "headers": { "Authorization": "Bearer laws_sg_REPLACE_WITH_YOUR_TOKEN" }
    }
  }
}
```

接入任何 agent 只需要三件事：**streamable HTTP 传输**、**静态 bearer header**、**端点 URL**。
据此改写成目标 agent 自己的格式即可 —— 常见差异只在根键名（`mcpServers` / `servers` / `mcp_servers`）
和 `type` 字段的取值（`streamable-http` / `http` / `url` 有无）。

**注意**：该端点不提供 OAuth 发现（`.well-known/*` 全 404），
所以客户端的「浏览器授权登录」按钮对它无效，只能用个人 token。

---

## 连上之后可以怎么问

站点建议的提问方式（点名法规、要求引用原文）：

- 「What does the Employment Act say about overtime pay? Cite the exact provisions.」
- 「Under the PDPA, when can an organisation disclose personal data without consent?」
- 「Summarise a director's duties under the Companies Act, with section citations.」
- 「Is the Misuse of Drugs Act provision on presumptions still in force? Quote it.」

实测的推荐调用顺序：`resolve_work`（点名法规时先用它）→ `get_work_context` → `read_provisions`。
工具清单与参数签名见 `references/api.md`。

站点自我声明的局限（转述给用户时有用）：

- 不是法律意见，不知道你的具体事实。
- 语料不完整：工具报「不在库里」只代表「这里没有」，**不代表该法规不存在**。
- 生效状态与修法历史由记录的关系推导；依赖 in-force 日期前请核对 Singapore Statutes Online。
- 语料规模（站点首页数字）：22,335 部法律与判决，2,170,061 条可引用条文，覆盖 1835–2026。
