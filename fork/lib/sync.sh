# shellcheck shell=bash
# Sync step of fork/daily.sh: merge upstream's newest release tag into the
# fork's branch in the script's own clone. Sets candidate, release_tag,
# sync_status, merged_tag, upstream_commits, and pushed.

git_repo() { git -C "$repo" "$@"; }

# vX.Y.Z tags, newest first; upstream's dev channel and other tags never match.
release_tags() { git_repo tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V -r; }

# 0 when the tag's GitHub release is published (not a draft or prerelease), 1 when
# it is not or has no release, 2 when GitHub can't be asked.
release_published() {
  local answer attempt
  for attempt in 1 2 3; do
    if answer=$(gh api "repos/$upstream_repo/releases/tags/$1" --jq '.draft or .prerelease' 2>&1); then
      [ "$answer" = false ]
      return
    fi
    case $answer in *"HTTP 404"*) return 1 ;; esac
    [ "$attempt" = 3 ] || sleep 5
  done
  return 2
}

# The newest release tag whose GitHub release is published.
latest_release() {
  local tag rc
  for tag in $(release_tags | head -n 5); do
    release_published "$tag"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$tag"
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      log "ERROR asking GitHub about the $tag release failed" >&2
      return 1
    fi
  done
  log "ERROR found no published release among upstream's newest vX.Y.Z tags" >&2
  return 1
}

# The newest release tag a commit contains: the version its build carries.
release_of() {
  local tag
  for tag in $(release_tags); do
    if git_repo merge-base --is-ancestor "$tag" "$1"; then
      printf '%s\n' "$tag"
      return 0
    fi
  done
  return 1
}

sync_prepare_clone() {
  if [ ! -d "$repo/.git" ]; then
    log "Cloning $origin_url into $repo"
    git clone --quiet "$origin_url" "$repo" || return 1
  fi
  git_repo remote set-url origin "$origin_url" || return 1
  git_repo remote get-url upstream >/dev/null 2>&1 || git_repo remote add upstream "$upstream_url" || return 1
  git_repo remote set-url upstream "$upstream_url" || return 1
  # gh's token has the workflow scope that pushing upstream's .github/workflows changes needs.
  git_repo config --replace-all credential.helper '' &&
    git_repo config --add credential.helper "!$(command -v gh) auth git-credential"
}

sync_upstream() {
  local tag
  sync_status=failed
  if ! sync_prepare_clone; then
    log "ERROR could not prepare $repo"
    return "$EXIT_SETUP"
  fi
  if git_repo rev-parse -q --verify MERGE_HEAD >/dev/null; then
    if [ "$continue_merge" = 1 ]; then
      log "ERROR the merge in $repo is not committed; resolve it, git add, git commit, then rerun with --continue"
      sync_status=conflict
      return "$EXIT_SETUP"
    fi
    log "Aborting the unresolved merge an earlier run left"
    git_repo merge --abort || return "$EXIT_SETUP"
  fi
  if [ -n "$(git_repo status --porcelain --untracked-files=no)" ]; then
    log "ERROR $repo has uncommitted changes; it belongs to this script, so inspect and clean it"
    return "$EXIT_SETUP"
  fi
  if ! git_repo fetch --quiet --no-tags origin "$branch" ||
    ! git_repo fetch --quiet --no-tags --force upstream 'refs/tags/v*:refs/tags/v*'; then
    log "ERROR fetching origin/$branch and upstream's tags failed"
    return "$EXIT_SETUP"
  fi
  tag=$(latest_release) || return "$EXIT_SETUP"

  if [ "$continue_merge" = 1 ]; then
    if ! git_repo merge-base --is-ancestor "origin/$branch" HEAD || [ "$(git_repo rev-parse HEAD)" = "$(git_repo rev-parse "origin/$branch")" ]; then
      log "ERROR --continue expects HEAD in $repo to be the resolved merge on top of origin/$branch"
      return "$EXIT_SETUP"
    fi
    candidate=$(git_repo rev-parse HEAD)
    release_tag=$(release_of "$candidate")
    merged_tag=$release_tag
    upstream_commits=$(git_repo rev-list --count --no-merges "origin/$branch..$candidate")
    sync_status=merged
    log "Continuing with the resolved merge $(short "$candidate") of $merged_tag"
    return 0
  fi

  git_repo checkout --quiet --detach "origin/$branch" || return "$EXIT_SETUP"
  if git_repo merge-base --is-ancestor "$tag" HEAD; then
    candidate=$(git_repo rev-parse HEAD)
    release_tag=$(release_of "$candidate")
    sync_status=up-to-date
    log "origin/$branch $(short "$candidate") already contains $tag, upstream's newest release"
    return 0
  fi
  upstream_commits=$(git_repo rev-list --count --no-merges "HEAD..$tag")
  log "Merging $tag ($upstream_commits upstream commits) into origin/$branch $(short "$(git_repo rev-parse HEAD)")"
  if git_repo merge --quiet --no-edit -m "Merge upstream $tag into $branch" "$tag"; then
    candidate=$(git_repo rev-parse HEAD)
    release_tag=$tag
    merged_tag=$tag
    sync_status=merged
    log "Merged into $(short "$candidate")"
    return 0
  fi
  if [ -z "$(git_repo diff --name-only --diff-filter=U)" ]; then
    log "ERROR git merge failed without conflicts"
    git_repo merge --abort 2>/dev/null
    return "$EXIT_SETUP"
  fi
  merged_tag=$tag
  sync_status=conflict
  log "CONFLICT in:"
  git_repo diff --name-only --diff-filter=U | sed 's/^/  /'
  log "The merge stays in progress in $repo. Resolve it as FORK.md describes, commit, and rerun fork/daily.sh --continue; or run git -C $repo merge --abort."
  return "$EXIT_CONFLICT"
}

# Pushes the merge to origin; when the branch refuses direct pushes, merges it
# through a pull request pinned to the same commit.
sync_push() {
  local origin_before sync_branch url
  origin_before=$(git_repo rev-parse "origin/$branch")
  if git_repo push --quiet origin "$candidate:refs/heads/$branch"; then
    pushed=true
    log "Pushed $(short "$candidate") to origin/$branch"
    return 0
  fi
  if [ "$(git_repo ls-remote origin "refs/heads/$branch" | cut -f1)" != "$origin_before" ]; then
    log "ERROR origin/$branch moved during this run; the next run merges again"
    return 1
  fi
  log "Direct push to $branch was rejected; merging through a pull request"
  sync_branch=fork-sync/$merged_tag
  git_repo push --quiet --force origin "$candidate:refs/heads/$sync_branch" || return 1
  url=$(gh pr create --repo "$fork_repo" --base "$branch" --head "$sync_branch" \
    --title "Merge upstream $merged_tag into $branch" --body "Upstream release sync by fork/daily.sh.") || return 1
  log "Opened $url"
  gh pr merge "$url" --merge --delete-branch --match-head-commit "$candidate" || return 1
  git_repo fetch --quiet --no-tags origin "$branch" || return 1
  if [ "$(git_repo rev-parse "origin/$branch^{tree}")" = "$(git_repo rev-parse "$candidate^{tree}")" ]; then
    candidate=$(git_repo rev-parse "origin/$branch")
  fi
  pushed=true
  log "Merged $url; origin/$branch is $(short "$(git_repo rev-parse "origin/$branch")")"
}
