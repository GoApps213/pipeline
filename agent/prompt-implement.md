You are implementing a feature request for this iOS app. Follow CLAUDE.md.

- The ticket is in .agent/run/issue.json (title, body, comments). Images are in .agent/run/images/.
- If .agent/run/feedback.log exists, it holds build errors or review findings from the last round.
  Fix those first.
- If you asked questions earlier, the answers are the newest comments in issue.json. Carry on from them;
  ask again only if an answer leaves a choice that still matters.
- If .agent/run/pr-feedback.json exists, the owner commented on your pull request. Address the comments
  and reviews in it, newest first; the most recent comment mentioning @agent is the request.
- If .agent/run/merge.md exists, `main` was merged into your branch before this run. Read the files you
  work on again. If it lists files with conflict markers, resolve those first by editing them: keep
  what both sides meant, remove every marker, and do not change other code to avoid the conflict. You
  cannot run `git merge` or `git add`, and need not; the pipeline commits the merge. Say in the
  summary how you resolved each one.
- Before writing code, decide whether the ticket is clear enough. Only if a choice matters and
  can't be inferred from the ticket or the code, write numbered questions to
  .agent/run/questions.md and stop without changing any code.
- Otherwise implement the ticket and add or update tests. CLAUDE.md, and any testing guide it
  points to, says which kind of test a change needs.
- If the labels in issue.json include `ai-skip-ui-tests`, add and change no UI tests, even where
  CLAUDE.md asks for them, and don't run any; unit tests are still needed. The pipeline verifies the
  change with the unit tests only. Say in the summary that UI tests were skipped.
- Run only the tests your change touches, from the repo root, by naming them:
  `scripts/verify.sh <test target>/<suite or class>`. CLAUDE.md lists this app's test targets and
  gives examples. Several names can be given at once.
- Finish when those pass. Do not run `scripts/verify.sh` with no names: the pipeline runs everything
  once you finish, and sends any failure back to you in .agent/run/feedback.log. This replaces
  any instruction in CLAUDE.md to run the full script before finishing.
- Run `scripts/verify.sh` with nothing around it. With a pipe or a redirect it runs inside the
  sandbox, where the build fails; with a variable in front it is refused.
- Your shell commands are `scripts/verify.sh`, `git diff`, `git status`, and read-only searches inside
  the repo (`grep`, `find`, `ls`). Use the file tools for everything else. Nothing outside the repo
  can be read or written.
- Do not commit, push, or edit anything in fastlane/, scripts/, .github/, .claude/ or .agent/
  (except files under .agent/run/). CLAUDE.md and the files listed under "protected" in
  .agent/project.json, such as the Xcode project file, are also off limits; if the ticket can't be
  done without changing one of them, say so in .agent/run/questions.md and stop.
- Finish by writing .agent/run/summary.md: what changed, how to try it, and every assumption you made.
