#!/usr/bin/env bash
#
# Editorial Noir — a warm near-black macOS theme, applied end to end.
#
#   bash editorial-noir.sh      (or bash noir-setup.sh for the whole setup)
#
# What it does, in order:
#   1. builds six 3840x2400 wallpapers into ~/Pictures/Editorial Noir
#   2. builds a matching Terminal.app colour profile and imports it
#   3. sets dark mode, graphite accent, wallpaper, Dock, hot corner, saver timing
#
# Nothing here needs sudo. Every macOS default it overwrites is saved first to
#   ~/Pictures/Editorial Noir/.defaults-backup.txt
#
# Requires: macOS 13+, python3 (Xcode Command Line Tools is enough), network
# access for the pip install and the three font downloads.

set -euo pipefail

DEST="${HOME}/Pictures/Editorial Noir"
WORK="$(mktemp -d /tmp/editorial-noir.XXXXXX)"
BACKUP="${DEST}/.defaults-backup.txt"
trap 'rm -rf "$WORK"' EXIT

# Personal overrides — see noir.local.example.sh.
# shellcheck source=/dev/null
[[ -f "$(dirname "$0")/noir.local.sh" ]] && source "$(dirname "$0")/noir.local.sh"
# The imprint line on 01-colophon.jpg. Defaults to the city of this Mac's time zone.
_tzcity="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/##; s#_# #g')"
NOIR_IMPRINT="${NOIR_IMPRINT:-$(printf '%s' "${NOIR_CITY:-${_tzcity:-Nocturne}}" | tr '[:lower:]' '[:upper:]')}"

# --- palette, single source of truth --------------------------------------
BASE_HEX="0D0C0B"   # warm near-black
BONE_HEX="E8E2D8"   # bone white ink
EMBER_HEX="C66A42"  # the one accent

say()  { printf '\033[38;5;180m›\033[0m %s\n' "$*"; }
warn() { printf '\033[38;5;209m!\033[0m %s\n' "$*"; }

# --------------------------------------------------------------- preflight
[[ "$(uname -s)" == "Darwin" ]] || { warn "macOS only."; exit 1; }
command -v python3 >/dev/null || {
  warn "python3 not found. Run: xcode-select --install"; exit 1; }

say "Building into ${DEST}"
mkdir -p "$DEST"

# ------------------------------------------------------- python + fonts
say "Setting up a throwaway Python env (pillow, numpy)…"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet --upgrade pip
"$WORK/venv/bin/pip" install --quiet pillow numpy
PY="$WORK/venv/bin/python"

say "Fetching Fraunces, Newsreader and IBM Plex Mono…"
GF="https://raw.githubusercontent.com/google/fonts/main/ofl"
curl -fsSL -o "$WORK/fraunces.ttf"   "$GF/fraunces/Fraunces%5BSOFT,WONK,opsz,wght%5D.ttf"
curl -fsSL -o "$WORK/newsreader.ttf" "$GF/newsreader/Newsreader%5Bopsz,wght%5D.ttf"
curl -fsSL -o "$WORK/plexmono.ttf"   "$GF/ibmplexmono/IBMPlexMono-Regular.ttf"
cp "$WORK/plexmono.ttf" "$DEST/IBMPlexMono-Regular.ttf"

