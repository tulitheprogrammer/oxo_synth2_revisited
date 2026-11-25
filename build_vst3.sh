#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/OxoSynth2VST3"
BUILD_DIR="$PROJECT_DIR/build"
# Bundle names from Identity.xcconfig (the local override wins, like in CMake).
IDENTITY_FILES=("$SCRIPT_DIR/Identity.xcconfig")
[[ -f "$SCRIPT_DIR/Identity.local.xcconfig" ]] && IDENTITY_FILES+=("$SCRIPT_DIR/Identity.local.xcconfig")
PRODUCT_NAME="$(sed -n 's/^OXO_PRODUCT_NAME[[:space:]]*=[[:space:]]*//p' "${IDENTITY_FILES[@]}" \
  | tail -1 | sed 's/[[:space:]]*$//')"
MARKETING_VERSION="$(sed -n 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*//p' "${IDENTITY_FILES[@]}" \
  | tail -1 | sed 's/[[:space:]]*$//')"
PLUGIN_SRC="$BUILD_DIR/VST3/Release/${PRODUCT_NAME// /}.vst3"
PLUGIN_DST_DIR="$HOME/Library/Audio/Plug-Ins/VST3"   # --global moves this
                                                   # (and the AU) to /Library
# AUv2: the SDK's smtg_target_add_auv2 wraps this same VST3 binary. Its own
# post-build copy hardcodes a literal "~" that /bin/cp does not expand, so
# install it ourselves (same as oxo_simple).
AUV2_SRC="$BUILD_DIR/VST3/Release/$PRODUCT_NAME.component"
AUV2_DST_DIR="$HOME/Library/Audio/Plug-Ins/Components"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

# --no-install: build only, leave ~/Library alone (tools/prepare_mac_installer:
# a ~/Library copy beside the pkg's /Library one = two plug-ins, same UIDs).
# --global: install into /Library (this machine keeps the global VST3 folder
# on an external volume and loads from there; hosts that scan both would
# otherwise show two entries). Nothing to do with the pkg, which stages its own.
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --global) PLUGIN_DST_DIR="/Library/Audio/Plug-Ins/VST3"
              # The global folders here live on exFAT (symlink to /Volumes/...).
              # VST3 works from there, but AudioComponentRegistrar does not pick
              # up an AU bundle from that volume (48 components, 4 registered),
              # so --global sends the AU to the user folder, which registers.
              AUV2_DST_DIR="$HOME/Library/Audio/Plug-Ins/Components"
              INSTALL_GLOBAL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
INSTALL_GLOBAL=${INSTALL_GLOBAL:-0}
# Should the SDK's post-build AUv2 copy ever reach ~/Library (it does in Oxo
# Drums' setup), --no-install undoes it when there was no copy before.
AUV2_DST="$AUV2_DST_DIR/$PRODUCT_NAME.component"
AUV2_WAS_INSTALLED=0
[[ -e "$AUV2_DST" ]] && AUV2_WAS_INSTALLED=1

echo "==> Configuring (Xcode generator)"
cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" -GXcode -DSMTG_CREATE_PLUGIN_LINK=OFF > "$BUILD_DIR.configure.log" 2>&1 \
  || { tail -30 "$BUILD_DIR.configure.log"; exit 1; }

# Xcode's copy phase only adds: start the bundled banks from scratch so a
# patch removed from Shared/Resources/Synth2 Factory (or Synth2 Starter
# Banks) leaves the bundle too.
rm -rf "$PLUGIN_SRC/Contents/Resources/Synth2 Factory" "$PLUGIN_SRC/Contents/Resources/Synth2 Starter Banks"

echo "==> Building (Release)"
cmake --build "$BUILD_DIR" --config Release -j 8 > "$BUILD_DIR.build.log" 2>&1 \
  || { grep -aE "error:|BUILD FAILED" "$BUILD_DIR.build.log" | head -30; exit 1; }

[[ -d "$PLUGIN_SRC" ]] || { echo "ERROR: built plugin not found at $PLUGIN_SRC" >&2; exit 1; }

