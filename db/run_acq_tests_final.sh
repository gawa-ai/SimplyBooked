#!/usr/bin/env bash
# Production-shaped check: apply ALL acq migrations first (as a real install would), then run every phase's tests.
# THROWAWAY database only (acqall). Usage: ./run_acq_tests_final.sh
cd "$(dirname "$0")" || exit 1
P="psql -h ${PGHOST:-/var/tmp/bospg} -p ${PGPORT:-55432} -U postgres -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists acqall" -c "create database acqall template template0 encoding 'UTF8' lc_collate 'C.utf8' lc_ctype 'C.utf8'" >/dev/null 2>&1 || { echo DB_CREATE_FAILED; exit 1; }
$P -d acqall -f tests/00_stub.sql >/dev/null 2>&1 || { echo STUB_FAILED; exit 1; }
for f in 020_acq_schema 021_acq_leads_crm 022_acq_outreach 023_acq_replies_demos_meetings 024_acq_followups_onboarding_metrics; do
  $P -d acqall -f "$f.sql" >/dev/null 2>/tmp/acq_mig_err.txt || { echo "MIGRATION_FAILED $f"; cat /tmp/acq_mig_err.txt; exit 1; }
done
for n in 1 2 3 4 5; do
  out=$($P -d acqall -f "tests/p$n.sql" 2>&1)
  echo "$out" | grep -v "PASS" | grep -E "FAIL|ERROR|[Ee]rror" | sed 's/^psql:[^ ]* //'
  echo "$out" | grep -q "ALL_TESTS_PASSED_P$n" || { echo "PHASE_${n}_FAILED_ON_FINAL_SCHEMA"; exit 1; }
  echo "phase $n: $(echo "$out" | grep -c 'PASS') checks pass on the final schema"
done
echo "ACQ_FINAL_SCHEMA_SUITE_OK"
