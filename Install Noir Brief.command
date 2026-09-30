#!/bin/bash
# Double-click me. Runs the Noir Brief installer from this folder.
cd "$(dirname "$0")" || exit 1
bash ./noir-brief-install.sh
status=$?
echo
if [ $status -eq 0 ]; then
  echo "Done. You can close this window."
else
  echo "Finished with errors (exit $status). Scroll up for the reason."
fi
