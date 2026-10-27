#!/bin/zsh
# CleanLock build helper.
#
# Usage: ./Scripts/build.sh <command> [options]
#
#   debug      Fast debug build with swiftc (no Xcode involved).
#   release    Optimized Release build with xcodebuild (universal binary).
#   install    Build Release and install the app into /Applications.
#   run        Build Debug and launch the app.
#   package    Build Release and create build/dist/CleanLock.zip.
#   clean      Remove build/ and the Swift module cache.
#   help       Show this message.
#
# Options
#   --arch <arm64|x86_64|universal>   Architecture for the `debug` command (default: arm64).
#   --no-sign                          Skip ad-hoc signing during `install`.
#
# Environment
#   CLEANLOCK_INSTALL_DIR              Install destination (default: /Applications).
#   CLEANLOCK_SIGN_IDENTITY            codesigning identity (default: auto-detected).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$0"
BUILD_DIR="$ROOT_DIR/build"
DEBUG_APP_DIR="$BUILD_DIR/Debug/CleanLock.app"
RELEASE_APP_DIR="$BUILD_DIR/Release/CleanLock.app"
DIST_DIR="$BUILD_DIR/dist"
DERIVED_DATA_DIR="$BUILD_DIR/dd"
MODULE_CACHE_DIR="/private/tmp/cleanlock-module-cache"

APP_NAME="CleanLock"
BUNDLE_ID="dev.cleanlock.CleanLock"
INSTALL_DIR="${CLEANLOCK_INSTALL_DIR:-/Applications}"
DEVELOPMENT_LANGUAGE="en"

MARKETING_VERSION=""
BUILD_NUMBER=""
DEPLOYMENT_TARGET=""

SWIFT_SOURCES=(
  "$ROOT_DIR/CleanLock/App/AppDelegate.swift"
  "$ROOT_DIR/CleanLock/App/CleanLockApp.swift"
  "$ROOT_DIR/CleanLock/Controllers/MenuBarController.swift"
  "$ROOT_DIR/CleanLock/Controllers/SettingsWindowController.swift"
  "$ROOT_DIR/CleanLock/Managers/CleaningModeManager.swift"
  "$ROOT_DIR/CleanLock/Managers/CursorController.swift"
  "$ROOT_DIR/CleanLock/Managers/InputBlocker.swift"
  "$ROOT_DIR/CleanLock/Managers/OverlayManager.swift"
  "$ROOT_DIR/CleanLock/Managers/PermissionManager.swift"
  "$ROOT_DIR/CleanLock/Managers/PointerDeviceSeizer.swift"
  "$ROOT_DIR/CleanLock/Managers/PreferencesStore.swift"
  "$ROOT_DIR/CleanLock/Models/AutoUnlockDuration.swift"
  "$ROOT_DIR/CleanLock/Models/CleaningModeState.swift"
  "$ROOT_DIR/CleanLock/Models/DisplayScope.swift"
  "$ROOT_DIR/CleanLock/Models/Localization.swift"
  "$ROOT_DIR/CleanLock/Models/OnboardingStep.swift"
  "$ROOT_DIR/CleanLock/Views/AnimatedLockIcon.swift"
  "$ROOT_DIR/CleanLock/Views/CleaningOverlayView.swift"
  "$ROOT_DIR/CleanLock/Views/OnboardingView.swift"
  "$ROOT_DIR/CleanLock/Views/SettingsView.swift"
)

# --- helpers ---------------------------------------------------------------

info() {
  echo "==> $*" >&2
}

die() {
  echo "error: $*" >&2
  exit 1
}

first_line() {
  print -r -- "${1%%$'\n'*}"
}

