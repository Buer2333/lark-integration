# lark-integration — VPS 运行时 + 调度基础设施

## 职责边界（改动前先看这里）

lark-integration 回答一个问题：**"lark-bot 怎么在 VPS 上跑 / 谁定时踢它"**。
lark-bot 回答另一个问题：**"job 做什么"**。

### 改动归属速查

| 改动类型 | 归属仓库 |
|---|---|
| `*.service` / `*.timer` systemd unit | **lark-integration**（本仓库） |
| VPS bootstrap / 运维脚本（`setup-server.sh` / `health-check.sh` / `deploy-service.sh`） | **lark-integration** |
| cron-job.org 或外部调度指向的 `repository_dispatch` workflow | **lark-integration** |
| VPS sudoers 配置、手动 `systemctl` 操作 | **lark-integration**（记在下方"VPS 手动操作日志"） |
| `.py` 业务逻辑 / 新 job 的 Python 实现 | **lark-bot** |
| 应用级 CI（跑 pytest / SSH 部署 Python 代码） | **lark-bot** |

### 常见耦合场景

- **新 job + 定时跑** → lark-bot 加 `jobs/new_job.py` + 注册 `run.py`；lark-integration 加 `deploy/new-job.{service,timer}`
- **只改频率** → 只改本仓库的 `.timer` OnCalendar
- **只改 job 行为/输出** → 只改 lark-bot 的 Python 代码

### 强制约束

`.github/workflows/boundary-check.yml` 有 guard：本仓库出现任何 `*.py` → CI 红。
lark-bot 有对称 guard：出现任何 `*.service` / `*.timer` → CI 红。
历史教训：2026-04-09 lark-bot/deploy/ 和 2026-04-10 lark-integration/deploy/ 两边各存一份 `gmvmax-monitor.timer`，两天后 drift 暴露。孤儿已于 2026-04-11 清理。

---

## 项目定位

**类型：调度/运行时基础设施仓库（无 Python 业务代码）**

### 三大子职责

1. **systemd 运行时契约**（`deploy/*.service` + `*.timer`）
   定义 lark-bot 的每个 job 在 VPS 上怎么被启动、以哪个用户、哪个工作目录、哪个 env 文件、哪个频率。VPS 上 `/etc/systemd/system/` 的 unit 文件应该与本仓库 `deploy/` **逐字节一致**。

2. **VPS bootstrap / 运维脚本**
   - `setup-server.sh` — 一次性 bootstrap（git clone、venv、systemd enable 等）
   - `health-check.sh` — 运维健康检查
   - `deploy-service.sh` — 手动推送单个 unit 文件到 VPS 的辅助脚本

3. **外部调度触发器 workflow**
   - ~~`.github/workflows/hourly-jobs.yml`~~ — 已于 2026-04-11 15:58 UTC 删除，hourly jobs 完全由 VPS `hourly-jobs.timer` 承担
   - `.github/workflows/nad-material-report.yml` — 事件驱动，飞书 `/report` 指令触发（不迁移）
   - `.github/workflows/video-transcribe.yml` — 事件驱动 + whisper/ffmpeg 重资源（永久保留 GH Actions，VPS e2-micro 容量不够）

## 部署流程

### 当前状态（2026-04-11 起）

- **Python 代码** → lark-bot 的 `deploy.yml` 自动 SSH pull + 重启服务
- **systemd unit 文件** → 本仓库的 `deploy-systemd.yml` 自动同步到 VPS

### `deploy-systemd.yml` 工作原理

- 触发：push 到 main 且 `deploy/*.service` 或 `deploy/*.timer` 有变更（也支持 `workflow_dispatch` 手动触发空跑）
- 流程：
  1. `appleboy/scp-action` 把 `deploy/*.{service,timer}` 推到 VPS 的 `/tmp/deploy-systemd-staging/`
  2. `appleboy/ssh-action` 逐个 `cmp` 对比 `/etc/systemd/system/` 下的现有文件
  3. diff 的用 `sudo install -m 0644 -o root -g root` 写入目标位置
  4. 有变更才 `sudo systemctl daemon-reload`
  5. 对每个变更的 `.timer` `sudo systemctl restart` + `is-active` 验证
- **跳过** `lark-bot-ws.service` / `tiktok-gateway.service`——这两个长驻 daemon 归 lark-bot/deploy.yml 管，本 workflow 不越界
- 不用 sudoers 定制：VPS 的 `shining` 用户已在 `google-sudoers` 组自带 passwordless sudo
- 不用 `rsync`：VPS 未安装，改用 `sudo install`

### 手动触发 / 紧急回退

```bash
# 强制空跑一次对齐（所有 unchanged 说明本地和 VPS 一致）
gh workflow run deploy-systemd.yml -R Buer2333/lark-integration

# 查看最近一次运行
gh run list -R Buer2333/lark-integration --workflow=deploy-systemd.yml --limit 3

# 紧急情况下手动同步某个文件（等价于 workflow 的单文件逻辑）
gcloud compute scp deploy/xxx.timer lark-bot:/tmp/ --zone=us-west1-b
gcloud compute ssh lark-bot --zone=us-west1-b --command="sudo install -m 0644 -o root -g root /tmp/xxx.timer /etc/systemd/system/xxx.timer && sudo systemctl daemon-reload && sudo systemctl restart xxx.timer"
```

