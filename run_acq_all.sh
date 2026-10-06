#!/usr/bin/env bash
# Full local verification on THROWAWAY databases (bostest, acqtest, acqall). Never point PGHOST/PGPORT at production.
#   1. Booking engine (bos): 59 SQL checks + 30-check n8n contract harness
#   2. Acquisition (acq): SQL suites phase by phase (+ every migration applied twice) and on the final schema
#   3. n8n workflow generation + static validation (all 14 workflows)
#   4. ACQ contract harness (real Code-node JS + real Postgres node queries)
#   5. Edge functions: strict type-check + unit tests
# Usage: ./run_acq_all.sh [max_phase=5]
set -uo pipefail
cd "$(dirname "$0")"; PH="${1:-5}"; rc=0
step() { echo; echo "== $1"; }
need() { grep -q "$2" <<<"$1" || { echo "!! $3"; rc=1; }; }

step "bos SQL suite (bostest)";        o=$(cd db && ./run_tests.sh);           echo "$o" | grep -E "FAIL|ERROR|ALL_TESTS"; need "$o" ALL_TESTS_PASSED "bos SQL suite failed"
step "bos workflows: generate + validate"; (cd n8n && python3 build_workflows.py >/dev/null && mkdir -p /tmp/bos-wf && cp 0*.json /tmp/bos-wf/ && node validate.js /tmp/bos-wf | tail -1)
step "bos contract harness";           o=$(cd n8n && node harness.js 2>&1);   echo "$o" | grep -E "FAIL|HARNESS"; need "$o" "HARNESS: 30 checks passed" "bos harness failed"

step "acq SQL suites, phase by phase (acqtest)"; o=$(cd db && ./run_acq_tests.sh "$PH" 2>&1); echo "$o" | grep -E "FAIL|ERROR|ALL_TESTS|SUITE_OK|DID_NOT"; need "$o" "ACQ_DB_SUITE_OK" "acq SQL suite failed"
step "acq workflows: generate + validate"; o=$(cd n8n && python3 acq_build.py >/dev/null && node validate.js acq | tail -1); echo "$o"; need "$o" "STATIC VALIDATION: PASS" "acq static validation failed"
step "acq contract harness";           o=$(cd n8n && node acq_harness.js "$PH" 2>/dev/null); echo "$o" | grep -E "^FAIL|ACQ HARNESS"; need "$o" "ACQ HARNESS (phase $PH)" "acq harness failed"
if [ "$PH" -ge 5 ]; then
  step "acq SQL suites on the final schema (acqall)"; o=$(cd db && ./run_acq_tests_final.sh 2>&1); echo "$o" | grep -E "checks pass|FAILED|SUITE_OK"; need "$o" "ACQ_FINAL_SCHEMA_SUITE_OK" "final-schema suite failed"
fi

step "edge functions: strict type-check"
TSC=$(command -v tsc || echo /opt/npm-tools/node_modules/.bin/tsc)
if [ -x "$TSC" ]; then
  (cd supabase/functions && "$TSC" --noEmit --strict --target es2022 --module esnext --moduleResolution bundler --lib es2022,dom --skipLibCheck --allowImportingTsExtensions _shared/keys.ts */handler.ts) && echo "tsc: OK" || { echo "!! tsc failed"; rc=1; }
else echo "tsc not available (skipped)"; fi
step "edge functions: unit tests"
for f in supabase/functions/*/*.test.ts; do
  d=$(dirname "$f"); o=$(cd "$d" && npx --yes tsx --test "$(basename "$f")" 2>&1)
  echo "$(echo "$o" | grep -E "^# (pass|fail)" | tr '\n' ' ') <- $d"; need "$o" "# fail 0" "tests failed in $d"
done
echo; [ $rc -eq 0 ] && echo "ALL LOCAL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $rc
