#!/bin/bash

# Reports drift between the flags a k3s/rke2 release binary exposes and the
# flags declared in channels (serverArgs/agentArgs, read from the *resolved*
# data/data.json after `go generate`).
#
# Three modes:
#
#   --mode pr      (default) For every version newly added in the PR (head vs a
#                  base data.json), report only the flags this version
#                  INTRODUCED compared to the previous patch in the same minor
#                  line, marking each with whether it is already declared in
#                  channels. If a version introduces no new flags, it is
#                  omitted; if no version introduces anything, the output file
#                  is left empty (the caller treats "empty" as "nothing to
#                  comment").
#
#   --mode audit   Full audit of the version(s) given via --versions: every
#                  flag exposed by the binary that is NOT declared in channels,
#                  plus the inverse (declared in channels but not exposed by the
#                  binary). Meant for manual runs (workflow_dispatch), possibly
#                  without any PR.
#
#   --mode general Whole-history sweep (meant to be run locally, NOT in CI: it
#                  downloads one binary per minor line). Walks the latest patch
#                  of every minor and, for each flag, records where it entered
#                  in the binaries and where it is missing from channels. It
#                  reports ONLY flags that were never declared — i.e. still
#                  missing at their most recent point. A flag that was missing
#                  early but later added to channels is intentionally omitted.
#                  By default it scans the latest patch of each minor; pass
#                  --all-patches to scan EVERY version (exact patch a flag
#                  entered, at the cost of hundreds of downloads). Use
#                  --minors N to limit to the N most recent minors.
#
# It reads serverArgs/agentArgs directly from data/data.json (anchors/merges
# already expanded), downloads the matching release binaries, runs
# `<bin> server|agent --help`, and diffs the flag sets. The check is purely
# informational and always exits 0.
#
# Usage:
#   ./verify-flags.sh --mode pr      --base <base-data.json> [--head data/data.json] [--out file.md]
#   ./verify-flags.sh --mode audit   --versions "<v1> <v2> ..." [--distro both|k3s|rke2]
#                                    [--head data/data.json] [--out file.md]
#   ./verify-flags.sh --mode general [--distro both|k3s|rke2] [--minors N]
#                                    [--all-patches] [--head data/data.json] [--out file.md]

set -euo pipefail

# Check dependencies
for cmd in jq curl tar; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: '$cmd' is not installed or not in PATH. Please install it." >&2
    exit 1
  fi
done

# ---- argument parsing ----
MODE="pr"
BASE_JSON=""
HEAD_JSON="data/data.json"
OUT="/dev/stdout"
DISTRO_FILTER="both"
VERSIONS_INPUT=""
MINORS_LIMIT=0   # general mode: 0 = all minors, N = only the N most recent
ALL_PATCHES=0    # general mode: 1 = scan every patch, 0 = latest patch per minor

usage() {
  sed -n '3,48p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)     MODE="${2:-}"; shift 2 ;;
    --base)     BASE_JSON="${2:-}"; shift 2 ;;
    --head)     HEAD_JSON="${2:-}"; shift 2 ;;
    --out)      OUT="${2:-}"; shift 2 ;;
    --distro)   DISTRO_FILTER="${2:-}"; shift 2 ;;
    --versions) VERSIONS_INPUT="${2:-}"; shift 2 ;;
    --minors)   MINORS_LIMIT="${2:-0}"; shift 2 ;;
    --all-patches) ALL_PATCHES=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ ! -f "$HEAD_JSON" ]]; then
  echo "Error: head data.json not found: $HEAD_JSON" >&2
  exit 1
fi

case "$MODE" in
  pr)
    if [[ -z "$BASE_JSON" ]]; then
      echo "Error: --mode pr requires --base <base-data.json>" >&2
      exit 1
    fi
    if [[ ! -f "$BASE_JSON" ]]; then
      echo "Error: base data.json not found: $BASE_JSON" >&2
      exit 1
    fi
    ;;
  audit)
    if [[ -z "$VERSIONS_INPUT" ]]; then
      echo "Error: --mode audit requires --versions \"<v1> <v2> ...\"" >&2
      exit 1
    fi
    ;;
  general)
    if ! [[ "$MINORS_LIMIT" =~ ^[0-9]+$ ]]; then
      echo "Error: --minors must be a non-negative integer (got '$MINORS_LIMIT')" >&2
      exit 1
    fi
    ;;
  *)
    echo "Error: --mode must be 'pr', 'audit' or 'general' (got '$MODE')" >&2
    exit 1
    ;;
