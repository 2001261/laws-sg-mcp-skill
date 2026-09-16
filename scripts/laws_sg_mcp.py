#!/usr/bin/env python3
# laws.sg MCP 配置引擎（纯 Python 移植版，Windows / macOS / Linux 通用）
#
# 把「登录/注册 laws.sg → 签发 MCP token → 写入客户端配置 → 验证连通」串成可脚本化流程。
# 接口契约见 ../references/api.md（均为实测或从站点前端源码反编译所得）。
#
# 依赖：仅 Python 3 标准库（不需要 curl / jq / npm / pip）。
#
# 合规自我约束：只调用 auth + token 接口，单次流程个位数请求；严格节流退避；
# 绝不抓取法律语料（语料一律走 MCP）。见 laws.sg/terms §05 Acceptable use。

import datetime
import getpass
import http.cookiejar
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser

# ---------------------------------------------------------------- 常量

BASE_URL = "https://laws.sg"
MCP_URL = BASE_URL + "/api/mcp"
ACCOUNT_PAGE = BASE_URL + "/account#mcp"
SERVER_NAME = "laws-sg"
TOKEN_ENV_VAR = "LAWS_SG_MCP_TOKEN"
TOKEN_PREFIX = "laws_sg"
TOKEN_INPUT_ID = "laws-sg-mcp-token"
TOKEN_DESCRIPTION = "laws.sg MCP token"
UA = "laws-sg-mcp-skill/1.0 (+local setup script)"
THROTTLE = float(os.environ.get("LAWS_SG_THROTTLE", "1.5"))  # 站点限流很紧：实测约 6 次快速请求即 429
SKILL_VERSION = "1.0.0"

IS_WINDOWS = os.name == "nt"


def _default_state_dir():
    if IS_WINDOWS:
        appdata = os.environ.get("APPDATA")
        if appdata:
            return os.path.join(appdata, "laws-sg")
    return os.path.join(os.path.expanduser("~"), ".config", "laws-sg")


STATE_DIR = os.environ.get("LAWS_SG_STATE_DIR") or _default_state_dir()
COOKIE_JAR = os.environ.get("LAWS_SG_COOKIE_JAR") or os.path.join(STATE_DIR, "cookies.txt")

JSON_OUT = False
VERBOSE = False
RESP_BODY = ""          # 最近一次响应体（文本）
RESP_HDR = None         # 最近一次响应头（email.message.Message，get 大小写不敏感）
RESP_STATUS = 0         # 最近一次 HTTP 状态码；0 = 网络层失败
RESULT_TOKEN = ""       # token create/ensure 的结果，走全局而非 stdout（避免与 --json 抢 stdout）
MCP_PV = ""             # initialize 协商出的协议版本；后续请求必须回带，否则服务端会报 Session not found

# 降级信号：调用方（SKILL.md / agent）依据 stderr 里的这一行切换到半自动流程
# FATAL_FALLBACK=False 时只返回 2 而不退出整个脚本，供 setup 内部做「登录失败→改注册」的尝试
FATAL_FALLBACK = True


# ---------------------------------------------------------------- 输出

def info(msg):
    print(msg, file=sys.stderr)


def warn(msg):
    print("[warn] " + msg, file=sys.stderr)


def error(msg):
    print("[error] " + msg, file=sys.stderr)


def die(msg):
    error(msg)
    raise SystemExit(1)


def verbose(msg):
    if VERBOSE:
        info("  · " + msg)


def fallback(msg):
    """打印 FALLBACK 信号；FATAL_FALLBACK 时以退出码 2 结束整个脚本。"""
    print("FALLBACK: manual", file=sys.stderr)
    error(msg)
    error("改走人工路径：浏览器打开 %s 创建 token，再用 verify / env-install / configure 收尾。" % ACCOUNT_PAGE)
    error("（或执行：%s manual --open）" % PROG)
    if FATAL_FALLBACK:
        raise SystemExit(2)
    return 2


def jout(obj):
    if JSON_OUT:
        if isinstance(obj, str):
            print(obj)
        else:
            print(json.dumps(obj, ensure_ascii=False))


PROG = os.path.basename(sys.argv[0]) if sys.argv else "laws_sg_mcp.py"


# ---------------------------------------------------------------- 文件权限（POSIX only，best-effort）

def chmod_best_effort(path, mode):
    if IS_WINDOWS:
        return
    try:
        os.chmod(path, mode)
    except OSError:
        pass


# ---------------------------------------------------------------- 状态目录 / cookie jar

def mkdir_state():
    if not os.path.isdir(STATE_DIR):
        os.makedirs(STATE_DIR, exist_ok=True)
    chmod_best_effort(STATE_DIR, 0o700)
    # cookie jar 里可能存会话凭据，收紧到 0600（POSIX；Windows 无等价物，跳过不报错）
    if not os.path.exists(COOKIE_JAR):
        try:
            open(COOKIE_JAR, "a").close()
        except OSError:
            pass
        chmod_best_effort(COOKIE_JAR, 0o600)


_cookie_jar = None
_opener = None


def _get_jar():
    global _cookie_jar, _opener
    if _cookie_jar is None:
        _cookie_jar = http.cookiejar.MozillaCookieJar(COOKIE_JAR)
        if os.path.exists(COOKIE_JAR):
            try:
                _cookie_jar.load(ignore_discard=True)
            except Exception:
                pass
        _opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(_cookie_jar))
    return _cookie_jar


# ---------------------------------------------------------------- HTTP 层


class NetError(Exception):
    """网络层失败（对应 bash 版的 curl 退出 / HTTP 000）。"""


def _raw_request(method, url, headers, data, use_cookies):
    """发一次请求，返回 (status, body_text, headers_msg)。网络失败抛 NetError。"""
    req = urllib.request.Request(url, data=data, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    opener = None
    if use_cookies:
        _get_jar()
        opener = _opener
    else:
        opener = urllib.request.build_opener()
    try:
        resp = opener.open(req, timeout=40)
        status, body, hdrs = resp.status, resp.read(), resp.headers
    except urllib.error.HTTPError as e:
        status, body, hdrs = e.code, e.read(), e.headers
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        raise NetError(str(e))
    if use_cookies:
        try:
            _cookie_jar.save(ignore_discard=True)
            chmod_best_effort(COOKIE_JAR, 0o600)
        except Exception:
            pass
    return status, body.decode("utf-8", "replace"), hdrs


def api(method, path, body=None, cookies=False):
    """REST API 请求。结果写入 RESP_STATUS / RESP_BODY / RESP_HDR。自带节流 + 429/5xx 退避重试。

    返回 True 表示拿到 HTTP 响应（任何状态码）；False 表示网络层或重试耗尽失败。
    """
    global RESP_STATUS, RESP_BODY, RESP_HDR
    if cookies:
        mkdir_state()
    attempt = 0
    delay = 2
    while True:
        time.sleep(THROTTLE)
        headers = {"User-Agent": UA, "Accept": "application/json, text/event-stream"}
        data = None
        # 浏览器对同源的 mutating 请求会带 Origin；缺失时 /api/account/* 实测返回 403
        if method != "GET":
            headers["Origin"] = BASE_URL
            headers["Referer"] = BASE_URL + "/account"
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = body.encode("utf-8")
        verbose("%s %s (attempt %d)" % (method, path, attempt + 1))
        try:
            RESP_STATUS, RESP_BODY, RESP_HDR = _raw_request(
                method, BASE_URL + path, headers, data, cookies)
        except NetError as e:
            RESP_STATUS, RESP_BODY, RESP_HDR = 0, "", None
            error("网络请求失败：%s" % str(e)[:300])
            return False
        if RESP_STATUS == 429 or 500 <= RESP_STATUS <= 599:
            attempt += 1
            if attempt >= 3:
                error("HTTP %d：重试 %d 次后仍失败 %s %s" % (RESP_STATUS, attempt, method, path))
                return False
            warn("HTTP %d，%ds 后重试（限流或服务端错误）" % (RESP_STATUS, delay))
            time.sleep(delay)
            delay *= 2
            continue
        return True


def resp_field(name):
    """取响应 JSON 顶层标量字段；取不到返回空串。"""
    try:
        d = json.loads(RESP_BODY)
    except Exception:
        return ""
    if not isinstance(d, dict):
        return ""
    v = d.get(name)
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (str, int, float)):
        return str(v)
    return ""


