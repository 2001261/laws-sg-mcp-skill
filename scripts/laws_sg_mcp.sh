#!/usr/bin/env bash
# laws.sg MCP 配置引擎
#
# 把「登录/注册 laws.sg → 签发 MCP token → 写入客户端配置 → 验证连通」串成可脚本化流程。
# 接口契约见 ../references/api.md（均为实测或从站点前端源码反编译所得）。
#
# 依赖：bash 3.2+ / curl / python3（macOS 自带；不需要 jq、npm、pip）
#
# 合规自我约束：只调用 auth + token 接口，单次流程个位数请求；严格节流退避；
# 绝不抓取法律语料（语料一律走 MCP）。见 laws.sg/terms §05 Acceptable use。

set -uo pipefail

# ---------------------------------------------------------------- 常量

BASE_URL="https://laws.sg"
MCP_URL="${BASE_URL}/api/mcp"
ACCOUNT_PAGE="${BASE_URL}/account#mcp"
SERVER_NAME="laws-sg"
TOKEN_ENV_VAR="LAWS_SG_MCP_TOKEN"
TOKEN_PREFIX="laws_sg"
TOKEN_INPUT_ID="laws-sg-mcp-token"
TOKEN_DESCRIPTION="laws.sg MCP token"
UA="laws-sg-mcp-skill/1.0 (+local setup script)"
THROTTLE="${LAWS_SG_THROTTLE:-1.5}"   # 站点限流很紧：实测约 6 次快速请求即 429
SKILL_VERSION="1.0.0"

STATE_DIR="${LAWS_SG_STATE_DIR:-${HOME}/.config/laws-sg}"
COOKIE_JAR="${LAWS_SG_COOKIE_JAR:-${STATE_DIR}/cookies.txt}"

JSON_OUT=0
VERBOSE=0
TMPD=""
RESP_BODY=""
RESP_HDR=""
RESP_ERR=""
RESP_STATUS="000"
RESULT_TOKEN=""     # token create/ensure 的结果，走全局而非 stdout（避免与 --json 抢 stdout）
MCP_PV=""           # initialize 协商出的协议版本；后续请求必须回带，否则服务端会报 Session not found

# ---------------------------------------------------------------- 输出

_c() { if [ -t 2 ]; then printf '\033[%sm' "$1"; fi; }
info()  { printf '%s\n' "$*" >&2; }
warn()  { printf '%s[warn]%s %s\n' "$(_c '0;33')" "$(_c 0)" "$*" >&2; }
error() { printf '%s[error]%s %s\n' "$(_c '0;31')" "$(_c 0)" "$*" >&2; }
die()   { error "$*"; exit 1; }
verbose() { if [ "$VERBOSE" -eq 1 ]; then info "  · $*"; fi; }

# 降级信号：调用方（SKILL.md / agent）依据 stderr 里的这一行切换到半自动流程
# FATAL_FALLBACK=0 时只返回 2 而不退出整个脚本，供 setup 内部做「登录失败→改注册」的尝试
FATAL_FALLBACK=1
fallback() {
  printf 'FALLBACK: manual\n' >&2
  error "$*"
  error "改走人工路径：浏览器打开 ${ACCOUNT_PAGE} 创建 token，再用 verify / env-install / configure 收尾。"
  error "（或执行：$0 manual --open）"
  if [ "$FATAL_FALLBACK" -eq 1 ]; then exit 2; fi
  return 2
}

jout() { if [ "$JSON_OUT" -eq 1 ]; then printf '%s\n' "$1"; fi; }

json_str_array() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1:]))' "$@"; }

# ---------------------------------------------------------------- 前置

need() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"; }

ensure_tmp() {
  if [ -z "$TMPD" ]; then
    TMPD="$(mktemp -d "${TMPDIR:-/tmp}/laws-sg-mcp.XXXXXX")" || die "无法创建临时目录"
    chmod 700 "$TMPD" 2>/dev/null || true
    RESP_BODY="${TMPD}/body"; RESP_HDR="${TMPD}/headers"; RESP_ERR="${TMPD}/curlerr"
    : >"$RESP_BODY"; : >"$RESP_HDR"; : >"$RESP_ERR"
    trap 'rm -rf "$TMPD"' EXIT
  fi
}

mkdir_state() {
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" || die "无法创建 ${STATE_DIR}"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  # curl 默认按 umask 建 cookie jar（0644）；里面可能存会话凭据，收紧到 0600
  if [ ! -e "$COOKIE_JAR" ]; then
    : >"$COOKIE_JAR" 2>/dev/null && chmod 600 "$COOKIE_JAR" 2>/dev/null
  fi
}

# ---------------------------------------------------------------- HTTP 层

# api METHOD PATH [BODY] [use_cookies:yes|no]
# 结果写入 RESP_STATUS / RESP_BODY / RESP_HDR。自带节流 + 429/5xx 退避重试。
api() {
  local method="$1" path="$2" body="${3:-}" cookies="${4:-no}"
  ensure_tmp
  local attempt=0 delay=2 status args
  : >"$RESP_BODY"; : >"$RESP_HDR"; : >"$RESP_ERR"
  [ "$cookies" = "yes" ] && mkdir_state

  while :; do
    sleep "$THROTTLE"
    args=(-sS -X "$method" -A "$UA" -m 40
          -H "Accept: application/json, text/event-stream"
          -o "$RESP_BODY" -D "$RESP_HDR" -w '%{http_code}')
    # 浏览器对同源的 mutating 请求会带 Origin；缺失时 /api/account/* 实测返回 403
    if [ "$method" != "GET" ]; then
      args+=(-H "Origin: ${BASE_URL}" -H "Referer: ${BASE_URL}/account")
    fi
    [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data-binary "$body")
    [ "$cookies" = "yes" ] && args+=(-b "$COOKIE_JAR" -c "$COOKIE_JAR")

    verbose "${method} ${path} (attempt $((attempt + 1)))"
    status="$(curl "${args[@]}" "${BASE_URL}${path}" 2>"$RESP_ERR")" || status="000"
    RESP_STATUS="$status"

    case "$status" in
      429|5[0-9][0-9])
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
          error "HTTP ${status}：重试 ${attempt} 次后仍失败 ${method} ${path}"
          [ -s "$RESP_ERR" ] && error "$(head -c 300 "$RESP_ERR")"
          return 1
        fi
        warn "HTTP ${status}，${delay}s 后重试（限流或服务端错误）"
        sleep "$delay"; delay=$((delay * 2))
        continue ;;
      000)
        error "网络请求失败：$(head -c 300 "$RESP_ERR")"
        return 1 ;;
    esac
    return 0
  done
}

resp_field() {  # 取顶层标量字段；取不到输出空
  python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: sys.exit(0)
if not isinstance(d,dict): sys.exit(0)
v=d.get(sys.argv[2])
if isinstance(v,bool): print("true" if v else "false")
elif isinstance(v,(str,int,float)): print(v)
' "$RESP_BODY" "$1" 2>/dev/null
}

resp_error() {
  local e m
  e="$(resp_field error)"; m="$(resp_field message)"
  if [ -n "$e" ]; then printf '%s\n' "$e"
  elif [ -n "$m" ]; then printf '%s\n' "$m"
  else head -c 300 "$RESP_BODY" 2>/dev/null; printf '\n'
  fi
}

# ---------------------------------------------------------------- MCP 握手

