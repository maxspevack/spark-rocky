#!/bin/bash
# spark-rocky repo test suite — runnable on ANY machine (no GB10 needed), so it can gate CI.
# It covers what is machine-independent: every shell script parses. The hardware-dependent proof lives in
# validate.sh, which runs
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
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
