# 故障排查与降级矩阵

脚本退出码：`0` 成功 / `1` 失败 / **`2` 需人工降级**（stderr 会打印 `FALLBACK: manual`）。
看到退出码 2 或 `FALLBACK: manual`，就切到本文最后一节的人工路径，不要在自动路径上反复重试。

---

## 什么时候必须降级（别再重试自动路径）

| 触发条件 | 为什么自动路径走不通 |
| --- | --- |
| 用户不愿把密码交给脚本 | 没有凭据就无法调 `/api/auth/sign-in/email` |
| 账号是 Google-only | 站点登录页有「Continue with Google」；这类账号没有密码，邮箱通道必然 401/400。OAuth 需浏览器，无法 headless 自动化 |
| 注册成功但 `get-session` 仍为 `null` | 说明站点开了邮箱验证门槛，需人工点邮件里的链接 |
| 持续 429 / 5xx（脚本已退避 3 次） | 限流或服务端故障，重试只会更糟 |
| 接口契约变了（404、未知校验错误、响应里没有 `plainTextToken`） | 本文档的契约是 2026-09-16 实测的，站点可能改版 |

---

## 症状对照表

### `HTTP 403` 且路径是 `/api/account/mcp-tokens`
**Origin 头缺失。** 实测：不带 `Origin: https://laws.sg` → 403；带上 → 401（无会话）或 200。
脚本对所有非 GET 请求都会发 `Origin` + `Referer`，正常不会遇到。若真遇到 403，说明脚本被改坏或站点改了校验规则。

### `HTTP 401 {"error":"Unauthorized"}`
会话无效或已过期。重新 `login`。注意 `get-session` 在未登录时返回的是**字面量 `null` + HTTP 200**，不是 401 —— 别把 200 当成已登录。

### `HTTP 400 {"code":"VALIDATION_ERROR","message":"[body.email] Invalid input: ..."}`
请求体字段名/类型不对。契约：
- `sign-in/email` 要 `{email, password}`
- `sign-up/email` 要 `{name, email, password}`，**`name` 必填**（脚本自动用邮箱前缀填充）

`message` 里会逐个列出缺失字段，照它改即可。

### `HTTP 429`
限流。实测约 6 次快速请求就会触发。脚本已内置：每次调用前 `sleep 1.5`，429/5xx 按 2s→4s→8s 退避、最多 3 次。
仍失败就停手等几分钟，**不要**调低 `LAWS_SG_THROTTLE`—— 站点条款明确禁止绕过限流。

### `token 被拒（HTTP 401）` 但你确认 token 是新的
按可能性排序：
1. 复制时缺字符或多空格（token 形如 `laws_sg_...`，很长）
2. token 已在 `/account#mcp` 被吊销
3. token 已过期（`expiresAt` 到期）
4. `LAWS_SG_MCP_TOKEN` 没导出到当前进程 —— 脚本读的是**进程环境变量**，
   写进 `~/.zshrc` 后必须 `source` 或开新 shell

用 `token list` 看该 token 的 `revokedAt` / `expiresAt` 即可确认 2、3。

### `{"code":-32600,"message":"Session not found"}`
**不是 token 失效，也不是服务端挂了 —— 是漏了 `MCP-Protocol-Version` 请求头。**

实测数据（同一个有效 token、`Mcp-Session-Id` 完全正确）：

| initialize 之后的请求是否带 `MCP-Protocol-Version: 2025-06-18` | 结果 |
| --- | --- |
| 不带 | 约 **2/3 概率**回 `Session not found` |
| 带 | **7/7 成功** |

带上之后仍有约 1/10 的残留抖动，所以正确做法是：**遇到 `Session not found` 就重做整段
`initialize` 握手再重试**，而不是重试单个请求、更不是重新签发 token。
脚本的 `verify` 已内置最多 4 次整段握手重试；实测 5/5 次都能拿到完整工具列表（其中 1 次用了重试）。

正规 MCP 客户端（kimi-code / Claude / Cursor）本来就按规范发这个头并自带重连，所以正常使用不受影响。
只有**裸调 HTTP**（curl、自写脚本）时才会踩到。

顺带：`tools/call` **强制要求** `Mcp-Session-Id`，缺失会回
`{"code":-32600,"message":"Bad Request: Missing session ID"}`。

### 工具调用报 `validation errors for call[...]`
参数名猜错了。服务端是 FastMCP + pydantic，错误信息会直接告诉你缺哪个、多哪个。已知签名：

| 工具 | 正确参数 |
| --- | --- |
| `resolve_work` | `jurisdiction`, **`reference`**（不是 `query`） |
| `search_legal` | `jurisdiction`, **`q`**（不是 `query`） |
| `read_provisions` | `jurisdiction`, `slug`, **`selector="section 38"`**（不是 `"38"`） |

`read_provisions` 的 selector 接受 `all` / `section 15` / `section 15-20` / `First Schedule`；
写错时返回体的 `recovery` 字段里有 `suggestion`、`example_call`、`valid_values`，照着改即可。
正规客户端从 `tools/list` 的 `inputSchema` 拿签名，不需要记这些。