def resp_error():
    e = resp_field("error")
    m = resp_field("message")
    if e:
        return e
    if m:
        return m
    return RESP_BODY[:300]


def hdr_get(name):
    if RESP_HDR is None:
        return ""
    v = RESP_HDR.get(name)
    return v.strip() if v else ""


# ---------------------------------------------------------------- MCP 握手


def mcp_post(payload, sid="", token=""):
    """POST 到 MCP 端点。自带节流 + 429/5xx 退避；返回 False 表示网络层或重试耗尽失败。

    401 等其余状态码都算「拿到响应」，返回 True，由调用方按 RESP_STATUS 分支。
    """
    global RESP_STATUS, RESP_BODY, RESP_HDR
    attempt = 0
    delay = 2
    while True:
        time.sleep(THROTTLE)
        headers = {
            "User-Agent": UA,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if token:
            headers["Authorization"] = "Bearer " + token
        if sid:
            headers["Mcp-Session-Id"] = sid
        # 关键：initialize 之后的请求必须回带协商出的协议版本，否则服务端会话查找失败
        # （实测：不带该头约 2/3 概率回 {"code":-32600,"message":"Session not found"}；带上则稳定成功）
        if MCP_PV:
            headers["MCP-Protocol-Version"] = MCP_PV
        verbose("POST " + MCP_URL)
        try:
            RESP_STATUS, RESP_BODY, RESP_HDR = _raw_request(
                "POST", MCP_URL, headers, payload.encode("utf-8"), False)
        except NetError as e:
            RESP_STATUS, RESP_BODY, RESP_HDR = 0, "", None
            error("MCP 请求失败：%s" % str(e)[:300])
            return False
        if RESP_STATUS == 429 or 500 <= RESP_STATUS <= 599:
            attempt += 1
            if attempt >= 3:
                error("MCP 请求 HTTP %d：重试 %d 次后仍失败" % (RESP_STATUS, attempt))
                return False
            warn("MCP HTTP %d，%ds 后重试" % (RESP_STATUS, delay))
            time.sleep(delay)
            delay *= 2
            continue
        return True


def mcp_message(raw):
    """响应体可能是纯 JSON，也可能是 SSE 帧；解出 JSON-RPC 消息（优先含 result/error 的）。"""
    raw = (raw or "").strip()
    if not raw:
        return None
    cands = [raw] if raw[0] in "{[" else []
    if not cands:
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                d = line[5:].strip()
                if d and d != "[DONE]":
                    cands.append(d)
    best = None
    for c in cands:
        try:
            o = json.loads(c)
        except Exception:
            continue
        best = o
        if isinstance(o, dict) and ("result" in o or "error" in o):
            break
    return best


def parse_init(msg):
    """解析 initialize 结果 → (serverInfo 字符串, protocolVersion)。"""
    try:
        d = msg if isinstance(msg, dict) else json.loads(msg)
    except Exception:
        return "", ""
    r = d.get("result") or {}
    si = r.get("serverInfo") or {}
    name = si.get("name") or "?"
    ver = si.get("version") or ""
    return ("%s %s" % (name, ver)).strip(), (r.get("protocolVersion") or "")


def parse_tools(msg):
    """解析 tools/list → (name 的 JSON 数组字符串, 人类可读行列表)。"""
    try:
        d = msg if isinstance(msg, dict) else json.loads(msg)
    except Exception:
        return "[]", ["  （无法解析 tools/list 响应）"]
    if isinstance(d, dict) and "error" in d:
        return "[]", ["  （tools/list 报错：%s）" % json.dumps(d["error"], ensure_ascii=False)]
    tools = ((d.get("result") or {}).get("tools")) or []
    names = json.dumps([t.get("name") for t in tools], ensure_ascii=False)
    lines = []
    if not tools:
        lines.append("  （服务端未返回工具）")
    for t in tools:
        desc = (t.get("description") or "").strip().splitlines()
        first = desc[0][:100] if desc else ""
        lines.append("  · %s%s" % (t.get("name", "?"), (": " + first) if first else ""))
    return names, lines


# ---------------------------------------------------------------- 会话 / 凭据

EMAIL = ""
PASSWORD = ""
NAME = ""
EXPIRES = ""
TOKEN = ""
CLIENT = "auto"
SCOPE = "user"
DRY_RUN = False
ALLOW_TOOLS = False
SAVE_CREDENTIALS = False
MODE = ""
PROFILE = ""
OPEN_BROWSER = False
TOKEN_INLINE = False
FORCE = False
CONFIG_PATH = ""


def session_active():
    if not api("GET", "/api/auth/get-session", cookies=True):
        return False
    if RESP_STATUS != 200:
        return False
    if RESP_BODY[:4].strip() == "null" or RESP_BODY.lstrip()[:4] == "null":
        return False
    return '"user"' in RESP_BODY


def resolve_credentials():
    global EMAIL, PASSWORD
    if not EMAIL:
        EMAIL = os.environ.get("LAWS_SG_EMAIL", "")
    if not PASSWORD:
        PASSWORD = os.environ.get("LAWS_SG_PASSWORD", "")
    if not EMAIL:
        if not sys.stdin.isatty():
            die("缺少邮箱：用 --email 或设置 LAWS_SG_EMAIL")
        sys.stderr.write("laws.sg 账号邮箱: ")
        sys.stderr.flush()
        EMAIL = sys.stdin.readline().strip()
    if not PASSWORD:
        if not sys.stdin.isatty():
            die("缺少密码：用 --password 或设置 LAWS_SG_PASSWORD（不要把密码写进命令行历史）")
        PASSWORD = getpass.getpass("laws.sg 账号密码（不回显）: ")
    if not EMAIL or not PASSWORD:
        die("邮箱和密码都不能为空")
    if len(PASSWORD) < 8:
        warn("密码短于 8 位；站点前端要求 minLength=8，可能被拒")
    return True


# ---------------------------------------------------------------- 子命令：诊断


def cmd_doctor():
    ok = 0
    n = 0
    problems = []

    def add_problem(p):
        nonlocal ok, n
        problems.append(p)
        n += 1
        ok = 1

    info("laws.sg MCP doctor (v%s)" % SKILL_VERSION)

    # 引擎只依赖 Python 标准库；这里报告解释器本体
    info("  ✓ python3: %s" % (sys.executable or shutil.which("python3") or "python3"))

    if api("GET", "/api/mcp"):
        if RESP_STATUS == 401 and "Missing or invalid laws.sg MCP token" in RESP_BODY:
            info("  ✓ 端点可达：%s（未带 token 如期 401）" % MCP_URL)
        else:
            info("  ? 端点返回 HTTP %d（预期 401）" % RESP_STATUS)
            add_problem("endpoint:%s" % RESP_STATUS)
    else:
        info("  ✗ 端点不可达：%s" % MCP_URL)
        add_problem("endpoint-unreachable")

    tok = os.environ.get(TOKEN_ENV_VAR, "")
    if tok:
        if tok.startswith(TOKEN_PREFIX + "_"):
            info("  ✓ %s 已设置（前缀正确，长度 %d）" % (TOKEN_ENV_VAR, len(tok)))
        else:
            info("  ? %s 已设置但前缀不是 %s_" % (TOKEN_ENV_VAR, TOKEN_PREFIX))
            add_problem("token-prefix")
    else:
        info("  · %s 未设置" % TOKEN_ENV_VAR)

    detect_clients()
    if DETECTED:
        info("  · 探测到 MCP 客户端：%s" % " ".join(DETECTED))
        for c in DETECTED:
            p = client_config_path(c, SCOPE)
            if not p:
                if shutil.which(c) and _run_quiet([c, "mcp", "get", SERVER_NAME]) == 0:
                    info("      ✓ %s 已配置 %s（CLI 管理）" % (c, SERVER_NAME))
                else:
                    info("      · %s 未配置（由其官方 CLI 管理）" % c)
                continue
            if os.path.isfile(p) and _config_has_server(p, c):
                info("      ✓ %s 已配置 %s：%s" % (c, SERVER_NAME, p))
            else:
                info("      · %s 未配置：%s" % (c, p))
    else:
        info("  · 未探测到已知 MCP 客户端（用 snippet 取片段手工接入你的 agent）")

    try:
        if os.path.getsize(COOKIE_JAR) > 0 and "session_token" in open(COOKIE_JAR, encoding="utf-8", errors="replace").read():
            info("  · 已有会话 cookie jar：%s" % COOKIE_JAR)
    except OSError:
        pass

    if ok == 0:
        info("  → 前置条件就绪")
    else:
        warn("发现 %d 个问题：%s" % (n, "|".join(problems)))
    jout({"ok": ok == 0, "problems": problems})
    return ok


def _run_quiet(argv):
    try:
        return subprocess.call(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return 1


def _config_has_server(path, client):
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception:
        return False
    if not isinstance(d, dict):
        return False
    return SERVER_NAME in (d.get(client_root_key(client)) or {})


# ---------------------------------------------------------------- 子命令：登录 / 注册


def cmd_login():
    resolve_credentials()
    mkdir_state()
    body = json.dumps({"email": EMAIL, "password": PASSWORD, "rememberMe": True})

    if not api("POST", "/api/auth/sign-in/email", body, cookies=True):
        return 1
    if RESP_STATUS != 200:
        msg = resp_error()
        error("登录失败 HTTP %d：%s" % (RESP_STATUS, msg))
        if RESP_STATUS in (401, 400):
            fallback("邮箱或密码不被接受（站点统一回「Invalid email or password」，不区分是哪种）。三种可能："
                     "密码打错了；该邮箱还没注册过（可用 --mode signup 注册）；或该账号是用「Continue with Google」"
                     "建的、根本没有密码，邮箱通道对它必然失败。")
        return 1

    info("登录请求已接受，校验会话…")
    if session_active():
        info("✓ 已登录 %s" % EMAIL)
        jout({"ok": True, "email": EMAIL, "signedUp": False})
        return 0
    return fallback("登录返回 200 但 get-session 为 null（可能存在邮箱验证门槛）。")


def cmd_signup():
    global FATAL_FALLBACK
    resolve_credentials()
    mkdir_state()
    name = NAME or (EMAIL.split("@")[0] if EMAIL else "") or "laws.sg user"

    body = json.dumps({"name": name, "email": EMAIL, "password": PASSWORD})

    if not api("POST", "/api/auth/sign-up/email", body, cookies=True):
        return 1
    if RESP_STATUS in (200, 201):
        info("注册请求已接受（HTTP %d），用户名「%s」" % (RESP_STATUS, name))
    else:
        msg = resp_error()
        error("注册失败 HTTP %d：%s" % (RESP_STATUS, msg))
        low = msg.lower()
        if "exist" in low or "already" in low:
            warn("账号可能已存在，改走登录")
            return cmd_login()
        return 1

    if session_active():
        info("✓ 注册并取得会话：%s" % EMAIL)
        jout({"ok": True, "email": EMAIL, "signedUp": True})
        return 0

    warn("注册后 get-session 仍为 null，尝试用密码登录一次…")
    FATAL_FALLBACK = False
    lrc = cmd_login()
    FATAL_FALLBACK = True
    if lrc == 0:
        return 0
    return fallback("注册后拿不到会话，站点可能开启了邮箱验证门槛。")


# ---------------------------------------------------------------- 子命令：token


def cmd_token_create():
    global RESULT_TOKEN
    if not NAME:
        die("缺少 --name（token 名称，3..80 字符，建议填客户端/设备名便于日后吊销）")
    if not (3 <= len(NAME) <= 80):
        die("--name 长度需在 3..80（当前 %d）" % len(NAME))

    # 纯本地校验先做完，再花网络请求去查会话
    expires = None
    if EXPIRES:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", EXPIRES):
            die("--expires 需为 YYYY-MM-DD（收到：%s）" % EXPIRES)
        # 照抄前端构造：新加坡时区当日 23:59:59.999 → UTC ISO
        try:
            d = datetime.datetime.fromisoformat(EXPIRES + "T23:59:59.999+08:00")
        except ValueError:
            die("--expires 需为合法的 YYYY-MM-DD（收到：%s）" % EXPIRES)
        expires = d.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

    if not session_active():
        fallback("没有有效会话，无法签发 token。")

    body = json.dumps({"name": NAME, "expiresAt": expires})

    if not api("POST", "/api/account/mcp-tokens", body, cookies=True):
        return 1
    if RESP_STATUS == 403:
        error("HTTP 403：Origin 校验未通过（脚本已发送 Origin: %s），站点契约可能已变更" % BASE_URL)
        return 1
    if RESP_STATUS not in (200, 201):
        error("签发失败 HTTP %d：%s" % (RESP_STATUS, resp_error()))
        if RESP_STATUS == 401:
            fallback("会话已失效。")
        return 1

    plain = resp_field("plainTextToken")
    if not plain:
        error("响应里没有 plainTextToken，契约可能已变更。原始响应：")
        error(RESP_BODY[:500])
        return 1
    RESULT_TOKEN = plain
    info("✓ 已签发 token「%s」——仅此一次可见，站点不会再次展示" % NAME)
    if JSON_OUT:
        jout({"ok": True, "name": NAME, "plainTextToken": plain})
    else:
        print(plain)
    return 0


def cmd_token_list():
    if not session_active():
        fallback("没有有效会话，无法列出 token。")
    if not api("GET", "/api/account/mcp-tokens", cookies=True):
        return 1
    if RESP_STATUS != 200:
        error("HTTP %d：%s" % (RESP_STATUS, resp_error()))
        return 1
    try:
        d = json.loads(RESP_BODY)
    except Exception:
        error("无法解析响应：%s" % RESP_BODY[:300])
        return 1
    items = d if isinstance(d, list) else ((d.get("tokens") or d.get("data")) or [])
    now = datetime.datetime.now(datetime.timezone.utc)

    def active(t):
        if t.get("revokedAt"):
            return False
        e = t.get("expiresAt")
        if not e:
            return True
        try:
            return datetime.datetime.fromisoformat(str(e).replace("Z", "+00:00")) > now
        except Exception:
            return True

    if JSON_OUT:
        jout({"ok": True, "tokens": items})
        return 0
    if not items:
        print("（该账号下没有 token）")
        return 0
    print("%-6s %-38s %-24s %-22s %s" % ("ACTIVE", "ID", "NAME", "EXPIRES", "REVOKED"))
    for t in items:
        print("%-6s %-38s %-24s %-22s %s" % (
            "yes" if active(t) else "no",
            str(t.get("id", ""))[:38], str(t.get("name", ""))[:24],
            str(t.get("expiresAt") or "never")[:22], t.get("revokedAt") or "-"))
    return 0


def cmd_token_revoke(tok_id=""):
    global FATAL_FALLBACK
    if not tok_id:
        die("用法：token revoke <id>")
    if not session_active():
        fallback("没有有效会话，无法吊销 token。")
    if not api("DELETE", "/api/account/mcp-tokens/%s" % tok_id, cookies=True):
        return 1
    if RESP_STATUS in (200, 204):
        info("✓ 已吊销 token %s" % tok_id)
        jout({"ok": True, "revoked": tok_id})
        return 0
    error("吊销失败 HTTP %d：%s" % (RESP_STATUS, resp_error()))
    return 1


# ---------------------------------------------------------------- 子命令：验证

# 服务端在 initialize 之后的请求上要求回带 MCP-Protocol-Version 头（MCP 2025-06-18 规范要求）。
# 缺这个头时，即便 Mcp-Session-Id 正确，也会回 {"code":-32600,"message":"Session not found"}
# —— 实测缺头约 2/3 概率失败，带头 7/7 成功。这条极易误诊为「服务端会话不稳定」。
# 保留整段握手重试作为兜底，但不要把这种错误当成 token 失效。


def mcp_session_lost():
    return ("Session not found" in RESP_BODY
            or "Missing session ID" in RESP_BODY
            or '"code":-32600' in RESP_BODY)


def cmd_verify(tok=None, quiet=False):
    global MCP_PV
    if tok is None:
        tok = os.environ.get(TOKEN_ENV_VAR, "")
    init = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "laws-sg-mcp-skill", "version": SKILL_VERSION}},
    })

    def say(msg):
        if not quiet:
            info(msg)

    if not tok:
        # 负向断言：确认端点存活、且确实只认 bearer token
        if not mcp_post(init):
            return 1
        if RESP_STATUS == 401 and "Missing or invalid laws.sg MCP token" in RESP_BODY:
            say("✓ 端点存活；未带 token 如期返回 401（www-authenticate: %s）" % hdr_get("WWW-Authenticate"))
            say("· 尚未配置 token —— 这是预期状态，不是故障")
            if not quiet:
                jout({"ok": True, "authenticated": False, "reason": "no-token"})
            return 0
        error("非预期响应 HTTP %d：%s" % (RESP_STATUS, RESP_BODY[:300]))
        if not quiet:
            jout({"ok": False, "authenticated": False, "status": RESP_STATUS})
        return 1

    attempt = 0
    max_attempts = 4
    sinfo = ""
    proto = ""
    while True:
        attempt += 1
        if attempt > 1 and not quiet:
            warn("会话被路由到其他实例（Session not found），重试整段握手 %d/%d" % (attempt, max_attempts))

        if not mcp_post(init, "", tok):
            return 1
        if RESP_STATUS == 401:
            error("token 被拒（HTTP 401）：%s" % RESP_BODY[:200])
            error("多半是已吊销、已过期，或复制时缺字符。重新签发一个即可。")
            if not quiet:
                jout({"ok": False, "authenticated": False, "reason": "token-rejected"})
            return 1
        if RESP_STATUS != 200:
            error("initialize 返回 HTTP %d：%s" % (RESP_STATUS, RESP_BODY[:300]))
            if not quiet:
                jout({"ok": False, "status": RESP_STATUS})
            return 1

        sid = hdr_get("Mcp-Session-Id")
        msg = mcp_message(RESP_BODY)
        sinfo, proto = parse_init(msg)
        MCP_PV = proto or "2025-06-18"   # 后续请求回带协商版本
        if attempt == 1:
            say("✓ initialize 成功：serverInfo=%s protocolVersion=%s" % (sinfo or "unknown", proto or "unknown"))
            if sid:
                say("  · Mcp-Session-Id: %s" % sid)

        mcp_post(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}), sid, tok)
        verbose("notifications/initialized → HTTP %d" % RESP_STATUS)

        if not mcp_post(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}), sid, tok):
            return 1
        if RESP_STATUS == 200 and not mcp_session_lost():
            break
        if RESP_STATUS != 200 and not mcp_session_lost():
            if not quiet:
                warn("tools/list 返回 HTTP %d；initialize 已成功，token 确认有效" % RESP_STATUS)
                jout({"ok": True, "authenticated": True, "tools": None})
            return 0
        if attempt >= max_attempts:
            error("连续 %d 次都拿不到 tools/list（服务端会话路由不稳定）。" % max_attempts)
            error("但 initialize 已成功、token 有效 —— MCP 客户端自己会重连，配置可用。")
            if not quiet:
                jout({"ok": True, "authenticated": True, "tools": None, "note": "session-routing-flaky"})
            return 0
        time.sleep(2)

    names, lines = parse_tools(mcp_message(RESP_BODY))
    say("✓ 可用 MCP 工具：")
    if not quiet:
        for ln in lines:
            info(ln)
        jout({"ok": True, "authenticated": True, "serverInfo": sinfo,
              "protocolVersion": proto, "tools": json.loads(names) if names != "[]" else []})
    return 0