# mcp_post PAYLOAD [SESSION_ID] [TOKEN]
# 自带 429/5xx 退避；返回非 0 表示网络层失败
mcp_post() {
  local payload="$1" sid="${2:-}" token="${3:-}" args
  local attempt=0 delay=2
  ensure_tmp
  while :; do
    : >"$RESP_BODY"; : >"$RESP_HDR"; : >"$RESP_ERR"
    sleep "$THROTTLE"
    args=(-sS -X POST -A "$UA" -m 40
          -H "Content-Type: application/json"
          -H "Accept: application/json, text/event-stream"
          -o "$RESP_BODY" -D "$RESP_HDR" -w '%{http_code}')
    [ -n "$token" ] && args+=(-H "Authorization: Bearer ${token}")
    [ -n "$sid" ] && args+=(-H "Mcp-Session-Id: ${sid}")
    # 关键：initialize 之后的请求必须回带协商出的协议版本，否则服务端会话查找失败
    # （实测：不带该头约 2/3 概率回 {"code":-32600,"message":"Session not found"}；带上则稳定成功）
    [ -n "$MCP_PV" ] && args+=(-H "MCP-Protocol-Version: ${MCP_PV}")
    verbose "POST ${MCP_URL}"
    RESP_STATUS="$(curl "${args[@]}" --data-binary "$payload" "$MCP_URL" 2>"$RESP_ERR")" || RESP_STATUS="000"
    if [ "$RESP_STATUS" = "000" ]; then
      error "MCP 请求失败：$(head -c 300 "$RESP_ERR")"
      return 1
    fi
    case "$RESP_STATUS" in
      429|5[0-9][0-9])
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
          error "MCP 请求 HTTP ${RESP_STATUS}：重试 ${attempt} 次后仍失败"
          return 1
        fi
        warn "MCP HTTP ${RESP_STATUS}，${delay}s 后重试"
        sleep "$delay"; delay=$((delay * 2))
        continue ;;
    esac
    return 0
  done
}

# 大小写不敏感取响应头（BSD awk 无 IGNORECASE，手工 tolower）
hdr_get() {
  awk -v want="$1" '
    BEGIN { want = tolower(want) }
    { line = $0; sub(/\r$/, "", line)
      p = index(line, ":"); if (p == 0) next
      k = tolower(substr(line, 1, p - 1))
      if (k == want) { v = substr(line, p + 1); sub(/^[ \t]+/, "", v); print v; exit } }
  ' "$RESP_HDR" 2>/dev/null
}

# 响应体可能是纯 JSON，也可能是 SSE 帧；解出 JSON-RPC 消息（优先含 result/error 的）
mcp_message() {
  python3 - "$RESP_BODY" <<'PY'
import json,sys
raw=open(sys.argv[1],encoding="utf-8",errors="replace").read().strip()
if not raw: sys.exit(0)
cands=[raw] if raw[0] in "{[" else []
if not cands:
    for line in raw.splitlines():
        line=line.strip()
        if line.startswith("data:"):
            d=line[5:].strip()
            if d and d!="[DONE]": cands.append(d)
best=None
for c in cands:
    try: o=json.loads(c)
    except Exception: continue
    best=o
    if isinstance(o,dict) and ("result" in o or "error" in o): break
if best is not None: print(json.dumps(best,ensure_ascii=False))
PY
}

# 解析 initialize 结果 → "serverInfo<TAB>protocolVersion"
parse_init() {
  printf '%s' "$1" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
r=d.get("result") or {}
si=r.get("serverInfo") or {}
name=si.get("name") or "?"
ver=si.get("version") or ""
print(("%s %s"%(name,ver)).strip()+"\t"+(r.get("protocolVersion") or ""))
' 2>/dev/null
}

# 解析 tools/list → 首行是 name 的 JSON 数组，其后是人类可读行
parse_tools() {
  printf '%s' "$1" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception:
    print("[]"); print("  （无法解析 tools/list 响应）"); sys.exit(0)
if "error" in d:
    print("[]"); print("  （tools/list 报错：%s）"%json.dumps(d["error"],ensure_ascii=False)); sys.exit(0)
tools=((d.get("result") or {}).get("tools")) or []
print(json.dumps([t.get("name") for t in tools],ensure_ascii=False))
if not tools:
    print("  （服务端未返回工具）")
for t in tools:
    desc=(t.get("description") or "").strip().splitlines()
    first=desc[0][:100] if desc else ""
    print("  · %s%s"%(t.get("name","?"),(": "+first) if first else ""))
' 2>/dev/null
}

# ---------------------------------------------------------------- 会话 / 凭据

session_active() {
  api GET "/api/auth/get-session" "" yes || return 1
  [ "$RESP_STATUS" = "200" ] || return 1
  local head8; head8="$(head -c 4 "$RESP_BODY" 2>/dev/null)"
  [ "$head8" = "null" ] && return 1
  grep -q '"user"' "$RESP_BODY" 2>/dev/null
}

resolve_credentials() {
  [ -n "$EMAIL" ] || EMAIL="${LAWS_SG_EMAIL:-}"
  [ -n "$PASSWORD" ] || PASSWORD="${LAWS_SG_PASSWORD:-}"
  if [ -z "$EMAIL" ]; then
    [ -t 0 ] || die "缺少邮箱：用 --email 或设置 LAWS_SG_EMAIL"
    printf 'laws.sg 账号邮箱: ' >&2
    read -r EMAIL
  fi
  if [ -z "$PASSWORD" ]; then
    [ -t 0 ] || die "缺少密码：用 --password 或设置 LAWS_SG_PASSWORD（不要把密码写进命令行历史）"
    printf 'laws.sg 账号密码（不回显）: ' >&2
    read -rs PASSWORD; printf '\n' >&2
  fi
  [ -n "$EMAIL" ] && [ -n "$PASSWORD" ] || die "邮箱和密码都不能为空"
  [ -z "${PASSWORD##???????}" ] && warn "密码短于 8 位；站点前端要求 minLength=8，可能被拒"
  return 0
}

# ---------------------------------------------------------------- 子命令：诊断

cmd_doctor() {
  local ok=0 n=0
  local problems=""
  add_problem() { problems="${problems}${problems:+|}$1"; n=$((n+1)); ok=1; }

  info "laws.sg MCP doctor (v${SKILL_VERSION})"

  local b
  for b in curl python3; do
    if command -v "$b" >/dev/null 2>&1; then info "  ✓ ${b}: $(command -v "$b")"
    else info "  ✗ 缺少 ${b}"; add_problem "missing:${b}"; fi
  done

  ensure_tmp
  if api GET "/api/mcp" "" no; then
    if [ "$RESP_STATUS" = "401" ] && grep -q "Missing or invalid laws.sg MCP token" "$RESP_BODY"; then
      info "  ✓ 端点可达：${MCP_URL}（未带 token 如期 401）"
    else
      info "  ? 端点返回 HTTP ${RESP_STATUS}（预期 401）"
      add_problem "endpoint:${RESP_STATUS}"
    fi
  else
    info "  ✗ 端点不可达：${MCP_URL}"
    add_problem "endpoint-unreachable"
  fi

  local tok="${LAWS_SG_MCP_TOKEN:-}"
  if [ -n "$tok" ]; then
    case "$tok" in
      ${TOKEN_PREFIX}_*) info "  ✓ ${TOKEN_ENV_VAR} 已设置（前缀正确，长度 ${#tok}）" ;;
      *) info "  ? ${TOKEN_ENV_VAR} 已设置但前缀不是 ${TOKEN_PREFIX}_"
         add_problem "token-prefix" ;;
    esac
  else
    info "  · ${TOKEN_ENV_VAR} 未设置"
  fi

  detect_clients
  if [ -n "$DETECTED" ]; then
    info "  · 探测到 MCP 客户端：${DETECTED}"
    local c p
    for c in $DETECTED; do
      p="$(client_config_path "$c" "${SCOPE:-user}")"
      if [ -z "$p" ]; then
        if command -v "$c" >/dev/null 2>&1 && "$c" mcp get "$SERVER_NAME" >/dev/null 2>&1; then
          info "      ✓ ${c} 已配置 ${SERVER_NAME}（CLI 管理）"
        else
          info "      · ${c} 未配置（由其官方 CLI 管理）"
        fi
        continue
      fi
      if [ -f "$p" ] && python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: sys.exit(1)
