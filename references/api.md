# laws.sg 接口契约（实测）

本文记录 2026-09-16 对 laws.sg 的实测结果，供任何 agent 直接使用，**不要重新逆向**。
标注 `[实测]` 的是发过真实请求验证的；标注 `[前端源码]` 的是从站点 JS chunk 反编译得到的调用方式；标注 `[推断]` 的尚未端到端验证。

站点信息：Next.js（Turbopack）+ Cloudflare，构建标识响应头 `x-reader-build: sg-7ec5f59725e929a9`。
账号体系为 **Better Auth**，`basePath: /api/auth`（来自 chunk `0ti94x_ivem5r.js` 的 `createAuthClient({basePath:"/api/auth"})`）。

---

## 1. MCP 端点

| 项 | 值 | 来源 |
| --- | --- | --- |
| URL | `https://laws.sg/api/mcp` | [实测] |
| Transport | Streamable HTTP | 官方 /legal-ai 页 |
| 鉴权 | `Authorization: Bearer laws_sg_...` | [实测] |
| serverName | `laws-sg` | [前端源码] region config |
| token 前缀 | `laws_sg` | [前端源码] |
| token 环境变量名 | `LAWS_SG_MCP_TOKEN` | [前端源码] |
| 可选用户头 | `x-laws-sg-user-id` | [前端源码]，MCP 鉴权**不需要** |

未带 token 或 token 无效时 [实测]：

```
HTTP/2 401
content-type: text/plain;charset=UTF-8
www-authenticate: Bearer realm="laws.sg MCP"

Missing or invalid laws.sg MCP token.
```

这组固定响应可作为**负向断言**：拿到它说明端点正常、只是缺凭据。

**不支持 OAuth 发现** [实测]：`/.well-known/oauth-protected-resource`、`/.well-known/oauth-authorization-server`、`/api/mcp/.well-known/oauth-protected-resource` 全部 404（落到 Next.js 的 HTML 404 页）。
→ 客户端自带的浏览器 OAuth 授权（如 kimi-code 的 `/mcp-config login <server>`）**用不上**，只能走个人 bearer token。

### 握手流程 [全部实测]

服务端身份：`initialize` 返回 `serverInfo = {"name":"Aturio Datahub","version":"3.2.0"}`，
协商出的 `protocolVersion = 2025-06-18`。（后端与 CSP 里的 `arturio-api.cancode.codes` 对应。）

```
POST /api/mcp   Authorization: Bearer <token>
                Content-Type: application/json
                Accept: application/json, text/event-stream
  {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
     "protocolVersion":"2025-06-18","capabilities":{},
     "clientInfo":{"name":"...","version":"..."}}}
→ HTTP 200, content-type: text/event-stream
  响应头带 Mcp-Session-Id: <32 位 hex>
  body 是 SSE 帧：
     event: message
     data: {"jsonrpc":"2.0","id":1,"result":{...}}
```

后续每个请求都必须带 `Mcp-Session-Id`，并且：

```
POST notifications/initialized  → HTTP 202, content-type: application/json, 空 body
POST tools/list | tools/call    → HTTP 200, content-type: text/event-stream（SSE 帧）
```

**最关键的坑：initialize 之后的请求必须回带 `MCP-Protocol-Version: <协商版本>` 头。**

| 是否带该头 | 实测结果 |
| --- | --- |
| 不带 | 约 2/3 概率回 `{"code":-32600,"message":"Session not found"}`（即便 `Mcp-Session-Id` 完全正确） |
| 带 `MCP-Protocol-Version: 2025-06-18` | 7/7 成功 |

带了之后仍有约 1/10 的残留抖动，所以客户端**必须**能在 `Session not found` 时重做整段
`initialize` 握手再重试，而不是把它当成 token 失效。
（`verify` 子命令内置了最多 4 次的整段握手重试。）

另外实测：`tools/call` **强制要求** `Mcp-Session-Id`，缺失直接回
`{"code":-32600,"message":"Bad Request: Missing session ID"}`。
响应体一律要按「可能是纯 JSON、也可能是 SSE 帧」两种情况解析。

### 工具清单 [实测，15 个]

