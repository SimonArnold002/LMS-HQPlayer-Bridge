#!/bin/sh
# Syntax-check and unit-test the plugin without an LMS install.
#
# There is no LMS on the Mac, so `perl -c` cannot load Slim::*.  tools/Slim/**
# is a minimal stub tree that satisfies the `use` lines; it is NOT a simulator
# and proves nothing about runtime behaviour - only that the modules compile
# and that the pure XML logic is correct.
#
# Usage:  sh tools/run_checks.sh        (from the repo root)
set -e
cd "$(dirname "$0")"
rm -rf Plugins && mkdir -p Plugins && ln -sfn ../../HQPlayerBridge Plugins/HQPlayerBridge

echo "== syntax =="
for m in Control Discovery UPnP Player Plugin Settings; do
    perl -I. syncheck.pl "Plugins::HQPlayerBridge::$m"
done

echo
echo "== unit tests =="
perl -I. t_control.pl
perl -I. t_player.pl

echo
echo "== called-vs-defined sweep (perl -c will NOT catch these) =="
cd ../HQPlayerBridge
grep -ho 'Plugins::HQPlayerBridge::[A-Za-z]*::[a-zA-Z_]*' ./*.pm | sort -u | while read -r c; do
    mod=${c#Plugins::HQPlayerBridge::}; mod=${mod%%::*}; fn=${c##*::}
    grep -q "^sub $fn" "$mod.pm" 2>/dev/null || echo "  MISSING $c"
done
echo "  (clean)"
