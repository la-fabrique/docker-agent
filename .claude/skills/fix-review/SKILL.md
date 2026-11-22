---
name: fix-review
description: Address the review comments on a GitHub PR - triage each unresolved thread against the PR's goal, reply briefly on comments about pre-existing code, fix the in-scope ones (signed commit, push, reply, resolve), then leave a summary message for the reviewer and re-request review. Use when asked to fix, address or handle PR review comments/feedback (e.g. "/fix-review 4965").
argument-hint: "[PR number] (default: the open PR of the current branch)"
---

# Fix PR review comments

Target PR: `$ARGUMENTS` if given, otherwise the open PR whose head is the current branch.
Helper: `.claude/skills/fix-review/scripts/review.sh` (`$R` below). It targets the
repo of remote `upstream` (falls back to `origin`); run it without arguments for usage.

Invoking this skill authorizes: signed commits on the PR branch, pushes to it
(never `--force` unless the branch was rebased, then `--force-with-lease`),
thread replies, resolving threads, one summary comment and a review re-request.
Stop and ask the user at any step marked **STOP**.

Write everything posted on GitHub in English, terse, factual, no filler.

## 1. Preflight

```bash
R=.claude/skills/fix-review/scripts/review.sh
git status --porcelain --untracked-files=no
$R pr [PR]
```

- Uncommitted tracked changes, or a rebase/merge in progress: **STOP**.
- Check out the PR's head branch (`head` field, `owner:branch`) and make sure it
  is up to date with its remote (`git pull --ff-only`). The head often lives on a
  fork remote (e.g. `origin`), not `upstream`: push there.
- Commits must be signed: run `git config --get user.signingkey` and
  `git config --get gpg.format`; if no signing key is configured: **STOP**.

## 2. Understand the PR's goal

From `$R pr`: title, body, linked issues (`closes`, read them with
`gh issue view <n> --repo <repo>`) and changed files. Then read
`git diff <mergeBase>...HEAD`. Write down, for yourself, the PR's focus in one
or two sentences: this is the yardstick for triage.

## 3. Collect the feedback

```bash
$R threads [PR]          # unresolved inline threads (threadId, path, line, comments)
$R reviews [PR]          # review bodies: summary points not attached to a line
$R threads [PR] --all    # resolved ones too, when a new comment refers to an earlier one
```

- Only work on the latest round: unresolved threads, plus actionable points in
  the most recent review body.
- Reviewers often reference earlier threads by comment id (`#4653284740`): look
  them up in `--all` to get the full context and what was already claimed fixed.
- A thread whose last comment is already ours with no reviewer follow-up is
  waiting on the reviewer: skip it.

## 4. Triage each item

Classify every thread / review point as one of:

| Class | Meaning | Action |
|-------|---------|--------|
| **in-scope** | Caused by, or directly part of, what the PR changes or promises (incl. tests and docs for the new feature) | fix it (step 5) |
| **pre-existing** | About code or behavior that predates the PR and that the PR neither introduces nor makes worse | short reply, no fix (step 6) |
| **disagree / unclear** | In scope, but the suggestion looks wrong, or needs a product/design decision | **STOP**, show the user your analysis, act on their answer |

Evidence for the pre-existing class:

```bash
$R blame [PR] <path> <line>     # PRE-EXISTING vs INTRODUCED BY PR, using the merge base
git log --oneline <mergeBase>..HEAD -- <path>
```

`blame` is a hint, not the verdict: an issue on an old line can still be
in-scope when the PR's new code is what makes it reachable or worse, and a
comment on a new line can be about a pattern copied from existing code. Judge by
the PR's focus. When in doubt, treat it as in-scope.

Show the user the triage table (thread, file:line, one-line summary, class,
reason) before changing any code. Continue without waiting unless an item is
**disagree / unclear**.

## 5. Fix in-scope items

One item at a time (group items only when they touch the same code and can't
be fixed separately; mention all of them in the commit message):

1. Read the code around the comment and every place the reviewer mentions.
   Fix the root cause the reviewer describes, not just the commented line; if
   they ask for a regression test, add one that fails without the fix.
2. Validate, per AGENTS.md: `task build`, the relevant `go test ./pkg/...`
   (with `-race` for concurrency), and `task lint`. Run the full `task test`
   before the last push. A failure you can't fix: **STOP**.
3. Commit. **Every commit must be signed and signed off** (`-S -s`, required by
   the repo: GPG/SSH signature + DCO `Signed-off-by`). Never commit without
   `-S`, never use `--no-verify`, and stop if signing fails:

   ```bash
   git add <files>
   git commit -S -s -m "fix(<area>): <what>" -m "Addresses review comment <comment url or id>."
   git log -1 --show-signature --format='%H %G?'   # must be G (good signature)
   ```

   Use Conventional Commits; follow the subject style of the PR's commits.
4. Push: `git push <head remote> HEAD:<head branch>`.
5. Reply in the thread, then resolve it:

   ```bash
   $R reply <threadId> "Fixed in <short sha>: <what changed, one or two sentences>. <test that covers it>."
   $R resolve <threadId>
   ```

   For a point that was only in a review body (no thread), there is nothing to
   resolve: cover it in the summary message (step 7).

Reply style (from earlier rounds on this repo):

> Fixed in 0dfd00cb8: DB plus WAL/SHM sidecars are forced to 0600. Test asserts owner-only mode.

> Fixed in 0dfd00cb8: the new async sender disables environment proxies while the SSRF guard is on, so the dial-time check validates the webhook host instead of the proxy.

If a fix only partly addresses the comment, say exactly what is left and
don't resolve the thread.

## 6. Reply on pre-existing items

One or two sentences, no fix, and **don't resolve** the thread (the reviewer
decides). State that the code predates the PR, with evidence, and offer a
follow-up:

```bash
$R reply <threadId> "This predates the PR: <path>:<line> is unchanged since <sha> (<subject>), and this change doesn't touch that path. Out of scope here; happy to address it in a follow-up PR."
```

For a pre-existing point raised only in a review body, mention it in the
summary message instead.

## 7. Summary message for the reviewer

Once every in-scope thread is fixed, replied to and resolved:

```bash
$R threads [PR]    # what's left must be only pre-existing / partial / disagree items
$R comment [PR] - <<'EOF'
Thanks for the review @<reviewer> 🙏 <N> points addressed in <sha range or list>:
<comma-separated short list of what was fixed>. See the per-thread replies for details.
<If any: "<M> comments are about pre-existing code and left open for you to decide (replied inline).">
Re-requesting review.
EOF
$R rerequest [PR] <reviewer login>
```

One message per reviewer whose comments were handled. Keep it to a few lines.

## 8. Report to the user

Triage table with the final outcome per item (fixed + sha / pre-existing /
left open and why), commits pushed, validation run, and the summary comment
URL.