# 幂等：现有 token 能用就复用（plainTextToken 只在创建时返回一次，丢了无法找回）
def cmd_token_ensure():
    existing = os.environ.get(TOKEN_ENV_VAR, "")
    if existing:
        info("检测到 %s 已设置，先验证是否可用…" % TOKEN_ENV_VAR)
        if cmd_verify(existing, quiet=True) == 0:
            info("✓ 现有 token 有效，直接复用（不签发新 token）")
            RESULT_TOKEN = existing
            if JSON_OUT:
                jout({"ok": True, "reused": True})
            else:
                print(existing)
            return 0
        warn("现有 token 无效，将签发新的")
    rc = cmd_token_create()
    if rc != 0:
        return rc
    if not JSON_OUT:
        print(RESULT_TOKEN)
    return 0


# ---------------------------------------------------------------- 客户端适配层
#
# 本 Skill 不绑定任何 agent。客户端分三类处理：
#   1) JSON 配置型 —— 有权威格式来源，脚本直接合并写入
#   2) CLI 型      —— 官方提供了 add 命令，脚本调用该命令（二进制不在则打印命令）
#   3) 未知客户端  —— 一律只输出片段，由 agent/用户自行适配。**绝不猜格式**
#
# 格式来源：kimi-code 取自其官方文档；cursor / vscode / claude / codex / generic
# 取自 laws.sg 的 /legal-ai 页面官方 snippet（见 references/clients.md）。

