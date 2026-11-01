# Claude Code DevTeam

A drop-in template that turns **Claude Code** into a disciplined software team for any repository: a planner, a test designer, implementers, reviewers, a security prober and a deterministic referee. It runs on **Claude's own models** (Opus, Sonnet and Haiku), each on the role where it pays off.

You describe the work as a spec and a set of small tasks. Then you say **"run phase 01"**:
- tests are written first, then frozen;
- code is written in isolated git worktrees;
- independent reviewers check it;
- each task is merged only when every gate is green;
- main is reverted automatically if it ever goes red.

```
 You ──▶ LEAD (your Claude Code session; thin, reads only short JSON results)
           │ launches
           ▼
       build-phase WORKFLOW (.claude/workflows/build-phase.js: deterministic control flow)
           │ spawns role agents                 │ every state change goes through
           ▼                                    ▼
       ROLE AGENTS (12)                    REFEREE (harness/referee.py: plain Python, no LLM)
       write tests, code and verdicts      owns git, worktrees, frozen tests, gates, merge + revert, ledger
       to files, never to chat             prints one short JSON line per step
           ▲
       GUARD (harness/guard.py): a hook before every tool call; each role may write only its own paths
```

## Why it is built this way

Models propose; deterministic code decides. Every rule below exists because something failed or cost too much in an earlier build.

| What went wrong before | What this template does |
|---|---|
| The lead's context was 41–97% of total spend (about 500K tokens re-read every turn) | The lead reads only small JSON results and the ledger. Exploring is delegated to a Haiku `explorer`. `make tokens` flags drift |
| Every role ran on Opus | Opus judges, Sonnet executes, Haiku relays. Only the last attempt escalates to Opus |
| A relay model retyped 24 KB payloads and corrupted them | **Pass by reference.** Every referee command prints one line of 900 bytes or less, and agents write their verdicts to `.loop/runs/<id>/` themselves |
| Implementers "fixed" the tests instead of the code | Tests are frozen with checksums. `check` restores any edited frozen test and reports it, and the guard blocks the write in the first place |
| Prompt-only rules failed (an agent dropped 3 databases) | `guard.py` checks each role's tool calls in code: writes outside its paths, git writes, referee commands and destructive commands are denied. It is a guardrail, not a sandbox (see Known limits) |
| A passing check could stand in for a review | `integrate` refuses unless the latest verdict of every required reviewer names the exact commit being merged and has no blocking finding |
| A gate hung for 10 hours | Every command has a timeout, and its process group is killed on expiry |
| About a third of blocks were environmental (dependencies, ports, the sandbox) | `doctor` checks the environment before any agent runs. Triage routes environment and flaky failures to a re-check that spends no attempt |
| Security problems were first found at the end of a milestone | Risk-lane tasks (auth, SQL, money, deletion) get a `security-prober` before merge |
| A merge could turn main red | Integration merges in a scratch tree, re-runs every gate, fast-forwards main, smoke-tests it, and auto-reverts if it is red |
| Harnesses were rebuilt for every project | One versioned kit: a project edits only `harness/project.toml` and `CLAUDE.md` |
| Scratch files, stale branches and orphan worktrees piled up | `reap` cleans up at every phase close |

---

## Step-by-step setup

### Step 0: Prerequisites

| Need | Check | Notes |
|---|---|---|
| Claude Code | `claude --version` | <https://code.claude.com> |
| Claude access | `claude` then `/status` | A Claude subscription (Pro, Max, Team or Enterprise) or an Anthropic API key with access to Opus, Sonnet and Haiku |
| Python 3.11+ | `python3 --version` | The referee and guard use only the standard library |
| git, make | `git --version && make --version` | Your project must be a git repository |
| Node.js (optional) | `node --version` | Only for the workflow-simulation tests in `make harness-test` |

### Step 1: Get the template and check it

