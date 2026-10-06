#!/usr/bin/env bash
# Rebuilds a throwaway local database and runs the full suite.
cd "$(dirname "$0")" || exit 1
P="psql -h ${PGHOST:-/var/tmp/bospg} -p ${PGPORT:-55432} -U postgres -v ON_ERROR_STOP=1 -q"
$P -c "drop database if exists bostest" -c "create database bostest" >/dev/null 2>&1
$P -d bostest -c "create role anon nologin" -c "create role authenticated nologin" >/dev/null 2>&1
$P -d bostest -f 001_booking_os_schema.sql >/dev/null 2>&1 || { echo SCHEMA_FAILED; $P -d bostest -f 001_booking_os_schema.sql; exit 1; }
$P -d bostest -f 002_seed_demo.sql >/dev/null
$P -d bostest -f 003_tests.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL_TESTS" | sed 's/^psql:[^ ]* //;s/NOTICE:  //'
