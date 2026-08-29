#!/bin/sh

set -eu

repository="o8vm/eggshell"
release_base="${EGGSHELL_RELEASE_URL:-https://github.com/${repository}/releases/latest/download}"
install_dir="${EGGSHELL_BIN_DIR:-${HOME}/.local/bin}"
target="${install_dir}/eggshell"
owner_file="${install_dir}/.eggshell.owner"
owner_identity="o8vm/eggshell"
staged=""

case "$(uname -s)" in
  Darwin) platform="macos" ;;
  Linux) platform="linux" ;;
  *) echo "eggshell: unsupported operating system: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) architecture="aarch64" ;;
  x86_64|amd64) architecture="x86_64" ;;
  *) echo "eggshell: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

asset="eggshell-${platform}-${architecture}.tar.gz"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/eggshell.XXXXXX")"
archive="${temporary}/${asset}"
checksum="${archive}.sha256"

cleanup() {
  rm -f "${temporary}/eggshell" "${archive}" "${checksum}"
  if [ -n "${staged}" ]; then rm -f "${staged}"; fi
  rmdir "${temporary}" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  "${release_base}/${asset}" --output "${archive}"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  "${release_base}/${asset}.sha256" --output "${checksum}"

expected="$(tr -d '[:space:]' < "${checksum}")"
if command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${archive}" | awk '{print $1}')"
else
  echo "eggshell: shasum or sha256sum is required" >&2
  exit 1
fi

if [ "${actual}" != "${expected}" ]; then
  echo "eggshell: release checksum mismatch" >&2
  exit 1
fi

tar -xzf "${archive}" -C "${temporary}" eggshell
mkdir -p "${install_dir}"
if [ -e "${target}" ] || [ -e "${owner_file}" ]; then
  if [ ! -f "${target}" ] || [ ! -f "${owner_file}" ] || \
      [ "$(cat "${owner_file}")" != "${owner_identity}" ]; then
    echo "eggshell: refusing to replace unowned ${target}" >&2
    exit 1
  fi
fi
staged="${target}.next.$$"
install -m 755 "${temporary}/eggshell" "${staged}"
mv -f "${staged}" "${target}"
staged=""
printf '%s\n' "${owner_identity}" > "${owner_file}"
chmod 600 "${owner_file}"
"${target}" install codex

echo "Run 'egg init' once in each project that should keep an Eggshell work graph."
case ":${PATH}:" in
  *:"${install_dir}":*) ;;
  *) echo "Add ${install_dir} to PATH to use egg outside Codex." ;;
esac