sys.exit(0 if sys.argv[2] in (d.get(sys.argv[3]) or {}) else 1)
' "$p" "$SERVER_NAME" "$(client_root_key "$c")" 2>/dev/null; then
        info "      ✓ ${c} 已配置 ${SERVER_NAME}：${p}"
      else
        info "      · ${c} 未配置：${p}"
      fi
    done
  else
    info "  · 未探测到已知 MCP 客户端（用 snippet 取片段手工接入你的 agent）"
  fi

  if [ -s "$COOKIE_JAR" ] && grep -q 'session_token' "$COOKIE_JAR" 2>/dev/null; then
    info "  · 已有会话 cookie jar：${COOKIE_JAR}"
  fi

  if [ "$ok" -eq 0 ]; then
    info "  → 前置条件就绪"
  else
    warn "发现 ${n} 个问题：${problems}"
  fi
  jout "{\"ok\":$([ "$ok" -eq 0 ] && echo true || echo false),\"problems\":$(printf '%s' "$problems" | python3 -c 'import json,sys;s=sys.stdin.read();print(json.dumps([x for x in s.split("|") if x]))')}"
  return "$ok"
}

# ---------------------------------------------------------------- 子命令：登录 / 注册

cmd_login() {
  resolve_credentials || return 1
  mkdir_state
  local body msg
  body="$(python3 -c 'import json,sys;print(json.dumps({"email":sys.argv[1],"password":sys.argv[2],"rememberMe":True}))' "$EMAIL" "$PASSWORD")"

  api POST "/api/auth/sign-in/email" "$body" yes || return 1
  if [ "$RESP_STATUS" != "200" ]; then
    msg="$(resp_error)"
    error "登录失败 HTTP ${RESP_STATUS}：${msg}"
    if [ "$RESP_STATUS" = "401" ] || [ "$RESP_STATUS" = "400" ]; then
      fallback "邮箱或密码不被接受（站点统一回「Invalid email or password」，不区分是哪种）。三种可能：密码打错了；该邮箱还没注册过（可用 --mode signup 注册）；或该账号是用「Continue with Google」建的、根本没有密码，邮箱通道对它必然失败。"
    fi
    return 1
  fi

  info "登录请求已接受，校验会话…"
  if session_active; then
    info "✓ 已登录 ${EMAIL}"
    jout "{\"ok\":true,\"email\":\"${EMAIL}\",\"signedUp\":false}"
    return 0
  fi
  fallback "登录返回 200 但 get-session 为 null（可能存在邮箱验证门槛）。"
}

cmd_signup() {
  resolve_credentials || return 1
  mkdir_state
  local name="$NAME"
  [ -n "$name" ] || name="${EMAIL%%@*}"
  [ -n "$name" ] || name="laws.sg user"

  local body msg
  body="$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"email":sys.argv[2],"password":sys.argv[3]}))' "$name" "$EMAIL" "$PASSWORD")"

  api POST "/api/auth/sign-up/email" "$body" yes || return 1
  case "$RESP_STATUS" in
    200|201) info "注册请求已接受（HTTP ${RESP_STATUS}），用户名「${name}」" ;;
    *)
      msg="$(resp_error)"
      error "注册失败 HTTP ${RESP_STATUS}：${msg}"
      case "$msg" in
        *exist*|*already*|*Exist*|*Already*)
          warn "账号可能已存在，改走登录"
          cmd_login; return $? ;;
      esac
      return 1 ;;
  esac

  if session_active; then
    info "✓ 注册并取得会话：${EMAIL}"
    jout "{\"ok\":true,\"email\":\"${EMAIL}\",\"signedUp\":true}"
    return 0
  fi

  warn "注册后 get-session 仍为 null，尝试用密码登录一次…"
  FATAL_FALLBACK=0
  cmd_login >/dev/null 2>&1
  local lrc=$?
  FATAL_FALLBACK=1
  if [ $lrc -eq 0 ]; then return 0; fi
  fallback "注册后拿不到会话，站点可能开启了邮箱验证门槛。"
}

# ---------------------------------------------------------------- 子命令：token

cmd_token_create() {
  [ -n "$NAME" ] || die "缺少 --name（token 名称，3..80 字符，建议填客户端/设备名便于日后吊销）"
  local n="${#NAME}"
  if [ "$n" -lt 3 ] || [ "$n" -gt 80 ]; then die "--name 长度需在 3..80（当前 ${n}）"; fi

  # 纯本地校验先做完，再花网络请求去查会话
  local expires="null"
  if [ -n "$EXPIRES" ]; then
    case "$EXPIRES" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) die "--expires 需为 YYYY-MM-DD（收到：${EXPIRES}）" ;;
    esac
    # 照抄前端构造：新加坡时区当日 23:59:59.999 → UTC ISO
    expires="$(python3 -c '
import json,sys,datetime
d=datetime.datetime.fromisoformat(sys.argv[1]+"T23:59:59.999+08:00")
print(json.dumps(d.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z"))
' "$EXPIRES")"
  fi

  session_active || fallback "没有有效会话，无法签发 token。"

  local body
  body="$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"expiresAt":json.loads(sys.argv[2])}))' "$NAME" "$expires")"

  api POST "/api/account/mcp-tokens" "$body" yes || return 1
  if [ "$RESP_STATUS" = "403" ]; then
    error "HTTP 403：Origin 校验未通过（脚本已发送 Origin: ${BASE_URL}），站点契约可能已变更"
    return 1
  fi
  if [ "$RESP_STATUS" != "200" ] && [ "$RESP_STATUS" != "201" ]; then
    error "签发失败 HTTP ${RESP_STATUS}：$(resp_error)"
    if [ "$RESP_STATUS" = "401" ]; then fallback "会话已失效。"; fi
    return 1
  fi

  local plain; plain="$(resp_field plainTextToken)"
  if [ -z "$plain" ]; then
    error "响应里没有 plainTextToken，契约可能已变更。原始响应："
    head -c 500 "$RESP_BODY" >&2; printf '\n' >&2
    return 1
  fi
  RESULT_TOKEN="$plain"
  info "✓ 已签发 token「${NAME}」——仅此一次可见，站点不会再次展示"
  if [ "$JSON_OUT" -eq 1 ]; then
    jout "{\"ok\":true,\"name\":\"${NAME}\",\"plainTextToken\":\"${plain}\"}"
  else
    printf '%s\n' "$plain"
  fi
}

cmd_token_list() {
  session_active || fallback "没有有效会话，无法列出 token。"
  api GET "/api/account/mcp-tokens" "" yes || return 1
  if [ "$RESP_STATUS" != "200" ]; then
    error "HTTP ${RESP_STATUS}：$(resp_error)"; return 1
  fi
  python3 - "$RESP_BODY" "$JSON_OUT" <<'PY'
import json,sys,datetime
d=json.loads(open(sys.argv[1],encoding="utf-8").read())
items = d if isinstance(d,list) else (d.get("tokens") or d.get("data") or [])
now=datetime.datetime.now(datetime.timezone.utc)
def active(t):
    if t.get("revokedAt"): return False
    e=t.get("expiresAt")
    if not e: return True
    try: return datetime.datetime.fromisoformat(str(e).replace("Z","+00:00"))>now
    except Exception: return True
if sys.argv[2]=="1":
    print(json.dumps({"ok":True,"tokens":items},ensure_ascii=False)); sys.exit(0)
if not items:
    print("（该账号下没有 token）"); sys.exit(0)
print("%-6s %-38s %-24s %-22s %s"%("ACTIVE","ID","NAME","EXPIRES","REVOKED"))
for t in items:
    print("%-6s %-38s %-24s %-22s %s"%(
        "yes" if active(t) else "no",
        str(t.get("id",""))[:38], str(t.get("name",""))[:24],
        str(t.get("expiresAt") or "never")[:22], t.get("revokedAt") or "-"))
PY
}

cmd_token_revoke() {
  local id="${1:-}"
  [ -n "$id" ] || die "用法：token revoke <id>"
  session_active || fallback "没有有效会话，无法吊销 token。"
  api DELETE "/api/account/mcp-tokens/${id}" "" yes || return 1
  case "$RESP_STATUS" in
    200|204) info "✓ 已吊销 token ${id}"; jout "{\"ok\":true,\"revoked\":\"${id}\"}"; return 0 ;;
    *) error "吊销失败 HTTP ${RESP_STATUS}：$(resp_error)"; return 1 ;;
  esac
}