```bash
git clone https://github.com/sfc-gh-tjia/Claude-code-devteam.git ~/devteam
cd ~/devteam
python3 -m pip install pytest     # if you don't have it
make harness-test                 # 22 tests: referee lifecycle, guard decisions, a no-LLM simulation of the workflow
```

### Step 2: Install it into your project

```bash
cd ~/devteam
./install.sh /path/to/your-project          # dry run: lists what would be copied; overwrites nothing
./install.sh /path/to/your-project --apply
cd /path/to/your-project
```

The installer copies the harness, agents, workflow, skill and plan templates. It adds `.loop/` and `.worktrees/` to `.gitignore`, and **never overwrites an existing file**. If your project already has a `CLAUDE.md` or `.claude/settings.json`, it skips them and says so: merge them by hand (Step 4).

### Step 3: Tell the harness how your project builds and tests

Edit **`harness/project.toml`**. It is the only harness file you change per project:

```toml
[project]
name = "my-app"
main_branch = "main"
test_cmd = "python3 -m pytest -q {tests}"     # runs ONE task's acceptance tests; {tests} = its test files
red_exit_codes = [1, 2]                        # exit codes that mean "tests fail" (needed to freeze them RED)

[[setup]]                                       # runs in every new task worktree
cmd = "uv sync --frozen"
timeout = 600

[[doctor]]                                      # fast environment checks, run before any agent is spent
name = "python"
cmd = "python3 --version"
timeout = 30

[[gates]]                                       # cheapest first; each has a timeout
id = "lint"
cmd = "uv run ruff check ."
timeout = 120
lanes = ["*"]

[[gates]]
id = "unit"
cmd = "uv run pytest -q"
timeout = 900
lanes = ["*"]
smoke = true                                    # also run on main right after each merge (red -> auto-revert)

[lanes]                                         # how much process a task gets, by the files it touches
risk = ["src/**/auth/**", "**/*.sql"]           # + security-prober
ui = ["web/**", "frontend/**"]                  # + ui-reviewer (screenshots against the spec)
light = ["docs/**", "*.md", "**/*.css"]         # skips QA design and QA functional
```

Starting points for other stacks. `{tests}` expands to the task's test file paths. Runners that can't take file paths can run the whole suite instead: that works, it's just slower.

| Stack | `test_cmd` | `red_exit_codes` | `[[setup]]` | gates |
|---|---|---|---|---|
| Python (pytest) | `python3 -m pytest -q {tests}` | `[1, 2]` | `uv sync --frozen` or `pip install -e .` | `ruff check .`, `pytest -q` |
| Node (Vitest / Jest) | `npx vitest run {tests}` / `npx jest {tests}` | `[1]` | `npm ci --prefer-offline` | `npm run lint`, `npm test` |
| Go | `go test ./...` | `[1, 2]` | `go mod download` | `go vet ./...`, `go test ./...` |
| Rust | `cargo test` | `[101]` | `cargo fetch` | `cargo clippy -- -D warnings`, `cargo test` |
| Java (Gradle) | `./gradlew test` | `[1]` | `./gradlew dependencies` | `./gradlew check` |

Check your values once:
1. Write a test that fails.
2. Run your `test_cmd` on it.
3. Confirm the exit code is in `red_exit_codes`.

Anything `[[setup]]` creates (virtualenvs, `node_modules`, build output) must be gitignored, or the scope check will flag it.

### Step 4: Write the project's rules for the agents

Fill in the placeholders in **`CLAUDE.md`**: one paragraph about the product and stack, where code and tests live, and any project rules. Keep it under about 60 lines, because every agent reads it on every run. The lead's playbook lives separately in `.claude/skills/devteam-lead/SKILL.md`.

If the installer skipped an existing `CLAUDE.md` or `.claude/settings.json`:
- **`CLAUDE.md`:** append the template's sections ("Commands", "How work flows", "Rules for every agent") to yours.
- **`.claude/settings.json`:** merge in the template's `permissions` and the `hooks.PreToolUse` guard entry. The guard hook is what enforces the lead's permissions.

