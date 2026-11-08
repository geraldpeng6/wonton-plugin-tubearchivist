# shellcheck shell=bash
# TubeArchivist：sso=proxy（网关给登录用户代带 Remote-User: <secrets.ta_user>，应用按这个头
# 自动建会话，见 docker-compose.yml 文件头）；清单没有 mcp。
#
# 数据探针用应用自己的设置接口写一条配置（存进 Elasticsearch），升级和重装后读回来对得上。
# 邮件探针（本插件的核心功能）在 data_check 里做：notify-init 配好的四个任务通知 URL 读回来
# 核对（地址、from、to 都来自核心注入），经应用自己的测试接口发真实信件——主人的内部地址要
# 发送成功、外部地址要在 SMTP 阶段被拒（应用报发送失败）；核心日志里要有投递记录。重装后配置
# 还在、不重复，用户删掉的那条不被初始化写回。
#
# 会话由套件助手建立：dweb --sso 走完整交接链（核心令牌登录 → 网关自动表单 → 应用），
# jar 里带上 wonton_app 和应用种的 sessionid、csrftoken（Django SessionAuthentication
# 的写请求要 CSRF）。状态文件自管（套件的 SMOKE_STATE 是目录），放探针脚本旁边。

web_assert() { grep -qi 'tubearchivist'; }   # 标准输入：应用真实页面（SPA 的 index.html）

_tb_dir() { printf '%s' "${BASH_SOURCE[0]%/*}"; }
_tb_state() { printf '%s/.smoke-mail-state' "$(_tb_dir)"; }

_tb_prep() {  # 建立应用会话：jar 里要有应用种的 csrftoken
  [[ -n "${SMOKE_JAR:-}" ]] || { echo "SMOKE_JAR 没设置"; return 1; }
  local log
  log="$(dweb --sso / 2>&1 >/dev/null)" || { echo "走不通网关代登录链：${log:-（无输出）}"; return 1; }
  grep -q csrftoken "$(_tb_jar)" ||
    { echo "应用会话没建立（jar 里没有 csrftoken，代登录头没生效？）"; return 1; }
}

_tb_csrf() { awk '$6 == "csrftoken" {print $7; exit}' "$(_tb_jar)"; }

_tb_post() { # _tb_post <路径> <JSON>：带 CSRF 的应用写请求，输出响应体
  web_get "$1" -X POST -H 'Content-Type: application/json' -H "X-CSRFToken: $(_tb_csrf)" -d "$2"
}

_tb_notifs() { web_get /api/task/notification/; }

identity_check() {  # /api/user/account/ 只回给已登录会话：200 且是管理员说明代登录头生效
  _tb_prep || return 1
  local out
  out="$(web_get /api/user/account/)" ||
    { echo "GET /api/user/account/ 失败：$out"; return 1; }
  jq -e '.is_staff == true and .is_superuser == true' <<<"$out" >/dev/null ||
    { echo "应用认出的账号不是管理员：$out"; return 1; }
}

data_write() {
  local marker out tok
  _tb_prep || return 1
  tok="$(_tb_csrf)"
  [[ -n "$tok" ]] || { echo "会话里没有 csrftoken"; return 1; }
  marker="$(( (RANDOM % 41) + 60 ))"   # 订阅页大小 60-100，探测值
  out="$(_tb_post /api/appsettings/config/ "{\"subscriptions\":{\"channel_size\":$marker}\"}")" ||
    { echo "POST /api/appsettings/config/ 失败：$out"; return 1; }
  printf 'channel_size\t%s\n' "$marker" >"$(_tb_state)" || { echo "写不进状态文件 $(_tb_state)"; return 1; }
  echo "已把订阅页大小写成 $marker（$(_tb_state)）"
}

