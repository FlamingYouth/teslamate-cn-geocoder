# TeslaMate 中国境内地址查询补丁

这是 TeslaMate 本体的非官方、小范围补丁，基于官方 **v4.3.0**，不是通知程序或 Grafana 地图主题。

上游基线：`33d200b2fba9d5138803916a788cef5eae31b1aa`。应用版本仍为 `4.3.0`，补丁镜像使用独立标签 `4.3.0-cn.1`，不会冒充官方镜像。

发布目标（发布是否完成及 digest 见测试报告）：

- 阿里云：`registry.cn-hangzhou.aliyuncs.com/bigbey/tesla-mate:4.3.0-cn.1`
- GitHub Packages：`ghcr.io/flamingyouth/teslamate-cn-geocoder:4.3.0-cn.1`

## 做了什么、没做什么

- 可选百度 V3 反向地理编码：将行程起终点、充电位置的坐标翻译成中文地址。
- 默认仍使用官方 Nominatim；显式设置 `GEOCODING_PROVIDER=baidu` 才切换。
- 不修改 GPS 坐标、Tesla 接口、行程采集、MQTT、通知模板、数据库结构或迁移文件。
- 不替换 Grafana 地图底图，也不解决 Tesla API 断线、GPS 没有采集等其他问题。
- 百度失败时不偷偷回退 OSM。符合上游保存条件的行程、位置与充电记录仍保存，地址可为空。
- **百度模式关闭上游后台批量地址修复**，不自动重写历史空地址。偶发失败留下的空地址也暂不自动补查；首版没有批量回填工具。
- 已有 OSM 地址保留。手动改变界面语言时，百度地址仍为中文；只重新查询百度地址，不迁移已有 OSM 地址。

百度地址会沿用现有 `addresses` 表：`osm_type=unknown`（没有 OSM 对象），正数 `osm_id` 是原始 WGS84 坐标六位小数的内部唯一编码，不是百度 POI ID 或 OSM ID。`raw.provider=baidu` 用于区分来源。这个设计让官方同版本镜像可读取数据，并在 OSM 地址刷新时跳过百度行。

## 部署：只替换 TeslaMate 服务

不要改数据库、Grafana、MQTT 或通知容器。不要执行 `docker compose down -v`。

1. 先对现有 PostgreSQL 数据做备份，并保留现有 Compose、`.env` 和加密密钥。先独立完成官方 v4.3.0 升级、确认能登录和正常采集，再应用补丁，避免把官方升级与地址补丁混在一起。
2. 在百度地图开放平台创建 **服务端应用**，确认有 V3 逆地理编码接口权限。浏览器/移动端 Key 不能直接当服务端 Key 使用。启用 IP 白名单时，填服务器真实出口公网 IP；启用 SN 校验时，还需要 SK。
3. 复制 `geocoder.env.example` 为 `geocoder.env`，只在本机填写 AK；SK 按需填写。限制文件权限，不要提交这个文件。
4. 在原来 `teslamate` 服务里改镜像并增加环境配置，其他服务不变：

```yaml
services:
  teslamate:
    image: registry.cn-hangzhou.aliyuncs.com/bigbey/tesla-mate:4.3.0-cn.1
    env_file:
      - ./geocoder.env
    # 原有 environment、volumes、ports、networks 等保持不变。
```

也可以把本仓库的 `compose.cn.override.yml` 放在原有 Compose 文件旁，并使用两个文件启动。`TESLAMATE_CN_IMAGE` 写入原有 `.env`，值是发布后给出的完整镜像地址；不要覆盖原有数据库变量。

```sh
chmod 600 geocoder.env
docker compose -f docker-compose.yml -f compose.cn.override.yml config --quiet
docker compose -f docker-compose.yml -f compose.cn.override.yml pull teslamate
docker compose -f docker-compose.yml -f compose.cn.override.yml up -d --no-deps teslamate
docker compose -f docker-compose.yml -f compose.cn.override.yml logs --tail=80 teslamate
```

旧的 `docker-compose` 可以使用同样参数；文件名按实际部署替换。避免把完整 `config` 输出贴上网，因为它可能包含数据库密码或百度 Key。

若原来的 `environment` 已经包含同名 `GEOCODING_PROVIDER` / `BAIDU_MAP_AK`，它们优先于 `env_file`，必须移除冲突项。原有 `NOMINATIM_PROXY` 只影响 OSM，不会代理百度请求。

