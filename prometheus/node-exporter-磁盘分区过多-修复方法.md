# Node Exporter 磁盘监控「显示过多分区」修复方法

> 环境：Prometheus `10.12.7.250:9091`　Grafana `10.12.7.250:3300`
> 问题：node 看板的磁盘面板显示一堆分区，实际只想看根分区 `/`

---

## 一、问题现象

Grafana 的 node-exporter 看板磁盘面板里，除了 `/` 还出现了：

```
/run、/run/lock、/run/user/0
/datas/httpserverDatas          ← NFS
/rootfs、/rootfs/run、/rootfs/datas/...
/etc/hosts、/etc/hostname、/etc/resolv.conf
/host/proc/fs/nfsd、/host/sys/fs/cgroup
```

而运维只想看到 **`/`**。

## 二、根因分析

两个问题叠加：

### 问题 1：node_exporter 默认采集**所有**挂载点
包括 tmpfs、NFS、overlay 等，不只是根分区。

### 问题 2：部分节点的 node_exporter **配置残缺**

| 节点 | node_exporter 配置 | 报告的 mountpoint |
|------|-------------------|------------------|
| **250** | ✅ 正确（有 `--path.*` 参数） | `/`、`/run`（宿主真实路径） |
| **218 / 220** | ❌ 无参数（`/bin/node_exporter`） | `/rootfs`、`/etc/hosts`、`/host/*`（**容器内**挂载点） |

218/220 因为没加 `--path.procfs/--path.sysfs/--path.rootfs`，node_exporter 读的是**容器自己的**挂载表，于是把容器内挂载点（`/etc/hosts`、`/rootfs/*`）全暴露出来了。

## 三、解决方案（两层，推荐都做）

### 方案 A：Prometheus 采集端过滤（改一处，所有看板通用）⭐

在 `prometheus.yml` 的 `Node` job 加 `metric_relabel_configs`：

```yaml
  - job_name: Node
    scrape_interval: 30s
    static_configs:
      - targets:
        - 10.12.7.250:9100
        # ... 其他节点
    metric_relabel_configs:
      # 1) 容器化 node_exporter 的根会报成 /rootfs，先规范化为 /
      - source_labels: [mountpoint]
        regex: '/rootfs'
        target_label: mountpoint
        replacement: '/'
      # 2) 丢弃伪文件系统(tmpfs/overlay/nfs/...)，真实磁盘(ext4/xfs/...)全保留
      - source_labels: [__name__, fstype]
        regex: 'node_filesystem_[^;]+;(tmpfs|devtmpfs|overlay|nfs|nfs4|autofs|squashfs|ramfs|fuse\..*|nsfs|proc|sysfs|cgroup2?)'
        action: drop
      # 3) 丢弃容器内挂载点(/etc/hosts /host/* /rootfs/*)
      - source_labels: [__name__, mountpoint]
        regex: 'node_filesystem_[^;]+;(/etc/.+|/host/.+|/rootfs/.+)'
        action: drop
```

生效：
```bash
curl -X POST http://localhost:9091/-/reload
```

> ✅ **推荐用 fstype 版**：按"文件系统类型"过滤（丢弃 tmpfs/NFS/overlay），
> 而不是白名单只留 `/`。好处：**以后新增真实磁盘挂载（如 NVMe 挂 `/opt`）会自动显示，无需改配置**。

### 方案 B：修复 node_exporter 配置（治本）

把残缺的 node_exporter 改成正确配置（以 218/220 为例）：

```yaml
  node-exporter:
      image: prom/node-exporter:v1.8.2       # 老版本 v0.16.0 建议升级
      container_name: node-exporter
      hostname: node-exporter
      restart: always
      command:
        - --path.procfs=/host/proc           # ← 关键：读宿主 /proc
        - --path.sysfs=/host/sys             # ← 关键：读宿主 /sys
        - --path.rootfs=/rootfs              # ← 关键：从宿主根读取
      volumes:
        - /proc:/host/proc:ro
        - /sys:/host/sys:ro
        - /:/rootfs:ro
      network_mode: "host"
```

生效：
```bash
docker compose -f /opt/dockercomposenode_exporter.yml up -d --force-recreate node-exporter
```

## 三之二、以后新增磁盘挂载怎么办（fstype 版的优势）

例如把 NVMe 盘挂到 `/opt`：

```bash
mkfs.ext4 /dev/nvme0n1          # 必须是真实文件系统(ext4/xfs)
mount /dev/nvme0n1 /opt
# 并写入 /etc/fstab 持久化
```

**需要改的配置：0 处** —— 全自动：

| 环节 | 行为 |
|------|------|
| node_exporter | ✅ 自动发现新挂载点（无需改） |
| Prometheus relabel（fstype 版） | ✅ 自动放行（ext4/xfs 不在丢弃列表） |
| Grafana | ✅ 磁盘面板自动出现 `/opt` |

> ⚠️ 前提：fstype 是真实文件系统（ext4/xfs）；若挂成 tmpfs/overlay 会被规则2丢弃。
> ⏱ 数据延迟：采集周期 30s。

**对比**：如果用"白名单只留 `/`"的旧版，**每次加盘都要改 `prometheus.yml` 并 reload**。

## 四、验证

### 1. 直接看 node_exporter 原始指标（应只有宿主真实挂载点）

```bash
curl -s http://<节点>:9100/metrics \
  | grep '^node_filesystem_size_bytes' \
  | grep -oE 'mountpoint="[^"]*"' | sort -u
```

期望（218/220/250）：
```
mountpoint="/"
mountpoint="/datas/httpserverDatas"
mountpoint="/run"
mountpoint="/run/lock"
mountpoint="/run/user/0"
```
（不再有 `/rootfs`、`/etc/hosts`、`/host/*`）

### 2. Prometheus 端（relabel 后，应只剩 `/`）

```bash
curl -s -G http://10.12.7.250:9091/api/v1/query \
  --data-urlencode 'query=count by (instance, mountpoint) (node_filesystem_size_bytes{job="Node"})'
```

期望：
```
10.12.7.218:9100  mountpoint=/
10.12.7.220:9100  mountpoint=/
10.12.7.250:9100  mountpoint=/
```

### 3. Grafana
刷新 node 看板 → 磁盘面板只显示 `/`。

## 五、涉及文件与备份

| 主机 | 文件 | 备份 | 改动 |
|------|------|------|------|
| 250 | `/opt/prometheus-data/conf/prometheus.yml` | `.bak-20260911-node`、`.bak2-20260911-node` | 加 `metric_relabel_configs` |
| 250 | `/opt/acoinfo/swfactory/prometheus/prometheus.yml` | `.bak-20260911` | 同步（保证下次部署一致） |
| 218 | `/opt/dockercomposenode_exporter.yml` | `.bak-20260911` | 升级 v1.8.2 + 加 `--path.*` + 挂载改 ro |
| 220 | `/opt/dockercomposenode_exporter.yml` | `.bak-20260911` | 同上 |

## 六、一句话总结

> **问题**：node_exporter 采集了所有挂载点（tmpfs/NFS），且 218/220 配置残缺还暴露了容器内挂载点。
> **解决**：① Prometheus relabel 只保留 `/`（兜底，所有看板生效）；② 修复 node_exporter 的 `--path.*` 参数（治本）。
> 两层做完，node 监控只看得到 `/.`