# ---------------------------------------------------------------- 子命令：验证

# 服务端在 initialize 之后的请求上要求回带 MCP-Protocol-Version 头（MCP 2025-06-18 规范要求）。
# 缺这个头时，即便 Mcp-Session-Id 正确，也会回 {"code":-32600,"message":"Session not found"}
# —— 实测缺头约 2/3 概率失败，带头 7/7 成功。这条极易误诊为「服务端会话不稳定」。
# 保留整段握手重试作为兜底，但不要把这种错误当成 token 失效。
mcp_session_lost() {
  grep -q 'Session not found' "$RESP_BODY" 2>/dev/null && return 0
  grep -q 'Missing session ID' "$RESP_BODY" 2>/dev/null && return 0
  grep -q '"code":-32600' "$RESP_BODY" 2>/dev/null && return 0
  return 1
}

cmd_verify() {
  local tok="${1:-${LAWS_SG_MCP_TOKEN:-}}"
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"laws-sg-mcp-skill","version":"'"${SKILL_VERSION}"'"}}}'

  if [ -z "$tok" ]; then
    # 负向断言：确认端点存活、且确实只认 bearer token
    mcp_post "$init" "" "" || return 1
    if [ "$RESP_STATUS" = "401" ] && grep -q "Missing or invalid laws.sg MCP token" "$RESP_BODY"; then
      info "✓ 端点存活；未带 token 如期返回 401（www-authenticate: $(hdr_get WWW-Authenticate)）"
      info "· 尚未配置 token —— 这是预期状态，不是故障"
      jout '{"ok":true,"authenticated":false,"reason":"no-token"}'
      return 0
    fi
    error "非预期响应 HTTP ${RESP_STATUS}：$(head -c 300 "$RESP_BODY")"
    jout "{\"ok\":false,\"authenticated\":false,\"status\":${RESP_STATUS}}"
    return 1
  fi

  local attempt=0 max_attempts=4 sid msg parsed sinfo proto tmsg names
  while :; do
    attempt=$((attempt + 1))
    [ $attempt -gt 1 ] && warn "会话被路由到其他实例（Session not found），重试整段握手 ${attempt}/${max_attempts}"

    mcp_post "$init" "" "$tok" || return 1
    if [ "$RESP_STATUS" = "401" ]; then
      error "token 被拒（HTTP 401）：$(head -c 200 "$RESP_BODY")"
      error "多半是已吊销、已过期，或复制时缺字符。重新签发一个即可。"
      jout '{"ok":false,"authenticated":false,"reason":"token-rejected"}'
      return 1
    fi
    if [ "$RESP_STATUS" != "200" ]; then
      error "initialize 返回 HTTP ${RESP_STATUS}：$(head -c 300 "$RESP_BODY")"
      jout "{\"ok\":false,\"status\":${RESP_STATUS}}"
      return 1
    fi

    sid="$(hdr_get Mcp-Session-Id)"
    msg="$(mcp_message)"
    parsed="$(parse_init "$msg")"
    sinfo="${parsed%%$'\t'*}"
    proto="${parsed##*$'\t'}"
    MCP_PV="${proto:-2025-06-18}"   # 后续请求回带协商版本
    if [ $attempt -eq 1 ]; then
      info "✓ initialize 成功：serverInfo=${sinfo:-unknown} protocolVersion=${proto:-unknown}"
      [ -n "$sid" ] && info "  · Mcp-Session-Id: ${sid}"
    fi

    mcp_post '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$sid" "$tok" || true
    verbose "notifications/initialized → HTTP ${RESP_STATUS}"

    mcp_post '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' "$sid" "$tok" || return 1
    if [ "$RESP_STATUS" = "200" ] && ! mcp_session_lost; then break; fi
    if [ "$RESP_STATUS" != "200" ] && ! mcp_session_lost; then
      warn "tools/list 返回 HTTP ${RESP_STATUS}；initialize 已成功，token 确认有效"
      jout '{"ok":true,"authenticated":true,"tools":null}'
      return 0
    fi
    if [ $attempt -ge $max_attempts ]; then
      error "连续 ${max_attempts} 次都拿不到 tools/list（服务端会话路由不稳定）。"
      error "但 initialize 已成功、token 有效 —— MCP 客户端自己会重连，配置可用。"
      jout '{"ok":true,"authenticated":true,"tools":null,"note":"session-routing-flaky"}'
      return 0
    fi
    sleep 2
  done

  tmsg="$(mcp_message)"
  parsed="$(parse_tools "$tmsg")"
  names="$(printf '%s\n' "$parsed" | head -n 1)"
  info "✓ 可用 MCP 工具："
  printf '%s\n' "$parsed" | tail -n +2 >&2
  jout "{\"ok\":true,\"authenticated\":true,\"serverInfo\":\"${sinfo}\",\"protocolVersion\":\"${proto}\",\"tools\":${names:-null}}"
  return 0
}

# 幂等：现有 token 能用就复用（plainTextToken 只在创建时返回一次，丢了无法找回）
cmd_token_ensure() {
  local existing="${LAWS_SG_MCP_TOKEN:-}"
  if [ -n "$existing" ]; then
    info "检测到 ${TOKEN_ENV_VAR} 已设置，先验证是否可用…"
    if cmd_verify "$existing" >/dev/null 2>&1; then
      info "✓ 现有 token 有效，直接复用（不签发新 token）"
      RESULT_TOKEN="$existing"
      if [ "$JSON_OUT" -eq 1 ]; then jout '{"ok":true,"reused":true}'; else printf '%s\n' "$existing"; fi
      return 0
    fi
    warn "现有 token 无效，将签发新的"
  fi
  cmd_token_create || return $?
  if [ "$JSON_OUT" -eq 0 ]; then printf '%s\n' "$RESULT_TOKEN"; fi
}

# ---------------------------------------------------------------- 客户端适配层
#
# 本 Skill 不绑定任何特定 agent。客户端分三类处理：
#   1) JSON 配置型 —— 有权威格式来源，脚本直接合并写入
#   2) CLI 型      —— 官方提供了 add 命令，脚本调用该命令（二进制不在则打印命令）
#   3) 未知客户端  —— 一律只输出片段，由 agent/用户自行适配。**绝不猜格式**
#
# 格式来源：kimi-code 取自其官方文档；cursor / vscode / claude / codex / generic
# 取自 laws.sg 的 /legal-ai 页面官方 snippet（见 references/clients.md）。

CLIENTS_JSON="kimi-code cursor vscode generic"
CLIENTS_CLI="claude codex"
CLIENTS_ALL="kimi-code claude codex cursor vscode generic"

