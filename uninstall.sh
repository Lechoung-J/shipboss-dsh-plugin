#!/usr/bin/env bash
# shipboss-dsh-plugin 卸载脚本：
#   1) 从 profile 的 cordis.patch.yml 移除 managed block；
#   2) 删除插件物化出来的技能目录（仅当它带 `.shipboss-version` 版本标记，
#      即确认为本插件所装；用户自己放的同名目录一律不动）。
#
# 安全规则（与 install.sh 同构）：
#   - 默认 dry-run；只有 --apply 才真正修改/删除；
#   - --apply 必须显式给 --dsh-home（否则退出码 2）；
#   - 拒绝写真实 home（$HOME/.dsh）与 /Applications；
#   - 写前做带时间戳备份；没有 managed block 时不做任何修改（幂等）。
#
# 用法：
#   bash uninstall.sh --profile <name> [--dsh-home <dir>] [--apply|--dry-run]
#
# 退出码：同 install.sh（0/1/2/4）。
set -euo pipefail

lower_path() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
path_is_same_or_under() {
  local child parent
  child=$(lower_path "$1")
  parent=$(lower_path "$2")
  [ "$child" = "$parent" ] && return 0
  case "$child" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

BEGIN_MARK='# >>> shipboss managed block (install.sh) >>>'
END_MARK='# <<< shipboss managed block <<<'

usage() {
  cat <<'USAGE'
用法: bash uninstall.sh --profile <name> [--dsh-home <dir>] [--apply|--dry-run]

  --profile <name>   目标 profile 名（$DSH_HOME/profiles/<name>）
  --dsh-home <dir>   DSH home 根目录（真删时必须是复制出来的临时目录）
  --apply            真正修改/删除（默认 dry-run，只打印将删除什么）
  --dry-run          显式 dry-run（默认行为）
  -h, --help         显示本帮助
USAGE
}

profile=''
dsh_home=''
apply=0
dry=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      [ $# -ge 2 ] || { echo 'uninstall.sh: --profile needs a value' >&2; exit 2; }
      profile="$2"; shift 2 ;;
    --profile=*)
      profile="${1#*=}"; shift ;;
    --dsh-home)
      [ $# -ge 2 ] || { echo 'uninstall.sh: --dsh-home needs a value' >&2; exit 2; }
      dsh_home="$2"; shift 2 ;;
    --dsh-home=*)
      dsh_home="${1#*=}"; shift ;;
    --apply)
      apply=1; shift ;;
    --dry-run)
      dry=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "uninstall.sh: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ "$apply" -eq 1 ] && [ -z "$dsh_home" ]; then
  echo 'uninstall.sh: refusing --apply without --dsh-home.' >&2
  exit 2
fi

if [ -z "$profile" ]; then
  echo 'uninstall.sh: --profile is required' >&2
  usage >&2
  exit 2
fi

if [ -n "$dsh_home" ]; then
  if [ ! -d "$dsh_home" ]; then
    echo "uninstall.sh: --dsh-home does not exist: $dsh_home" >&2
    exit 1
  fi
  dsh_home_abs=$(cd "$dsh_home" && pwd -P)
else
  dsh_home_abs="\$DSH_HOME"
fi

if [ "$dsh_home_abs" != '$DSH_HOME' ]; then
  home_abs=$(cd "$HOME" && pwd -P)
  if path_is_same_or_under "$dsh_home_abs" "$home_abs"; then
    echo "uninstall.sh: refusing to modify the real home / DSH home ($dsh_home_abs)." >&2
    exit 4
  fi
  if path_is_same_or_under "$dsh_home_abs" /Applications; then
    echo "uninstall.sh: refusing to modify /Applications." >&2
    exit 4
  fi
fi

if [ "$dsh_home_abs" = '$DSH_HOME' ]; then
  patch_file="\$DSH_HOME/profiles/$profile/cordis.patch.yml"
  skill_dir="\$DSH_HOME/skills/shipboss"
else
  patch_file="$dsh_home_abs/profiles/$profile/cordis.patch.yml"
  skill_dir="$dsh_home_abs/skills/shipboss"
fi

if [ "$apply" -eq 0 ] || [ "$dry" -eq 1 ]; then
  echo "uninstall.sh: DRY-RUN (nothing written)"
  echo "uninstall.sh: would remove the managed block (if present) from $patch_file"
  if [ -f "$skill_dir/.shipboss-version" ]; then
    echo "uninstall.sh: would remove the plugin-managed skill directory $skill_dir"
  else
    echo "uninstall.sh: would leave $skill_dir alone (no .shipboss-version marker)"
  fi
  exit 0
fi

# 1) 移除 profile patch 里的 managed block。
if [ ! -f "$patch_file" ]; then
  echo "uninstall.sh: no such file: $patch_file" >&2
  exit 1
fi

tmp=$(mktemp "${patch_file}.tmp.XXXXXX")
trap 'rm -f "$tmp"' EXIT
awk -v start="$BEGIN_MARK" -v end="$END_MARK" '
  $0 == start { skip = 1; next }
  $0 == end   { skip = 0; next }
  skip != 1   { print }
' "$patch_file" > "$tmp"

if cmp -s "$tmp" "$patch_file"; then
  echo "uninstall.sh: no shipboss managed block in $patch_file (nothing to do there)"
else
  stamp=$(date +%Y%m%d-%H%M%S)
  backup="${patch_file}.bak-${stamp}"
  if [ -e "$backup" ]; then
    backup="${backup}-$$"
  fi
  cp -p "$patch_file" "$backup"
  cat "$tmp" > "$patch_file"
  echo "uninstall.sh: backup written: $backup"
  echo "uninstall.sh: removed shipboss managed block from $patch_file"
fi

# 2) 只删自己装的技能目录：必须有 .shipboss-version 标记。
if [ -f "$skill_dir/.shipboss-version" ]; then
  removed="$skill_dir.uninstalled-$(date +%Y%m%d-%H%M%S)"
  if [ -e "$removed" ]; then
    removed="${removed}-$$"
  fi
  mv "$skill_dir" "$removed"
  rm -rf "$removed"
  echo "uninstall.sh: removed plugin-managed skill directory $skill_dir"
else
  echo "uninstall.sh: left $skill_dir alone (no .shipboss-version marker)"
fi
