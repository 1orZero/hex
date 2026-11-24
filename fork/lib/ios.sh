# shellcheck shell=bash
# iPhone step of fork/daily.sh: merge upstream's newest App Store tag into the
# fork's iOS branch, build ios/ under the fork's identity in a staging worktree,
# so the repo itself is never rewritten, and install it on the iPhone over the
# network, then copy the Mac's vocabulary into its App Group. Sets ios_candidate,
# ios_release, ios_sync_status, ios_merged_tag, ios_upstream_commits, ios_pushed, and
# ios_vocabulary_status.

ios_src=$home/ios-src
ios_derived=$home/ios-derived
ios_app=
ios_udid=
ios_tag_glob='ios-beta-appstore-*'
ios_vocabulary_dir=$state_dir/ios-vocabulary
ios_vocabulary_file=fork-mac-vocabulary.json

git_ios() { git -C "$ios_src" "$@"; }

# Upstream's App Store tags (ios-beta-appstore-X.Y.Z), newest first; with a commit, only
# the ones it contains.
ios_tags() {
  git_repo tag -l ${1:+--merged "$1"} "$ios_tag_glob" | grep -E '^ios-beta-appstore-[0-9]+(\.[0-9]+)*$' | sort -V -r
}

ios_worktree() {
  [ -e "$ios_src/.git" ] && return 0
  rm -rf "$ios_src"
  git_repo worktree prune
  git_repo worktree add --quiet --detach "$ios_src" "origin/$ios_branch"
}

ios_sync() {
  local head tag base fork
  ios_sync_status=failed
  if ! git_repo fetch --quiet --no-tags origin "$ios_branch" ||
    ! git_repo fetch --quiet --no-tags --force upstream "refs/tags/$ios_tag_glob:refs/tags/$ios_tag_glob"; then
    log "ERROR fetching origin/$ios_branch and upstream's App Store tags failed"
    return "$EXIT_SETUP"
  fi
  tag=$(ios_tags | head -n 1)
  if [ -z "$tag" ]; then
    log "ERROR upstream has no ios-beta-appstore-X.Y.Z tag"
    return "$EXIT_SETUP"
  fi
  if ! ios_worktree; then
    log "ERROR could not prepare $ios_src"
    return "$EXIT_SETUP"
  fi
  head=$(git_repo rev-parse "origin/$ios_branch") || return "$EXIT_SETUP"
  if git_ios rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null; then
    if [ "$continue_ios" = 1 ]; then
      ios_continue "$head"
      return
    fi
    log "Dropping the unresolved $ios_branch merge an earlier run left"
    git_ios cherry-pick --abort >/dev/null 2>&1 || git_ios cherry-pick --quit || return "$EXIT_SETUP"
  elif [ "$continue_ios" = 1 ]; then
    log "ERROR --continue-ios expects the resolved $ios_branch merge in $ios_src"
    return "$EXIT_SETUP"
  fi

  if git_repo merge-base --is-ancestor "$tag" "$head"; then
    ios_candidate=$head
    ios_release=$(ios_tags "$head" | head -n 1)
    ios_sync_status=up-to-date
    log "origin/$ios_branch $(short "$head") already contains $tag, upstream's newest App Store tag"
    return 0
  fi
  base=$(ios_tags "$head" | head -n 1)
  if [ -z "$base" ]; then
    log "ERROR origin/$ios_branch contains no App Store tag to merge from"
    return "$EXIT_SETUP"
  fi
  ios_merged_tag=$tag
  ios_upstream_commits=$(git_repo rev-list --count --no-merges "$base..$tag")
  log "Merging $tag ($ios_upstream_commits upstream commits since $base) into origin/$ios_branch $(short "$head")"
  # The merge is taken against $base, the tag the branch last merged. git's own merge base would
  # be the last dev commit both tags share, and an App Store tag is a release tree beside dev
  # whose changes dev later makes its own way, so they would conflict on files the fork never
  # touched. Here the fork's changes (head against base, as one commit) are applied to the tag.
  fork=$(git_repo commit-tree "$head^{tree}" -p "$base^{commit}" -m "Fork changes on $ios_branch at $head") || return "$EXIT_SETUP"
  if ! git_ios checkout --quiet --detach --force "$tag^{commit}" || ! git_ios clean -fdq; then
    log "ERROR could not check out $tag in $ios_src"
    return "$EXIT_SETUP"
  fi
  if git_ios cherry-pick --allow-empty --keep-redundant-commits "$fork" >/dev/null 2>&1; then
    ios_commit_merge "$head" "$tag"
    return
  fi
  if [ -z "$(git_ios diff --name-only --diff-filter=U)" ]; then
    log "ERROR applying the fork's changes to $tag failed without conflicts"
    git_ios cherry-pick --abort >/dev/null 2>&1
    return "$EXIT_SETUP"
  fi
  ios_sync_status=conflict
  log "CONFLICT in:"
  git_ios diff --name-only --diff-filter=U | sed 's/^/  /'
  log "The merge stays in $ios_src: HEAD is $tag and the fork's changes are being applied to it. Resolve each file as FORK.md on $ios_branch describes, git add it, and rerun fork/daily.sh --continue-ios; or run git -C $ios_src cherry-pick --abort."
  return "$EXIT_IOS_CONFLICT"
}

