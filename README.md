# Pipeline

The AI development pipeline for the GoApps213 iOS apps. A request filed from GoBuild becomes a GitHub issue labelled `ai-request`. The self-hosted runner on the Mac then runs a coding agent on it, verifies the build and tests, opens a pull request, has a second agent session review it, and builds the merged change to TestFlight. Each ticket's state is kept in `ai:*` labels and a status comment that GoBuild reads.

This repo holds the shared parts. Each app repo calls them, and supplies what only it knows.

## What a project has

| File | What it does |
| --- | --- |
| `.github/workflows/agent.yml` | Decides which labels and comments start the agent, then calls `agent.yml` here. Its `workflow_dispatch` trigger, with the pull request's number, is how housekeeping starts a run to resolve conflicts |
| `.github/workflows/housekeeping.yml` | Calls `housekeeping.yml` here daily and when issues or pull requests close. After a merge, it checks the other open pull requests for conflicts with `main` (`scripts/conflicts.sh`): an agent pull request gets an agent run that merges `main` and resolves them; any other gets a comment. Daily, it marks released any ticket still "building" whose merge is already on TestFlight (`scripts/released.sh`) |
| `.github/workflows/release.yml` | Calls `release.yml` here on pushes to `main`, monthly and on demand. A newer push cancels a build under way; the build that replaces it covers its merges, and marks their tickets released through `scripts/released.sh` |
| `.agent/project.json` | What to build and what to protect; see below |
| `scripts/verify.sh` | Builds and runs the tests. Given test names, runs only those and refuses anything else. `templates/verify.sh` does this from `project.json`; an app that needs more, such as GoTask's Firebase emulators, writes its own |
| `CLAUDE.md` | The agent's instructions for this app, including its test targets and example test names |

The caller workflows are in `templates/workflows/`, and a `project.json` to start from is in `templates/`. The project's `.gitignore` needs `.agent/run/` and `.build-number`.

### `.agent/project.json`

| Key | Meaning |
| --- | --- |
| `xcodeproj`, `scheme` | What the release lane builds |
| `bundle_id`, `team_id` | The app's identity, and the profile match fetches from `ios-certs` |
| `unit_tests`, `ui_tests` | The test targets, for `templates/verify.sh` |
| `attachments_repo` | The repo holding ticket images, in the same organization. Optional; the default is `<repo>-attachments` |
| `protected` | Files the agent may not change, beyond the shared list (`scripts/`, `fastlane/`, `.github/`, `.claude/`, `.agent/project.json`, `CLAUDE.md`, `.mcp.json`). List the Xcode project file and anything else that runs code at build time |
| `certificates_repo` | Optional; the default is `https://github.com/GoApps213/ios-certs.git` |

### Repo settings and secrets

- **Repo variable `PIPELINE_OWNER`:** the person whose labels and comments start the agent, and who is asked to review each pull request. With it unset, nothing starts.
- **Repo secret `ATTACHMENTS_TOKEN`:** contents read and write on the attachments repos. Without it, runs work but the agent doesn't get the ticket's images.

Both are set on each repo, not on the organization: on GitHub Free, organization variables and secrets don't reach private repos' workflows, although the API lists them for those repos.
- **`release` environment, limited to `main`:** `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION`, and `TICKETKIT_GITHUB_TOKEN` for an app that files requests.
- **Labels:** the pipeline's labels (`ai-request`, `ai-approved`, `ai-skip-review`, `ai-skip-ui-tests` and the `ai:*` states).
- **Merges:** squash only, with the PR title and body as the message.

## Adding a project

```sh
scripts/onboard.sh GoApps213/<repo> ~/dev/<repo>
```

It creates the labels, sets the Actions and merge settings, the `release` environment and `PIPELINE_OWNER`, and copies the templates into the checkout for any project files missing. It then lists what's left. A person still has to:

- create the App Store Connect app record and run `fastlane match appstore --git_url https://github.com/GoApps213/ios-certs.git --app_identifier <bundle ID>`;
- set the secrets;
- add the repo to the app's GitHub token, after which GoBuild lists it as a project.

## How a run stays contained

- **Scripts come from a pinned copy.** Each workflow downloads this repo at the tag it was called with, into the runner's temp folder, outside the project's checkout. `scripts/agent-run.sh` then copies what it runs into a fresh temp folder before the agent starts. This includes the project's `scripts/verify.sh` and `.agent/project.json`, taken from `main`.
- **The agent's settings are built per run.** `agent/settings.json` gets an `Edit(...)` deny rule for each of the project's protected files.
- **Protected files fail the run.** A run fails if any protected file changed, checked after the agent and again after verification.
- **More detail:** the reasons and the probe that checks this containment are in `docs/pipeline-setup.md` in `GoApps213/gotask`, where the pipeline was built.

## On the Mac

| Command | What it does |
| --- | --- |
| `scripts/pipeline.sh` | Starts the runner, keeps the Mac awake, and watches every repo's runs. Ctrl-C stops it all |
| `scripts/watch.sh` | The watcher on its own |
| `scripts/model.sh` | Shows or chooses the agent's model; kept in `~/.config/agent-pipeline/model` |

## Versions

Projects call `@v1`, and each reusable workflow downloads the scripts at its `pipeline-ref` input, which defaults to `v1`. A fix moves the `v1` tag:

```sh
git tag -f v1 && git push -f origin v1
```

A change that needs projects to change makes `v2`. Update the `pipeline-ref` defaults and the projects' `uses:` lines together.
