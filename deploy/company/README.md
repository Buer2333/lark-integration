# deploy/company — 公司服务器（dj 主机，CentOS Stream 9）专用 systemd 单元

## 用途

lark-bot 迁到公司服务器后，需要一套和 GCP 线上不同的单元：用户 `larkbot`、家目录 `/home/larkbot/`、
时区统一 UTC、ffmpeg 走 `~/.local/bin` 的静态版。本目录提供：

| 文件 | 作用 |
|---|---|
| `render_units` | 把 `deploy/` 一层的 `*.service` / `*.timer` 渲染成公司版（标准库，Python 3） |
| `hiileathy-fb-{close,roas}.{service,timer}` | 替代 GCP 上的两条 crontab（FB 日结 / FB ROAS 日报） |
| `install.sh` | 在公司服务器以 root 安装渲染结果 + 本目录专属单元 |

## 为什么放子目录（重要）

`.github/workflows/deploy-systemd.yml` 在 push 到 main 且 `deploy/*.service|*.timer|*.conf` 有变动时，
会把这些文件 scp 到 **GCP 线上主机**并 enable / restart。该 workflow 的 paths 过滤和 scp 的 glob 都不递归，
所以 `deploy/company/` 下的文件不会触发、也不会被拷到 GCP。**不要把公司版单元放进 `deploy/` 一层**，
否则合并到 main 就会覆盖 GCP 上的单元。

## 渲染规则（`render_units`）

> 脚本故意不带 `.py` 后缀：本仓库的 `boundary-check.yml` 会对任何 `*.py` 报红（Python 代码归 lark-bot）。

- `User=shining` -> `User=larkbot`；所有 `/home/shining/` -> `/home/larkbot/`
- 每个 `.service` 的 `[Service]` 段：`Environment=TZ=UTC`；`Environment=PATH=/home/larkbot/services/lark-bot/.venv/bin:/home/larkbot/.local/bin:/usr/local/bin:/usr/bin`（原有 PATH/TZ 行被替换）
- 每个 `.timer`：没写时区的 `OnCalendar=` 末尾补 ` UTC`（含 `*:15,45:00` 这类分钟级）；已带 UTC 或其他时区（如 `America/New_York`）的不动
- 没有 `MemoryMax=` 的 `.service` 补上：`lark-bot-ws` 为 `1G`，其余 `500M`；已有的保留
- 跳过（不生成，清单在脚本顶部 `SKIP_FILES`）：`cloudflared.service`、`h3-tunnel.service`、`tiktok-gateway.service`、
  `tts-order-reconcile.service`、`tts-order-reconcile.timer`；非单元文件（Caddyfile、cloudflared-config.yml、`*.conf`、`*.sh`）不处理
- 用法：`python3 render_units [--out DIR] [--check] [--quiet]`；`--check` 只生成到临时目录并打印每个文件的 diff 摘要

## 两个 FB 定时任务

替代 GCP crontab（UTC）：

- `hiileathy-fb-close`：每天 07:57 UTC，`ExecStartPre` 跑 `fb_roas.py --refresh`，`ExecStart` 跑 `fb_daily_close_push.py`
- `hiileathy-fb-roas`：每天 10:00 UTC，`ExecStartPre` 跑 `fb_roas.py --refresh`，`ExecStart` 跑 `fb_daily_roas_push.py --chat ${FB_ROAS_CHAT}`

两者都用 lark-bot 的 venv python，`WorkingDirectory=/home/larkbot/services/hiileathy-review`，
`EnvironmentFile` 依次读 lark-bot 的 `.env` 和 hiileathy-review 的 `.env`（后者覆盖前者）。

**必须配置**：目标群 chat_id 不写在 unit 里。请在 `/home/larkbot/services/hiileathy-review/.env` 里加一行
`FB_ROAS_CHAT=<chat_id>`。没配时 `hiileathy-fb-roas` 会在第一个 `ExecStartPre`（`test -n`）直接失败并触发 `OnFailure` 告警，
不会白跑刷新。两个脚本需要随快照进 `hiileathy-review/scripts/`（见 lark-bot 的 `sync_to_gitee.sh --extra`）。

## 安装和启用

在公司服务器上，以 root：

```bash
cd <本仓库>/deploy/company
./install.sh --dry-run                 # 先看将复制哪些文件、和现有文件的 diff
./install.sh                           # 渲染 -> 备份同名旧文件(.bak-<时间戳>) -> 复制到 /etc/systemd/system -> daemon-reload
./install.sh --enable <unit...>        # 同上，并对指定单元 systemctl enable --now（按给定顺序）
```

- 默认**不 enable、不 start** 任何单元。
- 拒绝在 hostname 为 `lark-bot` 的机器（GCP）上运行。
- 本机测试用 `--target-dir <tmpdir>`（此时不 daemon-reload、不 enable）。

## 切换当天的启用顺序

前提：**GCP 上的 lark-bot-ws 和所有 timer 必须已停**（否则两边同时推送/同时收飞书事件）。

1. 确认 `.env`、数据目录、`hiileathy-review/.env`（含 `FB_ROAS_CHAT`）已就位；`./install.sh --dry-run` 无异常
2. `./install.sh`（只安装，不启用）
3. 先启用 timer：`./install.sh --enable hourly-jobs.timer gmvmax-monitor.timer ... hiileathy-fb-close.timer hiileathy-fb-roas.timer`
   （逐个观察 `systemctl list-timers` 的下次触发时间是否符合预期的 UTC 时刻）
4. **最后**才启用 `lark-bot-ws.service`：`./install.sh --enable lark-bot-ws.service`
5. 观察 `journalctl -u lark-bot-ws -f`，确认长连接建立；回滚 = `systemctl disable --now` 对应单元，GCP 侧恢复
