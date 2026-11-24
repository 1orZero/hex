# shellcheck shell=bash
# Mac step of fork/daily.sh: build Hex with upstream's scripts/build-app.sh as
# a stable-channel release with updates off, sign it with the fork's Apple
# Development identity, and replace /Applications/Hex.app while Hex is idle.

mac_app=/Applications/Hex.app
mac_bundle=

# SHA-1 of the Apple Development identity whose certificate belongs to $team.
mac_identity() {
  local hash name
  security find-identity -v -p codesigning |
    sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(Apple Development: .*\)"$/\1 \2/p' |
    while read -r hash name; do
      if security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *$team"; then
        printf '%s\n' "$hash"
        break
      fi
    done
}

mac_requirement() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^#* *designated => //p'; }
mac_team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
mac_running() { pgrep -f "^$mac_app/Contents/MacOS/hex( |\$)" >/dev/null; }
mac_plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

mac_build() {
  local identity out version build_log=$log_dir/$run_id-mac-build.log
  mac_status=build-failed
  identity=$(mac_identity)
  if [ -z "$identity" ]; then
    log "ERROR no Apple Development signing identity for team $team in the keychain"
    return 1
  fi
  if [ "$(git_repo rev-parse HEAD)" != "$candidate" ] || [ -z "$release_tag" ]; then
    log "ERROR $repo is not at a release-tagged $(short "$candidate")"
    return 1
  fi
  version=${release_tag#v}
  # A rustup home of its own keeps stable current, as upstream builds with the
  # newest stable, without moving the toolchains Derek's other projects use.
  if ! RUSTUP_HOME=$home/rustup rustup toolchain install stable --profile minimal --no-self-update >>"$build_log" 2>&1; then
    log "ERROR installing the stable Rust toolchain failed"
    return 1
  fi
  log "Building $(short "$candidate") as Hex $version (stable channel); output in $build_log"
  # HEX_RELEASE_UNSIGNED builds Hex (anomaly.hex) ad-hoc signed, because the signing
  # path in macos-signing.sh takes only a Developer ID identity.
  if ! out=$(RUSTUP_HOME=$home/rustup RUSTUP_TOOLCHAIN=stable HEX_RELEASE_UNSIGNED=1 HEX_BUILD_CHANNEL=stable \
    HEX_VERSION=$version "$repo/scripts/build-app.sh" 2>>"$build_log"); then
    log "ERROR build-app.sh failed; last lines:"
    tail -n 40 "$build_log" | sed 's/^/  /'
    return 1
  fi
  mac_bundle=$(printf '%s\n' "$out" | tail -n 1)
  # HEX_DISABLE_UPDATES turns Hex's updater off for every launch LaunchServices makes;
  # HexForkCommit records the fork commit, which a stable build does not embed.
  plutil -replace LSEnvironment -json '{"HEX_DISABLE_UPDATES":"1"}' "$mac_bundle/Contents/Info.plist" &&
    plutil -replace HexForkCommit -string "$candidate" "$mac_bundle/Contents/Info.plist" || return 1
  log "Signing with the Apple Development identity of team $team"
  if ! mac_sign "$mac_bundle" "$identity" >>"$build_log" 2>&1; then
    log "ERROR signing failed; last lines:"
    tail -n 20 "$build_log" | sed 's/^/  /'
    return 1
  fi
  mac_verify "$mac_bundle" "$version" || return 1
  mac_status=built
}

mac_sign() {
  local bundle=$1 identity=$2 main item
  main=$bundle/Contents/MacOS/$(mac_plist "$bundle" CFBundleExecutable)
  # Nested code first, keeping the identifier and entitlements build-app.sh gave each.
  for item in "$bundle"/Contents/Library/* "$bundle"/Contents/MacOS/*; do
    [ -e "$item" ] && [ "$item" != "$main" ] || continue
    codesign --force --options runtime --timestamp=none --preserve-metadata=identifier,entitlements \
      --sign "$identity" "$item" || return 1
  done
  codesign --force --options runtime --timestamp=none --preserve-metadata=identifier,entitlements \
    --sign "$identity" "$bundle" || return 1
  codesign --verify --deep --strict "$bundle"
}

mac_verify() {
  local bundle=$1 version=$2 file reported
  while IFS= read -r file; do
    file -b "$file" | grep -q '^Mach-O' || continue
    if [ "$(mac_team "$file")" != "$team" ]; then
      log "ERROR $file is not signed by team $team; teach mac_sign about it"
      return 1
    fi
  done < <(find "$bundle" -type f)
  reported=$("$bundle/Contents/MacOS/hex" --version 2>/dev/null | head -n 1)
  if [ "$reported" != "hex $version" ] || [ "$(mac_plist "$bundle" HexForkCommit)" != "$candidate" ]; then
    log "ERROR the built app reports '$reported' at $(mac_plist "$bundle" HexForkCommit); expected hex $version at $candidate"
    return 1
  fi
  log "Built $reported (anomaly.hex, team $team, updates off)"
}

# Prints why Hex can't quit yet, or nothing when it is idle.
mac_busy_reason() {
  local json
  json=$("$mac_app/Contents/MacOS/hex" status --json 2>/dev/null) || { echo "status unavailable"; return; }
  printf '%s' "$json" | jq -r '
    if (.meeting.state // "idle") != "idle" then "meeting \(.meeting.state)"
    elif .listener.running == false then empty
    elif .capture.state != "idle" then "dictation \(.capture.state)"
    elif (.capture.pending_jobs // 0) > 0 then "\(.capture.pending_jobs) pending jobs"
    else empty end' 2>/dev/null || echo "unreadable status"
}

mac_quit_when_idle() {
  local deadline reason waited=0
  deadline=$(($(date +%s) + idle_wait))
  while :; do
    reason=$(mac_busy_reason)
    if [ -z "$reason" ]; then
      # quit without --force is refused while a recording is in progress.
      "$mac_app/Contents/MacOS/hex" quit >/dev/null 2>&1 && break
      reason="quit refused"
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "Hex stayed busy ($reason) for ${idle_wait}s; the next run installs"
      mac_status=busy
      return "$EXIT_MAC_BUSY"
    fi
    log "Hex is busy ($reason); checking again in 15s"
    sleep 15
  done
  while mac_running; do
    if [ "$waited" -ge 60 ]; then
      log "ERROR Hex did not quit within 60s"
      mac_status=install-failed
      return "$EXIT_MAC_INSTALL"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "Hex quit"
}

mac_install() {
  local staged=/Applications/.Hex.app.installing identity_change=0 was_running=0 rc json update waited=0
  mac_status=install-failed
  if [ -d "$mac_app" ]; then
    if [ "$(mac_plist "$mac_app" CFBundleIdentifier)" != anomaly.hex ]; then
      log "ERROR $mac_app is not Hex (anomaly.hex); not replacing it"
      return "$EXIT_MAC_INSTALL"
    fi
    if [ "$(mac_requirement "$mac_app")" != "$(mac_requirement "$mac_bundle")" ]; then
      identity_change=1
      if [ "$allow_identity_change" != 1 ]; then
        log "The installed Hex is signed by another identity (team $(mac_team "$mac_app")). Replacing it resets"
        log "macOS permissions such as Microphone and Accessibility, so rerun with --allow-identity-change while Derek can grant them again."
        mac_status=needs-derek
        return "$EXIT_MAC_IDENTITY"
      fi
    fi
  fi
  rm -rf "$staged" && ditto "$mac_bundle" "$staged" || { log "ERROR could not stage $staged"; return "$EXIT_MAC_INSTALL"; }
  if mac_running; then
    was_running=1
    mac_quit_when_idle
    rc=$?
    [ "$rc" -eq 0 ] || { rm -rf "$staged"; return "$rc"; }
  fi
  if [ "$identity_change" = 1 ]; then
    mkdir -p "$home/backup" && rm -rf "$home/backup/Hex.app" && mv "$mac_app" "$home/backup/Hex.app" &&
      log "Moved the previous Hex.app to $home/backup/Hex.app"
    if tccutil reset All anomaly.hex >/dev/null 2>&1; then
      log "Reset macOS permissions for anomaly.hex; Hex asks for them again"
    else
      log "tccutil reset failed; remove Hex from System Settings › Privacy & Security and grant it again"
    fi
  fi
  rm -rf "$mac_app"
  if ! mv "$staged" "$mac_app"; then
    log "ERROR could not move the new Hex.app into place"
    return "$EXIT_MAC_INSTALL"
  fi
  write_state mac "$candidate"
  mac_status=installed
  log "Installed $mac_app at $(short "$candidate")"
  [ "$was_running" = 1 ] || { log "Hex was not running, so it stays closed"; return 0; }
  open "$mac_app"
  while [ "$waited" -lt 60 ]; do
    if json=$("$mac_app/Contents/MacOS/hex" status --json 2>/dev/null); then
      log "Hex is running: $(printf '%s' "$json" | jq -r '"version \(.app_version), listener \(.listener.status), permissions ready: \(.permissions.ready), update: \(.update)"')"
      update=$(printf '%s' "$json" | jq -r '.update')
      if [ "$update" != unavailable ]; then
        log "ERROR the updater reports '$update' instead of unavailable; quit Hex before it updates itself"
        mac_status=installed-updates-on
        return "$EXIT_MAC_INSTALL"
      fi
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  log "Hex did not answer hex status within 60s of opening; check it on the Mac"
}
