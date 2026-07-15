#!/bin/bash

# For every k3s/rke2 version newly added to channels (compared against a base
# data.json), this script reports two things per version:
#
#   1. "Adicionadas pelo upstream" — flags that this version introduced compared
#      to the previous patch in the same minor line (binário novo − binário
#      anterior), each marked whether it is already declared in channels. This
#      answers "what did this version add".
#   2. "Faltando no channels" — every flag exposed by the release binary that is
#      NOT declared in serverArgs/agentArgs. This answers "what is missing".
#   Plus "Só no channels" — the inverse (flags in channels not in the binary).
#
# It reads the *resolved* serverArgs/agentArgs directly from data/data.json
# (anchors/merges already expanded by `go generate`), downloads the matching
# release binaries, runs `<bin> server|agent --help`, and diffs the flag sets.
# The check is purely informational and always exits 0.
#
# Usage:
#   ./verify-flags.sh <base-data.json> [head-data.json] [output.md]
#
# Example:
#   ./verify-flags.sh /tmp/base-data.json data/data.json /tmp/flags-report.md

set -euo pipefail

# Check dependencies
for cmd in jq curl tar; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: '$cmd' is not installed or not in PATH. Please install it." >&2
    exit 1
  fi
done

BASE_JSON="${1:-}"
HEAD_JSON="${2:-data/data.json}"
OUT="${3:-/dev/stdout}"

if [[ -z "$BASE_JSON" ]]; then
  echo "Usage: $0 <base-data.json> [head-data.json] [output.md]" >&2
  exit 1
fi
if [[ ! -f "$BASE_JSON" ]]; then
  echo "Error: base data.json not found: $BASE_JSON" >&2
  exit 1
fi
if [[ ! -f "$HEAD_JSON" ]]; then
  echo "Error: head data.json not found: $HEAD_JSON" >&2
  exit 1
fi

# Generic logging/CLI flags that are never cluster configuration and should
# never land in channels. Kept out of the report to reduce noise.
SANITIZE_RE='^(alsologtostderr|config|log|vmodule|help|v)$'

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# extract_help_flags <binary> <server|agent>
# Prints the sanitized set of flag names (one per line, sorted) from --help.
extract_help_flags() {
  local bin="$1" sub="$2"
  "$bin" "$sub" --help 2>/dev/null \
    | grep -oE '^\s+--[a-z0-9-]+' \
    | sed 's/^ *--//' \
    | grep -vE "$SANITIZE_RE" \
    | sort -u
}

# channel_args <data.json> <distro> <version> <serverArgs|agentArgs>
# Prints the declared flag keys for a version (one per line, sorted).
channel_args() {
  local json="$1" distro="$2" version="$3" field="$4"
  jq -r --arg v "$version" \
    ".${distro}.releases[] | select(.version==\$v) | .${field} // {} | keys[]" \
    "$json" 2>/dev/null | sort -u
}