CLIENTS_JSON = ["kimi-code", "cursor", "vscode", "generic"]
CLIENTS_CLI = ["claude", "codex"]
CLIENTS_ALL = ["kimi-code", "claude", "codex", "cursor", "vscode", "generic"]

DETECTED = []
CONFIGURED = ""


def client_installed(name):
    home = os.path.expanduser("~")
    if name == "kimi-code":
        kimi_home = os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code")
        return os.path.isdir(kimi_home) or bool(shutil.which("kimi"))
    if name == "claude":
        return (bool(shutil.which("claude"))
                or os.path.exists(os.path.join(home, ".claude.json"))
                or os.path.isdir(os.path.join(home, ".claude")))
    if name == "codex":
        return bool(shutil.which("codex")) or os.path.isdir(os.path.join(home, ".codex"))
    if name == "cursor":
        return os.path.isdir(os.path.join(home, ".cursor")) or (
            not IS_WINDOWS and os.path.isdir("/Applications/Cursor.app"))
    if name == "vscode":
        return bool(shutil.which("code")) or (
            not IS_WINDOWS and os.path.isdir("/Applications/Visual Studio Code.app"))
    return False   # generic 通用片段不算「已安装」，只在显式指定时写


def client_config_path(name, scope="user"):
    home = os.path.expanduser("~")
    cwd = os.getcwd()
    scope = scope or "user"
    if name == "kimi-code":
        if scope == "project":
            return os.path.join(cwd, ".kimi-code", "mcp.json")
        return os.path.join(os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code"), "mcp.json")
    if name == "cursor":
        if scope == "project":
            return os.path.join(cwd, ".cursor", "mcp.json")
        return os.path.join(home, ".cursor", "mcp.json")
    if name == "vscode":
        return os.path.join(cwd, ".vscode", "mcp.json")  # VS Code 是工作区级，无 user/project 之分
    if name == "generic":
        return CONFIG_PATH or os.path.join(cwd, ".mcp.json")
    return ""   # CLI 型客户端由自己的命令管理文件


# 写入 JSON 时的根键：多数客户端是 mcpServers，VS Code 是 servers
def client_root_key(name):
    return "servers" if name == "vscode" else "mcpServers"


def client_entry(name):
    """该客户端的 server 条目（dict）。默认用环境变量引用，配置文件里不落明文 token；
    --token-inline 时才写字面值（给不支持 env 展开的客户端用）。
    值为 None 的键表示「删掉这个键」—— 避免在 env 引用与明文之间切换时残留旧鉴权字段。"""
    if TOKEN_INLINE:
        bearer = os.environ.get(TOKEN_ENV_VAR) or RESULT_TOKEN
        if not bearer:
            bearer = TOKEN_PREFIX + "_REPLACE_WITH_YOUR_TOKEN"
    else:
        bearer = "${%s}" % TOKEN_ENV_VAR
    if name == "kimi-code":
        if TOKEN_INLINE:
            return {"url": MCP_URL, "headers": {"Authorization": "Bearer " + bearer},
                    "bearerTokenEnvVar": None, "enabled": True}
        # kimi-code 有专门的 bearerTokenEnvVar 字段，比 headers 更干净
        return {"url": MCP_URL, "bearerTokenEnvVar": TOKEN_ENV_VAR, "headers": None, "enabled": True}
    if name == "vscode":
        return {"type": "http", "url": MCP_URL,
                "headers": {"Authorization": "Bearer ${input:%s}" % TOKEN_INPUT_ID}}
    return {"type": "streamable-http", "url": MCP_URL,
            "headers": {"Authorization": "Bearer " + bearer}, "bearerTokenEnvVar": None}


def client_extra(name):
    # VS Code 需要额外声明一个 promptString input（首次使用时弹窗索取 token）
    if name == "vscode":
        return {"inputs": [{"type": "promptString", "id": TOKEN_INPUT_ID,
                            "description": TOKEN_DESCRIPTION, "password": True}]}
    return {}


def write_json_client(name):
    """JSON 合并写 → 0 成功 / 1 失败 / 3 原文件损坏"""
    global CONFIGURED
    path = client_config_path(name, SCOPE)
    if not path:
        error("%s：无法确定配置路径" % name)
        return 1
    root = client_root_key(name)
    entry = client_entry(name)
    extra = client_extra(name)

    data = {}
    if os.path.exists(path):
        raw = open(path, encoding="utf-8").read().strip()
        if raw:
            try:
                data = json.loads(raw)
            except Exception as e:
                error("%s 不是合法 JSON，已放弃写入（避免破坏现有配置）：%s" % (path, e))
                error("请手工修复后重试，或用 --dry-run 查看预期结果")
                return 3
    if not isinstance(data, dict):
        data = {}
    servers = data.get(root)
    if not isinstance(servers, dict):
        servers = {}
    cur = servers.get(SERVER_NAME)
    if not isinstance(cur, dict):
        cur = {}
    cur.update(entry)
    cur = {k: v for k, v in cur.items() if v is not None}   # 值为 null 表示删除该键
    servers[SERVER_NAME] = cur
    data[root] = servers
    # 合并额外顶层字段（如 VS Code 的 inputs），按 id 去重追加
    for k, v in extra.items():
        if isinstance(v, list):
            have = data.get(k)
            if not isinstance(have, list):
                have = []
            ids = {i.get("id") for i in have if isinstance(i, dict)}
            for item in v:
                if isinstance(item, dict) and item.get("id") not in ids:
                    have.append(item)
            data[k] = have
        else:
            data.setdefault(k, v)
    out = json.dumps(data, indent=2, ensure_ascii=False) + "\n"

    if DRY_RUN:
        print("PATH:" + path)
        print(out, end="")
        info("· [dry-run] %s → %s" % (name, path))
        for ln in out.rstrip("\n").splitlines():
            info("    " + ln)
        return 0

    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak." + time.strftime("%Y%m%d%H%M%S"))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    chmod_best_effort(tmp, 0o600)
    os.replace(tmp, path)

    info("✓ %s：已写入 %s" % (name, path))
    CONFIGURED += ("," if CONFIGURED else "") + name
    return 0


def run_cli_client(name):
    """CLI 型客户端 → 0 已执行 / 1 失败 / 4 二进制缺失（改为打印命令）"""
    global CONFIGURED
    if name == "claude":
        if not shutil.which("claude"):
            print(snippet_text("claude"))
            return 4
        scope_args = []
        if SCOPE == "user":
            scope_args = ["-s", "user"]
        elif SCOPE == "project":
            scope_args = ["-s", "project"]
        if DRY_RUN:
            info("· [dry-run] %s：将执行下面这条命令（未执行）" % name)
            for ln in snippet_text("claude").rstrip("\n").splitlines():
                info("    " + ln)
            if scope_args:
                info("    （实际执行时会附加 %s %s）" % tuple(scope_args))
            return 0
        if _run_quiet(["claude", "mcp", "get", SERVER_NAME]) == 0:
            if not FORCE:
                info("· %s：已存在 %s 条目，跳过（加 --force 覆盖）" % (name, SERVER_NAME))
                CONFIGURED += ("," if CONFIGURED else "") + name + "(已存在)"
                return 0
            _run_quiet(["claude", "mcp", "remove", SERVER_NAME])
        # 单引号让 ${LAWS_SG_MCP_TOKEN} 原样存进配置，由 Claude Code 运行时展开
        rc = subprocess.call([
            "claude", "mcp", "add", "--transport", "http"] + scope_args + [
            SERVER_NAME, MCP_URL,
            "--header", "Authorization: Bearer ${%s}" % TOKEN_ENV_VAR])
        if rc == 0:
            info("✓ %s：已通过 claude mcp add 注册 %s" % (name, SERVER_NAME))
            CONFIGURED += ("," if CONFIGURED else "") + name
            return 0
        error("%s：claude mcp add 失败" % name)
        return 1
    if name == "codex":
        if not shutil.which("codex"):
            print(snippet_text("codex"))
            return 4
        if DRY_RUN:
            info("· [dry-run] %s：将执行下面这条命令（未执行）" % name)
            for ln in snippet_text("codex").rstrip("\n").splitlines():
                info("    " + ln)
            return 0
        rc = subprocess.call(["codex", "mcp", "add", SERVER_NAME,
                              "--url", MCP_URL, "--bearer-token-env-var", TOKEN_ENV_VAR])
        if rc == 0:
            info("✓ %s：已通过 codex mcp add 注册 %s" % (name, SERVER_NAME))
            CONFIGURED += ("," if CONFIGURED else "") + name
            return 0
        error("%s：codex mcp add 失败（条目可能已存在，请先 codex mcp remove %s）" % (name, SERVER_NAME))
        return 1
    error("未知 CLI 客户端：%s" % name)
    return 1


# 探测本机装了哪些客户端；结果写入 DETECTED
def detect_clients():
    global DETECTED
    DETECTED = [c for c in CLIENTS_ALL if client_installed(c)]


def cmd_client_list():
    detect_clients()
    info("本机 MCP 客户端探测结果：")
    for c in CLIENTS_ALL:
        mark = "✓ 已安装" if client_installed(c) else "· 未检测到"
        p = client_config_path(c, SCOPE)
        if p:
            if os.path.isfile(p) and _config_has_server(p, c):
                mark += "，且已配置 %s" % SERVER_NAME
            sys.stderr.write("  %-10s %s\n               %s\n" % (c, mark, p))
        else:
            sys.stderr.write("  %-10s %s（由官方 CLI 管理）\n" % (c, mark))
    if not DETECTED:
        info("  （一个都没检测到 —— 用 snippet 拿片段手工接入你的 agent）")
    jout({"detected": DETECTED})
    return 0


# ---------------------------------------------------------------- env-install


def login_shell():
    """判定真实登录 shell。POSIX 上 $SHELL 不可信（子进程包装器常改写它）：
    macOS 用 dscl 兜底，其余用 $SHELL；Windows 无此概念，返回空。"""
    if IS_WINDOWS:
        return ""
    if sys.platform == "darwin":
        try:
            out = subprocess.check_output(
                ["dscl", ".", "-read", "/Users/" + os.environ.get("USER", ""), "UserShell"],
                stderr=subprocess.DEVNULL).decode("utf-8", "replace")
            parts = out.split()
            if len(parts) >= 2:
                return os.path.basename(parts[1])
        except Exception:
            pass
    s = os.environ.get("SHELL", "")
    if s:
        return os.path.basename(s)
    return "zsh"


def shell_profile():
    if PROFILE:
        return PROFILE
    home = os.path.expanduser("~")
    sh = login_shell()
    if sh == "zsh":
        return os.path.join(home, ".zshrc")
    if sh == "bash":
        bp = os.path.join(home, ".bash_profile")
        return bp if os.path.isfile(bp) else os.path.join(home, ".bashrc")
    return os.path.join(home, ".profile")


def cmd_env_install():
    global EMAIL, PASSWORD
    tok = TOKEN or RESULT_TOKEN or os.environ.get(TOKEN_ENV_VAR, "")
    if not tok:
        die("没有 token 可写：先 token create 拿到，或用 --token 传入")

    if IS_WINDOWS:
        # Windows 没有 shell profile 概念：用 setx 写入用户级环境变量。
        # token 短，不会碰到 setx 1024 字符截断问题。
        rc = subprocess.call(["setx", TOKEN_ENV_VAR, tok])
        if rc != 0:
            error("setx 失败（退出码 %d）" % rc)
            return 1
        info("✓ 已通过 setx 写入用户环境变量 %s" % TOKEN_ENV_VAR)
        info("  ⚠ 仅对【新开的终端 / 新启动的程序】生效；已打开的窗口请重开")
        if SAVE_CREDENTIALS:
            warn("--save-credentials 在 Windows 上不支持（setx 只写 token），已跳过邮箱/密码持久化")
        if PROFILE:
            warn("--profile 仅 POSIX 有效，Windows 上已忽略")
        jout({"ok": True, "profile": None})
        return 0

    pf = shell_profile()
    if not pf:
        die("无法确定 shell profile")
    home = os.path.expanduser("~")
    if not os.path.isfile(pf):
        warn("目标 profile %s 不存在，将新建（登录 shell 判定为 %s）" % (pf, login_shell() or "unknown"))
        zshrc = os.path.join(home, ".zshrc")
        if os.path.isfile(zshrc) and pf != zshrc:
            warn("但 %s 是存在的 —— 若你的登录 shell 其实是 zsh，请改用 --profile %s" % (zshrc, zshrc))
    if SAVE_CREDENTIALS:
        if not EMAIL:
            EMAIL = os.environ.get("LAWS_SG_EMAIL", "")
        if not PASSWORD:
            PASSWORD = os.environ.get("LAWS_SG_PASSWORD", "")
        warn("将把邮箱与密码以【明文】写入 %s（你显式传了 --save-credentials）" % pf)

    begin = "# >>> laws.sg MCP (managed by laws-sg-mcp skill) >>>"
    end = "# <<< laws.sg MCP <<<"
    lines = ['export %s="%s"' % (TOKEN_ENV_VAR, tok)]
    if SAVE_CREDENTIALS and EMAIL:
        lines.append('export LAWS_SG_EMAIL="%s"' % EMAIL)
        lines.append('export LAWS_SG_PASSWORD="%s"' % PASSWORD)
    block = "\n".join([begin] + lines + [end])

    old = ""
    if os.path.exists(pf):
        old = open(pf, encoding="utf-8", errors="replace").read()
        shutil.copy2(pf, pf + ".bak." + time.strftime("%Y%m%d%H%M%S"))
    pat = re.compile(r"\n?" + re.escape(begin) + r".*?" + re.escape(end) + r"\n?", re.S)
    new = pat.sub("\n", old) if old else ""
    new = new.rstrip("\n")
    new = (new + "\n\n" if new else "") + block + "\n"
    d = os.path.dirname(pf)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = pf + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new)
    chmod_best_effort(tmp, 0o600)
    os.replace(tmp, pf)

    info("✓ 已写入 %s（托管块；重复执行原地替换，旧文件已备份）" % pf)
    info("  新 shell 会自动带上 %s；当前 shell 请执行：source %s" % (TOKEN_ENV_VAR, pf))
    jout({"ok": True, "profile": pf})
    return 0


