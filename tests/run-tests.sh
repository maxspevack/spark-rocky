#!/bin/bash
# spark-rocky repo test suite — runnable on ANY machine (no GB10 needed), so it can gate CI.
# It covers what is machine-independent: every shell script parses, and the thermal-watchdog's decision
# logic is correct (including boundaries). The hardware-dependent proof lives in validate.sh, which runs
# ON the box. Run: make test  (or bash tests/run-tests.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
no(){ fail=$((fail+1)); echo "  FAIL: $1"; }

echo "== syntax: every shell script parses (bash -n) =="
while IFS= read -r f; do
  if err=$(bash -n "$f" 2>&1); then ok "$f"; else no "$f"; echo "        $err"; fi
done < <(find scripts tests -name '*.sh' | sort)

echo
echo "== thermal-watchdog decision logic (the real decide(), sourced) =="
# pull just the pure function out of the script so we test the shipping code, not a copy
source <(sed -n '/^decide()/,/^}/p' scripts/thermal-watchdog.sh)
t(){ # description  expected-glob  gpu_temp gpu_slowdown zone_temp zone_crit margin
  local desc="$1" pat="$2"; shift 2
  local got; got="$(decide "$@")"
  # shellcheck disable=SC2254
  case "$got" in $pat) ok "$desc -> $got";; *) no "$desc -> expected [$pat], got [$got]";; esac
}
t "cool reading does not trip"          'OK*'               45 90 60 100 5
t "hot GPU trips"                        'TRIP GPU*'         86 90 60 100 5
t "hot zone trips"                       'TRIP zone*'        45 90 96 100 5
t "unreadable GPU fails closed"          'TRIP fail-closed*' ''  ''  60 100 5
t "unreadable slowdown fails closed"     'TRIP fail-closed*' 50  ''  60 100 5
t "absurd margin forces a trip"          'TRIP*'             45 90 60 100 500
t "GPU exactly at threshold trips"       'TRIP GPU*'         85 90 60 100 5
t "GPU one degree below is fine"         'OK*'               84 90 60 100 5
t "zone with no critical exposed is OK"  'OK*'               45 90 99 ''  5

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
