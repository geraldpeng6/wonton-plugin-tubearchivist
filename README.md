# TubeArchivist 插件

订阅 YouTube 频道自动下载存档的云吞插件：应用是上游 [TubeArchivist](https://github.com/tubearchivist/tubearchivist) 官方镜像，外加它要求的 Elasticsearch 和 Redis。

- 打开网页经云吞网关代登录，进去就是自己的账号，没有第二个登录页。
- 下载的视频和元数据是本地文件，Jellyfin 等媒体库可以直接读取。
- 下载视频需要能访问 YouTube 的网络（出网权限 `network.egress`）。

## 网页登录怎么工作

TubeArchivist 支持反向代理传用户名（`TA_ENABLE_AUTH_PROXY`），但没有"可信代理地址"配置；出网插件必须只信云吞核心（见[公开插件规范的“网关代登录”一节](https://github.com/geraldpeng6/wonton-docs/blob/main/plugin-spec.md#网关代登录sso-proxy)）。所以网关代带的请求头不是用户名，而是安装时核心生成的密钥（清单 `secrets.ta_user`）：应用启动时以它为用户名建管理员，网关对登录用户的每个请求带上 `Remote-User: <密钥>`，打开网页就是管理员。这个值只在核心密钥库和容器环境里，设置页的账号名就是它。

## 图标

`icon.svg` 是上游 TubeArchivist 官方标志，原样放在白色满幅底上。来源、处理和许可见 [NOTICE](NOTICE)；TubeArchivist 名称和标志是上游项目的商标。
