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
# 的写请求要 CSRF）。数据标记存套件的 SMOKE_STATE（新套件是文件；老套件没有时退回探针
# 脚本旁自管的一份）。

web_assert() { grep -qi 'tubearchivist'; }   # 标准输入：应用真实页面（SPA 的 index.html）

_tb_dir() { printf '%s' "${BASH_SOURCE[0]%/*}"; }
_tb_state() { printf '%s' "${SMOKE_STATE:-$(_tb_dir)/.smoke-mail-state}"; }

_tb_prep() {  # 建立应用会话：jar 里要有应用种的 csrftoken。跑在套件 web_login 之前时 jar 是冷的；
  # 应用刚装好时 SSO 页可能还是无表单的预热页（sso_form_login 对它当成功返回），重试到拿到会话；
  # 还不行就走应用自己的账号登录（老 tag 没有代登录，账号密码是核心注入的密钥），网页身份两段并存。
  [[ -n "${SMOKE_JAR:-}" ]] || { echo "SMOKE_JAR 没设置"; return 1; }
  local log
  for _ in 1 2 3 4 5 6; do
    log="$(dweb --sso / 2>&1 >/dev/null)" || { echo "走不通网关代登录链：${log:-（无输出）}"; return 1; }
    grep -q csrftoken "$SMOKE_JAR" 2>/dev/null && return 0
    sleep 5
  done
  local container up url inst
  inst="${SMOKE_INSTANCE:-}"
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  container="wonton-${inst}--com-tubearchivist-app--app"
  up="$(docker exec "$container" printenv TA_USERNAME TA_PASSWORD 2>/dev/null)" ||
    { echo "容器里没有 TA_USERNAME/TA_PASSWORD，走不了应用原生登录"; return 1; }
  probes_web_url >/dev/null 2>&1 || { echo "拿不到应用网页地址"; return 1; }
  url="$(curl_t 30 "$SMOKE_WEB_ORIGIN/api/user/login/" --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg u "$(sed -n 1p <<<"$up")" --arg p "$(sed -n 2p <<<"$up")" \
      '{username:$u,password:$p,remember_me:true}')" -w '%{http_code}' -o /dev/null)" ||
    { echo "应用原生登录请求失败"; return 1; }
  [[ "$url" == 204 || "$url" == 200 ]] || { echo "应用原生登录被拒（HTTP $url）"; return 1; }
  curl_t 30 "$SMOKE_WEB_ORIGIN/" --noproxy '*' -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' ||
    { echo "登录后拿不到页面"; return 1; }
  grep -q csrftoken "$SMOKE_JAR" 2>/dev/null && return 0
  echo "应用会话没建立（SSO 和应用原生登录都没拿到 csrftoken；最后一步输出：${log:-无}）"
  return 1
}

_tb_csrf() { awk '$6 == "csrftoken" {print $7; exit}' "$SMOKE_JAR"; }

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
  out="$(_tb_post /api/appsettings/config/ "{\"subscriptions\":{\"channel_size\":$marker}}")" ||
    { echo "POST /api/appsettings/config/ 失败：$out"; return 1; }
  printf 'channel_size\t%s\n' "$marker" >"$(_tb_state)" || { echo "写不进状态文件 $(_tb_state)"; return 1; }
  echo "已把订阅页大小写成 $marker（$(_tb_state)）"
}

# ---------- 邮件（notify）：应用测试接口真发信，核对核心投进私聊 ----------
# 核心把信投进收件人的 Wonton 私聊后才从 Mailpit 删掉，投递失败会留着重试：信从 Mailpit 消失
# 就是投走了。核心投递成功不打日志（只有失败才记 error），所以不用核心日志当证据。

core_container() { # 核心容器：实例名拼（冒烟起的核心容器名固定这个形状）
  printf '%s' "wonton-${SMOKE_INSTANCE:?}--core"
}

mailpit_messages() { # 经核心的网络栈读 Mailpit 收件箱 API（SMTP 25/HTTP 8025 都不发布到宿主）。
  # API 要 Basic 认证（core:<密钥>，密钥在核心数据目录，核心的 mailbox 组件生成）。
  local pwd
  pwd="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/mailpit/api-password"')" ||
    { echo "读不到 Mailpit API 密钥"; return 1; }
  docker run --rm --network "container:$(core_container)" curlimages/curl:8.23.0 --noproxy '*' -s \
    -u "core:$pwd" "http://mailpit.wonton.internal:8025/api/v1/messages?limit=50"
}

