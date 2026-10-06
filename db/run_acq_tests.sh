#!/usr/bin/env bash
# Rebuilds a THROWAWAY database, applies the acq migrations up to phase N and runs each phase's tests.
# Usage: ./run_acq_tests.sh [max_phase=5]   (never point this at production)
cd "$(dirname "$0")" || exit 1
P="psql -h ${PGHOST:-/var/tmp/bospg} -p ${PGPORT:-55432} -U postgres -v ON_ERROR_STOP=1 -q"
MAX=${1:-5}
MIG=(020_acq_schema 021_acq_leads_crm 022_acq_outreach 023_acq_replies_demos_meetings 024_acq_followups_onboarding_metrics)
$P -d postgres -c "drop database if exists acqtest" -c "create database acqtest template template0 encoding 'UTF8' lc_collate 'C.utf8' lc_ctype 'C.utf8'" >/dev/null 2>&1 || { echo DB_CREATE_FAILED; exit 1; }
$P -d acqtest -f tests/00_stub.sql >/dev/null 2>&1 || { echo STUB_FAILED; $P -d acqtest -f tests/00_stub.sql; exit 1; }
for n in $(seq 1 "$MAX"); do
  f="${MIG[$((n-1))]}.sql"
  [ -f "$f" ] || { echo "SKIP phase $n (no $f)"; continue; }
  $P -d acqtest -f "$f" >/dev/null 2>/tmp/acq_mig_err.txt || { echo "MIGRATION_FAILED $f"; cat /tmp/acq_mig_err.txt; exit 1; }
  # idempotency: every migration must be safe to run twice
  $P -d acqtest -f "$f" >/dev/null 2>/tmp/acq_mig_err.txt || { echo "MIGRATION_NOT_RERUNNABLE $f"; cat /tmp/acq_mig_err.txt; exit 1; }
  echo "== phase $n: $f applied twice OK"
  if [ -f "tests/p$n.sql" ]; then
    out=$($P -d acqtest -f "tests/p$n.sql" 2>&1)
    echo "$out" | grep -E "PASS|FAIL|ERROR|[Ee]rror|DETAIL|HINT|ALL_TESTS" | sed 's/^psql:[^ ]* //;s/NOTICE:  //'
    echo "$out" | grep -q "ALL_TESTS_PASSED_P$n" || { echo "PHASE_${n}_TESTS_DID_NOT_COMPLETE"; exit 1; }
  fi
done
echo "ACQ_DB_SUITE_OK (phases 1..$MAX)"