# --continue-ios: the conflicts of the merge ios_sync left are resolved and added.
ios_continue() {
  local head=$1 tag picked
  picked=$(git_ios rev-parse CHERRY_PICK_HEAD)
  tag=$(git_repo tag -l --points-at "$(git_ios rev-parse HEAD)" "$ios_tag_glob" | sort -V -r | head -n 1)
  if [ -z "$tag" ] || [ "$(git_repo rev-parse "$picked^{tree}")" != "$(git_repo rev-parse "$head^{tree}")" ]; then
    log "ERROR $ios_src no longer holds the merge of an App Store tag into origin/$ios_branch $(short "$head"); run git -C $ios_src cherry-pick --abort"
    return "$EXIT_SETUP"
  fi
  if [ -n "$(git_ios diff --name-only --diff-filter=U)" ]; then
    log "ERROR files in $ios_src are still unmerged:"
    git_ios diff --name-only --diff-filter=U | sed 's/^/  /'
    return "$EXIT_SETUP"
  fi
  if git_ios diff --cached "$tag^{commit}" | grep -qE '^\+(<{7}|={7}|>{7})( |$)'; then
    log "ERROR the resolved files in $ios_src still hold conflict markers"
    return "$EXIT_SETUP"
  fi
  ios_merged_tag=$tag
  ios_upstream_commits=$(git_repo rev-list --count --no-merges "$(git_repo rev-parse "$picked^")..$tag")
  log "Continuing with the resolved merge of $tag into origin/$ios_branch $(short "$head")"
  ios_commit_merge "$head" "$tag"
}

# The merge commit of $ios_branch's head ($1) and the tag ($2), from the tree in the index.
ios_commit_merge() {
  local tree
  if ! tree=$(git_ios write-tree) ||
    ! ios_candidate=$(git_ios commit-tree "$tree" -p "$1" -p "$2^{commit}" -m "Merge upstream $2 into $ios_branch"); then
    log "ERROR could not commit the merge of $2"
    return "$EXIT_SETUP"
  fi
  git_ios cherry-pick --quit
  ios_release=$2
  ios_sync_status=merged
  log "Merged into $(short "$ios_candidate")"
}

ios_push() {
  if ! git_repo push --quiet origin "$ios_candidate:refs/heads/$ios_branch"; then
    log "ERROR pushing $(short "$ios_candidate") to origin/$ios_branch failed"
    return 1
  fi
  ios_pushed=true
  log "Pushed $(short "$ios_candidate") to origin/$ios_branch"
}

ios_checkout() {
  git_ios checkout --quiet --detach --force "$ios_candidate" && git_ios clean -fdq -- ios
}