### 配置项

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GEOCODING_PROVIDER` | `nominatim` | 仅接受 `nominatim` / `baidu` |
| `BAIDU_MAP_AK` | 空 | 百度模式必填，运行时配置，不能放进构建参数 |
| `BAIDU_MAP_SK` | 空 | 只有启用 SN 签名校验时填写 |
| `GEOCODING_TIMEOUT_MS` | `5000` | 读响应和等待连接池的超时，各自生效；范围 100–10000 毫秒，不是整个网络操作的硬总时限 |

请求固定走 HTTPS 百度官方域名，使用 `coordtype=wgs84ll`。纬度在前，经度在后。百度返回的转换坐标不会写回 TeslaMate。地址查询会将待查询坐标发送给百度；请确认自己接受其服务条款、配额和隐私政策。没有持续重试或无限请求；正常行程结束约查询两个点，充电位置约一个点，手动地址刷新会增加调用量。

## 验收方法

先使用独立空数据库和本地 Docker 验收，不连接正式车辆或正式数据库。完整结果记录在 `TEST_REPORT_CN.md`，未完成项目会明确标记。

服务器上由你最后验收：

1. 确认启动日志没有缺少 Key、数据库或加密配置的错误。
2. 正常完成一段新行程，核对起终点中文地址、里程与轨迹；再确认一次新充电记录的地址。
3. 观察旧行程没有被批量重写，通知程序仍正常。
4. 检查百度后台配额和出口 IP 白名单。实际服务器网络与权限仍需服务器侧验证，本地通过不能替代它。

常见错误只记录安全的状态码，不打印包含 Key 的请求 URL：

- `:baidu_api_status, 210`：出口 IP 白名单不匹配。
- `211`：SN 校验失败，核对 SK 与应用设置。
- `200 / 203 / 240`：AK、应用类型或接口权限不正确。
- `4 / 302 / 401`：配额或并发限制。
- `:baidu_transport_error`：网络、TLS、超时或 JSON 解码失败。

## 同版本回退

将 `teslamate` 镜像换回 `teslamate/teslamate:4.3.0`，重新创建 **这一项服务** 即可；不要删数据卷、不要修改加密密钥、不要反向执行数据库迁移。已有百度地址文字保留，新的地址查询恢复 OSM。

此处的回退只指补丁镜像 → 官方 **同版本 v4.3.0**。从 v4.3.0 降回更老版本是另一件事，必须使用对应旧版本数据库备份，不能依赖本补丁保证。

## 开发和发布

业务补丁仅涉及 5 个文件：`geocoder.ex`、新增 `geocoder/baidu.ex`、`locations.ex`、`repair.ex`、`runtime.exs`。测试、文档、密钥忽略规则和专用发布流程单独维护。没有新增依赖；另按用户确认做最小安全更新，`mix.lock` 只修改以下两个已有依赖。

原生验收还发现上游 `VaultTest` 两处全局 System 模拟会干扰后台数据库连接。只在测试中保留未模拟函数，并增加时间换算回归断言；生产加密/数据库实现不改，未跳过任何测试。详情见测试报告。

ARM64 和 AMD64 必须从同一 Git 提交构建，运行完整测试，通过后才发布。GHCR 包绑定本 GitHub 仓库；阿里云和 GHCR 应复制同一个已测试的多架构清单，发布后比对 digest，禁止同标签分别重编译。

升级其他官方版本时不能直接套用旧补丁镜像，要先重新核对接口、数据库和测试。不要把 TeslaMate 4000 端口直接开放到公网；使用原来的认证入口或受保护内网。

### 上游安全提示

2026-10-01 核对官方公告后，只更新两个已有依赖，不升级整个依赖树：

- Mint：`1.10.1 → 1.10.2`，修复 HTTP/2 内存耗尽和相关 HTTP 解析告警。见 [Mint 官方安全公告](https://github.com/elixir-mint/mint/security/advisories/GHSA-9x8p-qrf4-jq7g) 和 [版本告警清单](https://hex.pm/packages/mint/advisories)。
- LazyHTML：`0.1.12 → 0.1.13`，仅测试环境使用，修复 HTML 序列化告警。见 [官方公告](https://github.com/dashbitco/lazy_html/security/advisories/GHSA-8rqp-v692-v82q)。

**仍有上游告警，不等于全面安全审计通过**：Cowlib `2.20.0` 已是核对时最新发布版，Hex 仍报告 CVE-2026-43966、CVE-2026-43969。没有替换为未发布的分支。官方说明，当前 Cowboy（本项目 `2.19.0`）默认拒绝包含 CR/LF 的输出响应头，可缓解前者；后者要求攻击者可控数据传入 `cow_cookie:cookie/1`。详情见 [Cowlib 清单](https://hex.pm/packages/cowlib/advisories)、[43966 官方说明](https://cna.erlef.org/cves/CVE-2026-43966.html)、[43969 官方说明](https://cna.erlef.org/cves/CVE-2026-43969.html)。仍须保护访问入口并持续关注上游修复。

## 来源和许可

原项目为 [TeslaMate](https://github.com/teslamate-org/teslamate)，保留原始 `LICENSE`、`NOTICE` 和上游源码。补丁同样按 AGPL-3.0-or-later 提供。这不是 TeslaMate 官方、中国地图厂商或 Tesla 的官方版本。

接口依据：[百度 V3 逆地理编码](https://lbs.baidu.com/docs/webapi?title=reverse_geocoding%2Fguide%2Fwebservice-geocoding-abroad-base)、[百度 SN 签名说明](https://lbs.baidu.com/faq/api?title=webapi/appendix)。