```
list_jurisdictions    列出可用法域
search_legal          单一法域内的全文检索
resolve_work          用户点名某部法律/判例时的入口（服务端自述 START HERE）
get_court_decision    按中性引用 / decision id / slug / FRBR URI 取判决
get_treatment_history 该判决是否仍是有效先例（后续法院/立法如何对待它）
get_citation_graph    判决或法律的引用边
get_work              按 FRBR URI 或 slug 取 work（抽象法规）
get_expression        取某个语言/版本的 expression
get_work_context      取已解析 work 的精简上下文
get_nodes             取 expression 的文档节点（按 sort_order 分页）
read_provisions       按 selector 读条文
find_citations        查某部 work 的引用
list_regulation_types 列法域的法规类型码
list_issuing_bodies   列发布机关（政府机构）
report_issue          提交数据质量报告 —— ⚠ 这是**写操作**（写入 public.correction_events）
```

⚠ `report_issue` 是 15 个工具里唯一的写操作。给 agent 配权限时应注意：
用 `mcp__laws-sg__*` 通配放行会连它一起放行，等于允许 agent 向 laws.sg 提交数据纠错记录。
要收紧就单独 deny 掉 `mcp__laws-sg__report_issue`。

### 工具参数签名的坑 [实测]

参数名不能靠猜，服务端是 FastMCP + pydantic，猜错会返回详细的校验错误：

| 工具 | 正确参数 | 常见误猜 |
| --- | --- | --- |
| `resolve_work` | `jurisdiction`, **`reference`** | ~~`query`~~ |
| `search_legal` | `jurisdiction`, **`q`** | ~~`query`~~ |
| `read_provisions` | `jurisdiction`, `slug`, **`selector="section 38"`** | ~~`selector="38"`~~ |

`read_provisions` 的 selector 接受：`all`、`section 15`、`section 15-20`、`First Schedule`。
写错时服务端会返回带 `recovery` 字段的错误，里面有 `suggestion`、`example_call`、`valid_values`，
直接照着改即可 —— 正规 MCP 客户端会从 `tools/list` 的 `inputSchema` 拿到签名，
只有裸调 HTTP 时才需要记这些。

### 实测返回样例

`resolve_work(jurisdiction="sg", reference="Employment Act 1968")`：

```json
{"resolved":true,"confidence":"medium","method":"typesense_title","kind":"work",
 "work":{"slug":"act-1968-ema","seo_slug":"employment-act-1968",
         "frbr_work_uri":"/akn/sg/act/act/1968/EmA","title":"Employment Act 1968",
         "regulation_type":"ACT","number":"EmA","year":1968,"status":"in_force",
         "work_kind":"legislation","jurisdiction_code":"sg"},
 "next_steps":["get_work_context(jurisdiction='sg', slug='act-1968-ema', detail='summary')",
               "read_provisions(jurisdiction='sg', slug='act-1968-ema', selector='all')"],
 "disclaimer":"This data is provided for informational purposes only and does not constitute legal advice. Always verify with official jurisdiction sources."}
```

`read_provisions(jurisdiction="sg", slug="act-1968-ema", selector="section 38")` 取到的真实条文：

> —(1) Except as hereinafter provided, an employee must not be required under his or her
> contract of service to work —(a) more than 6 consecutive hours without a period of leisure;
> (b) **more than 8 hours in one day or more than 44 hours in one week** …

返回里带 `edition_label: "rev_ed_2020"`（2020 修订版）、`language: "en"`、`node_path`、
以及每条响应都有的 `disclaimer` 与 `request_id`。
→ 每个工具响应都自带「非法律意见、请核对官方来源」的免责声明，转述给用户时应保留这层意思。

---

## 2. 认证接口（Better Auth）

所有请求都要带 `Origin: https://laws.sg`（浏览器行为；Better Auth 会做 trustedOrigins 校验）。