# Reads version, build number and deployment target from the Xcode project so
# the CLI build never drifts from the Xcode build.
read_project_settings() {
  local pbxproj="$ROOT_DIR/CleanLock.xcodeproj/project.pbxproj"

  [[ -f "$pbxproj" ]] || die "missing Xcode project: $pbxproj"

  MARKETING_VERSION="$(first_line "$(sed -n -E 's/^[[:space:]]*MARKETING_VERSION = ([0-9.]+);.*/\1/p' "$pbxproj")")"
  BUILD_NUMBER="$(first_line "$(sed -n -E 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' "$pbxproj")")"
  DEPLOYMENT_TARGET="$(first_line "$(sed -n -E 's/^[[:space:]]*MACOSX_DEPLOYMENT_TARGET = ([0-9.]+);.*/\1/p' "$pbxproj")")"

  [[ -n "$MARKETING_VERSION" ]] || die "MARKETING_VERSION not found in project.pbxproj"
  [[ -n "$BUILD_NUMBER" ]] || die "CURRENT_PROJECT_VERSION not found in project.pbxproj"
  [[ -n "$DEPLOYMENT_TARGET" ]] || die "MACOSX_DEPLOYMENT_TARGET not found in project.pbxproj"
}

# Renders CleanLock/Resources/Info.plist into the bundle, replacing the Xcode
# build variables. The CLI build reuses the same source file as Xcode.
render_info_plist() {
  local destination="$1"

  sed \
    -e "s/\$(DEVELOPMENT_LANGUAGE)/$DEVELOPMENT_LANGUAGE/g" \
    -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e "s/\$(PRODUCT_NAME)/$APP_NAME/g" \
    -e "s/\$(MARKETING_VERSION)/$MARKETING_VERSION/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$DEPLOYMENT_TARGET/g" \
    "$ROOT_DIR/CleanLock/Resources/Info.plist" > "$destination"
}

copy_resources() {
  local resources_dir="$1"

  cp "$ROOT_DIR/CleanLock/Resources/AppIcon.icns" "$resources_dir/AppIcon.icns"
  mkdir -p "$resources_dir/en.lproj" "$resources_dir/ru.lproj"
  cp "$ROOT_DIR/CleanLock/Resources/en.lproj/InfoPlist.strings" "$resources_dir/en.lproj/InfoPlist.strings"
  cp "$ROOT_DIR/CleanLock/Resources/ru.lproj/InfoPlist.strings" "$resources_dir/ru.lproj/InfoPlist.strings"
}

# macOS matches the Accessibility and Input Monitoring grants against the code
# signature of the running binary, so the bundle must always carry a valid
# signature. A real identity also keeps the designated requirement stable across
# rebuilds, so the grants survive recompiling the app.
detect_sign_identity() {
  if [[ -n "$SIGN_IDENTITY_OVERRIDE" ]]; then
    echo "$SIGN_IDENTITY_OVERRIDE"
    return
  fi

  local identity
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n -E 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ "(Developer ID Application: [^"]+)".*/\1/p' \
    | head -n 1)"

  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n -E 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ "(Apple Development: [^"]+)".*/\1/p' \
      | head -n 1)"
  fi

  echo "${identity:--}"
}

sign_app() {
  local app="$1"
  local identity="$2"

  if ! command -v codesign >/dev/null 2>&1; then
    echo "warning: codesign not available, $app is left unsigned" >&2
    return 0
  fi

  info "Signing ($identity) $app"

  if ! codesign --force --sign "$identity" "$app"; then
    die "codesign failed for $app"
  fi

  if ! codesign --verify --deep --strict "$app"; then
    die "signature verification failed for $app"
  fi
}

# --- commands --------------------------------------------------------------

build_debug() {
  local arch="$1"
  local identity="${2:-}"
  local app_dir="$DEBUG_APP_DIR"
  local contents_dir="$app_dir/Contents"
  local macos_dir="$contents_dir/MacOS"
  local resources_dir="$contents_dir/Resources"

  info "Building debug ($arch) → $app_dir"

  rm -rf "$app_dir"
  mkdir -p "$macos_dir" "$resources_dir" "$MODULE_CACHE_DIR"

  case "$arch" in
    arm64|x86_64)
      compile_debug_arch "$arch" "$macos_dir/$APP_NAME"
      ;;
    universal)
      local temp_dir="$BUILD_DIR/.tmp-debug"
      mkdir -p "$temp_dir"
      compile_debug_arch arm64 "$temp_dir/$APP_NAME-arm64"
      compile_debug_arch x86_64 "$temp_dir/$APP_NAME-x86_64"
      lipo -create "$temp_dir/$APP_NAME-arm64" "$temp_dir/$APP_NAME-x86_64" \
        -output "$macos_dir/$APP_NAME"
      rm -rf "$temp_dir"
      ;;
    *)
      die "unknown arch: $arch (expected arm64, x86_64 or universal)"
      ;;
  esac

  render_info_plist "$contents_dir/Info.plist"
  copy_resources "$resources_dir"

  # swiftc writes the dSYM next to the binary; keep it out of the app bundle.
  if [[ -d "$macos_dir/$APP_NAME.dSYM" ]]; then
    rm -rf "$BUILD_DIR/Debug/$APP_NAME.dSYM"
    mv "$macos_dir/$APP_NAME.dSYM" "$BUILD_DIR/Debug/$APP_NAME.dSYM"
  fi

  chmod +x "$macos_dir/$APP_NAME"

  if [[ -n "$identity" ]]; then
    sign_app "$app_dir" "$identity"
  fi

  echo "$app_dir"
}