# Every identifier under upstream's app bundle ID (the app and extension IDs, the
# App Group, keychain groups) moves under $ios_prefix, so the app signs with $team
# and installs beside the official one. The version is the App Store tag's, as
# upstream's App Store build stamps it (ios/ci_scripts/ci_post_clone.sh).
ios_rewrite_identity() {
  local ios=$ios_src/ios upstream file version=${ios_release#ios-beta-appstore-}
  case $ios_prefix in
    "" | *[!A-Za-z0-9.-]*) log "ERROR HEX_FORK_IOS_BUNDLE_PREFIX '$ios_prefix' is not a bundle ID"; return 1 ;;
  esac
  case $version in
    "" | *[!0-9.]* | .* | *.) log "ERROR '$ios_release' is not an App Store tag"; return 1 ;;
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
  sed -i '' -E "s/^( +MARKETING_VERSION: ).*/\1$version/" "$ios/project.yml"
  log "Rewrote $upstream to $ios_prefix, version $version"
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
  log "Preparing $ios_src at $(short "$ios_candidate") ($ios_release); output in $build_log"
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
  local id name team_id version appex
  [ -d "$ios_app" ] || { log "ERROR $ios_app is missing"; return 1; }
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ios_app/Info.plist")
  name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ios_app/Info.plist")
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ios_app/Info.plist")
  team_id=$(codesign -dv "$ios_app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [ "$id" != "$ios_prefix" ] || [ "$team_id" != "$team" ]; then
    log "ERROR built $id signed by team $team_id; expected $ios_prefix and $team"
    return 1
  fi
  if ! codesign -d --entitlements - "$ios_app" 2>/dev/null | grep -qF "group.$ios_prefix"; then
    log "ERROR the built app lacks the group.$ios_prefix entitlement"
    return 1
  fi
  for appex in "$ios_app"/PlugIns/*.appex; do
    case $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appex/Info.plist") in
      "$ios_prefix".*) ;;
      *) log "ERROR $(basename "$appex") is not under $ios_prefix"; return 1 ;;
    esac
  done
  if ! codesign -d --entitlements - "$ios_app/PlugIns/HEXKeyboard.appex" 2>/dev/null | grep -qF "group.$ios_prefix"; then
    log "ERROR the keyboard lacks the group.$ios_prefix entitlement"
    return 1
  fi
  log "Built $name $version ($id, team $team_id)"
}

# Sets ios_udid to the paired $iphone's when it answers (its output goes to $1); 1 when it doesn't.
ios_device() {
  local devices
  devices=$(mktemp)
  xcrun devicectl list devices --json-output "$devices" >/dev/null 2>&1
  ios_udid=$(jq -r --arg name "$iphone" '.result.devices[]?
    | select(.deviceProperties.name == $name and .hardwareProperties.reality == "physical")
    | select(.connectionProperties.pairingState == "paired" and (.connectionProperties.transportType // "") != "")
    | .hardwareProperties.udid' "$devices" 2>/dev/null | head -n 1)
  rm -f "$devices"
  [ -n "$ios_udid" ] && xcrun devicectl device info details --device "$ios_udid" --timeout 90 >>"$1" 2>&1
}

ios_install() {
  local install_log=$log_dir/$run_id-ios-install.log
  ios_status=install-failed
  if ! ios_device "$install_log"; then
    log "$iphone is not reachable (another network, asleep, or unpaired); skipping the iPhone install"
    ios_status=skipped-unreachable
    return "$EXIT_IOS_SKIPPED"
  fi
  log "Installing on $iphone; output in $install_log"
  if ! xcrun devicectl device install app --device "$ios_udid" --timeout 600 "$ios_app" >>"$install_log" 2>&1; then
    log "ERROR devicectl install failed; last lines:"
    tail -n 20 "$install_log" | sed 's/^/  /'
    return "$EXIT_IOS_INSTALL"
  fi
  write_state ios "$ios_candidate"
  ios_status=installed
  log "Installed $ios_prefix on $iphone at $(short "$ios_candidate")"
}

# The Mac's vocabulary for the iPhone (ForkMacVocabulary on ios-stable): its terms in its order,
# copied into the App Group when they differ from the last copy or the app was just installed. The
# file holds names and email addresses, so it stays owner-only in $ios_vocabulary_dir.
ios_vocabulary() {
  local hex=${HEX_FORK_HEX:-$mac_app/Contents/MacOS/hex} next=$ios_vocabulary_dir/next/$ios_vocabulary_file
  local copied=$ios_vocabulary_dir/$ios_vocabulary_file copy_log=$log_dir/$run_id-ios-vocabulary.log count
  ios_vocabulary_status=failed
  (umask 077 && mkdir -p "$ios_vocabulary_dir/next") || return 1
  if ! (umask 077 && "$hex" vocabulary list --json 2>>"$copy_log" | jq -e '{terms: [.entries[].term]}' >"$next" 2>>"$copy_log"); then
    rm -f "$next"
    if ! mac_running; then
      ios_vocabulary_status=skipped-hex-not-running
      log "Hex isn't running on the Mac, so its vocabulary can't be read; the next run copies it"
      return 0
    fi
    log "ERROR reading the Mac's vocabulary failed; see $copy_log"
    return 1
  fi
  count=$(jq '.terms | length' "$next")
  if [ "$force" != 1 ] && [ "$ios_status" != installed ] && cmp -s "$next" "$copied"; then
    ios_vocabulary_status=up-to-date
    log "The iPhone already has the Mac's $count vocabulary terms"
    return 0
  fi
  if [ "$no_push" = 1 ]; then
    ios_vocabulary_status=changed
    log "--no-push: not copying the Mac's $count vocabulary terms to $iphone"
    return 0
  fi
  if [ "$ios_status" = skipped-unreachable ] || ! ios_device "$copy_log"; then
    ios_vocabulary_status=skipped-unreachable
    log "$iphone is not reachable; the next run copies the Mac's vocabulary"
    return "$EXIT_IOS_SKIPPED"
  fi
  if ! xcrun devicectl device copy to --device "$ios_udid" --domain-type appGroupDataContainer \
    --domain-identifier "group.$ios_prefix" --source "$next" --destination "$ios_vocabulary_file" \
    --timeout 120 >>"$copy_log" 2>&1; then
    log "ERROR copying the vocabulary to $iphone failed; last lines:"
    tail -n 20 "$copy_log" | sed 's/^/  /'
    return 1
  fi
  mv "$next" "$copied"
  ios_vocabulary_status=copied
  log "Copied the Mac's $count vocabulary terms to $iphone"
}
