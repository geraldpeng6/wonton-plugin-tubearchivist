"""装好后的通知配置（TubeArchivist 健康后运行）。

TubeArchivist 的任务结束通知走 Apprise，配置只能经它自己的 API 写进 Elasticsearch
（ta_config），没有配置文件或环境变量。这里按网页"设置 → Scheduling → Notifications"
提供的四个任务各配一条 mailto:// 链接，应用发的信落进收件人的 Wonton 私聊。

只在通知配置整体为空时写入：用户在应用里改过或删过的不覆盖；配置整体丢失（恢复备份、
重建 ES）时补回默认。Apprise 链接的三个地址都来自核心注入：服务器 WONTON_SMTP_HOST:PORT、
发件人 WONTON_MAIL_FROM、收件人 WONTON_OWNER_EMAIL（主人的内部邮箱，装好后不变）。

认证分两步：代登录头（Remote-User: secrets.ta_user，和应用收到的网关代登录头同值）取
应用的 API token，之后用 token 调通知接口——DRF 的 SessionAuthentication 对 POST 强制
CSRF，TokenAuthentication 不用，避免自己拼 csrf 换手。任何一步失败都非零退出，不静默跳过。
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://app:8000"

# 网页里能配通知的四个任务（frontend/src/api/actions/createAppriseNotificationUrl.ts）。
TASKS = [
    "update_subscribed",
    "extract_download",
    "download_pending",
    "check_reindex",
]


def request(method, path, payload=None, headers=None):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=body, method=method)
    req.add_header("Content-Type", "application/json")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode()
    except urllib.error.URLError as err:
        sys.exit(f"连不上应用（{err.reason}）：应用没起来或网络不通")


apprise_url = "mailto://{}:{}/?from={}&to={}".format(
    os.environ["WONTON_SMTP_HOST"],
    os.environ["WONTON_SMTP_PORT"],
    os.environ["WONTON_MAIL_FROM"],
    os.environ["WONTON_OWNER_EMAIL"],
)

# Remote-User 是核心生成保管的密钥，只走插件网络内部，不落盘。
status, raw = request(
    "GET", "/api/appsettings/token/", headers={"Remote-User": os.environ["WONTON_SECRET_TA_USER"]}
)
if status != 200:
    sys.exit(f"取应用 API token 失败（HTTP {status}）：{raw[:200]}")
token = json.loads(raw)["token"]
auth = {"Authorization": "Token " + token}

status, raw = request("GET", "/api/task/notification/", headers=auth)
if status != 200:
    sys.exit(f"读通知配置失败（HTTP {status}）：{raw[:200]}")
current = json.loads(raw)
if current:
    print(
        "通知已有配置（{}），不覆盖：{}".format(
            ", ".join(sorted(current)),
            apprise_url,
        )
    )
    sys.exit(0)

for task in TASKS:
    status, raw = request(
        "POST", "/api/task/notification/", {"task_name": task, "url": apprise_url}, headers=auth
    )
    if status != 200:
        sys.exit(f"配置 {task} 的通知失败（HTTP {status}）：{raw[:200]}")
    print(f"{task} 的通知已配好：{apprise_url}")