compile_debug_arch() {
  local arch="$1"
  local output="$2"

  swiftc \
    -target "$arch-apple-macos$DEPLOYMENT_TARGET" \
    -module-cache-path "$MODULE_CACHE_DIR" \
    -g \
    -Onone \
    -D DEBUG \
    -o "$output" \
    "${SWIFT_SOURCES[@]}"
}

build_release() {
  local identity="${1:-}"

  info "Building release (xcodebuild) → $RELEASE_APP_DIR"

  if ! xcodebuild \
    -project "$ROOT_DIR/CleanLock.xcodeproj" \
    -scheme CleanLock \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build 2>&1 | tail -n 5 >&2; then
    die "xcodebuild Release build failed"
  fi

  local product="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"
  [[ -d "$product" ]] || die "release product not found: $product"

  rm -rf "$RELEASE_APP_DIR"
  mkdir -p "$(dirname "$RELEASE_APP_DIR")"
  ditto "$product" "$RELEASE_APP_DIR"

  info "Architectures: $(lipo -archs "$RELEASE_APP_DIR/Contents/MacOS/$APP_NAME")"

  if [[ -n "$identity" ]]; then
    sign_app "$RELEASE_APP_DIR" "$identity"
  fi

  echo "$RELEASE_APP_DIR"
}

install_app() {
  local sign="$1"

  local identity=""
  if [[ "$sign" == "yes" ]]; then
    identity="$SIGN_IDENTITY"
  fi

  local source
  source="$(build_release "$identity")"

  info "Installing → $INSTALL_DIR/$APP_NAME.app"

  pkill -x "$APP_NAME" 2>/dev/null || true

  local privileged="no"
  if [[ ! -w "$INSTALL_DIR" ]]; then
    privileged="yes"
  fi

  if [[ "$privileged" == "yes" ]]; then
    sudo rm -rf "$INSTALL_DIR/$APP_NAME.app"
    sudo ditto "$source" "$INSTALL_DIR/$APP_NAME.app"
  else
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    ditto "$source" "$INSTALL_DIR/$APP_NAME.app"
  fi

  if [[ "$sign" == "no" ]]; then
    echo "warning: --no-sign leaves the bundle without a signature; macOS will refuse the Accessibility and Input Monitoring grants" >&2
  fi

  echo "$INSTALL_DIR/$APP_NAME.app"
}

run_app() {
  local app_dir
  app_dir="$(build_debug arm64 "$SIGN_IDENTITY")"

  info "Launching $app_dir"
  open -n "$app_dir"
}

package_app() {
  # Ad-hoc is the default for the distributable artifact: a development
  # certificate is unknown to the machines of the end users.
  local identity="${SIGN_IDENTITY_OVERRIDE:--}"

  local source
  source="$(build_release "$identity")"

  mkdir -p "$DIST_DIR"
  rm -f "$DIST_DIR/$APP_NAME.zip"

  info "Packaging → $DIST_DIR/$APP_NAME.zip"
  ditto -c -k --sequesterRsrc --keepParent "$source" "$DIST_DIR/$APP_NAME.zip"

  echo "$DIST_DIR/$APP_NAME.zip"
}

clean_all() {
  info "Cleaning build artifacts"
  rm -rf "$BUILD_DIR" "$MODULE_CACHE_DIR"
}

usage() {
  sed -n '2,20p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

# --- entry point -----------------------------------------------------------

command="${1:-help}"
shift || true

arch="arm64"
sign="yes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      arch="${2:-}"
      shift 2 || true
      ;;
    --no-sign)
      sign="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

read_project_settings

SIGN_IDENTITY_OVERRIDE="${CLEANLOCK_SIGN_IDENTITY:-}"
SIGN_IDENTITY="$(detect_sign_identity)"

case "$command" in
  debug)
    build_debug "$arch" "$SIGN_IDENTITY"
    ;;
  release)
    build_release "$SIGN_IDENTITY"
    ;;
  install)
    install_app "$sign"
    ;;
  run)
    run_app
    ;;
  package)
    package_app
    ;;
  clean)
    clean_all
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