# 该客户端的配置/数据目录是否存在，用来判断「装没装」
client_installed() {
  case "$1" in
    kimi-code) [ -d "${KIMI_CODE_HOME:-${HOME}/.kimi-code}" ] || command -v kimi >/dev/null 2>&1 ;;
    claude)    command -v claude >/dev/null 2>&1 || [ -e "${HOME}/.claude.json" ] || [ -d "${HOME}/.claude" ] ;;
    codex)     command -v codex >/dev/null 2>&1 || [ -d "${HOME}/.codex" ] ;;
    cursor)    [ -d "${HOME}/.cursor" ] || [ -d "/Applications/Cursor.app" ] ;;
    vscode)    command -v code >/dev/null 2>&1 || [ -d "/Applications/Visual Studio Code.app" ] ;;
    generic)   return 1 ;;   # 通用片段不算「已安装」，只在显式指定时写
    *)         return 1 ;;
  esac
}

client_config_path() {  # <name> <scope>
  local scope="${2:-user}"
  case "$1" in
    kimi-code)
      if [ "$scope" = "project" ]; then printf '%s\n' "${PWD}/.kimi-code/mcp.json"
      else printf '%s\n' "${KIMI_CODE_HOME:-${HOME}/.kimi-code}/mcp.json"; fi ;;
    cursor)
      if [ "$scope" = "project" ]; then printf '%s\n' "${PWD}/.cursor/mcp.json"
      else printf '%s\n' "${HOME}/.cursor/mcp.json"; fi ;;
    vscode)  printf '%s\n' "${PWD}/.vscode/mcp.json" ;;   # VS Code 是工作区级，无 user/project 之分
    generic) printf '%s\n' "${CONFIG_PATH:-${PWD}/.mcp.json}" ;;
    *)       printf '' ;;   # CLI 型客户端由自己的命令管理文件
  esac
}

# 写入 JSON 时的根键：多数客户端是 mcpServers，VS Code 是 servers
client_root_key() {
  case "$1" in
    vscode) printf 'servers' ;;
    *)      printf 'mcpServers' ;;
  esac
}

# 该客户端的 server 条目。默认用环境变量引用，配置文件里不落明文 token；
# --token-inline 时才写字面值（给不支持 env 展开的客户端用）。
# 值为 null 的键表示「删掉这个键」—— 避免在 env 引用与明文之间切换时残留旧鉴权字段。
client_entry_json() {
  local name="$1" bearer
  if [ "$TOKEN_INLINE" = "1" ]; then
    bearer="${LAWS_SG_MCP_TOKEN:-${RESULT_TOKEN}}"
    [ -n "$bearer" ] || bearer="${TOKEN_PREFIX}_REPLACE_WITH_YOUR_TOKEN"
  else
    bearer="\${${TOKEN_ENV_VAR}}"
  fi
  case "$name" in
    kimi-code)
      if [ "$TOKEN_INLINE" = "1" ]; then
        printf '{"url":"%s","headers":{"Authorization":"Bearer %s"},"bearerTokenEnvVar":null,"enabled":true}' "$MCP_URL" "$bearer"
      else
        # kimi-code 有专门的 bearerTokenEnvVar 字段，比 headers 更干净
        printf '{"url":"%s","bearerTokenEnvVar":"%s","headers":null,"enabled":true}' "$MCP_URL" "$TOKEN_ENV_VAR"
      fi ;;
    vscode)
      printf '{"type":"http","url":"%s","headers":{"Authorization":"Bearer ${input:%s}"}}' "$MCP_URL" "$TOKEN_INPUT_ID" ;;
    cursor|generic|*)
      printf '{"type":"streamable-http","url":"%s","headers":{"Authorization":"Bearer %s"},"bearerTokenEnvVar":null}' "$MCP_URL" "$bearer" ;;
  esac
}

# VS Code 需要额外声明一个 promptString input（首次使用时弹窗索取 token）
client_extra_json() {
  case "$1" in
    vscode) printf '{"inputs":[{"type":"promptString","id":"%s","description":"%s","password":true}]}' \
              "$TOKEN_INPUT_ID" "$TOKEN_DESCRIPTION" ;;
    *)      printf '{}' ;;
  esac
}

write_json_client() {  # <name> → 0 成功 / 1 失败 / 3 原文件损坏
  local name="$1" path root entry extra out rc
  path="$(client_config_path "$name" "$SCOPE")"
  [ -n "$path" ] || { error "${name}：无法确定配置路径"; return 1; }
  root="$(client_root_key "$name")"
  entry="$(client_entry_json "$name")"
  extra="$(client_extra_json "$name")"

  out="$(python3 - "$path" "$root" "$SERVER_NAME" "$entry" "$extra" "$DRY_RUN" 2>&1 <<'PY'
import json,os,sys,time,shutil
path,root,server,entry,extra,dry=sys.argv[1:7]
entry=json.loads(entry); extra=json.loads(extra)
data={}
if os.path.exists(path):
    raw=open(path,encoding="utf-8").read().strip()
    if raw:
        try: data=json.loads(raw)
        except Exception as e:
            print("PARSE_ERROR: %s"%e); sys.exit(3)
if not isinstance(data,dict): data={}
servers=data.get(root)
if not isinstance(servers,dict): servers={}
cur=servers.get(server)
if not isinstance(cur,dict): cur={}
cur.update(entry)
cur={k:v for k,v in cur.items() if v is not None}   # 值为 null 表示删除该键
servers[server]=cur
data[root]=servers
# 合并额外顶层字段（如 VS Code 的 inputs），按 id 去重追加
for k,v in extra.items():
    if isinstance(v,list):
        have=data.get(k)
        if not isinstance(have,list): have=[]
        ids={i.get("id") for i in have if isinstance(i,dict)}
        for item in v:
            if isinstance(item,dict) and item.get("id") not in ids: have.append(item)
        data[k]=have
    else:
        data.setdefault(k,v)
out=json.dumps(data,indent=2,ensure_ascii=False)+"\n"
if dry=="1":
    sys.stdout.write("PATH:"+path+"\n"); sys.stdout.write(out); sys.exit(0)
d=os.path.dirname(path)
if d: os.makedirs(d,exist_ok=True)
if os.path.exists(path):
    shutil.copy2(path,path+".bak."+time.strftime("%Y%m%d%H%M%S"))
tmp=path+".tmp"
open(tmp,"w",encoding="utf-8").write(out)
os.chmod(tmp,0o600)
os.replace(tmp,path)
print(path)
PY
)"
  rc=$?
  case $rc in
    3) error "${path} 不是合法 JSON，已放弃写入（避免破坏现有配置）：${out}"
       error "请手工修复后重试，或用 --dry-run 查看预期结果"
       return 3 ;;
    0) ;;
    *) error "写入 ${name} 配置失败：${out}"; return 1 ;;
  esac

  if [ "$DRY_RUN" = "1" ]; then
    info "· [dry-run] ${name} → ${path}"
    printf '%s\n' "$out" | tail -n +2 >&2
    return 0
  fi
  info "✓ ${name}：已写入 ${out}"
  CONFIGURED="${CONFIGURED}${CONFIGURED:+,}${name}"
}