esac

# Distros to consider. PR mode always scans both; audit/general honour --distro.
DISTROS=(k3s rke2)
if [[ "$MODE" != "pr" && "$DISTRO_FILTER" != "both" ]]; then
  DISTROS=("$DISTRO_FILTER")
fi

# Generic logging/CLI flags that are never cluster configuration and should
# never land in channels. Kept out of the report to reduce noise.
SANITIZE_RE='^(alsologtostderr|config|log|vmodule|help|v)$'

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Accumulated report body (rendered here, wrapped with a header at the end).
BODY="$WORKDIR/body.md"
: > "$BODY"

# Running totals used for the report header / caller signalling.
SECTIONS=0   # version sections actually emitted

# ---- small helpers ----

# as_lines <string>: print the string with a trailing newline, or nothing at
# all when empty (avoids feeding a phantom blank line to comm/while).
as_lines() { [[ -z "${1:-}" ]] || printf '%s\n' "$1"; }

# count_lines <string>: number of non-empty lines.
count_lines() {
  [[ -z "${1:-}" ]] && { echo 0; return 0; }
  local n
  n="$(grep -c '.' <<<"$1" || true)"
  echo "${n:-0}"
}

# extract_help_flags <binary> <server|agent>
# Prints the sanitized set of flag names (one per line, sorted) from --help.
# pipefail is disabled locally: greps legitimately return 1 on no-match.
extract_help_flags() {
  local bin="$1" sub="$2"
  (
    set +o pipefail
    "$bin" "$sub" --help 2>/dev/null \
      | grep -oE '^\s+--[a-z0-9-]+' \
      | sed 's/^ *--//' \
      | grep -vE "$SANITIZE_RE" \
      | sort -u
  )
}

# channel_args <data.json> <distro> <version> <serverArgs|agentArgs>
# Prints the declared flag keys for a version (one per line, sorted).
channel_args() {
  local json="$1" distro="$2" version="$3" field="$4"
  (
    set +o pipefail
    jq -r --arg v "$version" \
      ".${distro}.releases[] | select(.version==\$v) | .${field} // {} | keys[]" \
      "$json" 2>/dev/null | sort -u
  )
}

# version_exists <data.json> <distro> <version>
version_exists() {
  local json="$1" distro="$2" version="$3"
  jq -e --arg v "$version" \
    ".${distro}.releases[] | select(.version==\$v)" "$json" >/dev/null 2>&1
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
  # Versions whose numeric part == prevnum (excluding RCs), highest by sort -V.
  (
    set +o pipefail
    jq -r ".${distro}.releases[].version" "$HEAD_JSON" \
      | grep -v -- '-rc' \
      | awk -v want="$prevnum" '
          match($0, /v[0-9]+\.[0-9]+\.[0-9]+/) && substr($0, RSTART, RLENGTH) == want { print }
        ' \
      | sort -V | tail -1
  )
}

# download_binary <distro> <version> -> echoes path to runnable binary, or empty.
# Memoized: a binary already downloaded in this run is reused.
download_binary() {
  local distro="$1" version="$2"
  local ver_enc="${version//+/%2B}"
  local dest="$WORKDIR/${distro}-${version//[+\/]/_}"

  if [[ "$distro" == "k3s" ]]; then
    if [[ -x "$dest" ]]; then echo "$dest"; return; fi
    local url="https://github.com/k3s-io/k3s/releases/download/${ver_enc}/k3s"
    if curl -sfL "$url" -o "$dest" 2>/dev/null; then
      chmod +x "$dest"
      echo "$dest"
    fi
  else # rke2
    local ex="$WORKDIR/rke2-extract-${version//[+\/]/_}"
    if [[ -x "$ex/bin/rke2" ]]; then echo "$ex/bin/rke2"; return; fi
    local url="https://github.com/rancher/rke2/releases/download/${ver_enc}/rke2.linux-amd64.tar.gz"
    local tgz="$dest.tar.gz"
    if curl -sfL "$url" -o "$tgz" 2>/dev/null; then
      mkdir -p "$ex"
      if tar -xzf "$tgz" -C "$ex" bin/rke2 2>/dev/null; then
        chmod +x "$ex/bin/rke2"
        rm -f "$tgz"   # keep only the extracted binary (matters for general mode)
        echo "$ex/bin/rke2"
      fi
    fi
  fi
}