## VPS 手动操作日志

> 任何 sudoers 调整、非自动化的 systemd 操作、一次性配置变更都记在这里。避免"只存在于人脑里"的知识。

| 日期 | 操作 | 原因 |
|---|---|---|
| 2026-04-11 | 手动 `scp` + `daemon-reload` `gmvmax-monitor.timer` 从 `*:00,30` → `*:05,35` | 1529d7b commit 后暴露 lark-integration 无自动部署，drift 2 天 |
| 2026-04-11 | 在 lark-integration repo 配置 `VPS_HOST`/`VPS_USER`/`VPS_SSH_KEY` secrets | 新增 `deploy-systemd.yml` 需要 SSH 到 VPS；key 复用 `~/.ssh/google_compute_engine` |
| 2026-04-11 | 启动 hourly-jobs VPS ↔ GH Actions 双跑观察窗口 | Phase C 迁移 hourly-jobs 到 VPS systemd。Cron-job.org `hourly-trigger` 仍在 :58 触发 GH Actions（pause 待 C4），VPS `hourly-jobs.timer` 在 `:00` 触发。观察 3 个整点（13:00/14:00/15:00 UTC）两侧推送内容一致后关停 GH Actions 侧。 |
| 2026-04-11 13:00 UTC | **VPS 首次 hourly-jobs 数据 drift 事故** — `sudo systemctl stop && disable hourly-jobs.timer` | 首次 VPS 运行时 `~/.cache/lark-bot` 缺失 GH Actions 的累积状态：`account_discovery.json` 17k (vs GH 207k)、`balance_snapshot.json` 4k (vs 94k)、`ban_status.json` 13k (vs 15k，缺 ~8 条历史封户)、`ad_cost.json` 150k (vs 218k，缺封户历史消耗)。结果：47 个 cached-banned 重新推送到飞书（误报），ad_report 消耗 ~$804 ≈ GH Actions $1.6k 的一半。立即停 timer 防止 14:00 UTC 再次误推。 |
| 2026-04-11 13:30 UTC | 通过一次性 `dump-cache.yml` workflow 提取 GH Actions `~/.cache/lark-bot` 并 scp 到 VPS 覆盖 5 个核心文件（`ban_status`/`ad_cost`/`balance_snapshot`/`account_discovery`/`shop_gmv`），保留 VPS 本地的 `gmvmax_snapshot_*.json` | VPS 从未运行过 `hourly-jobs` 所以没有累积状态，gmvmax-monitor 只维护自己的 per-advertiser 快照。备份存于 `~/.cache/lark-bot.bak-pre-gh-restore/`。用 `FEISHU_ENV=test` 手动跑一遍三个 job 验证：`18 active, 47 cached-banned, 0 newly banned` 完全对齐 GH Actions，ad_report 总 Cost ~$1,938 回到正确量级。 |
| 2026-04-11 13:45 UTC | `sudo systemctl enable --now hourly-jobs.timer` 恢复 | 测试群验证通过，cache 对齐完成。14:00 UTC 起恢复 VPS ↔ GH Actions 双跑观察窗口（原计划被事故中断）。dump-cache.yml 留作一次性工具，C4 时删除。 |
| 2026-04-11 15:58 UTC | **双跑窗口被 TikTok token 限流打碎** — 紧急跳到 C4 | VPS 15:58:04 起跑，GH Actions 15:58:00 起 repository_dispatch，两边用同一套 `TIKTOK_ACCESS_TOKEN_XINCHENG/ZECHENG`。TikTok 40100 "Too many requests" 是 **per-token** 限流不看 IP，两条并发链路互相打 → 两边各 13-14 次 API 失败 → 生成的 ad_report 卡片数据崩掉（FlyNew-US-Shilajit MTD Cost $3.42 / ROI 16272、Hiileathy-US-Shilajit Today Cost $34 / ROI 157）。原 Plan C "双跑观察 3 小时再切" 的假设是错的 —— 之前没把 TikTok API token-level 限流考虑进去。决定：立即删 `hourly-jobs.yml` + `dump-cache.yml`（即使 cron-job.org 继续 fire，workflow 不存在 repository_dispatch 就空触发），cron-job.org 那侧的 pause 留给用户 UI 操作。 |

## 相关仓库

- [lark-bot](https://github.com/Buer2333/lark-bot) — Python 业务代码、MCP Server、应用 CI/CD

## 常用命令

```bash
# VPS 查看 timer 列表
gcloud compute ssh lark-bot --zone=us-west1-b --command="systemctl list-timers"

# VPS 查看某 job 最近日志
gcloud compute ssh lark-bot --zone=us-west1-b --command="journalctl -u gmvmax-monitor.service -n 100"

# VPS 手动触发一次 job（不等 timer）
gcloud compute ssh lark-bot --zone=us-west1-b --command="sudo systemctl start gmvmax-monitor.service"
```
