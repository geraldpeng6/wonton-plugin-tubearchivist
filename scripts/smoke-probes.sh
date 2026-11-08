# shellcheck shell=bash
# TubeArchivist：sso=proxy（网关给登录用户代带 Remote-User: <secrets.ta_user>，应用按这个头
# 自动建会话，见 docker-compose.yml 文件头）；清单没有 mcp。
#
# 数据探针用应用自己的设置接口写一条配置（存进 Elasticsearch），升级和重装后读回来对得上。
# 会话由套件助手建立：dweb --sso 走完整交接链（核心令牌登录 → 网关自动表单 → 应用），
# jar 里带上 wonton_app 和应用种的 sessionid、csrftoken（Django SessionAuthentication
# 的写请求要 CSRF）。探针只用套件保证的 SMOKE_* 变量和 web_get/dweb 助手。

web_assert() { grep -qi 'tubearchivist'; }   # 标准输入：应用真实页面（SPA 的 index.html）

_tb_url() { printf '%s' "${SMOKE_WEB_URL%/}"; } # 套件给的 web_url 带尾斜杠，拼 API 路径前归一化

_tb_get() { # <路径> [curl 参数…]：带应用会话走网关调 API；不归一化会把 //api/... 打到 SPA 兜底路由上
  local path="$1"
  shift
  curl -sS --noproxy '*' --max-time 60 --fail-with-body -b "${SMOKE_JAR:-}" "$@" "$( _tb_url )$path"
}

_tb_prep() {  # 建立应用会话：jar 里要有应用种的 csrftoken
  [[ -n "${SMOKE_JAR:-}" ]] || { echo "SMOKE_JAR 没设置"; return 1; }
  local log
  log="$(dweb --sso / 2>&1 >/dev/null)" || { echo "走不通网关代登录链：${log:-（无输出）}"; return 1; }
  grep -q csrftoken "$SMOKE_JAR" ||
    { echo "应用会话没建立（jar 里没有 csrftoken，代登录头没生效？）"; return 1; }
}

_tb_csrf() { awk '$6 == "csrftoken" {print $7; exit}' "$SMOKE_JAR"; }

identity_check() {  # /api/user/account/ 只回给已登录会话：200 且是管理员说明代登录头生效
  _tb_prep || return 1
  local out
  out="$( _tb_get /api/user/account/ )" ||
    { echo "GET /api/user/account/ 失败：$out"; return 1; }
  jq -e '.is_staff == true and .is_superuser == true' <<<"$out" >/dev/null ||
    { echo "应用认出的账号不是管理员：$out"; return 1; }
}

# 数据：应用设置存在 Elasticsearch 里，升级、重装都保留。订阅页大小写成哨兵值 99（默认 67、
# 范围 60-100），data_check 读回还是 99 就说明写进去的设置活着；标记值是确定性的，
# 不依赖 SMOKE_STATE 的形态（套件马上要统一它）。
TB_SENTINEL=99

data_write() {
  local out tok
  _tb_prep || return 1
  tok="$(_tb_csrf)"
  [[ -n "$tok" ]] || { echo "会话里没有 csrftoken"; return 1; }
  out="$( _tb_get /api/appsettings/config/ \
    -H 'Content-Type: application/json' -H "X-CSRFToken: $tok" \
    -X POST -d "{\"subscriptions\":{\"channel_size\":$TB_SENTINEL}}" )" ||
    { echo "POST /api/appsettings/config/ 失败：$out"; return 1; }
  echo "已把订阅页大小写成 $TB_SENTINEL"
}

data_check() {
  local out got tok
  _tb_prep || return 1
  out="$( _tb_get /api/appsettings/config/ )" ||
    { echo "GET /api/appsettings/config/ 失败：$out"; return 1; }
  got="$(jq -r '.subscriptions.channel_size // empty' <<<"$out")"
  [[ "$got" == "$TB_SENTINEL" ]] ||
    { echo "设置对不上：期望 channel_size=$TB_SENTINEL，读到 ${got:-无}（$out）"; return 1; }
  echo "订阅页大小还是 $TB_SENTINEL，数据在"
}