# render_marked <title> <flags> <set> <col>: append a table to $BODY marking
# each flag ✅/❌ by membership in <set>.
render_marked() {
  local title="$1" flags="$2" set="$3" col="$4"
  local n; n="$(count_lines "$flags")"
  {
    echo "**${title}:** ${n}"
    echo ""
    if (( n > 0 )); then
      echo "| Flag | ${col} |"
      echo "|------|:---:|"
      local f mark
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if grep -qxF "$f" <<<"$set"; then mark="✅ yes"; else mark="❌ no"; fi
        echo "| \`$f\` | $mark |"
      done <<<"$flags"
      echo ""
    fi
  } >> "$BODY"
}

# render_plain <title> <flags>: append a simple one-column table to $BODY.
render_plain() {
  local title="$1" flags="$2"
  local n; n="$(count_lines "$flags")"
  {
    echo "**${title}:** ${n}"
    echo ""
    if (( n > 0 )); then
      echo "| Flag |"
      echo "|------|"
      local f
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo "| \`$f\` |"
      done <<<"$flags"
      echo ""
    fi
  } >> "$BODY"
}

# ---- PR mode: flags a new version added upstream ----
process_version_pr() {
  local distro="$1" version="$2"

  local bin
  bin="$(download_binary "$distro" "$version")"
  if [[ -z "$bin" ]]; then
    {
      echo "<details><summary><strong>${distro} ${version}</strong> — binary download failed</summary>"
      echo ""
      echo "> Could not download the binary for this version; unable to detect new flags."
      echo ""
      echo "</details>"
      echo ""
    } >> "$BODY"
    SECTIONS=$((SECTIONS + 1))
    return
  fi

  local prev
  prev="$(previous_version "$distro" "$version")"
  [[ -z "$prev" ]] && return   # no baseline to diff against -> nothing to say

  local prev_bin
  prev_bin="$(download_binary "$distro" "$prev")"
  [[ -z "$prev_bin" ]] && return

  local bin_srv bin_agt prev_srv prev_agt ch_srv ch_agt ch_all
  bin_srv="$(extract_help_flags "$bin" server)"
  bin_agt="$(extract_help_flags "$bin" agent)"
  prev_srv="$(extract_help_flags "$prev_bin" server)"
  prev_agt="$(extract_help_flags "$prev_bin" agent)"
  ch_srv="$(channel_args "$HEAD_JSON" "$distro" "$version" serverArgs)"
  ch_agt="$(channel_args "$HEAD_JSON" "$distro" "$version" agentArgs)"
  ch_all="$(printf '%s\n%s\n' "$ch_srv" "$ch_agt" | sort -u | sed '/^$/d')"

  # Flags this version introduced vs the previous patch.
  local added_srv added_agt
  added_srv="$(comm -13 <(as_lines "$prev_srv") <(as_lines "$bin_srv"))"
  added_agt="$(comm -13 <(as_lines "$prev_agt") <(as_lines "$bin_agt"))"

  local n_srv n_agt
  n_srv="$(count_lines "$added_srv")"
  n_agt="$(count_lines "$added_agt")"
  (( n_srv == 0 && n_agt == 0 )) && return   # nothing new -> stay silent

  # How many of the new flags are NOT yet declared in channels (the ones worth
  # acting on).
  local missing_srv missing_agt n_missing
  missing_srv="$(comm -23 <(as_lines "$added_srv") <(as_lines "$ch_all"))"
  missing_agt="$(comm -23 <(as_lines "$added_agt") <(as_lines "$ch_agt"))"
  n_missing="$(( $(count_lines "$missing_srv") + $(count_lines "$missing_agt") ))"

  local badge=""
  (( n_missing > 0 )) && badge=" — ⚠️ ${n_missing} missing from channels"

  {
    echo "<details${badge:+ open}><summary><strong>${distro} ${version}</strong> — $((n_srv + n_agt)) new upstream flag(s)${badge}</summary>"
    echo ""
    echo "Compared against \`${prev}\`."
    echo ""
  } >> "$BODY"
  render_marked "New server flags" "$added_srv" "$ch_all" "In channels?"
  render_marked "New agent flags"  "$added_agt" "$ch_agt" "In agentArgs?"
  {
    echo "</details>"
    echo ""
  } >> "$BODY"

  SECTIONS=$((SECTIONS + 1))
}