### `Missing or invalid laws.sg MCP token.`
这是端点的**正常**未鉴权响应（HTTP 401 + `www-authenticate: Bearer realm="laws.sg MCP"`）。
`verify` 在没 token 时会主动拿它做负向断言，用来证明「端点活着，只是缺凭据」。看到它不等于出错。

### agent 里看不到 `laws-sg` / 连不上

按顺序排查（与具体 agent 无关）：

1. **重启 agent。** 多数 agent 只在会话启动时加载 MCP 配置，会话中途新增的 server 不会注册。
   （kimi-code 明确如此：重启会话后用 `/mcp` 查看；其他客户端看各自的 MCP 面板或日志。）
2. **agent 进程的环境里有 `LAWS_SG_MCP_TOKEN` 吗？**
   默认配置用的是环境变量引用，写进 `~/.zshrc` 后必须 `source` 或开新 shell，
   并且要**从那个 shell 启动 agent**。GUI 方式启动的 agent 可能读不到 shell profile，
   这种情况改用 `configure --token-inline`（明文落盘）或该客户端自己的密钥输入机制。
3. **写的是哪一级配置？** 项目级通常覆盖用户级。用 `scripts/laws_sg_mcp.sh clients`
   看每个客户端实际用的路径，用 `configure --scope user|project` 控制。
4. **条目被禁用了吗？** 脚本会强制 `enabled: true`，但你可能事后手改过。
5. **token 本身有效吗？** `scripts/laws_sg_mcp.sh verify` 是最快的判据 ——
   它能握手成功就说明 token 和端点都没问题，故障在客户端侧。
6. **不受信任的工作目录**：部分 agent（含 kimi-code）在 untrusted 目录里不加载项目级 MCP server，
   需要先在 workspace trust 提示里确认。

### `configure` 报「不是合法 JSON，已放弃写入」
你的 `mcp.json` 本来就是坏的（多余逗号、注释、尾随字符）。脚本刻意**不**覆盖它，避免毁掉现有配置。
手工修好后重试，或先 `configure --dry-run` 看预期结果。

---

## 手工核对接口（不依赖脚本）

```bash
# 1. 端点活着吗？预期 401 + 固定文案
curl -i https://laws.sg/api/mcp -H 'Accept: application/json, text/event-stream'

# 2. 会话有效吗？预期返回 JSON 用户对象；未登录返回字面量 null
curl -s https://laws.sg/api/auth/get-session -b <cookiejar>

# 3. 签发 token（注意 Origin 必需）
curl -s -X POST https://laws.sg/api/account/mcp-tokens \
  -H 'Content-Type: application/json' \
  -H 'Origin: https://laws.sg' \
  -b <cookiejar> \
  --data '{"name":"agent@myhost","expiresAt":null}'
# → {"token":{...},"plainTextToken":"laws_sg_..."}   plainTextToken 只出现这一次

# 4. 真握手验证 token
curl -s -X POST https://laws.sg/api/mcp \
  -H "Authorization: Bearer $LAWS_SG_MCP_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

---

## 人工降级路径（等价于 `manual --open`）

人工只做两件事，其余仍由脚本完成：

1. 浏览器打开 <https://laws.sg/account#mcp>
   - 登录：邮箱密码，或「Continue with Google」
   - **Token name**：3..80 字符，建议填客户端/设备名（站点提示「便于日后吊销」）
   - **Expiry**：可留空 = 永不过期
   - 创建后**立刻复制** `laws_sg_` 开头的 token —— 页面只显示一次
2. 把 token 交给脚本，剩下的验证、写 profile、写 mcp.json 全自动：

```bash
scripts/laws_sg_mcp.sh verify   laws_sg_xxxx
scripts/laws_sg_mcp.sh env-install --token laws_sg_xxxx
scripts/laws_sg_mcp.sh configure            # 默认 --client auto，探测本机装了哪些客户端
scripts/laws_sg_mcp.sh clients              # 复核：每个客户端的配置路径与是否已配置
```

然后重启你的 agent，用它自己的方式确认 `laws-sg` 已连接（kimi-code 用 `/mcp`）。
没被自动写入的客户端，用 `snippet --client all` 取片段手工接入。

---

## 安全注意

- **`plainTextToken` 只在创建响应里出现一次**，站点不再展示、也无法找回。丢了只能重新签发一个
  （旧的可以 `token revoke` 掉）。所以 `token ensure` 的语义是「现有 token 验证通过就复用」，
  绝不无脑新建。
- 密码默认**不持久化**，也不回显、不入日志。只有显式传 `--save-credentials` 才会把
  `LAWS_SG_EMAIL` / `LAWS_SG_PASSWORD` 明文写进 shell profile，脚本会当场警告。
- 会话 cookie jar 存在 `~/.config/laws-sg/cookies.txt`（0600）。它等价于「已登录」，
  用完可删；`setup` 流程结束不需要保留。
- 写 `mcp.json` 与 shell profile 前都会备份（`*.bak.<时间戳>`）。