### Step 5: Check the environment

```bash
make doctor        # runs your [[doctor]] checks plus git-state checks; fix anything red before going on
```

### Step 6: Plan the work

You can write the plan by hand, or open Claude Code and ask: *"use spec-author to plan ‹your idea›"*.

**1. `work/spec.md`:** the problem, the users, and numbered requirements with testable acceptance criteria:

```markdown
- **R-1** Users can upload a CSV of transactions. *Acceptance:* a valid 3-row file yields 3 typed rows.
- **R-2** Oversized uploads are rejected early. *Acceptance:* a 6 MB file fails with TOO_LARGE without reading it all.
```

**2. `work/phases/01.md`:** what the phase delivers, its tasks and exit criteria. Copy `work/phases/TEMPLATE.md`.

**3. `work/tasks/0001-short-slug.md`:** one per task, from `work/tasks/TEMPLATE.md`. The front matter is what the referee enforces:

```toml
+++
id = "0001"
phase = "01"
title = "Parse CSV upload into rows"
depends_on = []                                    # only real prerequisites
files = ["src/app/upload.py"]                      # the ONLY paths the implementer may edit
tests = ["tests/acceptance/test_0001_upload.py"]   # where QA writes the frozen acceptance tests
# lane = "risk"                                    # optional override
+++
```

The body has these sections:
- **Goal:** what the task achieves.
- **Interface:** the exact signatures and error cases the tests will pin.
- **Done When:** checkable items, each one testable.
- **Non-Goals.**
- **Notes:** how to run it, for the functional QA and UI reviewer.

Good tasks are small (one or two hours of work), touch a few files, and have Done When items a test can check. If something is uncertain, plan a spike task first.

### Step 7: Run a phase

```bash
claude                          # in your project; /model sonnet is the cheap way to drive
```

Then type:

```
run phase 01
```

The lead launches the `build-phase` workflow. Relaunching is safe: merged and frozen work is kept. Each phase runs these stages:

```
Preflight   referee recover → doctor → plan            (no expensive agent runs if the environment is broken)
Plan check  tech-lead (Opus), cached by main SHA + task-file hash
Build       up to max_parallel tasks at once:
              prepare (worktree + setup) → qa-designer (Opus) → freeze (must be RED, checksums)
              → implementer (Sonnet; last attempt Opus) → check (frozen intact, scope, tests, gates)
                  red → triage (Haiku): env/transient → re-check, no attempt spent · test_design → block · impl → retry
Review      reviewer (Opus) ‖ qa-functional (Sonnet) ‖ security-prober (Opus, risk lane) ‖ ui-reviewer (Sonnet, ui lane)
              → blocking findings → fix (≤ 2 rounds) → check
Integrate   lock → evidence commit → scratch merge → all gates → fast-forward main → smoke → revert if red
Close       phase gate → phase-reviewer (Opus: follow-ups, learnings) → ledger → reap → short result to the lead
```

### Step 8: Read the result and unblock

The lead reports what merged, what blocked (with a code), and follow-ups. Details are in **`work/ledger.md`**, plus `make status` for task states.