# ---- audit mode: every flag missing from channels for a given version ----
process_version_audit() {
  local distro="$1" version="$2"

  {
    echo "## ${distro} ${version}"
    echo ""
  } >> "$BODY"

  if ! version_exists "$HEAD_JSON" "$distro" "$version"; then
    {
      echo "> Version not found under \`${distro}.releases\` in data.json; every binary flag will read as missing."
      echo ""
    } >> "$BODY"
  fi

  local bin
  bin="$(download_binary "$distro" "$version")"
  if [[ -z "$bin" ]]; then
    {
      echo "> Could not download the binary for this version. Skipping."
      echo ""
    } >> "$BODY"
    SECTIONS=$((SECTIONS + 1))
    return
  fi

  local bin_srv bin_agt ch_srv ch_agt ch_all
  bin_srv="$(extract_help_flags "$bin" server)"
  bin_agt="$(extract_help_flags "$bin" agent)"
  ch_srv="$(channel_args "$HEAD_JSON" "$distro" "$version" serverArgs)"
  ch_agt="$(channel_args "$HEAD_JSON" "$distro" "$version" agentArgs)"
  ch_all="$(printf '%s\n%s\n' "$ch_srv" "$ch_agt" | sort -u | sed '/^$/d')"

  # server reads agent flags too: server --help vs serverArgs + agentArgs.
  # agent reads only itself: agent --help vs agentArgs only.
  local missing_srv missing_agt only_channels
  missing_srv="$(comm -23 <(as_lines "$bin_srv") <(as_lines "$ch_all"))"
  missing_agt="$(comm -23 <(as_lines "$bin_agt") <(as_lines "$ch_agt"))"
  # Declared in channels but not exposed by the binary (removed/renamed flags).
  only_channels="$(comm -13 <(as_lines "$(extract_help_flags "$bin" server)") <(as_lines "$ch_all"))"

  render_plain "Missing from server (server --help vs serverArgs + agentArgs)" "$missing_srv"
  render_plain "Missing from agent (agent --help vs agentArgs)" "$missing_agt"

  {
    echo "<details><summary>Only in channels (declared but not exposed by the binary)</summary>"
    echo ""
  } >> "$BODY"
  render_plain "Only in channels" "$only_channels"
  {
    echo "</details>"
    echo ""
  } >> "$BODY"

  SECTIONS=$((SECTIONS + 1))
}

# new_versions <distro> -> versions present in head but not in base
new_versions() {
  local distro="$1"
  (
    set +o pipefail
    comm -23 \
      <(jq -r ".${distro}.releases[].version" "$HEAD_JSON" | sort -u) \
      <(jq -r ".${distro}.releases[].version" "$BASE_JSON" | sort -u)
  )
}

# minors_for <distro> -> unique minor lines (vX.Y), ascending, RCs excluded.
minors_for() {
  local distro="$1"
  (
    set +o pipefail
    jq -r ".${distro}.releases[].version" "$HEAD_JSON" \
      | grep -v -- '-rc' \
      | grep -oE 'v[0-9]+\.[0-9]+' \
      | sort -V -u
  )
}

# all_versions_for <distro> -> every stable version, ascending, RCs excluded.
all_versions_for() {
  local distro="$1"
  (
    set +o pipefail
    jq -r ".${distro}.releases[].version" "$HEAD_JSON" \
      | grep -v -- '-rc' \
      | sort -V -u
  )
}

# cleanup_binary <distro> <version>: drop a downloaded binary to bound disk use
# (general mode scans each version exactly once, so nothing is reused).
cleanup_binary() {
  local distro="$1" version="$2"
  local dest="$WORKDIR/${distro}-${version//[+\/]/_}"
  if [[ "$distro" == "k3s" ]]; then
    rm -f "$dest"
  else
    rm -rf "$WORKDIR/rke2-extract-${version//[+\/]/_}" "$dest.tar.gz"
  fi
}