run_cli_client() {  # <name> → 0 已执行 / 1 失败 / 4 二进制缺失（改为打印命令）
  local name="$1" scopeflag=""
  case "$name" in
    claude)
      command -v claude >/dev/null 2>&1 || { snippet claude; return 4; }
      case "$SCOPE" in
        user)    scopeflag="-s user" ;;
        project) scopeflag="-s project" ;;
      esac
      if [ "$DRY_RUN" = "1" ]; then
        info "· [dry-run] ${name}：将执行下面这条命令（未执行）"
        snippet claude | sed 's/^/    /' >&2
        [ -n "$scopeflag" ] && info "    （实际执行时会附加 ${scopeflag}）"
        return 0
      fi
      if claude mcp get "$SERVER_NAME" >/dev/null 2>&1; then
        if [ "$FORCE" != "1" ]; then
          info "· ${name}：已存在 ${SERVER_NAME} 条目，跳过（加 --force 覆盖）"
          CONFIGURED="${CONFIGURED}${CONFIGURED:+,}${name}(已存在)"
          return 0
        fi
        claude mcp remove "$SERVER_NAME" >/dev/null 2>&1 || true
      fi
      # 单引号让 ${LAWS_SG_MCP_TOKEN} 原样存进配置，由 Claude Code 运行时展开
      if claude mcp add --transport http $scopeflag "$SERVER_NAME" "$MCP_URL" \
           --header 'Authorization: Bearer ${LAWS_SG_MCP_TOKEN}'; then
        info "✓ ${name}：已通过 claude mcp add 注册 ${SERVER_NAME}"
        CONFIGURED="${CONFIGURED}${CONFIGURED:+,}${name}"
        return 0
      fi
      error "${name}：claude mcp add 失败"; return 1 ;;
    codex)
      command -v codex >/dev/null 2>&1 || { snippet codex; return 4; }
      if [ "$DRY_RUN" = "1" ]; then
        info "· [dry-run] ${name}：将执行下面这条命令（未执行）"
        snippet codex | sed 's/^/    /' >&2
        return 0
      fi
      if codex mcp add "$SERVER_NAME" --url "$MCP_URL" --bearer-token-env-var "$TOKEN_ENV_VAR"; then
        info "✓ ${name}：已通过 codex mcp add 注册 ${SERVER_NAME}"
        CONFIGURED="${CONFIGURED}${CONFIGURED:+,}${name}"
        return 0
      fi
      error "${name}：codex mcp add 失败（条目可能已存在，请先 codex mcp remove ${SERVER_NAME}）"
      return 1 ;;
    *) error "未知 CLI 客户端：${name}"; return 1 ;;
  esac
}

# 探测本机装了哪些客户端；结果写入 DETECTED（空格分隔）
detect_clients() {
  DETECTED=""
  local c
  for c in $CLIENTS_ALL; do
    if client_installed "$c"; then DETECTED="${DETECTED}${DETECTED:+ }${c}"; fi
  done
}

cmd_client_list() {
  detect_clients
  info "本机 MCP 客户端探测结果："
  local c path mark
  for c in $CLIENTS_ALL; do
    if client_installed "$c"; then mark="✓ 已安装"; else mark="· 未检测到"; fi
    path="$(client_config_path "$c" "$SCOPE")"
    if [ -n "$path" ]; then
      if [ -f "$path" ] && python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: sys.exit(1)
sys.exit(0 if sys.argv[2] in (d.get(sys.argv[3]) or {}) else 1)
' "$path" "$SERVER_NAME" "$(client_root_key "$c")" 2>/dev/null; then
        mark="${mark}，且已配置 ${SERVER_NAME}"
      fi
      printf '  %-10s %s\n               %s\n' "$c" "$mark" "$path" >&2
    else
      printf '  %-10s %s（由官方 CLI 管理）\n' "$c" "$mark" >&2
    fi
  done
  [ -n "$DETECTED" ] || info "  （一个都没检测到 —— 用 snippet 拿片段手工接入你的 agent）"
  jout "{\"detected\":[$(printf '%s\n' ${DETECTED:-} | python3 -c 'import json,sys;print(",".join(json.dumps(l.strip()) for l in sys.stdin if l.strip()))')]}"
}

login_shell() {
  # $SHELL 不可信：子进程包装器常改写它（实测在 agent 的 Bash 工具里是 /bin/bash，
  # 而用户真实登录 shell 是 /bin/zsh）。macOS 上 dscl 才是权威的。
  local s=""
  if command -v dscl >/dev/null 2>&1; then
    s="$(dscl . -read "/Users/${USER:-$(id -un)}" UserShell 2>/dev/null | awk '{print $2}')"
  fi
  [ -n "$s" ] || s="${SHELL:-/bin/zsh}"
  basename "$s"
}

shell_profile() {
  if [ -n "$PROFILE" ]; then printf '%s\n' "$PROFILE"; return; fi
  case "$(login_shell)" in
    zsh)  printf '%s\n' "${HOME}/.zshrc" ;;
    bash) if [ -f "${HOME}/.bash_profile" ]; then printf '%s\n' "${HOME}/.bash_profile"
          else printf '%s\n' "${HOME}/.bashrc"; fi ;;
    *)    printf '%s\n' "${HOME}/.profile" ;;
  esac
}

cmd_env_install() {
  local tok="$TOKEN"
  [ -n "$tok" ] || tok="${RESULT_TOKEN}"
  [ -n "$tok" ] || tok="${LAWS_SG_MCP_TOKEN:-}"
  [ -n "$tok" ] || die "没有 token 可写：先 token create 拿到，或用 --token 传入"

  local pf; pf="$(shell_profile)"
  [ -n "$pf" ] || die "无法确定 shell profile"
  if [ ! -f "$pf" ]; then
    warn "目标 profile ${pf} 不存在，将新建（登录 shell 判定为 $(login_shell)）"
    if [ -f "${HOME}/.zshrc" ] && [ "$pf" != "${HOME}/.zshrc" ]; then
      warn "但 ${HOME}/.zshrc 是存在的 —— 若你的登录 shell 其实是 zsh，请改用 --profile ${HOME}/.zshrc"
    fi
  fi
  if [ "$SAVE_CREDENTIALS" = "1" ]; then
    [ -n "$EMAIL" ] || EMAIL="${LAWS_SG_EMAIL:-}"
    [ -n "$PASSWORD" ] || PASSWORD="${LAWS_SG_PASSWORD:-}"
    warn "将把邮箱与密码以【明文】写入 ${pf}（你显式传了 --save-credentials）"
  fi

  local written
  written="$(python3 - "$pf" "$tok" "$SAVE_CREDENTIALS" "$EMAIL" "$PASSWORD" 2>&1 <<'PY'
import os,re,sys,time,shutil
path,tok,save,email,pw=sys.argv[1:6]
BEGIN="# >>> laws.sg MCP (managed by laws-sg-mcp skill) >>>"
END="# <<< laws.sg MCP <<<"
lines=['export LAWS_SG_MCP_TOKEN="%s"'%tok]
if save=="1" and email:
    lines.append('export LAWS_SG_EMAIL="%s"'%email)
    lines.append('export LAWS_SG_PASSWORD="%s"'%pw)
block="\n".join([BEGIN]+lines+[END])
old=""
if os.path.exists(path):
    old=open(path,encoding="utf-8",errors="replace").read()
    shutil.copy2(path,path+".bak."+time.strftime("%Y%m%d%H%M%S"))
pat=re.compile(r"\n?"+re.escape(BEGIN)+r".*?"+re.escape(END)+r"\n?",re.S)
new=pat.sub("\n",old) if old else ""
new=new.rstrip("\n")
new=(new+"\n\n" if new else "")+block+"\n"
d=os.path.dirname(path)
if d: os.makedirs(d,exist_ok=True)
tmp=path+".tmp"
open(tmp,"w",encoding="utf-8").write(new)
os.chmod(tmp,0o600)
os.replace(tmp,path)
print(path)
PY
)"
  local rc=$?
  if [ $rc -ne 0 ]; then error "写入 profile 失败：${written}"; return 1; fi

  info "✓ 已写入 ${written}（托管块；重复执行原地替换，旧文件已备份）"
  info "  新 shell 会自动带上 ${TOKEN_ENV_VAR}；当前 shell 请执行：source ${written}"
  jout "{\"ok\":true,\"profile\":\"${written}\"}"
}