| Block code | Meaning | What to do |
|---|---|---|
| `DOCTOR_FAILED` | The environment is broken (no agents were spent) | Fix it, relaunch |
| `PRECHECK_BLOCKING` | Task files can't be built as written | Amend them per `.loop/precheck/NN.json`, relaunch |
| `TESTS_NOT_RED` / `TESTS_BROKEN` | QA couldn't write a valid failing test | Sharpen Done When, `python3 harness/referee.py reset ID`, relaunch |
| `TESTS_WRONG` | Triage blamed a frozen test | Fix the test in the worktree, `referee.py refreeze ID`, relaunch |
| `ENV` | The environment failed mid-task | Fix it, `referee.py unblock ID`, relaunch |
| `ATTEMPTS_EXHAUSTED` | Still red after 3 attempts | Split the task or clarify the spec, `reset ID` |
| `REVIEW_ROUNDS` | Blocking findings survived the fix rounds | It's a design problem: write `work/adr/ADR-NNN.md`, amend the tasks, `reset ID` |
| `MERGE_CONFLICT` | Two tasks touched the same code | `reset ID` and relaunch (it rebuilds on the new main) |
| `MAIN_RED_AFTER_MERGE` | Smoke failed on main; the merge was auto-reverted | Investigate the smoke gate, then `unblock ID` |
| `REVIEW_MISSING` / `REVIEW_STALE` / `REVIEW_BLOCKING` | `integrate` found no verdict from a required reviewer, a verdict for another commit, or a blocking finding | A reviewer failed to write its verdict file: relaunch. Repeated: read `.loop/runs/ID/` via `explorer` |
| `RUNNER_REFUSED` | The relay agent read chat text as a competing request | Relaunch right after a plain one-line request |
| `TOKEN_CAP` | The run hit `budgets.run_output_tokens` | Raise the cap or split the phase |

Three failed rounds on the same problem means design work: write an ADR rather than a fourth patch.

### Step 9: Measure

```bash
make tokens
```

It shows estimated cost, turns, lead context per turn, cost per role and model, cache hit rates and flags. Targets:
- lead context under 150K tokens per turn;
- the lead under 20% of spend;
- output/input above 1%;
- few environmental blocks.

**Start a fresh Claude Code session per phase.** Resume from `work/ledger.md` and `make status`, not from chat history.

---

## The team

| Role | Model | When it runs | May write |
|---|---|---|---|
| lead (your session) | Sonnet to drive, Opus to plan | always | anything; asks first for `.claude/` and `harness/` |
| spec-author | Opus | planning | `work/` |
| tech-lead | Opus | once per phase (cached if nothing changed) | `.loop/precheck/` |
| qa-designer | Opus | per task, except the light lane | the task's test paths, before freeze |
| implementer | Sonnet (last attempt Opus) | per task, up to 3 attempts | the task's `files`, in its worktree |
| triage | Haiku | on a red check | `.loop/runs/` |
| reviewer | Opus | per task and review round | `.loop/runs/` |
| qa-functional | Sonnet | per task, except the light lane | `.loop/runs/`, `/tmp` |
| security-prober | Opus | risk lane | `.loop/runs/`, `/tmp` |
| ui-reviewer | Sonnet | ui lane | `.loop/runs/`, `/tmp` |
| phase-reviewer | Opus | once per phase | `.loop/runs/` |
| runner | Haiku | every referee step | nothing (one `referee.py` command) |
| explorer | Haiku | ad hoc, for the lead | nothing |

**How much process to use:**
- **A small change** (under about two hours, a few files): do it directly in Claude Code (plan, test, code, `make verify`, commit). No workflow.
- **A feature** (3–10 tasks): one phase.
- **A product:** a spec, several phases, and spike tasks for the unknowns.

## Customize

| To change… | Edit |
|---|---|
| Which model a role uses | `model:` in `.claude/agents/<role>.md`, and/or the aliases in `.claude/settings.json` `env` |
| A role's instructions, tools or turn limit | `.claude/agents/<role>.md` |
| Gates, setup, lanes, parallelism, attempts, review rounds, token cap | `harness/project.toml` |
| What each role may write | `WRITES` / `READ_ONLY` in `harness/guard.py` (and `[protected]` in `project.toml`) |
| Paths agents may never touch | `[protected].paths` in `harness/project.toml` |
| The lead's playbook (process tiers, block codes) | `.claude/skills/devteam-lead/SKILL.md` |
| Cost estimates | `PRICE` in `harness/tokens.py` |

**Through an LLM gateway** (Amazon Bedrock, Google Cloud, Microsoft Foundry, or a corporate proxy): set `ANTHROPIC_BASE_URL` and that provider's credentials as usual. If the gateway uses different model ids, change the full ids in the agent files (for example `model: claude-opus-5-5`) or the `ANTHROPIC_DEFAULT_*_MODEL` aliases in `.claude/settings.json`.

