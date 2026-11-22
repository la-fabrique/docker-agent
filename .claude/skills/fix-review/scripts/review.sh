#!/usr/bin/env bash
# PR review-thread helper for the fix-review skill.
#
#   review.sh pr [PR]                     PR metadata (repo, head, base, merge-base, linked issues, files)
#   review.sh threads [PR] [--all]        unresolved review threads (--all: include resolved)
#   review.sh reviews [PR]                submitted reviews that have a body
#   review.sh blame [PR] <path> <line>    was this line introduced by the PR or is it pre-existing?
#   review.sh reply <thread-id> <body|->  reply in a review thread (- reads the body from stdin)
#   review.sh resolve <thread-id>         resolve a review thread
#   review.sh comment [PR] <body|->       top-level PR comment
#   review.sh rerequest [PR] <login>      re-request a review
#
# PR defaults to the open PR whose head is the current branch, on the repo of
# remote `upstream` (falls back to `origin`). Override with REPO=owner/name.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

# drop gh's "gh event listen" hint block from stderr
gh() { command gh "$@" 2> >(grep -vE '^(hint:|    gh event listen|  - )' >&2); }

base_remote() { git remote get-url upstream >/dev/null 2>&1 && echo upstream || echo origin; }

repo_slug() {
  local url
  url=$(git remote get-url "$(base_remote)")
  url=${url%.git}
  echo "${url#*github.com[:/]}"
}

REPO=${REPO:-$(repo_slug)}
OWNER=${REPO%/*}
NAME=${REPO#*/}

is_pr() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

current_pr() {
  local branch n
  branch=$(git branch --show-current)
  n=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq '.[0].number // empty')
  [[ -n $n ]] || die "no open PR on $REPO for branch '$branch'; pass the PR number"
  echo "$n"
}

body_arg() { if [[ $1 == - ]]; then cat; else printf '%s' "$1"; fi; }

merge_base() {
  local base remote
  base=$(gh pr view "$1" --repo "$REPO" --json baseRefName --jq .baseRefName)
  remote=$(base_remote)
  git fetch -q "$remote" "$base"
  git merge-base "$remote/$base" HEAD
}

cmd=${1:-}; shift || true
case $cmd in
  pr)
    if is_pr "${1:-}"; then PR=$1; else PR=$(current_pr); fi
    mb=$(merge_base "$PR")
    gh pr view "$PR" --repo "$REPO" \
      --json number,title,body,author,headRefName,headRefOid,headRepositoryOwner,baseRefName,url,closingIssuesReferences,files |
      jq --arg mb "$mb" --arg repo "$REPO" '{repo:$repo, number, url, title, author:.author.login,
          head:(.headRepositoryOwner.login + ":" + .headRefName), headSha:.headRefOid, base:.baseRefName,
          mergeBase:$mb, closes:[.closingIssuesReferences[]?.number], body,
          files:[.files[] | "\(.path) +\(.additions) -\(.deletions)"]}'
    ;;

  threads)
    if is_pr "${1:-}"; then PR=$1; shift; else PR=$(current_pr); fi
    filter='select(.isResolved | not)'
    [[ ${1:-} == --all ]] && filter='.'
    gh api graphql --paginate -F owner="$OWNER" -F name="$NAME" -F pr="$PR" -f query='
      query($owner:String!, $name:String!, $pr:Int!, $endCursor:String) {
        repository(owner:$owner, name:$name) { pullRequest(number:$pr) {
          reviewThreads(first:100, after:$endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes { id isResolved isOutdated path line originalLine
              comments(first:50) { nodes { databaseId author { login } createdAt body diffHunk
                pullRequestReview { databaseId } } } } } } } }' \
      --jq ".data.repository.pullRequest.reviewThreads.nodes[] | $filter |
        {threadId:.id, resolved:.isResolved, outdated:.isOutdated, path, line:(.line // .originalLine),
         reviewId:.comments.nodes[0].pullRequestReview.databaseId,
         diffHunk:(.comments.nodes[0].diffHunk | split(\"\n\") | .[-8:] | join(\"\n\")),
         comments:[.comments.nodes[] | {id:.databaseId, author:.author.login, at:.createdAt, body}]}"
    ;;

  reviews)
    if is_pr "${1:-}"; then PR=$1; else PR=$(current_pr); fi
    gh api --paginate "repos/$REPO/pulls/$PR/reviews" \
      --jq '.[] | select(.body != "") | {id, author:.user.login, state, at:.submitted_at, commit:.commit_id[:12], body}'
    ;;

  blame)
    if is_pr "${1:-}"; then PR=$1; shift; else PR=$(current_pr); fi
    path=${1:?path}; line=${2:?line}
    mb=$(merge_base "$PR")
    [[ -f $path ]] || { echo "$path: not in working tree (deleted or renamed by the PR?)"; exit 0; }
    sha=$(git blame -L "$line,$line" --porcelain HEAD -- "$path" | head -1 | cut -d' ' -f1)
    if git merge-base --is-ancestor "$sha" "$mb"; then
      echo "$path:$line PRE-EXISTING (last changed in ${sha:0:9}: $(git log -1 --format='%s, %as' "$sha"))"
    else
      echo "$path:$line INTRODUCED BY PR (${sha:0:9}: $(git log -1 --format=%s "$sha"))"
    fi
    ;;

  reply)
    tid=${1:?thread-id}; body=$(body_arg "${2:?body}")
    gh api graphql -F tid="$tid" -f body="$body" -f query='
      mutation($tid:ID!, $body:String!) {
        addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$tid, body:$body}) { comment { url } } }' \
      --jq .data.addPullRequestReviewThreadReply.comment.url
    ;;

  resolve)
    tid=${1:?thread-id}
    gh api graphql -F tid="$tid" -f query='
      mutation($tid:ID!) { resolveReviewThread(input:{threadId:$tid}) { thread { id isResolved } } }' \
      --jq '.data.resolveReviewThread.thread | "\(.id) resolved=\(.isResolved)"'
    ;;

  comment)
    if is_pr "${1:-}"; then PR=$1; shift; else PR=$(current_pr); fi
    body_arg "${1:?body}" | gh pr comment "$PR" --repo "$REPO" --body-file -
    ;;

  rerequest)
    if is_pr "${1:-}"; then PR=$1; shift; else PR=$(current_pr); fi
    gh api -X POST "repos/$REPO/pulls/$PR/requested_reviewers" -f "reviewers[]=${1:?login}" \
      --jq '"review re-requested from: " + ([.requested_reviewers[].login] | join(", "))'
    ;;

  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
