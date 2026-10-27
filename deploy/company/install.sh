#!/usr/bin/env bash
# install.sh — 在「公司服务器（dj 主机）」上以 root 安装公司版 systemd 单元。
#
# 做的事：render_units 渲染 deploy/*.service|*.timer -> 加上 deploy/company/*.service|*.timer
#         -> 备份同名旧文件(.bak-<时间戳>) -> 复制到 /etc/systemd/system/ -> daemon-reload。
# 默认「不 enable、不 start」任何东西。
#
# 用法：
#   sudo ./install.sh [--dry-run] [--target-dir DIR] [--enable UNIT [UNIT...]]
#     --dry-run          只打印将复制的文件和与现有文件的 diff，不改任何东西
#     --target-dir DIR   安装目录（默认 /etc/systemd/system；非默认目录时不 daemon-reload/enable，供本机测试）
#     --enable U...      安装后 `systemctl enable --now` 指定的 timer/service（按给定顺序）
#
# 拒绝在 hostname 为 lark-bot 的机器（GCP 线上主机）上运行。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TARGET="/etc/systemd/system"
TARGET="${DEFAULT_TARGET}"
DRY_RUN=0
ENABLE=()

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit "${1:-2}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --target-dir) TARGET="${2:?--target-dir 需要目录}"; shift 2 ;;
    --enable)
      shift
      [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ] || { echo "--enable 需要至少一个 unit 名" >&2; usage 2; }
      while [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; do ENABLE+=("$1"); shift; done ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

# 防呆：GCP 线上主机 hostname 是 lark-bot，绝不在上面安装公司版单元
HN_FULL="$(hostname 2>/dev/null || true)"
HN_SHORT="$(hostname -s 2>/dev/null || echo "${HN_FULL}")"
if [ "${HN_FULL}" = "lark-bot" ] || [ "${HN_SHORT}" = "lark-bot" ]; then
  echo "拒绝运行：当前 hostname=${HN_FULL}，这是 GCP 线上主机（lark-bot）。公司版单元只能装在公司服务器上。" >&2
  exit 3
fi

REAL_TARGET=0
[ "${TARGET}" = "${DEFAULT_TARGET}" ] && REAL_TARGET=1
if [ "${DRY_RUN}" -eq 0 ] && [ "${REAL_TARGET}" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "需要 root（或用 --dry-run / --target-dir 测试）" >&2; exit 2
fi
if [ "${#ENABLE[@]}" -gt 0 ] && [ "${REAL_TARGET}" -ne 1 ]; then
  echo "--enable 只能配合默认 --target-dir 使用" >&2; exit 2
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

echo "[1/4] 渲染 deploy/ 一层的单元 -> ${STAGE}/rendered"
python3 "${HERE}/render_units" --out "${STAGE}/rendered" --quiet >"${STAGE}/render.log"
tail -n 3 "${STAGE}/render.log"

echo "[2/4] 汇总待安装文件（渲染结果 + deploy/company 专属单元）"
mkdir -p "${STAGE}/all"
cp "${STAGE}/rendered/"* "${STAGE}/all/"
shopt -s nullglob
for f in "${HERE}"/*.service "${HERE}"/*.timer; do cp "${f}" "${STAGE}/all/"; done
shopt -u nullglob

TS="$(date +%Y%m%d-%H%M%S)"
CHANGED=0
echo "[3/4] 安装到 ${TARGET}（dry-run=${DRY_RUN}）"
[ "${DRY_RUN}" -eq 1 ] || mkdir -p "${TARGET}"
for src in "${STAGE}/all/"*; do
  name="$(basename "${src}")"
  dst="${TARGET}/${name}"
  if [ -f "${dst}" ] && cmp -s "${src}" "${dst}"; then
    echo "  unchanged: ${name}"; continue
  fi
  CHANGED=$((CHANGED + 1))
  if [ -f "${dst}" ]; then
    echo "  update   : ${name}（旧文件备份为 ${name}.bak-${TS}）"
    [ "${DRY_RUN}" -eq 1 ] && { diff -u "${dst}" "${src}" | sed 's/^/      /' || true; }
    [ "${DRY_RUN}" -eq 1 ] || cp -p "${dst}" "${dst}.bak-${TS}"
  else
    echo "  new      : ${name}"
  fi
  [ "${DRY_RUN}" -eq 1 ] || install -m 0644 "${src}" "${dst}"
done
if [ "${DRY_RUN}" -eq 1 ]; then echo "  共 ${CHANGED} 个文件将被写入（dry-run，未写入）"; else echo "  共 ${CHANGED} 个文件已写入"; fi

echo "[4/4] daemon-reload / enable"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "  dry-run：不执行 daemon-reload"
  [ "${#ENABLE[@]}" -gt 0 ] && echo "  dry-run：将 enable --now: ${ENABLE[*]}"
  exit 0
fi
if [ "${REAL_TARGET}" -ne 1 ]; then
  echo "  非默认 --target-dir：跳过 daemon-reload / enable"; exit 0
fi
systemctl daemon-reload
echo "  daemon-reload OK"
if [ "${#ENABLE[@]}" -eq 0 ]; then
  echo "  未指定 --enable：没有 enable / start 任何单元。"
  exit 0
fi
for u in "${ENABLE[@]}"; do
  [ -f "${TARGET}/${u}" ] || { echo "  没有这个单元文件: ${u}" >&2; exit 1; }
done
for u in "${ENABLE[@]}"; do
  echo "  enable --now ${u}"
  systemctl enable --now "${u}"
done
