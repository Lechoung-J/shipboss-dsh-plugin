#!/usr/bin/env bash
# shipboss-dsh-plugin 安装脚本：把带 config 的 insert 块写进 profile 的 cordis.patch.yml。
#
# 技能本身由插件 apply() 在宿主启动时物化到 $DSH_HOME/skills/shipboss/；
# 本脚本只负责让 profile 加载这个插件。
#
# 安全规则（硬约束）：
#   - 默认 dry-run；只有 --apply 才写文件；
#   - --apply 必须显式给 --dsh-home（否则直接退出码 2）；
#   - 拒绝写真实 home（$HOME/.dsh）与 /Applications；
#   - 写前做带时间戳备份；重复执行结果幂等。
#
# 用法：
#   bash install.sh --profile <name> [--dsh-home <dir>] [--apply]
#
# 退出码：
#   0 成功 / dry-run 成功
#   1 参数指向的 profile 不存在等环境问题
#   2 参数错误（含 --apply 未给 --dsh-home）
#   4 拒绝写入真实 home / /Applications
set -euo pipefail

# 路径边界比较：大小写归一化（macOS 默认大小写不敏感），
# 符号链接已由调用方的 pwd -P 归一化。按 `/` 边界匹配，避免 /Applications-evil 误判。
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
用法: bash install.sh --profile <name> [--dsh-home <dir>] [--apply]

  --profile <name>   目标 profile 名（$DSH_HOME/profiles/<name>）
  --dsh-home <dir>   DSH home 根目录（真装时必须是复制出来的临时目录）
  --apply            真正写文件（默认 dry-run，只打印将写入的块）
  --dry-run          显式 dry-run（默认行为）
  -h, --help         显示本帮助

没有 --dsh-home 的 --apply 会被直接拒绝（退出码 2）。
USAGE
}

profile=''
dsh_home=''
apply=0
dry=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      [ $# -ge 2 ] || { echo 'install.sh: --profile needs a value' >&2; exit 2; }
      profile="$2"; shift 2 ;;
    --profile=*)
      profile="${1#*=}"; shift ;;
    --dsh-home)
      [ $# -ge 2 ] || { echo 'install.sh: --dsh-home needs a value' >&2; exit 2; }
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
      echo "install.sh: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

# AC-10 / 硬约束：--apply 且未给 --dsh-home -> 直接拒绝。
if [ "$apply" -eq 1 ] && [ -z "$dsh_home" ]; then
  echo 'install.sh: refusing --apply without --dsh-home (this guard protects ~/.dsh/profiles/desktop).' >&2
  exit 2
fi

if [ -z "$profile" ]; then
  echo 'install.sh: --profile is required' >&2
  usage >&2
  exit 2
fi

if [ -n "$dsh_home" ]; then
  if [ ! -d "$dsh_home" ]; then
    echo "install.sh: --dsh-home does not exist: $dsh_home" >&2
    exit 1
  fi
  dsh_home_abs=$(cd "$dsh_home" && pwd -P)
else
  dsh_home_abs="\$DSH_HOME"
fi

if [ "$dsh_home_abs" != '$DSH_HOME' ]; then
  home_abs=$(cd "$HOME" && pwd -P)
  # 真实 home 根、$HOME/.dsh 以及它们下面的任何路径都拒绝（含裸 $HOME）。
  if path_is_same_or_under "$dsh_home_abs" "$home_abs"; then
    echo "install.sh: refusing to modify the real home / DSH home ($dsh_home_abs). Use a copied profile under \$TMPDIR." >&2
    exit 4
  fi
  if path_is_same_or_under "$dsh_home_abs" /Applications; then
    echo "install.sh: refusing to modify /Applications." >&2
    exit 4
  fi
fi

if [ "$dsh_home_abs" = '$DSH_HOME' ]; then
  profile_dir="\$DSH_HOME/profiles/$profile"
else
  profile_dir="$dsh_home_abs/profiles/$profile"
fi

block=$(cat <<BLOCK
$BEGIN_MARK
- insert:
    - id: shipboss
      name: shipboss-dsh-plugin
      config:
        enabled: true
        skillRoot: null
        onConflict: skip
$END_MARK
BLOCK
)

if [ "$dry" -eq 1 ] || [ "$apply" -eq 0 ]; then
  echo "install.sh: DRY-RUN (nothing written)"
  echo "install.sh: target profile: $profile_dir"
  echo "install.sh: block that would be appended to $profile_dir/cordis.patch.yml:"
  printf '%s\n' "$block"
  exit 0
fi

if [ ! -d "$profile_dir" ]; then
  echo "install.sh: profile directory does not exist: $profile_dir" >&2
  exit 1
fi
patch_file="$profile_dir/cordis.patch.yml"
if [ ! -f "$patch_file" ]; then
  echo "install.sh: profile has no cordis.patch.yml: $patch_file" >&2
  exit 1
fi

# 幂等：先移除旧的 managed block，再追加新的。
tmp=$(mktemp "${patch_file}.tmp.XXXXXX")
trap 'rm -f "$tmp"' EXIT
awk -v start="$BEGIN_MARK" -v end="$END_MARK" '
  $0 == start { skip = 1; next }
  $0 == end   { skip = 0; next }
  skip != 1   { print }
' "$patch_file" > "$tmp"

if [ -s "$tmp" ]; then
  last_byte=$(tail -c 1 "$tmp" | od -An -t x1 | tr -d ' \n')
  if [ "$last_byte" != '0a' ]; then
    printf '\n' >> "$tmp"
  fi
fi
printf '%s\n' "$block" >> "$tmp"

if cmp -s "$tmp" "$patch_file"; then
  echo "install.sh: already installed and up to date: $patch_file"
  exit 0
fi

stamp=$(date +%Y%m%d-%H%M%S)
backup="${patch_file}.bak-${stamp}"
if [ -e "$backup" ]; then
  backup="${backup}-$$"
fi
cp -p "$patch_file" "$backup"
cat "$tmp" > "$patch_file"

echo "install.sh: backup written: $backup"
echo "install.sh: installed shipboss-dsh-plugin into $patch_file"
echo "install.sh: the skill will be materialized on the next DSH start at $dsh_home_abs/skills/shipboss"