data_check() {
  local state line marker out got url ext core_log task recorded
  state="$(_tb_state)"
  [[ -s "$state" ]] || { echo "状态文件 $state 不存在或为空：data_write 没跑过？"; return 1; }
  line="$(head -n 1 "$state")"
  marker="${line##*$'\t'}"
  _tb_prep || return 1
  out="$(_tb_notifs)" || { echo "GET /api/task/notification/ 失败：$out"; return 1; }
  got="$(jq -r '.subscriptions.channel_size // empty' <<<"$out")"
  [[ "$got" == "$marker" ]] ||
    { echo "设置对不上：期望 channel_size=$marker，读到 ${got:-无}（$out）"; return 1; }
  echo "订阅页大小还是 $marker，数据在"

  url="$(jq -r '.update_subscribed.urls[0] // empty' <<<"$out")"
  # 通知是 notify-init 写的（mailto 链接，见 config/notify-init.py）。第一遍 data_check 在"装 tag
  # 再升级"之后：四条都该在。之后删掉 check_reindex 那条模拟用户改动，重装后的第二遍核对
  # 剩下三条还在、不重复、被删的不被写回。
  if grep -q '^phase=checked' "$state" 2>/dev/null; then
    recorded="$(sed -n 's/^url=//p' "$state")"
    [[ "$url" == "$recorded" ]] ||
      { echo "重装后通知变了：期望 $recorded，实际 ${url:-无}"; return 1; }
    for task in update_subscribed extract_download download_pending; do
      got="$(jq -r --arg t "$task" '.[$t].urls // [] | length' <<<"$out")"
      [[ "$got" == 1 ]] || { echo "重装后 $task 应有 1 条通知，实际 $got：$out"; return 1; }
      got="$(jq -r --arg t "$task" '.[$t].urls[0]' <<<"$out")"
      [[ "$got" == "$url" ]] || { echo "重装后 $task 的通知变了：期望 $url，实际 $got"; return 1; }
    done
    got="$(jq -r '.check_reindex.urls // [] | length' <<<"$out")"
    [[ "$got" == 0 ]] ||
      { echo "删掉的 check_reindex 通知被初始化写回来了（$got 条）：$out"; return 1; }
    echo "重装后三条通知原样在、不重复，删掉的一条没被写回"
    return 0
  fi

  [[ -n "$url" ]] || { echo "通知里没有 mailto 链接（notify-init 没跑成？）：$out"; return 1; }
  for task in extract_download download_pending check_reindex; do
    got="$(jq -r --arg t "$task" '.[$t].urls[0] // empty' <<<"$out")"
    [[ "$got" == "$url" ]] ||
      { echo "$task 的通知和 update_subscribed 不一致：期望 $url，实际 ${got:-无}"; return 1; }
  done
  echo "四个任务各一条相同的通知：$url"

  # 真实信件：收件人是主人的内部地址，经核心投进 Wonton 私聊；应用自己的测试接口报成败。
  out="$(_tb_post /api/task/notification/test/ "{\"url\":\"$url\",\"task_name\":\"update_subscribed\"}")" ||
    { echo "内部地址测试信失败：$out"; return 1; }
  jq -e '.success == true' <<<"$out" >/dev/null ||
    { echo "内部地址测试信没发出去：$out"; return 1; }
  echo "内部地址测试信发送成功（$out）"

  # 核心日志里的投递记录（docker 在冒烟机上可用，套件自己也用 docker；见 probes_env）。
  core_log="$(docker logs "wonton-$SMOKE_INSTANCE--core" 2>&1 | grep -i mail | tail -3)"
  [[ -n "$core_log" ]] || { echo "核心日志里没找到 mail 记录"; return 1; }
  echo "核心日志：$core_log"

  # 外部地址：SMTP 阶段 550，应用报发送失败。
  ext="${url%%&to=*}&to=someone@example.com"
  out="$(_tb_post /api/task/notification/test/ "{\"url\":\"$ext\",\"task_name\":\"update_subscribed\"}")"
  jq -e '.success == false' <<<"$out" >/dev/null ||
    { echo "外部地址没被拒（期望应用报失败）：$out"; return 1; }
  echo "外部地址被拒（$out）"

  out="$(_tb_notifs)" || { echo "读通知配置失败：$out"; return 1; }
  got="$(jq -r '.check_reindex.urls[0] // empty' <<<"$out")"
  [[ -n "$got" ]] || { echo "check_reindex 没有通知可删：$out"; return 1; }
  out="$(web_get /api/task/notification/ -X DELETE -H 'Content-Type: application/json' \
    -H "X-CSRFToken: $(_tb_csrf)" -d '{"task_name":"check_reindex","url":"'"$got"'"}')" &&
    [[ -z "$out" ]] || { echo "删 check_reindex 通知失败：$out"; return 1; }
  echo "phase=checked" >>"$state"
  echo "url=$url" >>"$state"
  echo "已删 check_reindex 的通知，重装后核对剩下三条"
}
