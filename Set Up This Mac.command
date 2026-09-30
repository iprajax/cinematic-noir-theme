#!/bin/bash
# Double-click me on a new Mac. Rebuilds the whole Editorial Noir setup.
cd "$(dirname "$0")" || exit 1
bash ./noir-setup.sh
status=$?
echo
if [ $status -eq 0 ]; then
  echo "Done. You can close this window."
else
  echo "Finished with errors (exit $status). Scroll up for the reason."
fi
