#!/bin/sh
# Bootstrap only: fetch a pinned native executable before Lean is available.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime_root=${EGGSHELL_PREFIX:-${HOME:?HOME or EGGSHELL_PREFIX is required}/.local}
project=$PWD
check_only=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) runtime_root=${2:?--prefix needs a path}; shift 2 ;;
    --project) project=${2:?--project needs a path}; shift 2 ;;
    --check) check_only=true; shift ;;
    *) echo 'usage: setup.sh [--prefix PATH] [--project PATH] [--check]' >&2; exit 1 ;;
  esac
done
case "$runtime_root" in /*) ;; *) echo '--prefix must be absolute' >&2; exit 1 ;; esac
project=$(CDPATH= cd -- "$project" && pwd)
export EGGSHELL_PREFIX="$runtime_root"
unset CODEX_THREAD_ID
runtime=$runtime_root/libexec/eggshell
marker=$runtime_root/libexec/eggshell.owner
if "$check_only"; then
  if [ ! -x "$runtime" ] || [ ! -f "$marker" ] || [ "$(cat "$marker")" != o8vm/eggshell ]; then
    echo '{"runtime":"missing","configuration":"unknown"}'
    exit 1
  fi
  if ! "$runtime" --help | grep -q 'eggshell setup'; then
    echo '{"runtime":"update_required","configuration":"unchecked"}'
    exit 1
  fi
  exec "$runtime" setup --project "$project" --check
fi
case "$(uname -s)" in Darwin) platform=macos ;; Linux) platform=linux ;; *) exit 1 ;; esac
case "$(uname -m)" in arm64|aarch64) arch=aarch64 ;; x86_64|amd64) arch=x86_64 ;; *) exit 1 ;; esac
pins=$root/runtime-pins/$platform-$arch
{
  IFS= read -r release
  IFS= read -r asset
  IFS= read -r expected
} < "$pins"
case "$release:$asset" in *[!a-zA-Z0-9._:-]*) echo 'Invalid runtime asset name' >&2; exit 1 ;; esac
case "$expected" in *[!0-9a-f]*|'') echo 'Invalid runtime checksum' >&2; exit 1 ;; esac
[ "${#expected}" -eq 64 ] || exit 1
temporary=$(mktemp -d "${TMPDIR:-/tmp}/eggshell-setup.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM
archive=$temporary/runtime.tar.gz
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --max-time 60 --max-filesize 104857600 \
  "https://github.com/momonpya/eggshell/releases/download/$release/$asset" --output "$archive"
if command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$archive" | awk '{print $1}')
else
  actual=$(sha256sum "$archive" | awk '{print $1}')
fi
[ "$actual" = "$expected" ] || { echo 'Runtime checksum mismatch; nothing installed' >&2; exit 1; }
[ "$(tar -tzf "$archive")" = eggshell ] || { echo 'Unexpected runtime archive members' >&2; exit 1; }
case "$(tar -tvzf "$archive")" in -*) ;; *) echo 'Runtime must be a regular file' >&2; exit 1 ;; esac
tar -xzf "$archive" -C "$temporary" eggshell
chmod 755 "$temporary/eggshell"
"$temporary/eggshell" install runtime
"$runtime" setup --project "$project"
echo 'Review Eggshell in /hooks, start a new chat, and verify two-chat reuse.'
