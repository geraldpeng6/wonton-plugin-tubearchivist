# shellcheck shell=bash
# TubeArchivist：sso=proxy（网关给登录用户代带 Remote-User: <secrets.ta_user>，应用按这个头
# 自动建会话，见 docker-compose.yml 文件头）；清单没有 mcp。
#
# 数据探针用应用自己的设置接口写一条配置（存进 Elasticsearch），升级和重装后读回来对得上。
# 探针自建会话：先登核心（token），再打开应用页面——代登录头在首个请求上让应用登录并种下
# csrftoken，之后的写请求带上它（Django SessionAuthentication 要 CSRF）。

TB_ID="com.tubearchivist.app"

web_assert() { grep -qi 'tubearchivist'; }   # 标准输入：应用真实页面（SPA 的 index.html）

# 套件探针（SMOKE_*）和 e2e（E2E_*）两套变量名都兜住，字段取值见各套件。
_tb_env() {
  _TB_JAR="${E2E_JAR:-$SMOKE_JAR}"
  _TB_BASE="${E2E_BASE:-$SMOKE_BASE}"
  _TB_TOKEN="${E2E_TOKEN:-$SMOKE_TOKEN}"
  _TB_WEB_URL="${E2E_WEB_URL:-$SMOKE_WEB_URL}"
}

_tb_state_file() {  # 套件给的是文件，e2e 给的是文件，dev.sh probes 给的是状态目录
  if [[ -d "${SMOKE_STATE:-}" ]]; then
    printf '%s/tubearchivist.probe' "$SMOKE_STATE"
  else
    printf '%s' "${SMOKE_STATE:-}"
  fi
}

_tb_prep() {  # 备好 _TB_JAR/_TB_URL，建立核心会话和应用会话（jar 里带上 csrftoken）
  _tb_env
  [[ -n "$_TB_JAR" && -n "$_TB_BASE" && -n "$_TB_TOKEN" ]] ||
    { echo "探针环境变量不齐：jar/base/token 至少缺一"; return 1; }
  if [[ -z "$_TB_WEB_URL" ]]; then
    local plugins
    plugins="$(curl -sS --noproxy '*' --fail-with-body -H "Authorization: Bearer $_TB_TOKEN" "$_TB_BASE/_wonton/api/plugins")" ||
      { echo "列不出插件，拿不到网页地址"; return 1; }
    _TB_WEB_URL="$(jq -rn --arg id "$TB_ID" --arg json "$plugins" \
      '$json | fromjson | .plugins[] | select(.id==$id) | .web_url // ""')" ||
      { echo "解析网页地址失败"; return 1; }
    [[ -n "$_TB_WEB_URL" ]] || { echo "插件没有网页地址"; return 1; }
  fi
  _TB_URL="$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$_TB_WEB_URL")"
  # 核心会话：令牌登不进时后面全部失败，如实报错。
  local code
  code="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' -c "$_TB_JAR" -b "$_TB_JAR" \
    --data-urlencode "token=$_TB_TOKEN" "$_TB_BASE/_wonton/login")" ||
    { echo "核心登录请求失败"; return 1; }
  [[ "$code" == 2* || "$code" == 30* ]] || { echo "核心令牌登录不了（HTTP $code）"; return 1; }
  # 打开应用页面：网关代登录头在首个请求上让应用登录，响应种下 sessionid 和 csrftoken。
  curl -sS --noproxy '*' -o /dev/null -L -b "$_TB_JAR" -c "$_TB_JAR" -H 'Accept: text/html' "$_TB_URL/" ||
    { echo "打开应用页面失败"; return 1; }
  grep -q csrftoken "$_TB_JAR" || { echo "应用会话没建立（jar 里没有 csrftoken）"; return 1; }
}

_tb_csrf() { awk '$6 == "csrftoken" {print $7; exit}' "$_TB_JAR"; }

identity_check() {  # /api/user/account/ 只回给已登录会话：200 且是管理员说明代登录头生效
  _tb_prep || return 1
  local out
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$_TB_JAR" "$_TB_URL/api/user/account/")" ||
    { echo "GET /api/user/account/ 失败：$out"; return 1; }
  jq -e '.is_staff == true and .is_superuser == true' <<<"$out" >/dev/null ||
    { echo "应用认出的账号不是管理员：$out"; return 1; }
}

data_write() {
  local state
  state="$(_tb_state_file)" || { echo "SMOKE_STATE 没设置"; return 1; }
  _tb_prep || return 1
  local tok marker out
  tok="$(_tb_csrf)"
  [[ -n "$tok" ]] || { echo "会话里没有 csrftoken"; return 1; }
  marker="$(( (RANDOM % 41) + 60 ))"   # 订阅页大小 60-100，探测值
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$_TB_JAR" -c "$_TB_JAR" \
    -H 'Content-Type: application/json' -H "X-CSRFToken: $tok" \
    -X POST -d "{\"subscriptions\":{\"channel_size\":$marker}}" \
    "$_TB_URL/api/appsettings/config/")" ||
    { echo "POST /api/appsettings/config/ 失败：$out"; return 1; }
  printf 'channel_size\t%s\n' "$marker" >"$state" || { echo "写不进状态文件 $state"; return 1; }
  echo "已把订阅页大小写成 $marker（$state）"
}

data_check() {
  local state line marker out got
  state="$(_tb_state_file)" || { echo "SMOKE_STATE 没设置"; return 1; }
  [[ -s "$state" ]] || { echo "状态文件 $state 不存在或为空：data_write 没跑过？"; return 1; }
  line="$(head -n 1 "$state")"
  marker="${line##*$'\t'}"
  _tb_prep || return 1
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$_TB_JAR" "$_TB_URL/api/appsettings/config/")" ||
    { echo "GET /api/appsettings/config/ 失败：$out"; return 1; }
  got="$(jq -r '.subscriptions.channel_size // empty' <<<"$out")"
  [[ "$got" == "$marker" ]] ||
    { echo "设置对不上：期望 channel_size=$marker，读到 ${got:-无}（$out）"; return 1; }
  echo "订阅页大小还是 $marker，数据在"
}