# ---------------------------------------------------------------- configure


def cmd_configure():
    global CONFIGURED
    CONFIGURED = ""
    rc_any = 0
    spec = CLIENT
    if spec == "auto":
        detect_clients()
        targets = list(DETECTED)
        if not targets:
            warn("--client auto 没探测到任何已知客户端")
            info("可用客户端：%s" % " ".join(CLIENTS_ALL))
            info("请用 snippet 取片段手工接入你的 agent：")
            for c in CLIENTS_ALL:
                info("  %s snippet --client %s" % (PROG, c))
            jout({"ok": False, "reason": "no-client-detected"})
            return 1
        info("探测到客户端：%s" % " ".join(targets))
    elif spec == "all":
        targets = list(CLIENTS_ALL)
    else:
        targets = [t for t in spec.split(",") if t]

    for c in targets:
        if c not in CLIENTS_ALL:
            error("未知客户端：%s（可用：%s，或 auto / all）" % (c, " ".join(CLIENTS_ALL)))
            rc_any = 1
            continue
        if c in CLIENTS_CLI:
            rc = run_cli_client(c)
            if rc == 4:
                info("· %s：未找到其 CLI，已打印官方命令，请手工执行" % c)
            elif rc != 0:
                rc_any = 1
        else:
            if write_json_client(c) != 0:
                rc_any = 1

    if CONFIGURED:
        info("已配置：%s" % CONFIGURED)
        if not TOKEN_INLINE:
            info("token 通过环境变量 %s 间接引用，配置文件里没有明文" % TOKEN_ENV_VAR)
            info("→ 请先跑 env-install（或自行 export），否则客户端取不到 token")
        else:
            warn("--token-inline：token 已明文写入配置文件，注意文件权限与提交风险")
        info("⚠ 多数 agent 只在会话启动时加载 MCP 配置 → 请重启 agent / 重新加载 MCP 后再验证")
    if ALLOW_TOOLS:
        kimi_allow_tools()
    jout({"ok": rc_any == 0, "configured": CONFIGURED, "scope": SCOPE})
    return rc_any