# compact_labels <space-separated-labels>: join with commas, but collapse long
# lists to "first … last (N total)" so patch-level reports stay readable.
compact_labels() {
  local -a arr=($1)
  local n=${#arr[@]}
  if (( n == 0 )); then
    echo "—"
  elif (( n <= 8 )); then
    local IFS=', '; echo "${arr[*]}"
  else
    echo "${arr[0]} … ${arr[n-1]} (${n} total)"
  fi
}

# latest_patch <distro> <minor> -> highest stable version of that exact minor.
latest_patch() {
  local distro="$1" minor="$2"
  (
    set +o pipefail
    jq -r ".${distro}.releases[].version" "$HEAD_JSON" \
      | grep -v -- '-rc' \
      | awk -v m="$minor" '
          match($0, /v[0-9]+\.[0-9]+/) && substr($0, RSTART, RLENGTH) == m { print }
        ' \
      | sort -V | tail -1
  )
}

# render_general_table <title> <entered-map> <chan-map> <missing-map> <latest-map>
# Emits, for every flag still missing from channels at its latest minor, where
# it entered and the minors where it is missing. Maps are passed by name.
render_general_table() {
  local title="$1"
  local -n _ent="$2" _chan="$3" _miss="$4" _lat="$5"
  local -a rows=()
  local f
  for f in "${!_ent[@]}"; do
    # chan==0 means it is NOT declared at its most recent exposing minor, i.e.
    # it was never added to channels. Flags added later are skipped.
    [[ "${_chan[$f]:-0}" == "0" ]] && rows+=("$f")
  done
  local n=${#rows[@]}
  {
    echo "**${title}:** ${n}"
    echo ""
    if (( n > 0 )); then
      echo "| Flag | Entered | Still missing at | Missing in |"
      echo "|------|:-------:|:----------------:|------------|"
      local sorted miss
      sorted="$(printf '%s\n' "${rows[@]}" | sort)"
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        miss="$(compact_labels "${_miss[$f]# }")"   # trim leading space + compact
        echo "| \`$f\` | ${_ent[$f]} | ${_lat[$f]} | ${miss} |"
      done <<<"$sorted"
      echo ""
    fi
  } >> "$BODY"
}

# process_general_distro <distro>
# Walks the latest patch of every minor (oldest -> newest), building the
# per-flag "entered / missing" timeline, then reports the flags never declared.
process_general_distro() {
  local distro="$1"

  # Build the list of points to scan. Each point has a version to download and
  # a label to display (the full version in --all-patches mode, else the minor).
  local -a scan_versions=() scan_labels=()
  local minor ver
  if (( ALL_PATCHES )); then
    while IFS= read -r ver; do
      [[ -z "$ver" ]] && continue
      scan_versions+=("$ver"); scan_labels+=("$ver")
    done < <(all_versions_for "$distro")
  else
    local -a minors
    mapfile -t minors < <(minors_for "$distro")
    if (( MINORS_LIMIT > 0 )) && (( ${#minors[@]} > MINORS_LIMIT )); then
      minors=("${minors[@]: -MINORS_LIMIT}")
    fi
    for minor in "${minors[@]}"; do
      [[ -z "$minor" ]] && continue
      ver="$(latest_patch "$distro" "$minor")"
      [[ -z "$ver" ]] && continue
      scan_versions+=("$ver"); scan_labels+=("$minor")
    done
  fi

  # flag -> first point exposing it (server / agent contexts kept separate).
  local -A ent_srv=() lat_srv=() chan_srv=() miss_srv=()
  local -A ent_agt=() lat_agt=() chan_agt=() miss_agt=()

  local total=${#scan_versions[@]}
  local processed=0 i version label bin bsrv bagt csrv cagt call f
  for i in "${!scan_versions[@]}"; do
    version="${scan_versions[$i]}"
    label="${scan_labels[$i]}"
    echo "[general] ${distro} $((i + 1))/${total}: ${label} (${version})" >&2

    bin="$(download_binary "$distro" "$version")"
    if [[ -z "$bin" ]]; then
      echo "> ${distro} ${label}: could not download \`${version}\`; skipped." >> "$BODY"
      echo "" >> "$BODY"
      continue
    fi
    processed=$((processed + 1))

    bsrv="$(extract_help_flags "$bin" server)"
    bagt="$(extract_help_flags "$bin" agent)"
    csrv="$(channel_args "$HEAD_JSON" "$distro" "$version" serverArgs)"
    cagt="$(channel_args "$HEAD_JSON" "$distro" "$version" agentArgs)"
    call="$(printf '%s\n%s\n' "$csrv" "$cagt" | sort -u | sed '/^$/d')"

    # server context: server --help vs serverArgs + agentArgs
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ -z "${ent_srv[$f]:-}" ]] && ent_srv[$f]="$label"
      lat_srv[$f]="$label"
      if grep -qxF "$f" <<<"$call"; then
        chan_srv[$f]=1
      else
        chan_srv[$f]=0
        miss_srv[$f]="${miss_srv[$f]:-} $label"
      fi
    done <<<"$bsrv"

    # agent context: agent --help vs agentArgs
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ -z "${ent_agt[$f]:-}" ]] && ent_agt[$f]="$label"
      lat_agt[$f]="$label"
      if grep -qxF "$f" <<<"$cagt"; then
        chan_agt[$f]=1
      else
        chan_agt[$f]=0
        miss_agt[$f]="${miss_agt[$f]:-} $label"
      fi
    done <<<"$bagt"

    cleanup_binary "$distro" "$version"
  done

  {
    echo "## ${distro}"
    echo ""
    if (( ALL_PATCHES )); then
      echo "_Scanned:_ ${processed}/${total} patches (all versions)."
    else
      echo "_Scanned:_ ${processed}/${total} minors (latest patch each)."
    fi
    echo ""
  } >> "$BODY"

  render_general_table "Server flags never declared (server --help vs serverArgs + agentArgs)" \
    ent_srv chan_srv miss_srv lat_srv
  render_general_table "Agent flags never declared (agent --help vs agentArgs)" \
    ent_agt chan_agt miss_agt lat_agt

  SECTIONS=$((SECTIONS + 1))
}

# ---- main ----
if [[ "$MODE" == "pr" ]]; then
  for distro in "${DISTROS[@]}"; do
    while IFS= read -r version; do
      [[ -z "$version" ]] && continue
      process_version_pr "$distro" "$version"
    done < <(new_versions "$distro")
  done

  # No findings -> empty output file signals "nothing to comment".
  if (( SECTIONS == 0 )); then
    : > "$OUT"
    exit 0
  fi

  {
    echo "# New upstream flags (channels vs binary)"
    echo ""
    echo "For each version added in this PR, the flags it introduced compared to"
    echo "the previous patch. ⚠️ marks flags not yet declared in channels."
    echo ""
    cat "$BODY"
  } > "$OUT"
  exit 0
fi

if [[ "$MODE" == "general" ]]; then
  for distro in "${DISTROS[@]}"; do
    process_general_distro "$distro"
  done

  {
    echo "# Flag introduction & channel gaps (general audit)"
    echo ""
    if (( ALL_PATCHES )); then
      echo "Every version (all patches). For each flag the binary exposes but"
      echo "that was **never** declared in channels (still missing at its most"
      echo "recent version), this lists the exact patch where it entered and the"
      echo "versions where it is missing — i.e. where you can add it."
    else
      echo "Latest patch of each minor line. For each flag the binary exposes but"
      echo "that was **never** declared in channels (still missing at its most"
      echo "recent minor), this lists where it entered and the minors where it is"
      echo "missing — i.e. where you can add it."
    fi
    echo "Flags that were added to channels at some later point are"
    echo "intentionally omitted."
    echo ""
    cat "$BODY"
  } > "$OUT"
  exit 0
fi

# audit mode
# Split the versions input on whitespace and/or commas.
read -r -a VERSIONS <<< "${VERSIONS_INPUT//,/ }"

for distro in "${DISTROS[@]}"; do
  for version in "${VERSIONS[@]}"; do
    [[ -z "$version" ]] && continue
    # Only audit a version against a distro whose tag it matches (k3s/rke2),
    # unless the caller pinned a single distro explicitly.
    if [[ "$DISTRO_FILTER" == "both" && "$version" != *"$distro"* ]]; then
      continue
    fi
    process_version_audit "$distro" "$version"
  done
done

{
  echo "# Flag audit (channels vs binary)"
  echo ""
  echo "Full list of binary flags not declared in channels for the requested"
  echo "version(s)."
  echo ""
  if (( SECTIONS == 0 )); then
    echo "No matching versions were audited. Check the versions/distro inputs."
    echo ""
  else
    cat "$BODY"
  fi
} > "$OUT"

exit 0
