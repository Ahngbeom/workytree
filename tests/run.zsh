#!/usr/bin/env zsh
# Runs every tests/*.test.zsh in its own process; exit 1 if any file fails.
cd "${0:A:h:h}" || exit 1
rc=0
for f in tests/*.test.zsh; do
  print "== $f"
  zsh "$f" || rc=1
done
exit $rc