CONFIGURED=""
DETECTED=""

cmd_configure() {
  CONFIGURED=""
  local spec="$CLIENT" targets="" c rc_any=0
  case "$spec" in
    auto)
      detect_clients
      targets="$DETECTED"
      if [ -z "$targets" ]; then
        warn "--client auto 没探测到任何已知客户端"
        info "可用客户端：${CLIENTS_ALL}"
        info "请用 snippet 取片段手工接入你的 agent："
        for c in $CLIENTS_ALL; do info "  $0 snippet --client ${c}"; done
        jout '{"ok":false,"reason":"no-client-detected"}'
        return 1
      fi
      info "探测到客户端：${targets}" ;;
    all) targets="$CLIENTS_ALL" ;;
    *)   targets="$(printf '%s' "$spec" | tr ',' ' ')" ;;
  esac

  for c in $targets; do
    case " ${CLIENTS_ALL} " in
      *" ${c} "*) ;;
      *) error "未知客户端：${c}（可用：${CLIENTS_ALL}，或 auto / all）"; rc_any=1; continue ;;
    esac
    case " ${CLIENTS_CLI} " in
      *" ${c} "*)
        run_cli_client "$c"
        case $? in
          0) ;;
          4) info "· ${c}：未找到其 CLI，已打印官方命令，请手工执行" ;;
          *) rc_any=1 ;;
        esac ;;
      *)
        write_json_client "$c"
        [ $? -ne 0 ] && rc_any=1 ;;
    esac
  done

  if [ -n "$CONFIGURED" ]; then
    info "已配置：${CONFIGURED}"
    if [ "$TOKEN_INLINE" != "1" ]; then
      info "token 通过环境变量 ${TOKEN_ENV_VAR} 间接引用，配置文件里没有明文"
      info "→ 请先跑 env-install（或自行 export），否则客户端取不到 token"
    else
      warn "--token-inline：token 已明文写入配置文件，注意文件权限与提交风险"
    fi
    info "⚠ 多数 agent 只在会话启动时加载 MCP 配置 → 请重启 agent / 重新加载 MCP 后再验证"
  fi
  if [ "$ALLOW_TOOLS" = "1" ]; then kimi_allow_tools; fi
  jout "{\"ok\":$([ $rc_any -eq 0 ] && echo true || echo false),\"configured\":\"${CONFIGURED}\",\"scope\":\"${SCOPE}\"}"
  return "$rc_any"
}

# kimi-code 专属的可选项：免审批放行该 server 的工具。其他 agent 有自己的权限机制。
kimi_allow_tools() {
  local cfg="${KIMI_CODE_HOME:-${HOME}/.kimi-code}/config.toml"
  local pattern="mcp__${SERVER_NAME}__*"
  if ! client_installed kimi-code; then
    warn "--allow-tools 只对 kimi-code 生效，且未检测到 kimi-code，跳过"
    return 0
  fi
  if [ ! -f "$cfg" ]; then warn "未找到 ${cfg}，跳过 permission rule"; return 0; fi
  if grep -Fq "$pattern" "$cfg"; then info "· permission rule 已存在，跳过"; return 0; fi
  cp "$cfg" "${cfg}.bak.$(date +%Y%m%d%H%M%S)" || return 1
  printf '\n[[permission.rules]]\ndecision = "allow"\npattern = "%s"\n' "$pattern" >>"$cfg"
  info "✓ kimi-code：已追加 permission rule allow ${pattern}（原文件已备份）"
  info "  注意 report_issue 是写操作，如需收紧再单独 deny mcp__${SERVER_NAME}__report_issue"
}

# ---------------------------------------------------------------- 子命令：片段 / 人工路径

snippet() {  # <client>：只打印片段，不落盘
  local client="$1"
  local shown="${LAWS_SG_MCP_TOKEN:-${RESULT_TOKEN}}"
  [ -n "$shown" ] || shown="${TOKEN_PREFIX}_REPLACE_WITH_YOUR_TOKEN"
  case "$client" in
    kimi-code)
      cat <<EOF
// ~/.kimi-code/mcp.json（项目级：./.kimi-code/mcp.json，项目级覆盖用户级）
{
  "mcpServers": {
    "${SERVER_NAME}": {
      "url": "${MCP_URL}",
      "bearerTokenEnvVar": "${TOKEN_ENV_VAR}"
    }
  }
}
// 也可在 TUI 里 /mcp-config 交互式添加，/mcp 查看连接状态
EOF
      ;;
    claude)
      cat <<EOF
export ${TOKEN_ENV_VAR}=${shown}
claude mcp add --transport http ${SERVER_NAME} ${MCP_URL} --header "Authorization: Bearer \${${TOKEN_ENV_VAR}}"
EOF
      ;;
    codex)
      cat <<EOF
export ${TOKEN_ENV_VAR}=${shown}
codex mcp add ${SERVER_NAME} --url ${MCP_URL} --bearer-token-env-var ${TOKEN_ENV_VAR}
EOF
      ;;
    cursor)
      cat <<EOF
// ~/.cursor/mcp.json —— 保留 \${${TOKEN_ENV_VAR}} 引用并在环境里 export，或直接替换为 token 本身
{
  "mcpServers": {
    "${SERVER_NAME}": {
      "type": "streamable-http",
      "url": "${MCP_URL}",
      "headers": { "Authorization": "Bearer \${${TOKEN_ENV_VAR}}" }
    }
  }
}
EOF
      ;;
    vscode)
      cat <<EOF
// .vscode/mcp.json —— VS Code 首次使用时弹窗索取 token，token 不落文件
{
  "inputs": [
    { "type": "promptString", "id": "${TOKEN_INPUT_ID}", "description": "${TOKEN_DESCRIPTION}", "password": true }
  ],
  "servers": {
    "${SERVER_NAME}": {
      "type": "http",
      "url": "${MCP_URL}",
      "headers": { "Authorization": "Bearer \${input:${TOKEN_INPUT_ID}}" }
    }
  }
}
EOF
      ;;
    json|other|generic)
      cat <<EOF
{
  "mcpServers": {
    "${SERVER_NAME}": {
      "type": "streamable-http",
      "url": "${MCP_URL}",
      "headers": { "Authorization": "Bearer ${shown}" }
    }
  }
}
EOF
      ;;
    *) error "未知客户端：${client}（可用：${CLIENTS_ALL}，或 all）"; return 1 ;;
  esac
}

cmd_snippet() {
  local c
  if [ "$CLIENT" = "all" ]; then
    for c in $CLIENTS_ALL; do
      printf '### %s\n' "$c" >&2
      snippet "$c" || return 1
      printf '\n'
    done
  else
    snippet "$CLIENT"
  fi
}

cmd_manual() {
  cat <<EOF
半自动路径（人工只做 2 件事：浏览器点几下 + 粘贴一次 token）

  1. 打开 ${ACCOUNT_PAGE}
     登录（邮箱密码，或「Continue with Google」）
     → Token name 填 3..80 字符（建议客户端/设备名，便于日后吊销）
     → Expiry 可留空（永不过期）
     → 创建，复制以 ${TOKEN_PREFIX}_ 开头的 token（页面只显示一次）

  2. 把 token 交给脚本，剩下全自动：
       $0 verify   ${TOKEN_PREFIX}_xxxx
       $0 env-install --token ${TOKEN_PREFIX}_xxxx
       $0 configure --client auto      # 自动探测本机装了哪些 MCP 客户端
       $0 clients                      # 只想看探测结果、不写入

  之后重启你的 agent（多数 agent 只在会话启动时加载 MCP 配置），${SERVER_NAME} 就会出现。
EOF
  if [ "$OPEN_BROWSER" = "1" ] && command -v open >/dev/null 2>&1; then
    open "$ACCOUNT_PAGE" && info "已在浏览器打开 ${ACCOUNT_PAGE}"
  fi
}

