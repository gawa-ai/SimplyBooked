#!/usr/bin/env bash
# Netlify build step: copies the SimplyBooked photos and films (generated in Higgsfield) into site/media
# so the website serves its own copies instead of hot-linking. Fails the deploy if any file cannot be fetched,
# so a broken page is never published silently.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p site/media
fail=0
while read -r name url; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  out="site/media/$name"
  if [[ -s "$out" ]]; then echo "cached  $name"; continue; fi
  if curl -fsSL --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 300 -o "$out.part" "$url"; then
    # refuse anything that isn't really the expected file type (e.g. an HTML error page)
    case "$name" in
      *.mp4) sig=$(head -c 8 "$out.part" | tail -c 4) ; ok=$([[ "$sig" == "ftyp" ]] && echo 1 || echo 0) ;;
      *.png) sig=$(head -c 4 "$out.part" | tail -c 3) ; ok=$([[ "$sig" == "PNG" ]] && echo 1 || echo 0) ;;
      *) ok=1 ;;
    esac
    if [[ "$ok" == 1 ]]; then
      mv "$out.part" "$out"; echo "fetched $name ($(wc -c < "$out") bytes)"
    else
      rm -f "$out.part"; echo "FAILED  $name: not a valid ${name##*.} file <- $url" >&2; fail=1
    fi
  else
    rm -f "$out.part"; echo "FAILED  $name <- $url" >&2; fail=1
  fi
done < scripts/media.txt
exit $fail