# --------------------------------------------------------- the wallpapers
say "Rendering six wallpapers — this takes about a minute…"
OUT="$DEST" FONTDIR="$WORK" IMPRINT="$NOIR_IMPRINT" "$PY" <<'PYWALL'
"""Editorial Noir wallpapers.

Narrow palette on purpose: warm charcoal base, bone-white ink at very low
opacity, one ember accent. Everything gets fine film grain, which is not
decoration — it dithers the gradients so they don't band on a dark panel
or after JPEG.
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 3840, 2400            # 16:10, covers 13" and 15" at retina density
OUT = os.environ["OUT"]
FD = os.environ["FONTDIR"]
FRAUNCES = os.path.join(FD, "fraunces.ttf")
NEWSREADER = os.path.join(FD, "newsreader.ttf")
PLEX = os.path.join(FD, "plexmono.ttf")

BASE = (13, 12, 11)
BONE = (232, 226, 216)
EMBER = (198, 106, 66)

rng = np.random.default_rng(7)   # fixed seed: same grain on every machine


def font(path, size, axes=None):
    """axes is ordered by the font's own axis order:
    Fraunces -> [opsz, wght, SOFT, WONK];  Newsreader -> [wght, opsz]."""
    f = ImageFont.truetype(path, size)
    if axes:
        f.set_variation_by_axes(axes)
    return f


def canvas(base=BASE):
    return np.zeros((H, W, 3), dtype=np.float64) + np.array(base, dtype=np.float64)


def radial(arr, cx, cy, radius, color, strength, power=2.0):
    ys, xs = np.mgrid[0:H, 0:W]
    d = np.sqrt(((xs - cx) / radius) ** 2 + ((ys - cy) / radius) ** 2)
    falloff = np.clip(1.0 - d, 0.0, 1.0) ** power
    arr += falloff[..., None] * np.array(color, dtype=np.float64) * strength
    return arr


def grain(arr, amount=3.2, chroma=0.35):
    luma = rng.normal(0, amount, (H, W, 1))
    chro = rng.normal(0, amount * chroma, (H, W, 3))
    return arr + luma + chro


def vignette(arr, strength=0.34):
    ys, xs = np.mgrid[0:H, 0:W]
    nx = (xs - W / 2) / (W / 2)
    ny = (ys - H / 2) / (H / 2)
    r = np.sqrt(nx ** 2 + ny ** 2) / np.sqrt(2)
    return arr * (1.0 - strength * (r ** 2.1))[..., None]


def ink():
    return Image.new("RGBA", (W, H), (0, 0, 0, 0))


def finish(arr, name, ink_layer=None):
    arr = grain(vignette(arr))
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
    if ink_layer is not None:
        img = Image.alpha_composite(img.convert("RGBA"), ink_layer).convert("RGB")
    path = os.path.join(OUT, name)
    img.save(path, "JPEG", quality=95, subsampling=0, optimize=True)
    print(f"    {name}")


def colophon():
    a = canvas()
    a = radial(a, W * 0.72, H * 0.30, W * 0.62, (46, 40, 34), 0.85, power=2.4)
    a = radial(a, W * 0.20, H * 0.88, W * 0.45, (22, 24, 30), 0.7, power=2.2)
    layer = ink(); d = ImageDraw.Draw(layer)
    m = int(W * 0.085)
    d.line([(m, H - m), (W - m, H - m)], fill=BONE + (26,), width=2)
    d.text((m, H - m - 150), "Editorial Noir",
           font=font(NEWSREADER, 96, [300, 36]), fill=BONE + (120,))
    fm = font(PLEX, 40)
    d.text((m, H - m + 46), os.environ["IMPRINT"] + "  ·  MMXXVI", font=fm, fill=BONE + (58,))
    d.text((W - m, H - m + 46), "I", font=fm, fill=EMBER + (150,), anchor="ra")
    finish(a, "01-colophon.jpg", layer)


def rule():
    a = canvas((11, 11, 12))
    a = radial(a, W * 0.5, H * 0.52, W * 0.80, (34, 32, 33), 0.75, power=2.8)
    layer = ink(); d = ImageDraw.Draw(layer)
    y = int(H * 0.5)
    for i in range(240):                       # hairline, fading at both ends
        t = i / 239
        x0 = int(W * 0.12 + t * W * 0.76)
        x1 = int(W * 0.12 + (t + 1 / 239) * W * 0.76)
        d.line([(x0, y), (x1, y)],
               fill=BONE + (int(44 * (np.sin(np.pi * t) ** 0.55)),), width=2)
    d.text((W * 0.5, y - 92), "quiet",
           font=font(FRAUNCES, 132, [96, 300, 40, 1]), fill=BONE + (96,), anchor="ms")
    d.text((W * 0.5, y + 118), "N  O  C  T  U  R  N  E",
           font=font(PLEX, 34), fill=BONE + (40,), anchor="ma")
    finish(a, "02-rule.jpg", layer)


def ligature():
    a = canvas((14, 12, 11))
    a = radial(a, W * 0.30, H * 0.38, W * 0.70, (48, 41, 36), 0.9, power=2.5)
    glyph = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glyph).text((W * 0.62, H * 1.06), "&",
                               font=font(FRAUNCES, 3400, [144, 200, 0, 1]),
                               fill=12, anchor="ms")      # ~4.5% — a whisper
    glyph = glyph.filter(ImageFilter.GaussianBlur(1.4))
    g = np.asarray(glyph, dtype=np.float64)[..., None] / 255.0
    a = a * (1 - g) + g * np.array(BONE, dtype=np.float64)
    layer = ink(); d = ImageDraw.Draw(layer)
    d.text((W * 0.085, H * 0.085), "AMPERSAND",
           font=font(PLEX, 38), fill=BONE + (64,))
    d.text((W * 0.085, H * 0.085 + 78), "et",
           font=font(NEWSREADER, 44, [400, 16]), fill=EMBER + (120,))
    finish(a, "03-ligature.jpg", layer)


def dusk():
    ys = np.linspace(0, 1, H)[:, None, None]
    top = np.array([9, 10, 14], dtype=np.float64)
    bot = np.array([26, 21, 19], dtype=np.float64)
    a = np.repeat(top + (bot - top) * (ys ** 1.5), W, axis=1)
    a = radial(a, W * 0.5, H * 1.02, W * 0.9, (58, 38, 26), 0.55, power=2.0)
    a = radial(a, W * 0.14, H * 0.12, W * 0.38, (20, 26, 38), 0.6, power=2.4)
    finish(a, "04-dusk.jpg")


def arc():
    a = canvas((12, 12, 13))
    a = radial(a, W * 0.86, H * 0.80, W * 0.55, (38, 35, 33), 0.7, power=2.6)
    layer = ink(); d = ImageDraw.Draw(layer)
    cx, cy = W * 0.80, H * 0.86
    for r, alpha in zip([W * .30, W * .42, W * .54, W * .66], [52, 34, 22, 14]):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=BONE + (alpha,), width=2)
    d.ellipse([cx - 9, cy - 9, cx + 9, cy + 9], fill=EMBER + (170,))
    d.text((W * 0.085, H * 0.16), "Concentric",
           font=font(NEWSREADER, 116, [300, 48]), fill=BONE + (104,))
    d.text((W * 0.085, H * 0.16 + 150), "studies in falloff",
           font=font(NEWSREADER, 52, [320, 16]), fill=BONE + (54,))
    finish(a, "05-arc.jpg", layer)


def grid():
    a = canvas((12, 11, 11))
    a = radial(a, W * 0.5, H * 0.18, W * 0.75, (40, 36, 33), 0.62, power=2.6)
    layer = ink(); d = ImageDraw.Draw(layer)
    step = 120
    for x in range(step, W, step):
        d.line([(x, 0), (x, H)], fill=BONE + (7,), width=1)
    for y in range(step, H, step):
        d.line([(0, y), (W, y)], fill=BONE + (7,), width=1)
    for x in range(step * 4, W, step * 4):
        d.line([(x, 0), (x, H)], fill=BONE + (13,), width=1)
    for y in range(step * 4, H, step * 4):
        d.line([(0, y), (W, y)], fill=BONE + (13,), width=1)
    d.text((W * 0.5, H * 0.54), "the grid",
           font=font(FRAUNCES, 168, [120, 300, 60, 1]), fill=BONE + (86,), anchor="ms")
    d.line([(W * .5 - 60, H * .54 + 70), (W * .5 + 60, H * .54 + 70)],
           fill=EMBER + (130,), width=3)
    finish(a, "06-grid.jpg", layer)


for fn in (colophon, rule, ligature, dusk, arc, grid):
    fn()
PYWALL

# --------------------------------------------------- the Terminal profile
say "Writing the Terminal profile…"
OUT="$DEST" "$PY" <<'PYTERM'
"""Terminal.app .terminal file. Colours are NSKeyedArchiver-encoded NSColor
blobs, which is why this is Python and not a plain plist."""
import os, plistlib
from plistlib import UID

def nscolor(h):
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return plistlib.dumps({
        "$version": 100000, "$archiver": "NSKeyedArchiver",
        "$top": {"root": UID(1)},
        "$objects": ["$null",
                     {"$class": UID(2), "NSColorSpace": 2,
                      "NSRGB": f"{r:.6f} {g:.6f} {b:.6f}".encode() + b"\x00"},
                     {"$classes": ["NSColor", "NSObject"], "$classname": "NSColor"}],
    }, fmt=plistlib.FMT_BINARY)

def nsfont(name, size):
    return plistlib.dumps({
        "$version": 100000, "$archiver": "NSKeyedArchiver",
        "$top": {"root": UID(1)},
        "$objects": ["$null",
                     {"$class": UID(3), "NSName": UID(2), "NSSize": size,
                      "NSfFlags": 16},
                     name,
                     {"$classes": ["NSFont", "NSObject"], "$classname": "NSFont"}],
    }, fmt=plistlib.FMT_BINARY)

# 16-colour ANSI set tuned so git diff and syntax highlighting stay legible
# without any one hue shouting over the others.
ANSI = ["1A1817", "C4634A", "8A9A6B", "C9A227", "7189A8", "A0768F", "6E9B97", "D8D2C7",
        "4A4540", "E07B5E", "A6B584", "E0BC4F", "92A8C4", "BE95AC", "8FB8B3", "F5F0E8"]
NAMES = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
         "BrightBlack", "BrightRed", "BrightGreen", "BrightYellow",
         "BrightBlue", "BrightMagenta", "BrightCyan", "BrightWhite"]

theme = {
    "name": "Editorial Noir", "type": "Window Settings",
    "ProfileCurrentVersion": 2.07,
    "BackgroundColor": nscolor("0D0C0B"),
    "TextColor": nscolor("E8E2D8"),
    "TextBoldColor": nscolor("F5F0E8"),
    "CursorColor": nscolor("C66A42"),
    "SelectionColor": nscolor("2E2A26"),
    "CursorType": 1, "CursorBlink": False,
    "Font": nsfont("SFMono-Regular", 14.0),
    "FontAntialias": True, "FontWidthSpacing": 1.02, "FontHeightSpacing": 1.16,
    "BackgroundBlur": 0.0, "BackgroundAlphaInactive": 1.0,
    "BackgroundSettingsForInactiveWindows": False,
    "ShowWindowSettingsNameInTitle": False, "ShowActiveProcessInTitle": True,
    "ShowShellCommandInTitle": False, "ShowDimensionsInTitle": False,
    "ShowTTYNameInTitle": False, "ShowRepresentedURLInTitle": False,
    "ShowActiveProcessArgumentsInTitle": False, "ShowCommandKeyInTitle": False,
    "columnCount": 110, "rowCount": 32,
    "ShouldLimitScrollback": 0, "ScrollbackLines": 0,
    "useOptionAsMetaKey": True,
    "Bell": False, "VisualBell": True, "VisualBellOnlyWhenMuted": True,
    "BlinkText": False,
}
for name, hexval in zip(NAMES, ANSI):
    theme[f"ANSI{name}Color"] = nscolor(hexval)

path = os.path.join(os.environ["OUT"], "Editorial Noir.terminal")
with open(path, "wb") as f:
    plistlib.dump(theme, f, fmt=plistlib.FMT_XML)
PYTERM

# ------------------------------------------------------------------ README
cat > "$DEST/README.md" <<EOF
# Editorial Noir

Base \`#${BASE_HEX}\` — a charcoal with a little red in it rather than a flat
neutral. Bone-white ink \`#${BONE_HEX}\`. One ember accent \`#${EMBER_HEX}\`,
used sparingly.

Wallpapers are 3840 × 2400 and carry deliberate film grain, which dithers the
gradients so they don't band on a dark panel.

| File | Notes |
|---|---|
| 01-colophon.jpg | Masthead rule and imprint line. The quiet default. |
| 02-rule.jpg | Single fading hairline, centred. |
| 03-ligature.jpg | Oversized Fraunces ampersand at ~4% opacity. |
| 04-dusk.jpg | Pure gradient, no type. Best for screenshots. |
| 05-arc.jpg | Concentric hairlines falling off bottom-right. |
| 06-grid.jpg | Faint engineering grid with a serif mark. |

\`Editorial Noir.terminal\` — SF Mono 14 with the ANSI set above.
\`IBMPlexMono-Regular.ttf\` — install via Font Book if you prefer Plex.

Type: Fraunces (display), Newsreader (text), IBM Plex Mono (mono).
EOF

# ------------------------------------------- back up what we're about to change
say "Backing up current settings to ${BACKUP##*/}…"
{
  echo "# Editorial Noir — values before $(date '+%Y-%m-%d %H:%M')"
  for k in AppleAccentColor AppleHighlightColor AppleInterfaceStyle; do
    echo "defaults write -g $k -- $(defaults read -g "$k" 2>/dev/null || echo '<unset>')"
  done
  for k in show-recents mineffect wvous-bl-corner wvous-bl-modifier; do
    echo "defaults write com.apple.dock $k -- $(defaults read com.apple.dock "$k" 2>/dev/null || echo '<unset>')"
  done
  echo "defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -- $(defaults read com.apple.WindowManager EnableStandardClickToShowDesktop 2>/dev/null || echo '<unset>')"
  echo "defaults -currentHost write com.apple.screensaver idleTime -- $(defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || echo '<unset>')"
  echo "defaults write com.apple.Terminal 'Default Window Settings' -- $(defaults read com.apple.Terminal 'Default Window Settings' 2>/dev/null || echo '<unset>')"
} > "$BACKUP"

# ------------------------------------------------------------- appearance
say "Dark mode, pinned — not Auto…"
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'

say "Graphite accent and highlight…"
defaults write -g AppleAccentColor -int -1
defaults write -g AppleAquaColorVariant -int 6
defaults write -g AppleHighlightColor -string "0.847059 0.847059 0.862745 Graphite"

# ------------------------------------------------------------- wallpaper
say "Setting the wallpaper on every desktop…"
osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"${DEST}/01-colophon.jpg\""

# ------------------------------------------------------ dock and hot corner
say "Dock, hot corner, click-to-show-desktop…"
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock mineffect -string scale
defaults write com.apple.dock wvous-bl-corner -int 5      # 5 = start screen saver
defaults write com.apple.dock wvous-bl-modifier -int 0
defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
killall Dock 2>/dev/null || true

# ------------------------------------------------------------ screen saver
# 5 minutes, not the 20-minute default — on most Macs the display sleeps at 10,
# so at 20 the screen saver would never actually fire.
say "Screen saver idle time → 5 minutes…"
defaults -currentHost write com.apple.screensaver idleTime -int 300

# ---------------------------------------------------------------- terminal
say "Importing the Terminal profile…"
open "${DEST}/Editorial Noir.terminal"
sleep 3
defaults write com.apple.Terminal "Default Window Settings" -string "Editorial Noir"
defaults write com.apple.Terminal "Startup Window Settings" -string "Editorial Noir"

# -------------------------------------------------------------------- done
cat <<EOF

  Editorial Noir is in place. Files live in ${DEST}

  Two things macOS won't let a script do — both are a few clicks:

    1. Screen saver source
       System Settings ▸ Wallpaper ▸ Screen Saver… ▸ Custom ▸ Photos ▸
       Options… ▸ Source ▸ Choose Folder… → pick "Editorial Noir",
       tick Shuffle. Sonoma and later keep this in a sandboxed container
       that isn't writable from outside.

    2. Icon & widget style
       System Settings ▸ Appearance ▸ Icon & widget style ▸ Dark ▸ Always.
       The preference key for this moved in macOS 26 and isn't stable
       enough to write blind.

  Terminal: quit it (⌘Q) and reopen so the profile takes. If a window is
  already running something you can't restart, switch it in place with
  ⌘I ▸ Profile ▸ Editorial Noir.

  To undo the system settings, the previous values are in
  ${BACKUP##*/} inside that folder.

EOF
