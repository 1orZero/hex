# shellcheck shell=bash
# iPhone step of fork/daily.sh: build ios/ under the fork's identity in a
# staging worktree, so the repo itself is never rewritten, and install it on
# the iPhone over the network.

ios_src=$home/ios-src
ios_derived=$home/ios-derived
ios_app=

ios_checkout() {
  if [ -e "$ios_src/.git" ]; then
    git -C "$ios_src" checkout --quiet --detach --force "$candidate" && git -C "$ios_src" clean -fdq -- ios
    return
  fi
  rm -rf "$ios_src"
  git_repo worktree prune
  git_repo worktree add --quiet --detach "$ios_src" "$candidate"
}

# Every identifier under upstream's app bundle ID (the app and extension IDs, the
# App Group, keychain groups) moves under $ios_prefix, so the app signs with $team
# and installs beside the official one.
ios_rewrite_identity() {
  local ios=$ios_src/ios upstream file
  case $ios_prefix in
    "" | *[!A-Za-z0-9.-]*) log "ERROR HEX_FORK_IOS_BUNDLE_PREFIX '$ios_prefix' is not a bundle ID"; return 1 ;;
  esac
  upstream=$(cd "$ios" && xcodegen dump --spec project.yml --type json 2>/dev/null | jq -r '.targets.HEXMobile.settings.base.PRODUCT_BUNDLE_IDENTIFIER // empty')
  case $upstream in
    "" | *[!A-Za-z0-9.-]*) log "ERROR could not read the HEXMobile bundle ID from ios/project.yml"; return 1 ;;
  esac
  grep -rlF --include='*.swift' --include='*.entitlements' --include=project.yml "$upstream" "$ios" |
    grep -v '/HEXMobileTests/' |
    while IFS= read -r file; do
      sed -i '' "s/$(printf '%s' "$upstream" | sed 's/\./\\./g')/$ios_prefix/g" "$file"
    done
  if grep -rlF --include='*.swift' --include='*.entitlements' --include=project.yml "$upstream" "$ios" | grep -qv '/HEXMobileTests/'; then
    log "ERROR $upstream is still referenced in $ios"
    return 1
  fi
  if ! grep -qF "group.$ios_prefix" "$ios/HEXMobile/HEXMobile.entitlements"; then
    log "ERROR the app's entitlements do not name group.$ios_prefix"
    return 1
  fi
  log "Rewrote $upstream to $ios_prefix"
  cat >"$ios/project.fork.yml" <<EOF
include:
  - project.yml
settings:
  base:
    DEVELOPMENT_TEAM: $team
targets:
  HEXMobile:
    info:
      properties:
        CFBundleDisplayName: "$ios_app_name"
  HEXKeyboard:
    info:
      properties:
        CFBundleDisplayName: "$ios_app_name Keyboard"
EOF
}

ios_build() {
  local ios=$ios_src/ios build_log=$log_dir/$run_id-ios-build.log pins
  local pinned=()
  ios_status=build-failed
  log "Preparing $ios_src at $(short "$candidate"); output in $build_log"
  ios_checkout >>"$build_log" 2>&1 || { log "ERROR could not check out $ios_src"; return 1; }
  ios_rewrite_identity || return 1
  if [ -x "$ios/scripts/fetch-cleanup-model.sh" ] && ! "$ios/scripts/fetch-cleanup-model.sh" >>"$build_log" 2>&1; then
    log "ERROR fetching the cleanup tagger model failed"
    return 1
  fi
  if ! (cd "$ios" && xcodegen generate --spec project.fork.yml --quiet) >>"$build_log" 2>&1; then
    log "ERROR xcodegen failed; last lines:"
    tail -n 20 "$build_log" | sed 's/^/  /'
    return 1
  fi
  if [ -f "$ios/Package.resolved" ]; then
    pins=$ios/HEXMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
    mkdir -p "$pins" && cp "$ios/Package.resolved" "$pins/Package.resolved" || return 1
    pinned=(-onlyUsePackageVersionsFromResolvedFile)
  fi
  log "Building Release for $ios_prefix (team $team)"
  if ! xcodebuild build -quiet -project "$ios/HEXMobile.xcodeproj" -scheme HEXMobile -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$ios_derived" -allowProvisioningUpdates \
    ${pinned[@]+"${pinned[@]}"} >>"$build_log" 2>&1; then
    log "ERROR xcodebuild failed; last lines:"
    tail -n 40 "$build_log" | sed 's/^/  /'
    return 1
  fi
  ios_app=$ios_derived/Build/Products/Release-iphoneos/HEX.app
  ios_verify || return 1
  ios_status=built
}

ios_verify() {
  local id name team_id
  [ -d "$ios_app" ] || { log "ERROR $ios_app is missing"; return 1; }
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ios_app/Info.plist")
  name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ios_app/Info.plist")
  team_id=$(codesign -dv "$ios_app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [ "$id" != "$ios_prefix" ] || [ "$team_id" != "$team" ]; then
    log "ERROR built $id signed by team $team_id; expected $ios_prefix and $team"
    return 1
  fi
  if ! codesign -d --entitlements - "$ios_app" 2>/dev/null | grep -qF "group.$ios_prefix"; then
    log "ERROR the built app lacks the group.$ios_prefix entitlement"
    return 1
  fi
  log "Built $name ($id, team $team_id)"
}

ios_install() {
  local devices udid install_log=$log_dir/$run_id-ios-install.log
  ios_status=install-failed
  devices=$(mktemp)
  xcrun devicectl list devices --json-output "$devices" >/dev/null 2>&1
  udid=$(jq -r --arg name "$iphone" '.result.devices[]?
    | select(.deviceProperties.name == $name and .hardwareProperties.reality == "physical")
    | select(.connectionProperties.pairingState == "paired" and (.connectionProperties.transportType // "") != "")
    | .hardwareProperties.udid' "$devices" 2>/dev/null | head -n 1)
  rm -f "$devices"
  if [ -z "$udid" ] || ! xcrun devicectl device info details --device "$udid" --timeout 90 >>"$install_log" 2>&1; then
    log "$iphone is not reachable (another network, asleep, or unpaired); skipping the iPhone install"
    ios_status=skipped-unreachable
    return "$EXIT_IOS_SKIPPED"
  fi
  log "Installing on $iphone; output in $install_log"
  if ! xcrun devicectl device install app --device "$udid" --timeout 600 "$ios_app" >>"$install_log" 2>&1; then
    log "ERROR devicectl install failed; last lines:"
    tail -n 20 "$install_log" | sed 's/^/  /'
    return "$EXIT_IOS_INSTALL"
  fi
  write_state ios "$candidate"
  ios_status=installed
  log "Installed $ios_prefix on $iphone at $(short "$candidate")"
}