# The SDK's post-build step generates moduleinfo.json INSIDE the bundle. With
# the Xcode generator an incremental build can skip that script and leave a
# 0-byte file from an earlier run behind: the validator then silently skips the
# module and a host reading moduleinfo sees no plug-in at all. Regenerate
# whenever it is missing or empty (same command the SDK uses, then re-sign the
# file, which the SDK signs on its own rather than through the bundle seal).
MODULEINFO="$PLUGIN_SRC/Contents/Resources/moduleinfo.json"
if [[ ! -s "$MODULEINFO" ]]; then
  "$BUILD_DIR/bin/Release/moduleinfotool" -create -version "$MARKETING_VERSION" \
    -path "$PLUGIN_SRC" -output "$MODULEINFO"
  codesign --force --sign - "$MODULEINFO"
  echo "==> Regenerated moduleinfo.json (the build left it empty)"
fi
if [[ $INSTALL -eq 0 ]]; then
  [[ $AUV2_WAS_INSTALLED -eq 0 && -e "$AUV2_DST" ]] && rm -rf "$AUV2_DST"
  echo "==> Built (--no-install: nothing copied to ~/Library)"
  exit 0
fi
# On --global the target is /Library, which the installer's "no home folders"
# rule already leaves alone; an unwritable one is a plain error, not sudo bait.
mkdir -p "$PLUGIN_DST_DIR" 2>/dev/null \
  || { echo "ERROR: cannot write $PLUGIN_DST_DIR (run with sudo for a system install)" >&2; exit 1; }
# exFAT (this machine's global folders) has no xattrs, so macOS writes an
# AppleDouble ._NAME beside every file it creates -- including inside a bundle,
# where those stray files are unsigned and break the code seal. They cannot be
# excluded: the driver makes them on write. Purge them after the copy and, if
# any were there, sign again (adhoc: a dev install is not a release).
strip_appledouble() {
  find "$1" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
}
# codesign writes its CodeResources through the exFAT driver, so signing itself
# re-creates the sidecars: purge, sign, purge AGAIN. Skipping the second purge
# leaves ._CodeResources next to the seal, and every later codesign --verify
# reports "file added: ... ._Info.plist" and fails.
seal_bundle() {
  strip_appledouble "$1"
  codesign --force --sign - --timestamp=none "$1" >/dev/null 2>&1 || return 1
  strip_appledouble "$1"
}
RSYNC_OPTS=(-a --delete --exclude '.DS_Store' --exclude '._*')
PLUGIN_DST="$PLUGIN_DST_DIR/$(basename "$PLUGIN_SRC")"
rsync "${RSYNC_OPTS[@]}" "$PLUGIN_SRC" "$PLUGIN_DST_DIR/"
seal_bundle "$PLUGIN_DST"
echo "==> Installed $PLUGIN_DST"
[[ $INSTALL_GLOBAL -eq 1 ]] && echo "==> Global install: hosts that scan both folders now load this one copy"

if [[ -d "$AUV2_SRC" ]]; then
  mkdir -p "$AUV2_DST_DIR"
  rsync "${RSYNC_OPTS[@]}" "$AUV2_SRC" "$AUV2_DST_DIR/"
  # AUv2 loads its DSP from Contents/Resources/plugin.vst3, a SYMLINK into the
  # build tree. rsync copies the link as is, so the installed AU would break
  # the moment this checkout moves: replace it with the real bundle (what
  # tools/prepare_mac_installer does for the pkg, and what the code seal wants).
  AUV2_INNER="$AUV2_DST/Contents/Resources/plugin.vst3"
  rm -rf "$AUV2_INNER"
  rsync -a --exclude '.DS_Store' --exclude '._*' "$PLUGIN_SRC/" "$AUV2_INNER/"
  # Sealing an added resource invalidates the component's signature, so sign
  # inner-out (adhoc, like tools/prepare_mac_installer with the real identity).
  seal_bundle "$AUV2_INNER"
  seal_bundle "$AUV2_DST"
  echo "==> Signed the AU (nested plugin.vst3 is a real copy)"
  echo "==> Installed $AUV2_DST"
fi
