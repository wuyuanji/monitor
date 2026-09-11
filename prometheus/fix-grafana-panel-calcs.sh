#!/usr/bin/env bash
#
# fix-grafana-panel-calcs.sh
# ------------------------------------------------------------------
# 用途：把 Grafana 看板中指定面板的 Calculation(计算方式) 从 mean(平均)
#       改成 lastNotNull(当前值)，修复"容器数量/CPU 显示小数"类问题。
# 原理：调用 Grafana 官方 HTTP API，读看板 -> 改一个字段 -> 写回。
#       与 Grafana 版本基本无关(只依赖两个长期稳定的 API 端点)。
#
# 用法：
#   GRAFANA_PASS=xxx ./fix-grafana-panel-calcs.sh              # 实际执行
#   GRAFANA_PASS=xxx DRY_RUN=1 ./fix-grafana-panel-calcs.sh    # 只预览不改
#
# 可调环境变量：
#   GRAFANA_URL           默认 http://localhost:3300
#   GRAFANA_USER          默认 admin
#   GRAFANA_PASS          (必填)
#   PANEL_TITLE_PATTERN   面板标题匹配(子串,不区分大小写) 默认 "Running containers"
#   CALC_TO               目标计算方式 默认 lastNotNull
#   DRY_RUN               1=只预览
#   BACKUP_DIR            备份目录 默认 ./grafana-calcs-backup
# ------------------------------------------------------------------
set -euo pipefail

: "${GRAFANA_URL:=http://localhost:3300}"
: "${GRAFANA_USER:=admin}"
: "${PANEL_TITLE_PATTERN:=Running containers}"
: "${CALC_TO:=lastNotNull}"
: "${DRY_RUN:=0}"
: "${BACKUP_DIR:=./grafana-calcs-backup}"

if [[ -z "${GRAFANA_PASS:-}" ]]; then
    echo "ERROR: 请设置 GRAFANA_PASS (例: GRAFANA_PASS=acoinfo $0)" >&2
    exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "ERROR: 需要 python3" >&2; exit 1; }
command -v curl    >/dev/null 2>&1 || { echo "ERROR: 需要 curl" >&2; exit 1; }

export GRAFANA_URL GRAFANA_USER GRAFANA_PASS PANEL_TITLE_PATTERN CALC_TO DRY_RUN BACKUP_DIR

python3 << 'PYEOF'
import json, os, base64, urllib.request, urllib.error

URL   = os.environ['GRAFANA_URL'].rstrip('/')
USER  = os.environ['GRAFANA_USER']
PASS  = os.environ['GRAFANA_PASS']
TITLE = os.environ['PANEL_TITLE_PATTERN']
CALC  = os.environ['CALC_TO']
DRY   = os.environ['DRY_RUN'] == '1'
BK    = os.environ['BACKUP_DIR']

AUTH = base64.b64encode(f'{USER}:{PASS}'.encode()).decode()

def api(path, method='GET', body=None):
    req = urllib.request.Request(URL + path, method=method)
    req.add_header('Authorization', 'Basic ' + AUTH)
    req.add_header('Content-Type', 'application/json')
    if body is not None:
        req.data = json.dumps(body).encode()
    return json.load(urllib.request.urlopen(req, timeout=30))

# 0) 连通性/鉴权检查
try:
    health = api('/api/health')
    print(f"[OK] Grafana {health.get('version','?')} @ {URL}")
except urllib.error.HTTPError as e:
    print(f"[FAIL] 无法访问/鉴权失败: HTTP {e.code}"); raise SystemExit(1)
except Exception as e:
    print(f"[FAIL] 连接失败: {e}"); raise SystemExit(1)

os.makedirs(BK, exist_ok=True)

# 1) 列出所有看板，逐个检查
dashboards = api('/api/search?type=dash-db&limit=1000')
print(f"[i] 扫描 {len(dashboards)} 个看板，匹配面板标题含 \"{TITLE}\" 的，目标 Calculation={CALC}"
      + ("  (DRY-RUN 预览模式)" if DRY else ""))
print("-" * 72)

changed = 0
for meta in dashboards:
    uid = meta.get('uid')
    if not uid:
        continue
    try:
        obj = api('/api/dashboards/uid/' + uid)
    except Exception:
        continue
    dash = obj.get('dashboard', {})
    # 收集所有嵌套面板(含 row 内的)
    panels = []
    for p in dash.get('panels', []):
        panels.append(p)
        panels.extend(p.get('panels', []) or [])
    hits = [p for p in panels if TITLE.lower() in (p.get('title') or '').lower()]
    if not hits:
        continue

    need = False
    for p in hits:
        ro = p.get('options', {}).get('reduceOptions', {})
        cur = ro.get('calcs')
        if cur and cur != [CALC]:
            need = True
    if not need:
        print(f"  [skip]    {dash.get('title',''):<30} 已是 {CALC}")
        continue

    # 2) 备份(改前)
    bkfile = os.path.join(BK, uid + '.json')
    json.dump(obj, open(bkfile, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

    # 3) 改动
    for p in hits:
        ro = p.setdefault('options', {}).setdefault('reduceOptions', {})
        ro['calcs'] = [CALC]

    if DRY:
        print(f"  [dry]     {dash.get('title',''):<30} 将修改 {len(hits)} 个面板  (备份 {bkfile})")
    else:
        try:
            dash.pop('id', None)          # provisioning/import 时不带自增 id
            res = api('/api/dashboards/db', 'POST',
                      {'dashboard': dash, 'overwrite': True,
                       'message': f'fix calcs -> {CALC}'})
            print(f"  [OK]      {dash.get('title',''):<30} {len(hits)} 个面板 -> {CALC} "
                  f"(v{res.get('version')}, 备份 {bkfile})")
        except urllib.error.HTTPError as e:
            print(f"  [FAIL]    {dash.get('title',''):<30} HTTP {e.code}: {e.read()[:120]}")
            continue
    changed += 1

print("-" * 72)
print(f"[done] {'将修改' if DRY else '已修改'} {changed} 个看板；备份目录: {BK}")
if changed and not DRY:
    print("[tip] 在 Grafana 界面刷新看板即可看到效果")
PYEOF
