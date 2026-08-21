#!/bin/bash
# Checks every catalogue entry against its live source.
#   ./Scripts/verify-catalog.sh [direct|github|brew|script|teamids|all]
# Prints a TSV: id <tab> kind <tab> OK|FAIL <tab> detail
set -uo pipefail
CATALOG="${CATALOG:-Sources/MacSetup/Resources/catalog.json}"
WHICH="${1:-all}"

# Compare catalogue Team IDs against apps actually installed on this Mac.
if [ "$WHICH" = "teamids" ]; then
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
  python3 -c '
import json, sys
for a in json.load(open(sys.argv[1]))["apps"]:
    if a.get("bundleId") and a.get("teamId"):
        print("\t".join([a["id"], a["bundleId"], a["teamId"]]))
' "$CATALOG" > /tmp/msteam.tsv
  while IFS=$'\t' read -r id bundle claimed; do
    path=$(mdfind "kMDItemCFBundleIdentifier == '$bundle'" 2>/dev/null | head -1)
    [ -n "$path" ] && [ -d "$path" ] || continue
    actual=$(codesign -dv --verbose=4 "$path" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
    [ -n "$actual" ] || continue
    if [ "$actual" = "$claimed" ]; then
      printf '%s\tteamid\tOK\t%s\n' "$id" "$actual"
    else
      printf '%s\tteamid\tFAIL\tcatalog=%s actual=%s\n' "$id" "$claimed" "$actual"
    fi
  done < /tmp/msteam.tsv
  exit 0
fi

check_url() {   # url -> "code|bytes|type|final"
  local url="$1" out code attempt delay
  for attempt in 1 2 3; do
    out=$(curl -fsSLI -A 'MacSetup/1.0' --connect-timeout 20 --max-time 45 \
          -o /dev/null -w '%{http_code}|%{size_download}|%{content_type}|%{url_effective}' "$url" 2>/dev/null)
    if [ -z "$out" ] || [ "${out%%|*}" = "000" ]; then
      # Some CDNs reject HEAD; retry with a one-byte ranged GET.
      out=$(curl -fsSL -A 'MacSetup/1.0' -r 0-0 --connect-timeout 20 --max-time 45 \
            -o /dev/null -w '%{http_code}|%{size_download}|%{content_type}|%{url_effective}' "$url" 2>/dev/null)
    fi
    code="${out%%|*}"
    case "$code" in
      429|503|502|504)
        delay=$((attempt * 4))
        sleep "$delay"
        continue ;;
      *) break ;;
    esac
  done
  printf '%s' "$out"
}

python3 - "$CATALOG" "$WHICH" <<'PY' > /tmp/mscheck.tsv
import json, sys
cat = json.load(open(sys.argv[1])); which = sys.argv[2]
for a in cat['apps']:
    s = a['source']; k = s['kind']
    if which not in ('all', k): continue
    if k == 'direct':
        for tag, key in (('url','url'), ('arm64','urlArm64'), ('x86','urlX86')):
            if s.get(key): print('\t'.join([a['id'], 'direct', tag, s[key]]))
    elif k == 'github':
        print('\t'.join([a['id'], 'github', s['repo'], s['assetPattern']]))
    elif k == 'brew':
        print('\t'.join([a['id'], 'brew', 'cask' if s.get('cask') else 'formula', s.get('cask') or s['formula']]))
    elif k == 'script':
        print('\t'.join([a['id'], 'script', '-', s['url']]))
PY

