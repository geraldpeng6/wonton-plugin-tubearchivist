# shellcheck shell=bash
# TubeArchivist：sso=proxy（网关给登录用户代带 Remote-User: <secrets.ta_user>，应用按这个头
# 自动建会话，见 docker-compose.yml 文件头）；清单没有 mcp。
#
# 数据探针用应用自己的设置接口写一条配置（存进 Elasticsearch），升级和重装后读回来对得上。
# 会话由套件助手建立：dweb --sso 走完整交接链（核心令牌登录 → 网关自动表单 → 应用），
# jar 里带上 wonton_app 和应用种的 sessionid、csrftoken（Django SessionAuthentication
# 的写请求要 CSRF）。探针只用套件保证的 SMOKE_* 变量和 web_get/dweb 助手。

web_assert() { grep -qi 'tubearchivist'; }   # 标准输入：应用真实页面（SPA 的 index.html）

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
  out="$(web_get /api/user/account/)" ||
    { echo "GET /api/user/account/ 失败：$out"; return 1; }
  jq -e '.is_staff == true and .is_superuser == true' <<<"$out" >/dev/null ||
    { echo "应用认出的账号不是管理员：$out"; return 1; }
}

data_write() {
  local state marker out tok
  state="${SMOKE_STATE:-}"
  [[ -n "$state" ]] || { echo "SMOKE_STATE 没设置"; return 1; }
  _tb_prep || return 1
  tok="$(_tb_csrf)"
  [[ -n "$tok" ]] || { echo "会话里没有 csrftoken"; return 1; }
  marker="$(( (RANDOM % 41) + 60 ))"   # 订阅页大小 60-100，探测值
  out="$(web_get /api/appsettings/config/ \
    -H 'Content-Type: application/json' -H "X-CSRFToken: $tok" \
    -X POST -d "{\"subscriptions\":{\"channel_size\":$marker}}")" ||
    { echo "POST /api/appsettings/config/ 失败：$out"; return 1; }
  printf 'channel_size\t%s\n' "$marker" >"$state" || { echo "写不进状态文件 $state"; return 1; }
  echo "已把订阅页大小写成 $marker（$state）"
}

data_check() {
  local state line marker out got tok
  state="${SMOKE_STATE:-}"
  [[ -n "$state" ]] || { echo "SMOKE_STATE 没设置"; return 1; }
  [[ -s "$state" ]] || { echo "状态文件 $state 不存在或为空：data_write 没跑过？"; return 1; }
  line="$(head -n 1 "$state")"
  marker="${line##*$'\t'}"
  _tb_prep || return 1
  out="$(web_get /api/appsettings/config/)" ||
    { echo "GET /api/appsettings/config/ 失败：$out"; return 1; }
  got="$(jq -r '.subscriptions.channel_size // empty' <<<"$out")"
  [[ "$got" == "$marker" ]] ||
    { echo "设置对不上：期望 channel_size=$marker，读到 ${got:-无}（$out）"; return 1; }
  echo "订阅页大小还是 $marker，数据在"
}
