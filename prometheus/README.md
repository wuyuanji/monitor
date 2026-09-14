# 监控栈部署说明 (Prometheus + Grafana + Loki + Alloy)

> 单机 Docker Compose 部署包 | 更新: 2026-09-11

---

## 一、目录结构

```
prometheus/
├── deployprometheus.sh          # 一键部署脚本（替换AUTHIP + 建目录 + load镜像 + up）
├── docker-compose.yml           # 编排文件（13个服务：监控栈 + 日志栈）
├── prometheus.yml               # Prometheus 抓取配置（含 node 挂载点过滤）
├── alert-rules.yml              # 告警规则（54条）
├── alertmanager.yml             # 告警通知配置
├── email.tmpl                   # 邮件模板
├── process-exporter.yml         # 进程监控配置
├── prometheus.tar.gz            # 镜像包（13个镜像，离线部署用）
├── acohub-log/                  # 日志与可视化栈
│   ├── docker-compose.yaml.deprecated-20260911   # 已废弃（内容已并入上级 compose）
│   └── config/
│       ├── grafana/provisioning/
│       │   ├── datasources/     # 数据源（Prometheus + Loki）
│       │   └── dashboards/      # 看板（provider + 3个看板JSON）
│       ├── loki/local-config.yaml
│       └── alloy/config.alloy   # 日志采集（docker 容器日志 → Loki）
└── grafana/                     # 原始看板JSON（归档）
```

---

## 二、部署步骤

```bash
# 1. 把本目录拷贝到目标机
scp -r prometheus/ root@<目标机>:/opt/acoinfo/swfactory/

# 2. 执行部署（在目标机）
cd /opt/acoinfo/swfactory/prometheus
bash deployprometheus.sh
#  脚本会：检测本机IP → 你确认 → 把 *.yml/*.sh/acohub-log 里的 AUTHIP 替换为实际IP
#         → 创建数据目录 → docker load 镜像 → docker compose up -d

# 3. 验证
docker ps --format '{{.Names}}|{{.Status}}' | grep -E 'prometheus|grafana|loki|alloy|cadvisor|exporter'
```

**前提**：目标机已安装 `docker` + `docker compose`。

---

## 三、部署后自动完成的事

| 项 | 说明 |
|----|------|
| 13 个服务启动 | Prometheus / Alertmanager / cAdvisor / node-exporter / mysql·redis·es·mongodb·nginx·process exporter / Grafana / Loki / Alloy |
| Grafana 数据源 | 自动创建 **Prometheus** + **Loki**（provisioning） |
| Grafana 看板 | 自动加载 3 个到 **AcoHub** 文件夹（provisioning）→ **无需手动导入** |
| Grafana 主页 | 自动设为 **Docker monitoring** |

---

## 四、⚠️ 主页仪表板配置说明

**主页 = Docker monitoring**，通过 `docker-compose.yml` 的 grafana 环境变量设置：

```yaml
  grafana:
    environment:
      - GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/provisioning/dashboards/docker-monitoring.json
```

| 说明 | 内容 |
|------|------|
| 配置段 | Grafana `[dashboards] default_home_dashboard_path`（环境变量前缀 `GF_DASHBOARDS_`）|
| 路径 | **容器内路径** `/etc/grafana/provisioning/dashboards/docker-monitoring.json`（宿主对应 `acohub-log/config/grafana/provisioning/dashboards/`）|
| 优先级 | 用户个人偏好 > 组织偏好(homeDashboardUID) > 本默认值 |
| 换别的看板 | 把路径末尾文件名改成目标看板 JSON 即可（如 `home.json`）|

**给已运行环境改主页**（环境变量只在容器启动时读，已跑的环境用 API）：
```bash
curl -X PUT -u admin:acoinfo http://<IP>:3300/api/org/preferences \
  -H 'Content-Type: application/json' \
  -d '{"homeDashboardUID":"q5_EX4iIz932"}'     # Docker monitoring 的 uid
```

---

## 五、配置速查（想改什么，改哪个文件）

| 需求 | 文件 | 说明 |
|------|------|------|
| **主页仪表板** | `docker-compose.yml` → grafana.environment | `GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH` |
| **Grafana 登录密码** | `docker-compose.yml` → grafana.environment | `GF_SECURITY_ADMIN_PASSWORD`（默认 acoinfo）|
| **告警规则** | `alert-rules.yml` | 54 条；改完 `curl -X POST localhost:9091/-/reload` |
| **抓取目标/job** | `prometheus.yml` | 加 target / metric_relabel_configs |
| **Grafana 看板** | `acohub-log/config/grafana/provisioning/dashboards/*.json` | 放 JSON 即自动加载（30s 重扫）|
| **Grafana 数据源** | `acohub-log/config/grafana/provisioning/datasources/*.yaml` | 注意 `uid` 要与看板引用一致 |
| **日志采集规则** | `acohub-log/config/alloy/config.alloy` | 采集哪些容器日志 |
| **Loki 存储配置** | `acohub-log/config/loki/local-config.yaml` | 存储/保留策略 |
| **邮件告警** | `alertmanager.yml` + `email.tmpl` | SMTP 配置 |

---

## 六、访问方式（默认端口）

| 服务 | 地址 | 凭据 |
|------|------|------|
| Grafana | http://&lt;IP&gt;:3300 | `admin` / `acoinfo` |
| Prometheus | http://&lt;IP&gt;:9091 | 无 |
| Alertmanager | http://&lt;IP&gt;:9093 | 无 |
| Loki | http://&lt;IP&gt;:3100 | 无 |
| cAdvisor | http://&lt;IP&gt;:8080 | 无 |

---

## 七、注意事项

| # | 项 | 说明 |
|---|----|------|
| 1 | **AUTHIP 占位符** | 所有配置里用 `AUTHIP` 占位，deploy 脚本部署时替换为本机 IP。**不要手动写死 IP** |
| 2 | **数据源 uid** | 看板引用的 `VxKm9JLNk`(Prometheus)、`P8E80F9AEF21F6940`(Loki) 必须与 datasources 里的 `uid` 一致，否则看板报"数据源不存在" |
| 3 | **看板 provisioning** | `disableDeletion: true`（删文件不删看板）、`allowUiUpdates: true`（UI 可改）|
| 4 | **Grafana 数据卷** | 命名卷 `grafana-volume`（新环境为空，看板来自 provisioning，**无需导入**）|
| 5 | **Prometheus 数据** | 持久化在 `/opt/prometheus-data/data`（保留 30 天）|
| 6 | **离线部署** | `prometheus.tar.gz` 已含 13 个镜像，`docker load` 即可，**无需联网** |
| 7 | **告警通知** | 需先在 `alertmanager.yml` 配好邮件/Webhook，否则告警只显示不发送 |

---

## 附录：process-exporter 配置示例

`process-exporter.yml` 用于监控指定进程，示例：

```yaml
process_names:
  - name: armory-server
    exe:
      - /usr/app/armory-server
```

详见 `process-exporter.yml`。
