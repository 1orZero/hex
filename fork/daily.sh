#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Daily pipeline for the 1orzero/hex fork on Derek's Mac. It merges upstream's
# newest release tag into the fork's stable branch and upstream's newest App
# Store tag into its ios-stable branch, then builds and installs the Mac app
# from stable and the iPhone app from ios-stable when each differs from the
# commit it last installed, and copies the Mac's vocabulary to the iPhone when it
# changed. FORK.md lists the options, exit codes, and what to do on a merge
# conflict.
set -uo pipefail

fork_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

EXIT_SETUP=2
EXIT_IOS_SKIPPED=10
EXIT_CONFLICT=20
EXIT_MERGE_BUILD=21
EXIT_PUSH=22
EXIT_IOS_CONFLICT=23
EXIT_IOS_MERGE_BUILD=24
EXIT_IOS_PUSH=25
EXIT_MAC_BUILD=30
EXIT_IOS_BUILD=31
EXIT_MAC_BUSY=40
EXIT_MAC_IDENTITY=41
EXIT_MAC_INSTALL=42
EXIT_IOS_INSTALL=43
EXIT_IOS_VOCABULARY=44

home=${HEX_FORK_HOME:-$HOME/.hex-fork}
repo=$home/repo
state_dir=$home/state
log_dir=$home/logs
branch=${HEX_FORK_BRANCH:-stable}
ios_branch=${HEX_FORK_IOS_BRANCH:-ios-stable}
fork_repo=${HEX_FORK_REPO:-1orzero/hex}
upstream_repo=${HEX_FORK_UPSTREAM_REPO:-anomalyco/hex}
origin_url=https://github.com/$fork_repo.git
upstream_url=https://github.com/$upstream_repo.git
team=${HEX_FORK_TEAM_ID:-67A6AV33K9}
iphone=${HEX_FORK_IPHONE:-Derek888}
ios_prefix=${HEX_FORK_IOS_BUNDLE_PREFIX:-io.veraze.hex.mobile}
ios_app_name=${HEX_FORK_IOS_APP_NAME:-Hex Fork}
idle_wait=${HEX_FORK_IDLE_WAIT:-600}

# Everything loads up front: the sync step may rewrite the clone this runs from.
# shellcheck source=lib/sync.sh
. "$fork_dir/lib/sync.sh"
# shellcheck source=lib/mac.sh
. "$fork_dir/lib/mac.sh"
# shellcheck source=lib/ios.sh
. "$fork_dir/lib/ios.sh"

continue_merge=0
continue_ios=0
allow_identity_change=0
no_push=0
force=0

run_id=$(date '+%Y%m%d-%H%M%S')
run_started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
log_file=
candidate=
release_tag=
sync_status=not-run
merged_tag=
upstream_commits=0
pushed=false
mac_status=not-run
ios_candidate=
ios_release=
ios_sync_status=not-run
ios_merged_tag=
ios_upstream_commits=0
ios_pushed=false
ios_status=not-run
ios_vocabulary_status=not-run

usage() {
  cat <<'EOF'
Usage: fork/daily.sh [--continue] [--continue-ios] [--allow-identity-change] [--no-push] [--force]

  --continue               finish a merge whose conflicts were resolved and committed in the clone
  --continue-ios           finish an ios-stable merge whose conflicts were resolved and added in ios-src
  --allow-identity-change  replace a Hex.app signed by another identity; macOS permissions reset,
                           so run it only while Derek can grant them again
  --no-push                merge and build only; push and install nothing
  --force                  build and install even when the installed commits match
EOF
}

# The first nonzero code in the order given: what the run exits with.
first_failure() {
  local code
  for code in "$@"; do
    [ "$code" -ne 0 ] && { echo "$code"; return; }
  done
  echo 0
}

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
step() { log "== $*"; }
short() { printf '%.9s' "$1"; }

read_state() { cat "$state_dir/$1-installed" 2>/dev/null || true; }

