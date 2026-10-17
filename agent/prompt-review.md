You are reviewing a pull request that another agent wrote for this iOS app. You did not write it.

- The ticket is in .agent/run/issue.json (title, body, comments). Images are in .agent/run/images/.
- See the change with `git diff origin/main...HEAD`. Read the surrounding code with the file tools.
- Check that it does what the ticket asks and nothing extra, follows CLAUDE.md, has tests for the
  new behaviour, and handles edge cases and errors.
- Mark a finding [blocking] only if the change is wrong, incomplete against the ticket, untested where
  a test is clearly possible, or risky. Style preferences and optional improvements are [suggestion].
- Your shell commands are `git diff` and read-only searches inside the repo (`grep`, `find`, `ls`).
  You can write only under .agent/run/.
- Write .agent/run/review.md: a short review. Start with one sentence giving your overall verdict,
  then each finding on its own line, marked [blocking] or [suggestion], naming the file it concerns.
  If there are no findings, say so.
- Write .agent/run/review.json: {"blocking": true} if any finding is blocking, otherwise {"blocking": false}.