| 用途 | 请求 | 状态 |
| --- | --- | --- |
| 登录 | `POST /api/auth/sign-in/email` body `{"email","password"}` | [实测端点存在]：空 body 返回 400 `{"code":"VALIDATION_ERROR","message":"[body.email] Invalid input: expected string, received undefined; [body.password] ..."}` |
| 注册 | `POST /api/auth/sign-up/email` body `{"name","email","password"}` | [实测端点存在]：空 body 返回 400，缺 `name`/`email`/`password` 三项 |
| 查会话 | `GET /api/auth/get-session` | [实测]：未登录返回字面量 `null` + HTTP 200 |
| 登出 | `POST /api/auth/sign-out` | [前端源码] |
| Google 登录 | `POST /api/auth/sign-in/social` body `{"provider":"google","callbackURL","errorCallbackURL":"/login"}` | [前端源码]，需浏览器，**无法 headless 自动化** |

前端实际调用（chunk `01euqwsnmcj4j.js`）：

```js
// 登录，注意带 rememberMe
authClient.signIn.email({ email, password, rememberMe: true })
// 注册，name 缺省用邮箱前缀，再退到 "laws.sg user"
authClient.signUp.email({
  name: nameInput.trim() || email.split("@")[0] || "laws.sg user",
  email, password
})
```

约束与行为：

- 密码前端 `minLength: 8`（`<input type="password" minLength="8" required>`）。服务端阈值未实测，按 ≥8 处理。
- `name` 是**必填**字段，但可自动派生（邮箱前缀），无需人工输入。
- 注册成功后前端直接 `router.push(redirect)`（默认 `/account`），中间没有邮箱验证页。
  **[实测确认] 无邮件验证门槛**：真实邮箱跑 `sign-up/email` → HTTP 200，紧接着
  `GET /api/auth/get-session` 就返回完整 user 对象，可直接签发 token，全程无需碰邮箱。
  脚本仍保留防御性检测（注册后 get-session 若为 `null` 则降级），以防站点日后加上验证。
- [实测] `name` 省略时前端用邮箱前缀（`someone@example.com` → `someone`），服务端接受。
- [实测] token 的 `id` 是 UUID；`expiresAt` 传 `null` 时列表显示为永不过期。
- Google-only 账号用邮箱密码登录会失败（Better Auth 报账号不存在/密码错误）→ 走人工降级。
- Cookie：region config 里 `auth.cookiePrefix = "laws-sg"`，readerGate cookie 实测为 `laws-sg-visited`。
  会话 cookie 名应为 `laws-sg.session_token` 或 HTTPS 下的 `__Secure-laws-sg.session_token`。
  **不要硬编码**：用 curl 的 cookie jar（`-b jar -c jar`）自动接管。
  jar 要 `chmod 600`（curl 按 umask 建，默认 0644），它等价于「已登录」凭据。

### 实测错误文案（用于分支判断）

| 场景 | HTTP | 文案 |
| --- | --- | --- |
| 邮箱格式非法 | 400 | `[body.email] Invalid email address` |
| 邮箱不存在**或**密码错 | 401 | `Invalid email or password` |
| 未登录访问 `/api/account/mcp-tokens` | 401 | `{"error":"Unauthorized"}` |
| 缺 `Origin` 头访问 `/api/account/*` | 403 | （空 body） |
| MCP 端点缺/错 token | 401 | `Missing or invalid laws.sg MCP token.` |

关键：401 的 `Invalid email or password` **不区分**「邮箱没注册过」和「密码打错」（防账号枚举）。
所以自动化流程无法先验判断该登录还是该注册，只能「先试登录 → 失败再试注册 → 注册报已存在则回头登录」，
脚本的 `setup --mode auto` 就是这个逻辑。

站点允许的本地 Origin（region config `auth.localOrigins`，仅开发环境用）：
`http://localhost:3002`、`http://127.0.0.1:3002`、`http://localhost:8787`、`http://127.0.0.1:8787`。

---

## 3. Token 签发接口

来自 `/account` 页面的 chunk `0nijlo2z2ytq4.js` [前端源码]，端点存在性已 [实测]。

### 创建

```
POST https://laws.sg/api/account/mcp-tokens
Content-Type: application/json
Origin: https://laws.sg          # 必需
Cookie: <better-auth 会话>

{"name": "<3..80 字符>", "expiresAt": "<ISO 8601>" | null}
```

成功响应：