pass=0; fail=0
while IFS=$'\t' read -r id kind meta value; do
  case "$kind" in
    direct|script)
      r=$(check_url "$value"); code="${r%%|*}"; rest="${r#*|}"
      bytes="${rest%%|*}"; rest="${rest#*|}"; ctype="${rest%%|*}"; final="${rest#*|}"
      if [ "$code" = "200" ] || [ "$code" = "206" ]; then
        printf '%s\t%s(%s)\tOK\t%s %s\n' "$id" "$kind" "$meta" "$code" "${final:0:90}"; pass=$((pass+1))
      elif [ "$code" = "429" ] || [ "$code" = "503" ]; then
        printf '%s\t%s(%s)\tSKIP\tvendor rate limited (http %s) — not a catalogue problem\n' \
               "$id" "$kind" "$meta" "$code"
      else
        printf '%s\t%s(%s)\tFAIL\thttp=%s %s\n' "$id" "$kind" "$meta" "${code:-none}" "${value:0:70}"; fail=$((fail+1))
      fi ;;
    github)
      # Unmetered endpoints, same as the installer uses: the API's 60/hour
      # limit made this check fail for reasons that had nothing to do with the
      # catalogue being correct.
      tag=$(curl -fsSLI -A 'MacSetup/1.0' --connect-timeout 20 -o /dev/null \
            -w '%{url_effective}' "https://github.com/$meta/releases/latest" 2>/dev/null | sed 's|.*/tag/||')
      assets=""
      if [ -n "$tag" ]; then
        assets=$(curl -fsSL -A 'MacSetup/1.0' --connect-timeout 20 \
                 "https://github.com/$meta/releases/expanded_assets/$tag" 2>/dev/null \
                 | grep -oE 'href="[^"]*/releases/download/[^"]*"' \
                 | sed 's|href="|https://github.com|; s|"$||')
      fi
      if [ -z "$assets" ]; then
        printf '%s\tgithub\tFAIL\tcould not read releases for %s\n' "$id" "$meta"
        fail=$((fail+1)); continue
      fi
      hit=$(printf '%s\n' "$assets" \
            | while IFS= read -r u; do printf '%s' "${u##*/}" | grep -qE "$value" && printf '%s\n' "$u"; done | head -1)
      # "Latest" is not always a Mac release — Obsidian ships Android builds to
      # the same repo — so mirror the installer's walk-back through recent tags
      # rather than reporting a break the installer would not actually hit.
      if [ -z "$hit" ]; then
        for t in $(curl -fsSL -A 'MacSetup/1.0' --connect-timeout 20 \
                   "https://github.com/$meta/releases" 2>/dev/null \
                   | grep -oE "/$meta/releases/tag/[^\"]+" | sed 's|.*/tag/||' \
                   | awk '!seen[$0]++' | head -8); do
          [ "$t" = "$tag" ] && continue
          hit=$(curl -fsSL -A 'MacSetup/1.0' --connect-timeout 20 \
                "https://github.com/$meta/releases/expanded_assets/$t" 2>/dev/null \
                | grep -oE 'href="[^"]*/releases/download/[^"]*"' \
                | sed 's|href="|https://github.com|; s|"$||' \
                | while IFS= read -r u; do printf '%s' "${u##*/}" | grep -qE "$value" && printf '%s\n' "$u"; done | head -1)
          [ -n "$hit" ] && break
        done
      fi
      if [ -n "$hit" ]; then
        printf '%s\tgithub\tOK\t%s\n' "$id" "${hit##*/}"; pass=$((pass+1))
      else
        avail=$(printf '%s\n' "$assets" | sed 's|.*/||' | head -4 | tr '\n' ' ')
        printf '%s\tgithub\tFAIL\t/%s/ matched nothing; assets: %s\n' "$id" "$value" "$avail"
        fail=$((fail+1))
      fi ;;
    brew)
      if brew info --"$meta" "$value" >/dev/null 2>&1; then
        printf '%s\tbrew(%s)\tOK\t%s\n' "$id" "$meta" "$value"; pass=$((pass+1))
      else
        printf '%s\tbrew(%s)\tFAIL\tno such %s: %s\n' "$id" "$meta" "$meta" "$value"; fail=$((fail+1))
      fi ;;
  esac
done < /tmp/mscheck.tsv

printf '\n== %s passed, %s failed ==\n' "$pass" "$fail" >&2