write_state() {
  printf '%s\n' "$2" >"$state_dir/$1-installed.tmp" && mv "$state_dir/$1-installed.tmp" "$state_dir/$1-installed"
}

check_tools() {
  local tool missing=
  for tool in git gh jq rustup cargo xcodegen xcodebuild xcrun codesign security openssl ditto plutil curl; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  [ -z "$missing" ] && return 0
  log "ERROR missing tools:$missing"
  return 1
}

acquire_lock() {
  local lock=$home/run.lock pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "ERROR another run (pid $pid) is in progress"
      return 1
    fi
    rm -rf "$lock" && mkdir "$lock" || return 1
  fi
  echo $$ >"$lock/pid"
  trap 'rm -rf "$home/run.lock"' EXIT
}

# Writes state/last-run.json and the summary, then returns the exit code.
finish() {
  local code=$1
  jq -n \
    --arg started "$run_started" --arg finished "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson exit "$code" \
    --arg branch "$branch" --arg candidate "$candidate" --arg release "$release_tag" \
    --arg sync "$sync_status" --arg merged_tag "$merged_tag" --argjson commits "$upstream_commits" --argjson pushed "$pushed" \
    --arg mac "$mac_status" --arg mac_installed "$(read_state mac)" \
    --arg ios_branch "$ios_branch" --arg ios_candidate "$ios_candidate" --arg ios_release "$ios_release" \
    --arg ios_sync "$ios_sync_status" --arg ios_merged_tag "$ios_merged_tag" \
    --argjson ios_commits "$ios_upstream_commits" --argjson ios_pushed "$ios_pushed" \
    --arg ios "$ios_status" --arg ios_installed "$(read_state ios)" --arg ios_vocabulary "$ios_vocabulary_status" --arg log "$log_file" \
    '{started: $started, finished: $finished, exit: $exit, branch: $branch, candidate: $candidate, release: $release,
      sync: {status: $sync, merged_tag: $merged_tag, upstream_commits: $commits, pushed: $pushed},
      mac: {status: $mac, installed: $mac_installed},
      ios_sync: {branch: $ios_branch, status: $ios_sync, merged_tag: $ios_merged_tag, upstream_commits: $ios_commits, pushed: $ios_pushed},
      ios: {status: $ios, candidate: $ios_candidate, release: $ios_release, installed: $ios_installed},
      ios_vocabulary: {status: $ios_vocabulary}, log: $log}' >"$state_dir/last-run.json"
  step "Summary"
  log "sync: $sync_status, merged tag: ${merged_tag:-none} ($upstream_commits upstream commits), pushed: $pushed"
  log "candidate: ${candidate:-none} (release ${release_tag:-unknown})"
  log "ios sync: $ios_sync_status, merged tag: ${ios_merged_tag:-none} ($ios_upstream_commits upstream commits), pushed: $ios_pushed"
  log "ios candidate: ${ios_candidate:-none} (${ios_release:-unknown})"
  log "mac: $mac_status (installed: $(read_state mac))"
  log "ios: $ios_status (installed: $(read_state ios))"
  log "ios vocabulary: $ios_vocabulary_status"
  log "exit: $code"
  return "$code"
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --continue) continue_merge=1 ;;
      --continue-ios) continue_ios=1 ;;
      --allow-identity-change) allow_identity_change=1 ;;
      --no-push) no_push=1 ;;
      --force) force=1 ;;
      -h | --help) usage; return 0 ;;
      *) usage >&2; return "$EXIT_SETUP" ;;
    esac
    shift
  done
  export PATH="$PATH:/opt/homebrew/bin:$HOME/.cargo/bin"
  # build-app.sh copies the binary from <repo>/target, so the clone keeps its own.
  unset CARGO_TARGET_DIR
  mkdir -p "$state_dir" "$log_dir" || return "$EXIT_SETUP"
  command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; return "$EXIT_SETUP"; }
  log_file=$log_dir/$run_id.log
  exec > >(tee -a "$log_file") 2>&1
  ln -sf "$run_id.log" "$log_dir/latest.log"
  find "$log_dir" -type f -mtime +30 -delete

  step "Hex fork daily run $run_id"
  if ! check_tools || ! acquire_lock; then
    finish "$EXIT_SETUP"
    return
  fi

  step "Sync"
  local rc stable_rc=0 ios_sync_rc=0
  sync_upstream
  rc=$?
  case $rc in
    0) ;;
    "$EXIT_CONFLICT") stable_rc=$rc ;;
    *) finish "$rc"; return ;;
  esac
  step "iOS sync"
  ios_sync
  rc=$?
  case $rc in
    0) ;;
    "$EXIT_IOS_CONFLICT") ios_sync_rc=$rc ;;
    *) finish "$(first_failure "$stable_rc" "$rc")"; return ;;
  esac

  local merged=0 ios_merged=0 mac_needed=0 ios_needed=0 mac_rc=0 ios_rc=0
  [ "$sync_status" = merged ] && merged=1
  [ "$ios_sync_status" = merged ] && ios_merged=1
  if [ "$stable_rc" -eq 0 ]; then
    if [ "$merged" = 1 ] || [ "$force" = 1 ] || [ "$candidate" != "$(read_state mac)" ]; then
      mac_needed=1
    else
      mac_status=up-to-date
      log "The Mac already runs $(short "$candidate")"
    fi
  fi
  if [ "$ios_sync_rc" -eq 0 ]; then
    if [ "$ios_merged" = 1 ] || [ "$force" = 1 ] || [ "$ios_candidate" != "$(read_state ios)" ]; then
      ios_needed=1
    else
      ios_status=up-to-date
      log "The iPhone already runs $(short "$ios_candidate")"
    fi
  fi

  if [ "$mac_needed" = 1 ]; then
    step "Mac build"
    mac_build || mac_rc=$EXIT_MAC_BUILD
  fi
  if [ "$ios_needed" = 1 ]; then
    step "iOS build"
    ios_build || ios_rc=$EXIT_IOS_BUILD
  fi

  if [ "$merged" = 1 ] && [ "$mac_rc" -ne 0 ]; then
    log "The merged $branch does not build; it is not pushed or installed"
    sync_status="merged-build-failed"
    stable_rc=$EXIT_MERGE_BUILD
  fi
  if [ "$ios_merged" = 1 ] && [ "$ios_rc" -ne 0 ]; then
    log "The merged $ios_branch does not build; it is not pushed or installed"
    ios_sync_status="merged-build-failed"
    ios_sync_rc=$EXIT_IOS_MERGE_BUILD
  fi
  if [ "$no_push" = 1 ]; then
    log "--no-push: skipping pushes and installs"
  else
    if [ "$merged" = 1 ] && [ "$stable_rc" -eq 0 ]; then
      step "Push"
      sync_push || stable_rc=$EXIT_PUSH
    fi
    if [ "$ios_merged" = 1 ] && [ "$ios_sync_rc" -eq 0 ]; then
      step "iOS push"
      ios_push || ios_sync_rc=$EXIT_IOS_PUSH
    fi

    if [ "$mac_needed" = 1 ] && [ "$mac_rc" -eq 0 ] && [ "$stable_rc" -eq 0 ]; then
      step "Mac install"
      mac_install
      mac_rc=$?
    fi
    if [ "$ios_needed" = 1 ] && [ "$ios_rc" -eq 0 ] && [ "$ios_sync_rc" -eq 0 ]; then
      step "iOS install"
      ios_install
      ios_rc=$?
    fi
  fi

  local vocabulary_rc=0
  step "iPhone vocabulary"
  ios_vocabulary
  case $? in
    0) ;;
    "$EXIT_IOS_SKIPPED") vocabulary_rc=$EXIT_IOS_SKIPPED ;;
    *) vocabulary_rc=$EXIT_IOS_VOCABULARY ;;
  esac
  finish "$(first_failure "$stable_rc" "$ios_sync_rc" "$mac_rc" "$ios_rc" "$vocabulary_rc")"
}

main "$@"; exit $?
