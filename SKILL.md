---
name: laws-sg-mcp
description: 配置 laws.sg（新加坡法律法规与判例库）官方 MCP 服务——自动登录或注册账号、签发个人 bearer token、探测并写入本机 MCP 客户端配置、做真握手验证；自动路径失败时降级为浏览器引导
type: prompt
whenToUse: 用户想接入 laws.sg MCP、已有配置连不上、token 失效需重签，或需要让 agent 检索新加坡法律（Act / Bill / 附属立法 / 判决 / Hansard）并给出可核对的条文引用时
arguments:
  - action
---

# laws.sg MCP 接入

把 laws.sg 的官方 MCP 服务接到**当前 agent** 上。站点免费，但**必须先有账号、再签发个人 token**；
端点只认 bearer token（不提供 OAuth 发现，客户端的「浏览器授权登录」对它无效）。

**本 Skill 不绑定任何特定 agent。** `configure` 默认探测本机装了哪些 MCP 客户端并逐个写入；
探测不到或客户端不在支持列表里，就输出通用片段让 agent/用户自行接入 —— 脚本不猜任何格式。

人工步骤：理想 0 步（已有可用 token），最坏 2 步（浏览器创建 token + 粘贴一次）。

**所有脚本路径都相对本 SKILL.md 所在目录**，下文写作 `python3 scripts/laws_sg_mcp.py`。
引擎是单文件纯 Python 脚本，只依赖 **Python 3 标准库**，不需要 curl、jq、npm、pip；
Windows / macOS / Linux 通用（Windows 上把 `python3` 换成 `python`，脚本用法不变）。

请求参数：`$action`（可选，如 `setup` / `verify` / `reissue` / `doctor`）；未给则按下面的判断树自行决定。

---

## 先判断走哪条路

```
1. 环境里已有 LAWS_SG_MCP_TOKEN？
   └─ 跑 python3 scripts/laws_sg_mcp.py verify
      ├─ 通过 → 跳到「只补配置」，几乎零人工
      └─ 被拒（401）→ 需要重新签发
2. 用户愿意提供 laws.sg 的邮箱+密码吗？
   ├─ 愿意 → 全自动路径（下面 A）
   └─ 不愿意 / 是 Google 登录的账号 / 自动路径报 FALLBACK → 半自动路径（下面 B）
```

任何时候脚本以**退出码 2** 结束、或 stderr 出现 `FALLBACK: manual`，立刻切到 B，不要在 A 上反复重试。

---

## A. 全自动路径

一条命令跑完 doctor → 登录/注册 → 签发 token → 写 shell profile → 探测并写入客户端配置 → 真握手验证：

```bash
python3 scripts/laws_sg_mcp.py setup
```

`setup` 默认 `--client auto`：只写**探测到已安装**的客户端，不会为没装的工具乱建配置文件。

凭据取值优先级：`--email/--password` 参数 → 环境变量 `LAWS_SG_EMAIL`/`LAWS_SG_PASSWORD` → 交互式提示（密码不回显）。

**代理执行时优先用环境变量传密码，不要写进命令行**（会进 shell 历史）：

```bash
LAWS_SG_EMAIL=user@example.com LAWS_SG_PASSWORD="$(cat /path/to/pwfile)" \
  python3 scripts/laws_sg_mcp.py setup
```

行为要点：

- 已有 token 且验证通过 → **直接复用，跳过登录与签发**（token 明文只显示一次，复用优先于新建）
- `--mode auto`（默认）先试登录，失败再注册；也可显式 `--mode login` / `--mode signup`
  （站点登录失败统一回 `Invalid email or password`，不区分「没注册」和「密码错」，所以只能这样试）
- 注册时 `name` 自动取邮箱前缀，无需向用户追问
- token 名建议 `agent@<hostname>` 这类可辨识名字（3..80 字符），便于日后吊销
- 结束后会提示：**必须重启 agent**，多数 agent 只在会话启动时加载 MCP 配置

### 指定 / 查看客户端

```bash
python3 scripts/laws_sg_mcp.py clients                    # 只探测：装了哪些、配置在哪、是否已配置
python3 scripts/laws_sg_mcp.py configure                  # 等价于 --client auto
python3 scripts/laws_sg_mcp.py configure --client all     # 支持列表里的全都写
python3 scripts/laws_sg_mcp.py configure --client cursor,vscode
python3 scripts/laws_sg_mcp.py configure --client kimi-code --allow-tools   # kimi-code 专属：免审批放行
```

可写入的客户端：`kimi-code` `claude` `codex` `cursor` `vscode` `generic`
（`claude`/`codex` 走各自官方 CLI；其余走 JSON 合并写）。
**列表外的 agent 一律用 `snippet` 取通用片段自行接入。**

默认 token 通过环境变量 `LAWS_SG_MCP_TOKEN` 间接引用，配置文件里不落明文；
客户端不支持 env 展开时加 `--token-inline`（会明文落盘，脚本会警告）。

### 只补配置（token 已就绪）