```json
{"token": { "...": "元数据对象" }, "plainTextToken": "laws_sg_..."}
```

失败响应形如 `{"error":"Could not create token."}`（前端读的就是 `t.error`）。

实测状态码：

- `GET /api/account/mcp-tokens` 未登录 → **401**，`content-type: application/json`
- `POST /api/account/mcp-tokens` **不带 Origin** → **403**
- `POST` 带 `Origin: https://laws.sg` 但无会话 → **401** `{"error":"Unauthorized"}`

→ 403 与 401 的差别就是 Origin 头，这是最容易踩的坑。

### 字段细节

- `name`：前端 `<input minLength=3 maxLength=80 required>`，placeholder `Claude Desktop`，
  提示文案「Use a client or device name so it is easy to revoke later.」
  → 建议用 `kimi-code@<hostname>` 这类可辨识名字。
- `expiresAt`：前端构造方式，照抄即可（新加坡时区当日末尾）：
  ```js
  dateInput ? new Date(`${dateInput}T23:59:59.999+08:00`).toISOString() : null
  ```
  `null` = 永不过期。
- `plainTextToken` **只在创建响应里出现一次**，前端立刻展示并提示「Tokens are shown once」。
  → 无法事后找回；丢了只能重新签发。这是 `token ensure` 必须「先验证现有 token、通过就复用」的根本原因。

### 列表 / 吊销

```
GET    https://laws.sg/api/account/mcp-tokens          # [实测] 未登录 401
DELETE https://laws.sg/api/account/mcp-tokens/{id}     # [前端源码] encodeURIComponent(id)
```

token 元数据字段（从前端用法反推）：`id`、`expiresAt`、`revokedAt`，另有前端展示的 `name`、创建时间。

前端「有效 token」判定，直接沿用：

```js
!t.revokedAt && (!t.expiresAt || t.expiresAt > now)
```

---

## 4. 限流

[实测] 在几秒内连续发约 6 个请求即出现 `HTTP 429`（探测 `/login`、`/account`、`/api/mcp` 等路径时触发）。

脚本必须：

- 每次 API 调用前 `sleep 1.5`
- 429 / 5xx 指数退避（2s → 4s → 8s），最多 3 次
- 保持幂等，优先复用已签发的 token，不要反复创建

---

## 5. 合规边界

`https://laws.sg/terms`（Last updated 12 September 2026）§05 Acceptable use：

> Read, search, quote and link freely — that is what the site is for. What you may not do:
> Hit the site hard enough to degrade it for anyone else, or work around rate limits, access
> controls or the terms of a token issued to you. Automated bulk collection needs our agreement
> first; ask, and use the MCP endpoint where it fits.

因此本 Skill 的自我约束：

- 只调用 auth + token 两类接口，单次流程总计个位数请求
- **绝不**用 HTTP 抓取法律语料；语料一律通过 MCP 工具获取
- 严格退避，不以任何方式绕过限流或访问控制
- 自动化的范围仅限「用户本人账号的登录与 token 签发」，等价于站点自带 UI 的行为

---

## 6. 站点 region config 原文（关键字段）

来自页面内嵌 JSON（`/_next/static/chunks/0_.wxo0ae2-m5.js` 与 `/login` HTML）：

```json
"auth": {
  "cookiePrefix": "laws-sg",
  "localOrigins": ["http://localhost:3002", "http://127.0.0.1:3002",
                   "http://localhost:8787", "http://127.0.0.1:8787"],
  "defaultUserName": "laws.sg user"
},
"readerGate": { "enabled": true, "cookieName": "laws-sg-visited", "timeZone": "Asia/Singapore" },
"mcp": {
  "serverName": "laws-sg",
  "tokenPrefix": "laws_sg",
  "tokenEnvVar": "LAWS_SG_MCP_TOKEN",
  "tokenInputId": "laws-sg-mcp-token",
  "tokenDescription": "laws.sg MCP token",
  "userHeader": "x-laws-sg-user-id"
}
```

`readerGate.enabled = true`：未登录用户每天有阅读条数限制，登录后不限。这是用户愿意注册账号的附带好处，但不影响 MCP。
