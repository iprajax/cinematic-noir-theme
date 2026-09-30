#!/usr/bin/env bash
#
# Editorial Noir — the whole setup, on this Mac, in one go.
#
#   git clone https://github.com/<you>/cinematic-noir-theme && cd cinematic-noir-theme
#   bash noir-setup.sh
#
# In order:
#   1. backs up the target Mac's current appearance settings (for undo)
#   2. editorial-noir.sh    — wallpapers, Terminal profile, base theme
#   3. my-settings.sh       — optional: a snapshot from your other Mac (made
#                             with noir-capture.sh), layered on top so your
#                             own tweaks win over the preset
#   4. noir-brief-install.sh — the brief, NoirWall menu-bar dot, NoirSaver
#
# To refresh the snapshot on the source Mac first:  bash noir-capture.sh
# Nothing here needs sudo.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NOIR="${HOME}/Pictures/Editorial Noir"

say()  { printf '\033[38;5;180m›\033[0m %s\n' "$*"; }
warn() { printf '\033[38;5;209m!\033[0m %s\n' "$*"; }

# --------------------------------------------------------------- preflight
[[ "$(uname -s)" == "Darwin" ]] || { warn "macOS only."; exit 1; }
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Command Line Tools are missing (needed for python3 and to compile NoirWall/NoirSaver)."
  warn "A window will open — install, then run this script again."
  xcode-select --install 2>/dev/null || true
  exit 1
fi
for f in editorial-noir.sh noir-brief-install.sh noir-capture.sh; do
  [[ -f "${HERE}/${f}" ]] || { warn "Missing ${f} next to this script."; exit 1; }
done

# ------------------------------------------------------------------ backup
mkdir -p "$NOIR"
UNDO="${NOIR}/.before-setup-$(date '+%Y%m%d-%H%M').sh"
say "Backing up this Mac's current appearance settings…"
bash "${HERE}/noir-capture.sh" --out "$UNDO"

# ------------------------------------------------------------- base theme
say "Applying the Editorial Noir base theme…"
bash "${HERE}/editorial-noir.sh"

# ----------------------------------------------------------- your snapshot
WALLPAPER=""; WALLPAPER_ABS=""; SAVER=""
if [[ -f "${HERE}/my-settings.sh" ]]; then
  say "Applying your snapshot ($(sed -n '2s/^# //p' "${HERE}/my-settings.sh"))…"
  # shellcheck source=/dev/null
  source "${HERE}/my-settings.sh"
else
  say "No my-settings.sh — keeping the preset as is."
fi

# A wallpaper that isn't one of the six generated ones has to come from the
# copied folder.
if [[ -n "$WALLPAPER" && ! -f "${NOIR}/${WALLPAPER}" && -f "${HERE}/${WALLPAPER}" ]]; then
  cp "${HERE}/${WALLPAPER}" "${NOIR}/"
fi
wp="${WALLPAPER:+${NOIR}/${WALLPAPER}}"; wp="${wp:-$WALLPAPER_ABS}"
if [[ -n "$wp" && -f "$wp" ]]; then
  osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"${wp}\""
elif [[ -n "$wp" ]]; then
  warn "Wallpaper ${wp} isn't on this Mac — left the Editorial Noir default."
fi
killall Dock 2>/dev/null || true

# ------------------------------------------------------------------ brief
say "Installing Noir Brief…"
bash "${HERE}/noir-brief-install.sh"

# -------------------------------------------------------------------- done
case "$SAVER" in
  ""|NoirSaver*)    SAVER_STEP="System Settings ▸ Screen Saver ▸ Other ▸ NoirSaver" ;;
  iLifeSlideshows*) SAVER_STEP="System Settings ▸ Screen Saver ▸ Photos ▸ Options… ▸ Source ▸
                 Choose Folder… → \"Editorial Noir\", tick Shuffle" ;;
  *)               SAVER_STEP="System Settings ▸ Screen Saver — pick the one you used (${SAVER:-unknown})" ;;
esac

cat <<EOF

  Setup complete.

  One click macOS won't let a script make:

    Screen saver  ${SAVER_STEP}

  Then log out and back in once, so the accent colour and icon style reach
  every app, and quit and reopen Terminal (⌘Q) for its profile.

  Undo the system settings:  bash "${UNDO}"

EOF