# ---------------------------------------------------------------- 子命令：编排

cmd_setup() {
  info "=== laws.sg MCP 全自动配置 ==="
  cmd_doctor || warn "doctor 报告了问题，仍继续尝试"

  if [ -n "${LAWS_SG_MCP_TOKEN:-}" ] && cmd_verify >/dev/null 2>&1; then
    info "✓ ${TOKEN_ENV_VAR} 已存在且有效 —— 跳过登录与签发"
    RESULT_TOKEN="${LAWS_SG_MCP_TOKEN}"
  else
    case "$MODE" in
      signup) cmd_signup || return $? ;;
      login)  cmd_login  || return $? ;;
      auto|"")
        resolve_credentials || return $?
        info "先尝试登录；账号不存在则自动注册"
        FATAL_FALLBACK=0
        cmd_login >/dev/null 2>&1
        local lrc=$?
        FATAL_FALLBACK=1
        if [ $lrc -eq 0 ]; then
          info "✓ 已登录 ${EMAIL}"
        else
          warn "登录未成功（多半是该邮箱还没注册过），改为注册新账号"
          cmd_signup || return $?
        fi ;;
      *) die "未知 --mode：${MODE}（可选 auto|login|signup）" ;;
    esac

    cmd_token_ensure || return $?
    case "$RESULT_TOKEN" in
      ${TOKEN_PREFIX}_*) export LAWS_SG_MCP_TOKEN="$RESULT_TOKEN"
                         info "✓ 已取得 token（长度 ${#RESULT_TOKEN}）" ;;
      *) error "拿到的不是合法 token（应以 ${TOKEN_PREFIX}_ 开头）"; return 1 ;;
    esac
  fi

  TOKEN="$RESULT_TOKEN"
  cmd_env_install || return $?
  cmd_configure   || return $?

  info "=== 验证 MCP 连通性 ==="
  cmd_verify || return $?

  info ""
  info "=== 完成 ==="
  info "重启你的 agent（多数 agent 只在会话启动时加载 MCP 配置），${SERVER_NAME} 就会出现"
  info "已配置的客户端：${CONFIGURED:-（无）}；探测详情可跑：$0 clients"
  if [ "$SAVE_CREDENTIALS" != "1" ]; then
    info "本次未持久化密码；日后重新签发 token 需再次提供凭据"
  fi
}

# ---------------------------------------------------------------- 入口

usage() {
  cat <<EOF
laws.sg MCP 配置引擎 v${SKILL_VERSION}

用法：$(basename "$0") <command> [options]

账号 / token
  login    --email E --password P          邮箱密码登录（或 LAWS_SG_EMAIL / LAWS_SG_PASSWORD）
  signup   --email E --password P [--name N]
                                           注册（name 缺省取邮箱前缀）并登录
  token create --name N [--expires YYYY-MM-DD]
                                           签发；token 仅此一次可见
  token list                               列出账号下所有 token 及有效性
  token revoke <id>                        吊销
  token ensure --name N                    幂等：现有 token 能用就复用，否则新建

本地落地
  clients                                  探测本机装了哪些 MCP 客户端、各自配置文件在哪、是否已配置
  verify [token]                           真握手 initialize + tools/list；无 token 时做 401 负向断言
  env-install [--token T] [--profile P] [--save-credentials]
                                           幂等写入 shell profile 托管块
  configure [--client auto|all|<名字>[,<名字>...]] [--scope user|project]
            [--token-inline] [--force] [--path FILE] [--allow-tools] [--dry-run]
                                           写入客户端配置。auto=只写探测到的；默认 token 走环境变量引用不落明文
  snippet [--client <名字>|all]            只打印片段，不落盘

  可写入的客户端：${CLIENTS_ALL}
  其中 claude / codex 走各自的官方 CLI 命令；kimi-code / cursor / vscode / generic 走 JSON 合并写。
  未列出的 agent 一律用 snippet 拿通用片段自行接入 —— 脚本不猜格式。

编排 / 诊断
  setup [--mode auto|login|signup] [--client ...] [--scope ...]
                                           全自动：doctor → 登录/注册 → 签发 → env → 配置 → 验证
  doctor                                   前置条件 + 客户端探测
  manual [--open]                          打印半自动降级步骤（--open 同时打开浏览器）

全局选项：--json 结构化输出；-v/--verbose 详细日志
退出码：0 成功 / 1 失败 / 2 需人工降级（stderr 打印 FALLBACK: manual）
EOF
}

main() {
  local cmd="${1:-}"
  if [ $# -gt 0 ]; then shift; fi

  EMAIL=""; PASSWORD=""; NAME=""; EXPIRES=""; TOKEN=""; CLIENT="auto"
  SCOPE="user"; DRY_RUN="0"; ALLOW_TOOLS="0"; SAVE_CREDENTIALS="0"; MODE=""
  PROFILE=""; OPEN_BROWSER="0"; TOKEN_INLINE="0"; FORCE="0"; CONFIG_PATH=""

  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) JSON_OUT=1 ;;
      -v|--verbose) VERBOSE=1 ;;
      --email) EMAIL="${2:-}"; shift ;;
      --password) PASSWORD="${2:-}"; shift ;;
      --name) NAME="${2:-}"; shift ;;
      --expires) EXPIRES="${2:-}"; shift ;;
      --token) TOKEN="${2:-}"; shift ;;
      --client) CLIENT="${2:-}"; shift ;;
      --scope) SCOPE="${2:-}"; shift ;;
      --mode) MODE="${2:-}"; shift ;;
      --profile) PROFILE="${2:-}"; shift ;;
      --dry-run) DRY_RUN="1" ;;
      --allow-tools) ALLOW_TOOLS="1" ;;
      --save-credentials) SAVE_CREDENTIALS="1" ;;
      --token-inline) TOKEN_INLINE="1" ;;
      --force) FORCE="1" ;;
      --path) CONFIG_PATH="${2:-}"; shift ;;
      --open) OPEN_BROWSER="1" ;;
      -h|--help) usage; exit 0 ;;
      --) shift; while [ $# -gt 0 ]; do positional+=("$1"); shift; done; break ;;
      -*) die "未知选项：$1" ;;
      *) positional+=("$1") ;;
    esac
    shift
  done

  case "$cmd" in
    ""|help|-h|--help) usage; exit 0 ;;
  esac

  need curl; need python3

  case "$cmd" in
    doctor)      cmd_doctor ;;
    clients)     cmd_client_list ;;
    login)       cmd_login ;;
    signup)      cmd_signup ;;
    verify)      cmd_verify "${positional[0]:-}" ;;
    env-install) cmd_env_install ;;
    configure)   cmd_configure ;;
    snippet)     cmd_snippet ;;
    setup)       cmd_setup ;;
    manual)      cmd_manual ;;
    token)
      case "${positional[0]:-}" in
        create) cmd_token_create ;;
        list)   cmd_token_list ;;
        revoke) cmd_token_revoke "${positional[1]:-}" ;;
        ensure) cmd_token_ensure ;;
        *) die "token 子命令需为 create|list|revoke|ensure（收到：${positional[0]:-空}）" ;;
      esac ;;
    *) error "未知命令：${cmd}"; usage; exit 1 ;;
  esac
}

main "$@"
