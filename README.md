# laws-sg-mcp-skill

[laws.sg](https://laws.sg) 是新加坡法律法规与判例的免费查询库（Act / Bill / 附属立法 / 判决 / Hansard），官方提供 MCP 服务供 agent 检索。但接入有个门槛：**必须先注册账号、再登录签发个人 bearer token**，端点不提供 OAuth 发现，各客户端的「浏览器授权登录」对它无效——这一步通常要人在浏览器里点好几下。

本仓库是一个 **agent 无关的 Skill**，把这段接入流程压缩到：

- 理想情况 **0 步人工**（一条命令全自动跑完）
- 最坏情况 **2 步人工**（浏览器里创建 token + 粘贴一次）

## 它能做什么

- 自动登录 / 注册 laws.sg 账号（邮箱密码通道，Better Auth 接口）
- 自动签发、复用、吊销个人 MCP token（幂等）
- 探测本机装了哪些 MCP 客户端，逐个写入配置（**不为没装的客户端建文件**）
- 真握手验证（`initialize` + `tools/list`），失败给出可操作的排障指引
- 自动路径走不通时，降级为浏览器引导 + 片段输出的半自动模式

## 仓库结构

```
SKILL.md                    # Skill 主入口：判断树 + 全/半自动两条路径
scripts/laws_sg_mcp.sh      # 配置引擎（仅依赖 bash / curl / python3）
references/
  api.md                    # laws.sg 认证与 token 接口的实测文档
  clients.md                # 各客户端配置文件位置与字段说明
  troubleshooting.md        # 401/403/429、Session not found 等排障手册
```

## 快速开始

**给 agent 用**：把本目录作为 skill 加载（或直接把 `SKILL.md` 的内容交给 agent），agent 会按里面的判断树执行。

**给人用**：直接跑脚本也行——

```bash
# 全自动：doctor → 登录/注册 → 签发 → 写配置 → 验证
LAWS_SG_EMAIL=you@example.com LAWS_SG_PASSWORD=... \
  scripts/laws_sg_mcp.sh setup

# 或者分步 / 半自动
scripts/laws_sg_mcp.sh manual --open     # 浏览器引导创建 token
scripts/laws_sg_mcp.sh clients           # 探测本机装了哪些 MCP 客户端
scripts/laws_sg_mcp.sh verify            # 真握手验证
scripts/laws_sg_mcp.sh --help            # 完整命令列表
```

跑完后**重启你的 agent**——大多数 agent 只在会话启动时加载 MCP 配置。

## 支持的客户端

| 客户端 | 写入方式 |
| --- | --- |
| kimi-code / cursor / vscode / generic | JSON 合并写（保留已有配置） |
| claude / codex | 调用各自官方 CLI，CLI 缺失时打印命令降级 |
| 其他 agent | `snippet` 输出通用配置片段，自行接入 |

`configure --client auto`（默认）只写探测到已安装的客户端。

## 安全设计

- token 默认以环境变量 `LAWS_SG_MCP_TOKEN` **引用**进配置，不落明文；`--token-inline` 才会写字面值（且有警告）
- 密码不持久化、不回显、不入日志
- 写配置前自动备份；cookie jar 与配置文件均为 0600
- 严格节流（默认每次 API 调用间隔 1.5s，429/5xx 指数退避）——站点限流很紧，这是合规要求不是性能问题

## 合规边界

- 本 Skill 只自动化「用户本人账号的登录与 token 签发」，等价于站点自带 UI 的操作
- **不抓取法律语料**——语料一律通过官方 MCP 工具获取（站点条款亦如此要求）

## 免责

laws.sg 自述并非官方发布者，而是对 Singapore Statutes Online（立法）与 eLitigation（判决）公开文本的免费再呈现，不提供法律意见；工具报「不在库里」不代表该法规不存在，关键事项请核对官方来源。