_tb_mail_in_mailpit() { # <收件人>：TubeArchivist 发的、还没被核心取走的信（From 是注入的发件地址）
  mailpit_messages | jq -r --arg f "com.tubearchivist.app@plugins.wonton.internal" --arg t "$1" '
    [.messages[] | select((.From.Address == $f) and ([.To[].Address] | index($t)))] | length'
}

wonton_chat_events() { # <条数>：核心投递事件的房间最近消息。核心实测亚秒取走信件（投完即删），
  # 在 Mailpit 里几乎抓不到中间态，投进主人 Wonton 私聊的房间事件才是权威证据。
  local mu room adm
  mu="$(docker exec "$(core_container)" printenv WONTON_MATRIX_URL)" || { echo "读不到 Matrix 地址"; return 1; }
  # 通知房间是第一封信投递时才建的：一封信都还没投过时读不到文件，按 0 条投递算
  # （_delivered_after 的轮询会等它出现），不当错误。
  room="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-notice-room"' 2>/dev/null)" ||
    { echo '{"chunk":[]}'; return 0; }
  adm="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-admin-token"' 2>/dev/null)" ||
    { echo "读不到 Matrix 管理令牌"; return 1; }
  docker run --rm --network "container:$(core_container)" curlimages/curl:8.23.0 --noproxy '*' -s \
    -H "Authorization: Bearer $adm" "$mu/_matrix/client/v3/rooms/$room/messages?limit=$1&dir=b"
}

_tb_mail_in_wonton_chat() { # <主题>：本插件已投进主人 Wonton 私聊的邮件事件数
  wonton_chat_events 30 | jq -r --arg s "$1" '
    [.chunk[] | select(.content["app.wonton.plugin_mail"].subject == $s)] | length'
}

_tb_mail_roundtrip() { # <主题>：等 TA 的测试信（主题固定带任务名）投进主人私聊，再核对 Mailpit 没有滞留
  local subj="$1" out seen=0
  for _ in {1..12}; do
    sleep 5
    out="$(_tb_mail_in_wonton_chat "$subj")" || { echo "$out"; return 1; }
    if [[ "$out" != 0 ]]; then seen=1; break; fi
  done
  [[ "$seen" == 1 ]] || { echo "等了 1 分钟没看到信投进主人的 Wonton 私聊（投递失败？）"; return 1; }
  for _ in {1..12}; do
    sleep 5
    out="$(_tb_mail_in_mailpit "owner@wonton.internal")" || { echo "$out"; return 1; }
    [[ "$out" == 0 ]] && { echo "信已投进主人的 Wonton 私聊，Mailpit 没有滞留"; return 0; }
  done
  echo "信投进了私聊，但 Mailpit 里还有滞留（核心没删？）"
  return 1
}

data_check() {
  local state line marker out got url ext task recorded
  state="$(_tb_state)"
  [[ -s "$state" ]] || { echo "状态文件 $state 不存在或为空：data_write 没跑过？"; return 1; }
  line="$(head -n 1 "$state")"
  marker="${line##*$'\t'}"
  _tb_prep || return 1
  # 订阅页大小在应用配置里（/api/appsettings/config/）；四个任务的 Apprise 通知在
  # /api/task/notification/，两个端点各回各的，别混读。
  out="$(web_get /api/appsettings/config/)" ||
    { echo "GET /api/appsettings/config/ 失败：$out"; return 1; }
  got="$(jq -r '.subscriptions.channel_size // empty' <<<"$out")"
  [[ "$got" == "$marker" ]] ||
    { echo "设置对不上：期望 channel_size=$marker，读到 ${got:-无}（$out）"; return 1; }
  echo "订阅页大小还是 $marker，数据在"
  out="$(_tb_notifs)" || { echo "GET /api/task/notification/ 失败：$out"; return 1; }

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
  _tb_mail_roundtrip "[TA] update_subscribed process ended with SUCCESS" || return 1

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
    -H "X-CSRFToken: $(_tb_csrf)" -d '{"task_name":"check_reindex","url":"'"$got"'"}')" ||
    { echo "删 check_reindex 通知失败：$out"; return 1; }
  [[ -z "$out" ]] || { echo "删 check_reindex 通知失败：$out"; return 1; }
  echo "phase=checked" >>"$state"
  echo "url=$url" >>"$state"
  echo "已删 check_reindex 的通知，重装后核对剩下三条"
}