```bash
python3 scripts/laws_sg_mcp.py verify                                   # 确认真的能握手
python3 scripts/laws_sg_mcp.py env-install --token "$LAWS_SG_MCP_TOKEN"  # 写入 shell profile（Windows：setx 用户环境变量，新开终端生效）
python3 scripts/laws_sg_mcp.py configure                                # 探测并写入客户端
```

### 重新签发 / 吊销

```bash
python3 scripts/laws_sg_mcp.py token list                    # 现有 token 的有效性与 id
python3 scripts/laws_sg_mcp.py token revoke <id>
python3 scripts/laws_sg_mcp.py token create --name "agent@new" [--expires 2027-12-31]
python3 scripts/laws_sg_mcp.py token ensure --name "agent@$(hostname -s)"   # 幂等
```

### 分步执行（排障时更好定位）

```bash
python3 scripts/laws_sg_mcp.py doctor
python3 scripts/laws_sg_mcp.py login  --email E --password P     # 或 signup
python3 scripts/laws_sg_mcp.py token ensure --name "agent@$(hostname -s)"
python3 scripts/laws_sg_mcp.py env-install
python3 scripts/laws_sg_mcp.py configure
python3 scripts/laws_sg_mcp.py verify
```

---

## B. 半自动降级路径

```bash
python3 scripts/laws_sg_mcp.py manual --open     # 打印步骤并在浏览器打开 /account#mcp
```

请用户完成两件事：

1. 浏览器登录（邮箱密码或「Continue with Google」）→ 填 Token name（3..80 字符）→
   Expiry 可留空 → 创建 → **立刻复制** `laws_sg_` 开头的 token（页面只显示一次，之后无法找回）
2. 把 token 交回来

拿到 token 后，验证与配置仍全自动：

```bash
python3 scripts/laws_sg_mcp.py verify   laws_sg_xxxx
python3 scripts/laws_sg_mcp.py env-install --token laws_sg_xxxx
python3 scripts/laws_sg_mcp.py configure
```

---

## 交付前必须确认

1. `verify` 输出里 `initialize` 成功、并列出真实工具名 —— 这是唯一的连通性证据，不要跳过。
   （已实测：serverInfo 为 `Aturio Datahub 3.2.0`，protocolVersion `2025-06-18`，共 15 个工具。）
2. 明确告诉用户：**重启 agent**，然后用该 agent 自己的方式确认 `laws-sg` 已连接
   （kimi-code 用 `/mcp`；其他客户端看各自的 MCP 面板/日志）。
3. token 落地位置说清楚：`LAWS_SG_MCP_TOKEN` 写在 shell profile 的托管块里，
   客户端配置默认只用环境变量引用，**没有明文 token**（除非用了 `--token-inline`）。
4. 报告实际写了哪些客户端（`configure` 会打印「已配置：…」），没写的那些要把 snippet 给用户。
5. 如果用户要免审批放行工具，提醒一句：15 个工具里 `report_issue` 是**写操作**
   （向 laws.sg 提交数据纠错记录），通配放行会连它一起放行，建议单独 deny。

---

## 参考资料（按需读，别一次性全加载）

| 文件 | 什么时候读 |
| --- | --- |
| `references/troubleshooting.md` | 任何失败、401/403/429、`Session not found`、客户端里看不到 server、需要判断是否该降级时。**优先读这份** |
| `references/api.md` | 脚本报契约类错误、需要手工调接口、需要工具参数签名、或怀疑站点改版时 |
| `references/clients.md` | 要接支持列表之外的 agent、或用户问「配置该写哪、字段什么意思」时 |

---

## 约束（务必遵守）

- **不要用 HTTP 抓取 laws.sg 的法律语料。** 语料一律通过 MCP 工具获取。
  站点条款（§05 Acceptable use）禁止把站点打到影响他人、禁止绕过限流或访问控制、
  批量自动采集需事先获得同意，并明确要求「在合适场景使用 MCP 端点」。
- **不要调低脚本的节流阈值**（`LAWS_SG_THROTTLE`）来"加速"——站点限流很紧，
  实测约 6 次快速请求即 429；退避是合规要求，不是性能问题。
- **不要为没装的客户端创建配置文件。** 用 `--client auto`（默认）而不是 `all`。
- 密码默认不持久化、不回显、不入日志。只有用户显式要求 `--save-credentials` 才会明文写入
  shell profile，且脚本会当场警告。
- 本 Skill 自动化的是「用户本人账号的登录与 token 签发」，等价于站点自带 UI 的操作，
  单次流程总计个位数请求。

---

## 免责转述

laws.sg 自述：它不是官方发布者，而是对 Singapore Statutes Online（立法）与
eLitigation（判决）公开文本的免费再呈现；不提供法律意见；语料不完整时工具会报「不在库里」，
那只代表「这里没有」而**不代表该法规不存在**；生效日期与修法历史依赖前请核对
Singapore Statutes Online。每个工具响应都自带 disclaimer，转述给用户时应保留这层意思。