# kimi-code 专属的可选项：免审批放行该 server 的工具。其他 agent 有自己的权限机制。
def kimi_allow_tools():
    home = os.path.expanduser("~")
    cfg = os.path.join(os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code"), "config.toml")
    pattern = "mcp__%s__*" % SERVER_NAME
    if not client_installed("kimi-code"):
        warn("--allow-tools 只对 kimi-code 生效，且未检测到 kimi-code，跳过")
        return 0
    if not os.path.isfile(cfg):
        warn("未找到 %s，跳过 permission rule" % cfg)
        return 0
    try:
        text = open(cfg, encoding="utf-8", errors="replace").read()
    except OSError:
        return 1
    if pattern in text:
        info("· permission rule 已存在，跳过")
        return 0
    shutil.copy2(cfg, cfg + ".bak." + time.strftime("%Y%m%d%H%M%S"))
    with open(cfg, "a", encoding="utf-8") as f:
        f.write('\n[[permission.rules]]\ndecision = "allow"\npattern = "%s"\n' % pattern)
    info("✓ kimi-code：已追加 permission rule allow %s（原文件已备份）" % pattern)
    info("  注意 report_issue 是写操作，如需收紧再单独 deny mcp__%s__report_issue" % SERVER_NAME)
    return 0


# ---------------------------------------------------------------- 子命令：片段 / 人工路径

def snippet_text(client):
    shown = os.environ.get(TOKEN_ENV_VAR) or RESULT_TOKEN
    if not shown:
        shown = TOKEN_PREFIX + "_REPLACE_WITH_YOUR_TOKEN"
    if client == "kimi-code":
        return """// ~/.kimi-code/mcp.json（项目级：./.kimi-code/mcp.json，项目级覆盖用户级）
{
  "mcpServers": {
    "%s": {
      "url": "%s",
      "bearerTokenEnvVar": "%s"
    }
  }
}
// 也可在 TUI 里 /mcp-config 交互式添加，/mcp 查看连接状态
""" % (SERVER_NAME, MCP_URL, TOKEN_ENV_VAR)
    if client == "claude":
        return """export %s=%s
claude mcp add --transport http %s %s --header "Authorization: Bearer ${%s}"
""" % (TOKEN_ENV_VAR, shown, SERVER_NAME, MCP_URL, TOKEN_ENV_VAR)
    if client == "codex":
        return """export %s=%s
codex mcp add %s --url %s --bearer-token-env-var %s
""" % (TOKEN_ENV_VAR, shown, SERVER_NAME, MCP_URL, TOKEN_ENV_VAR)
    if client == "cursor":
        return """// ~/.cursor/mcp.json —— 保留 ${%s} 引用并在环境里 export，或直接替换为 token 本身
{
  "mcpServers": {
    "%s": {
      "type": "streamable-http",
      "url": "%s",
      "headers": { "Authorization": "Bearer ${%s}" }
    }
  }
}
""" % (TOKEN_ENV_VAR, SERVER_NAME, MCP_URL, TOKEN_ENV_VAR)
    if client == "vscode":
        return """// .vscode/mcp.json —— VS Code 首次使用时弹窗索取 token，token 不落文件
{
  "inputs": [
    { "type": "promptString", "id": "%s", "description": "%s", "password": true }
  ],
  "servers": {
    "%s": {
      "type": "http",
      "url": "%s",
      "headers": { "Authorization": "Bearer ${input:%s}" }
    }
  }
}
""" % (TOKEN_INPUT_ID, TOKEN_DESCRIPTION, SERVER_NAME, MCP_URL, TOKEN_INPUT_ID)
    if client in ("json", "other", "generic"):
        return """{
  "mcpServers": {
    "%s": {
      "type": "streamable-http",
      "url": "%s",
      "headers": { "Authorization": "Bearer %s" }
    }
  }
}
""" % (SERVER_NAME, MCP_URL, shown)
    error("未知客户端：%s（可用：%s，或 all）" % (client, " ".join(CLIENTS_ALL)))
    return None


def cmd_snippet():
    if CLIENT == "all":
        for c in CLIENTS_ALL:
            info("### %s" % c)
            text = snippet_text(c)
            if text is None:
                return 1
            print(text)
    else:
        text = snippet_text(CLIENT)
        if text is None:
            return 1
        print(text, end="")
    return 0


def cmd_manual():
    print("""半自动路径（人工只做 2 件事：浏览器点几下 + 粘贴一次 token）

  1. 打开 %s
     登录（邮箱密码，或「Continue with Google」）
     → Token name 填 3..80 字符（建议客户端/设备名，便于日后吊销）
     → Expiry 可留空（永不过期）
     → 创建，复制以 %s_ 开头的 token（页面只显示一次）

  2. 把 token 交给脚本，剩下全自动：
       %s verify   %s_xxxx
       %s env-install --token %s_xxxx
       %s configure --client auto      # 自动探测本机装了哪些 MCP 客户端
       %s clients                      # 只想看探测结果、不写入

  之后重启你的 agent（多数 agent 只在会话启动时加载 MCP 配置），%s 就会出现。
""" % (ACCOUNT_PAGE, TOKEN_PREFIX,
       PROG, TOKEN_PREFIX, PROG, TOKEN_PREFIX, PROG, PROG, SERVER_NAME))
    if OPEN_BROWSER:
        try:
            webbrowser.open(ACCOUNT_PAGE)
            info("已在浏览器打开 %s" % ACCOUNT_PAGE)
        except Exception as e:
            warn("无法打开浏览器：%s（请手动访问 %s）" % (e, ACCOUNT_PAGE))
    return 0


# ---------------------------------------------------------------- 子命令：编排


def cmd_setup():
    global TOKEN, FATAL_FALLBACK
    info("=== laws.sg MCP 全自动配置 ===")
    if cmd_doctor() != 0:
        warn("doctor 报告了问题，仍继续尝试")

    if os.environ.get(TOKEN_ENV_VAR) and cmd_verify(quiet=True) == 0:
        info("✓ %s 已存在且有效 —— 跳过登录与签发" % TOKEN_ENV_VAR)
        RESULT_TOKEN = os.environ[TOKEN_ENV_VAR]
    else:
        if MODE == "signup":
            rc = cmd_signup()
            if rc != 0:
                return rc
        elif MODE == "login":
            rc = cmd_login()
            if rc != 0:
                return rc
        elif MODE in ("auto", ""):
            resolve_credentials()
            info("先尝试登录；账号不存在则自动注册")
            FATAL_FALLBACK = False
            lrc = cmd_login()
            FATAL_FALLBACK = True
            if lrc == 0:
                info("✓ 已登录 %s" % EMAIL)
            else:
                warn("登录未成功（多半是该邮箱还没注册过），改为注册新账号")
                rc = cmd_signup()
                if rc != 0:
                    return rc
        else:
            die("未知 --mode：%s（可选 auto|login|signup）" % MODE)

        rc = cmd_token_ensure()
        if rc != 0:
            return rc
        if RESULT_TOKEN.startswith(TOKEN_PREFIX + "_"):
            os.environ[TOKEN_ENV_VAR] = RESULT_TOKEN
            info("✓ 已取得 token（长度 %d）" % len(RESULT_TOKEN))
        else:
            error("拿到的不是合法 token（应以 %s_ 开头）" % TOKEN_PREFIX)
            return 1

    TOKEN = RESULT_TOKEN
    if cmd_env_install() != 0:
        return 1
    if cmd_configure() != 0:
        return 1

    info("=== 验证 MCP 连通性 ===")
    if cmd_verify() != 0:
        return 1

    info("")
    info("=== 完成 ===")
    info("重启你的 agent（多数 agent 只在会话启动时加载 MCP 配置），%s 就会出现" % SERVER_NAME)
    info("已配置的客户端：%s；探测详情可跑：%s clients" % (CONFIGURED or "（无）", PROG))
    if not SAVE_CREDENTIALS:
        info("本次未持久化密码；日后重新签发 token 需再次提供凭据")
    return 0


# ---------------------------------------------------------------- 入口

USAGE = """laws.sg MCP 配置引擎 v%s

用法：%s <command> [options]

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
                                           幂等写入 shell profile 托管块（Windows：setx 用户环境变量）
  configure [--client auto|all|<名字>[,<名字>...]] [--scope user|project]
            [--token-inline] [--force] [--path FILE] [--allow-tools] [--dry-run]
                                           写入客户端配置。auto=只写探测到的；默认 token 走环境变量引用不落明文
  snippet [--client <名字>|all]            只打印片段，不落盘

  可写入的客户端：%s
  其中 claude / codex 走各自的官方 CLI 命令；kimi-code / cursor / vscode / generic 走 JSON 合并写。
  未列出的 agent 一律用 snippet 拿通用片段自行接入 —— 脚本不猜格式。

编排 / 诊断
  setup [--mode auto|login|signup] [--client ...] [--scope ...]
                                           全自动：doctor → 登录/注册 → 签发 → env → 配置 → 验证
  doctor                                   前置条件 + 客户端探测
  manual [--open]                          打印半自动降级步骤（--open 同时打开浏览器）

全局选项：--json 结构化输出；-v/--verbose 详细日志
退出码：0 成功 / 1 失败 / 2 需人工降级（stderr 打印 FALLBACK: manual）
""" % (SKILL_VERSION, PROG, " ".join(CLIENTS_ALL))


def main():
    global JSON_OUT, VERBOSE, EMAIL, PASSWORD, NAME, EXPIRES, TOKEN, CLIENT, SCOPE
    global DRY_RUN, ALLOW_TOOLS, SAVE_CREDENTIALS, MODE, PROFILE, OPEN_BROWSER
    global TOKEN_INLINE, FORCE, CONFIG_PATH, FATAL_FALLBACK

    argv = sys.argv[1:]
    cmd = argv[0] if argv else ""
    if argv:
        argv = argv[1:]

    if cmd in ("", "help", "-h", "--help"):
        print(USAGE)
        return 0

    positional = []
    i = 0
    value_opts = {"--email": "EMAIL", "--password": "PASSWORD", "--name": "NAME",
                  "--expires": "EXPIRES", "--token": "TOKEN", "--client": "CLIENT",
                  "--scope": "SCOPE", "--mode": "MODE", "--profile": "PROFILE",
                  "--path": "CONFIG_PATH"}
    flag_opts = {"--json": "JSON_OUT", "-v": "VERBOSE", "--verbose": "VERBOSE",
                 "--dry-run": "DRY_RUN", "--allow-tools": "ALLOW_TOOLS",
                 "--save-credentials": "SAVE_CREDENTIALS", "--token-inline": "TOKEN_INLINE",
                 "--force": "FORCE", "--open": "OPEN_BROWSER"}
    while i < len(argv):
        a = argv[i]
        if a in value_opts:
            val = argv[i + 1] if i + 1 < len(argv) else ""
            globals()[value_opts[a]] = val
            i += 1
        elif a in flag_opts:
            globals()[flag_opts[a]] = True
        elif a in ("-h", "--help"):
            print(USAGE)
            return 0
        elif a == "--":
            positional.extend(argv[i + 1:])
            break
        elif a.startswith("-"):
            die("未知选项：%s" % a)
        else:
            positional.append(a)
        i += 1

    if cmd == "doctor":
        return cmd_doctor()
    if cmd == "clients":
        return cmd_client_list()
    if cmd == "login":
        return cmd_login()
    if cmd == "signup":
        return cmd_signup()
    if cmd == "verify":
        return cmd_verify(positional[0] if positional else None)
    if cmd == "env-install":
        return cmd_env_install()
    if cmd == "configure":
        return cmd_configure()
    if cmd == "snippet":
        return cmd_snippet()
    if cmd == "setup":
        return cmd_setup()
    if cmd == "manual":
        return cmd_manual()
    if cmd == "token":
        sub = positional[0] if positional else ""
        if sub == "create":
            return cmd_token_create()
        if sub == "list":
            return cmd_token_list()
        if sub == "revoke":
            return cmd_token_revoke(positional[1] if len(positional) > 1 else "")
        if sub == "ensure":
            return cmd_token_ensure()
        die("token 子命令需为 create|list|revoke|ensure（收到：%s）" % (sub or "空"))
    error("未知命令：%s" % cmd)
    print(USAGE, file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