# previous_version <distro> <version>
# Prints the previous patch in the same minor line (highest stable version with
# patch-1) found in the head data.json, or nothing if none exists.
previous_version() {
  local distro="$1" version="$2"
  local num major minor patch prevnum
  num="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' <<<"$version" | head -1)"
  [[ -z "$num" ]] && return 0
  major="$(echo "${num#v}" | cut -d. -f1)"
  minor="$(echo "${num#v}" | cut -d. -f2)"
  patch="$(echo "${num#v}" | cut -d. -f3)"
  (( patch <= 0 )) && return 0
  prevnum="v${major}.${minor}.$((patch - 1))"
  # Versões cujo trecho numérico == prevnum (exclui RCs), maior por sort -V.
  jq -r ".${distro}.releases[].version" "$HEAD_JSON" \
    | grep -v -- '-rc' \
    | awk -v want="$prevnum" '
        match($0, /v[0-9]+\.[0-9]+\.[0-9]+/) && substr($0, RSTART, RLENGTH) == want { print }
      ' \
    | sort -V | tail -1
}

# emit_flag_table <title>   (flags read from stdin)
emit_flag_table() {
  local title="$1"
  local -a flags=()
  mapfile -t flags
  {
    echo "**${title}:** ${#flags[@]}"
    echo ""
    if [[ ${#flags[@]} -gt 0 ]]; then
      echo "| Flag |"
      echo "|------|"
      local f
      for f in "${flags[@]}"; do
        echo "| \`$f\` |"
      done
      echo ""
    fi
  } >> "$OUT"
}

# emit_marked_table <title> <set> <col-header>   (flags read from stdin)
# Renders a table marking each flag ✅/❌ according to membership in <set>.
emit_marked_table() {
  local title="$1" set="$2" col="$3"
  local -a flags=()
  mapfile -t flags
  {
    echo "**${title}:** ${#flags[@]}"
    echo ""
    if [[ ${#flags[@]} -gt 0 ]]; then
      echo "| Flag | ${col} |"
      echo "|------|:---:|"
      local f mark
      for f in "${flags[@]}"; do
        if grep -qxF "$f" <<<"$set"; then mark="✅ sim"; else mark="❌ não"; fi
        echo "| \`$f\` | $mark |"
      done
      echo ""
    fi
  } >> "$OUT"
}

# download_binary <distro> <version> -> echoes path to runnable binary, or empty
download_binary() {
  local distro="$1" version="$2"
  local ver_enc="${version//+/%2B}"
  local dest="$WORKDIR/${distro}-${version//[+\/]/_}"

  if [[ "$distro" == "k3s" ]]; then
    local url="https://github.com/k3s-io/k3s/releases/download/${ver_enc}/k3s"
    if curl -sfL "$url" -o "$dest" 2>/dev/null; then
      chmod +x "$dest"
      echo "$dest"
    fi
  else # rke2
    local url="https://github.com/rancher/rke2/releases/download/${ver_enc}/rke2.linux-amd64.tar.gz"
    local tgz="$dest.tar.gz"
    if curl -sfL "$url" -o "$tgz" 2>/dev/null; then
      local ex="$WORKDIR/rke2-extract-${version//[+\/]/_}"
      mkdir -p "$ex"
      if tar -xzf "$tgz" -C "$ex" bin/rke2 2>/dev/null; then
        chmod +x "$ex/bin/rke2"
        echo "$ex/bin/rke2"
      fi
    fi
  fi
}

# process_version <distro> <version>
process_version() {
  local distro="$1" version="$2"

  echo "## ${distro} ${version}" >> "$OUT"
  echo "" >> "$OUT"

  local bin
  bin="$(download_binary "$distro" "$version")"
  if [[ -z "$bin" ]]; then
    echo "> ⚠️ Binário indisponível para download (release ainda não publicada?). Pulando." >> "$OUT"
    echo "" >> "$OUT"
    return
  fi

  # Modelo assimétrico:
  #  - server LÊ o agent também: server --help é comparado com serverArgs ∪ agentArgs
  #    (flag de agent também vale no server).
  #  - agent lê SÓ ele: agent --help é comparado apenas com agentArgs.
  local bin_srv bin_agt ch_srv ch_agt ch_all
  bin_srv="$(extract_help_flags "$bin" server)"
  bin_agt="$(extract_help_flags "$bin" agent)"
  ch_srv="$(channel_args "$HEAD_JSON" "$distro" "$version" serverArgs)"
  ch_agt="$(channel_args "$HEAD_JSON" "$distro" "$version" agentArgs)"
  ch_all="$(printf '%s\n%s\n' "$ch_srv" "$ch_agt" | sort -u | sed '/^$/d')"

  # ---- Novidades: delta vs patch anterior da mesma minor ----
  echo "### 🆕 Adicionadas pelo upstream nesta versão" >> "$OUT"
  echo "" >> "$OUT"
  local prev prev_bin
  prev="$(previous_version "$distro" "$version")"
  if [[ -z "$prev" ]]; then
    echo "> _Sem patch anterior na mesma minor para comparar._" >> "$OUT"
    echo "" >> "$OUT"
  else
    prev_bin="$(download_binary "$distro" "$prev")"
    if [[ -z "$prev_bin" ]]; then
      echo "> ⚠️ Patch anterior \`$prev\` sem binário para comparar." >> "$OUT"
      echo "" >> "$OUT"
    else
      echo "_Comparando com \`$prev\`._" >> "$OUT"
      echo "" >> "$OUT"
      comm -13 <(extract_help_flags "$prev_bin" server) <(echo "$bin_srv") \
        | emit_marked_table "Novas flags de server" "$ch_all" "Já no channels?"
      comm -13 <(extract_help_flags "$prev_bin" agent) <(echo "$bin_agt") \
        | emit_marked_table "Novas flags de agent" "$ch_agt" "Já no agentArgs?"
    fi
  fi

  # ---- Faltando no channels ----
  echo "### ❌ Faltando no channels" >> "$OUT"
  echo "" >> "$OUT"
  # server: tudo do server --help ausente em serverArgs ∪ agentArgs
  comm -23 <(echo "$bin_srv") <(echo "$ch_all") \
    | emit_flag_table "Faltando no server (server --help vs serverArgs + agentArgs)"
  # agent: tudo do agent --help ausente em agentArgs
  comm -23 <(echo "$bin_agt") <(echo "$ch_agt") \
    | emit_flag_table "Faltando no agent (agent --help vs agentArgs)"
}

# new_versions <distro> -> versions present in head but not in base
new_versions() {
  local distro="$1"
  comm -23 \
    <(jq -r ".${distro}.releases[].version" "$HEAD_JSON" | sort -u) \
    <(jq -r ".${distro}.releases[].version" "$BASE_JSON" | sort -u)
}

# ---- main ----
: > "$OUT"
{
  echo "# Verificação de flags (channels × binário)"
  echo ""
  echo "Para cada versão **nova** neste PR: flags que o upstream **adicionou**"
  echo "(vs o patch anterior) e todas as flags do binário **faltando** no channels."
  echo ""
} >> "$OUT"

found_any=0
for distro in k3s rke2; do
  while IFS= read -r version; do
    [[ -z "$version" ]] && continue
    found_any=1
    process_version "$distro" "$version"
  done < <(new_versions "$distro")
done

if [[ "$found_any" -eq 0 ]]; then
  echo "_Nenhuma versão nova detectada — nada a verificar._" >> "$OUT"
fi

exit 0