## Commands

| Command | What it does |
|---|---|
| `make doctor` | Preflight: your `[[doctor]]` checks plus git state |
| `make verify` | Every gate on the current tree. "Done" means this is green |
| `make status` | Task states as small JSON |
| `make ledger` | Regenerate `work/ledger.md` |
| `make reap` | Remove merged worktrees, branches and logs |
| `make tokens` | Token and cost telemetry from Claude Code's transcripts |
| `make harness-test` | The harness's own tests |
| `python3 harness/referee.py reset\|unblock\|refreeze ID` | Act on a blocked task (see Step 8) |

## Layout

```
CLAUDE.md                        rules every agent reads (keep it short)
Makefile                         doctor · verify · status · ledger · reap · tokens · harness-test
install.sh                       copy into a repo without overwriting anything (dry run by default)
harness/
  project.toml                   THE per-project file: test command, setup, doctor, gates, lanes, budgets
  referee.py                     the deterministic referee (stdlib only)
  guard.py                       PreToolUse hook, one policy per role
  tokens.py                      token and cost telemetry
  tests/                         referee, guard, and a no-LLM workflow simulation
.claude/
  settings.json                  model aliases, allow/ask/deny rules, the lead's guard hook
  agents/*.md                    12 roles: model, effort, tools, maxTurns, guard hook
  workflows/build-phase.js       the phase pipeline
  skills/devteam-lead/SKILL.md   the lead's playbook
work/
  spec.md · phases/ · tasks/ · adr/        your plan (templates included)
  ledger.md · evidence/                    written by the referee
```

Runtime state is gitignored: `.worktrees/task-NNNN/` (one per task) and `.loop/` (state, runs, jobs, logs).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `install.sh`: "not a git repository root" | Run `git init`, or point it at the repo root |
| A freeze fails with `TESTS_NOT_RED` on every task | `red_exit_codes` doesn't match your test runner; check it with Step 3's test |
| The scope check flags generated files | Gitignore what `[[setup]]` creates, or add it to `scope_ignore` |
| A gate times out | Raise its `timeout`, or split it. Long gates run as detached jobs, polled by the workflow |
| Browser e2e tests can't start | Browsers often can't start inside the macOS sandbox. Run a browser daemon outside it and point the gate at it |
| The lead's context keeps growing | Start a fresh session per phase; never paste logs into it; use `explorer` for big reads |
| The guard blocks something legitimate | Read its reason in `.loop/hook.log` (one JSON line per decision), then adjust `WRITES` in `harness/guard.py` if the role really needs it |

## Known limits

- **The guard is a guardrail, not a sandbox.** It checks each tool call, but a general-purpose interpreter it allows (`python3 -c`, `node -e`) can still write files outside a role's paths. The backstops are the referee's checks: frozen tests are restored, out-of-scope diffs are refused, `integrate` requires current review verdicts and a clean main checkout, and a red main is reverted. For unattended runs, add OS-level isolation (a sandbox, container or separate user).

- **What's tested:** the referee and guard have real tests, and the workflow's control flow is checked by a simulation with stubbed agents. How well the prompts and models behave on your codebase is something a pilot phase shows.
- **Detached jobs** assume the Bash sandbox lets a child process outlive its command. If not, raise `budgets.bash_wait_s` toward 590, or keep gates under about 9 minutes.
- **Mutation testing** is language-specific and not built in; add it as a gate where it pays off.

## Related

**[Claude-code-devteam-custom-model](https://github.com/sfc-gh-tjia/Claude-code-devteam-custom-model)** is the same harness with a model gateway. It runs on DeepSeek, free NVIDIA-hosted models or any OpenAI-compatible endpoint, and adds a standalone `claude-custom` mode for everyday use without an Anthropic account.
