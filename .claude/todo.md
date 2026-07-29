# jjt — TODO

jjt is a pool manager for reusable **jj workspaces** — same idea as
[treehouse](https://github.com/kunchenguid/treehouse), which does this for
git worktrees, but built on `jj workspace` instead. Written in Ruby
(pinned via `.tool-versions`, currently `ruby 4`).

## Repo scaffolding (done 2026-07-07)

- [x] `jj git init --colocate` in this directory
- [x] Decide: create the GitHub remote (`robacarp/jjt`) now or later — deferred, local only for now
- [x] Decide: install the jj-workspace Claude Code hooks (`WorktreeCreate`/
      `WorktreeRemove`) — deferred, skipped for now (sample still lives in
      `~/.claude/AGENTS.md` under "jj workspace hooks" if revisited)
- [x] `Gemfile` + `jjt.gemspec` (deps: `thor ~> 1.5`, `tomlib ~> 0.7` for TOML
      config; dev dep `rspec ~> 3.13`) — both gem names verified on rubygems.org
- [x] `lib/jjt/version.rb`, `lib/jjt.rb`
- [x] `bin/jjt` executable + Thor-based CLI skeleton in `lib/jjt/cli.rb` with
      stub subcommands (`get`, `status`, `return`, `prune`, `destroy`, `init`,
      `update`, `version`) raising `NotImplementedError` for now
- [x] `README.md`
- [x] `.gitignore` (`/.bundle/`, `/pkg/`, `*.gem`, `.claude/worktrees`,
      `.claude/settings.local.json`, etc.)
- [x] `LICENSE` — confirmed MIT with user, added

All committed as a single working-copy commit: "Add initial gem scaffolding".
`bundle install` and `bundle exec bin/jjt help` both verified working.

## Feature backlog, ported from treehouse

Source: https://github.com/kunchenguid/treehouse (Go, git-worktree pool
manager, researched 2026-07-07). Map each git-worktree concept to its jj
equivalent.

### Pool / state management

- [x] Config loader: repo-level `jjt.toml` (`max_trees`, default 16; optional
      `root` dir for workspace storage) + user-level `~/.config/jjt/config.toml`
      (global defaults + hooks) — `Jjt::Config.load`, repo root found by
      walking up for `.jj`/`.git`, repo config wins over user config
      (hooks deep-merged), full rspec coverage
- [x] Pool state file (JSON), file-locked, atomic writes (tmp file + rename)
      — `Jjt::Store`: generic path, `flock`-guarded read/transaction, writes
      go to a `.tmp` sibling then `rename`d into place; concurrency proven
      with a two-thread lock-serialization spec. Default state file
      location/schema deferred to the command work that consumes it.
- [ ] State recovery: if the state file is corrupt/missing, rebuild entries
      from `jj workspace list` and mark them leased until verified — deferred,
      not needed until the state file schema/location has more real usage
- [ ] In-use detection: process scanning (which PIDs have cwd inside a
      workspace path) + short-lived owner reservation, so two agents never
      grab the same workspace — no daemon required — deferred, single-writer
      `jjt get` is safe enough via the store's flock for now
- [ ] Dirty detection via `jj status` / `jj diff --stat` — not yet consulted
      by `acquire`/`release`; an idle-but-dirty workspace just gets silently
      reset to `trunk()` on reuse right now
- [x] "Merged" check for prune safety: `Jjt::Pool#unlanded_work?` runs
      `jj log -r "(::@ ~ ::trunk()) ~ empty()"` — non-empty output means real
      commits exist that aren't an ancestor of `trunk()` yet. Since `::@`
      includes `@` itself, this also covers "clean" (an in-progress edit is
      just a non-empty leaf commit) — one check does both, see
      `spec/jjt/pool_integration_spec.rb`.

### Commands

State: single **global** store at `~/.local/state/jjt/state.json` (or
`$XDG_STATE_HOME/jjt/state.json`), keyed by workspace path with a
`repo_root` field per entry — not per-repo. This was necessary because a
pool workspace (`jj workspace add`) has its own `.jj` and is not a
filesystem descendant of the original repo root, so walking up from inside
one can't rediscover a repo-relative state file. `jjt get` exports
`JJT_REPO_ROOT` into the spawned subshell so `jjt status` run from inside
it still scopes correctly to the right repo. `resolve_repo_root` also falls
back to `Pool.repo_root_for(Dir.pwd)` (a store lookup by cwd) before it
falls back further to walking up for `.jj`/`.git` — otherwise a second
shell that only inherited the workspace's cwd (a new terminal tab, say),
without `JJT_REPO_ROOT` in its env, would resolve its own repo_root to the
workspace's own `.jj` instead of the real originating repo. `jjt
return`/`find_by_path` don't need any of this since they look up by path
across all repos regardless.
Default workspace storage root (when `jjt.toml`'s `root` isn't set):
`~/.local/state/jjt/workspaces/<sha256(repo_root)[0,8]>/`.

- [x] `jjt` / `jjt get [NAME]` — find an idle workspace of this repo, or
      create one with `jj workspace add -r trunk()` if under `max_trees`;
      spawns a subshell inside it (`Jjt::Pool#acquire`, `lib/jjt/cli.rb`).
      Reusing an idle workspace resets it via `jj new trunk()`. Note: since
      `trunk()` only resolves *remote* bookmarks (`main@origin` etc.), a
      repo with no remote/tracked bookmark yet — like this one — resets to
      the empty root commit. Real `jj` command syntax verified against a
      scratch repo (see `spec/jjt/pool_integration_spec.rb`). If cwd (or a
      subdirectory of it) is already a known workspace and no `NAME` was
      given, `get` skips acquisition entirely and just spawns a subshell in
      place — otherwise a second terminal tab that only inherited the
      working directory (not the leasing shell's state) would get handed a
      *different* idle workspace of the same repo instead of the one it was
      already sitting in. That fast path also skips auto-release on exit,
      since this invocation never leased the workspace itself and another
      shell may still be using it. `Pool#find_by_path`/`Pool.repo_root_for`
      match ancestor directories, not just the exact workspace root.
- [x] `jjt get --lease [--lease-holder LABEL]` — same acquisition, no
      subshell: reserve it in state and print the path only
- [x] `jjt status` — lists this repo's pool state (idle/in-use/leased per
      workspace) + the current workspace if cwd is inside one
- [x] `jjt return [PATH]` — release a workspace back to the idle pool
      (defaults to cwd). Does NOT yet stop processes running in it — that's
      tied to the deferred in-use-detection item above.
- [x] `jjt get` also auto-releases on subshell exit now (not just `jjt
      return`): spawns the shell as a real subprocess instead of `exec`,
      ignores SIGINT while it runs so Ctrl-C reaches the subshell instead of
      killing `jjt`, then releases in an `ensure` block keyed off exit.
- [x] `jjt prune` — dry-run by default, `--yes` to actually remove. Safety
      checks: idle, no unlanded work (see `unlanded_work?` above). Flags:
      `--all` (shorthand for all four include/orphan flags below), `--global`
      (scope to every repo in the store, not just this one), `--verbose`,
      `--include-unlanded`, `--include-in-use`, `--include-leased`,
      `--prune-orphans` (state rows whose workspace directory is gone).
      `Jjt::Pool#prune_candidates` does the selection, `#remove` does the
      actual forget+delete+drop-from-store.
- [x] `jjt destroy <path>` — targeted removal via `Pool#remove`, same safety
      checks as `prune` by default (idle + no unlanded work + directory still
      exists), `--force` to skip all of them.
- [x] `jjt init` — writes a default `jjt.toml` (`max_trees = 16`) at the
      repo root; errors if one already exists
- [ ] `jjt update` — self-update
- [x] `jjt version` — prints `Jjt::VERSION`

### No-branch-conflict story

- [ ] Work out the jj equivalent of treehouse's "detached HEAD, reset to
      whichever branch is further ahead" trick. jj workspaces normally sit on
      an anonymous commit on top of a revset (e.g. `trunk()`) with no bookmark
      needed at all — this may be *simpler* than treehouse's version rather
      than something to port 1:1. Confirm and document the behavior.

### Hooks

- [x] `post_create` — runs after `jj workspace add` or after resetting a
      reused workspace (e.g. install deps)
- [x] `pre_destroy` — runs before `jj workspace forget`/directory delete (e.g.
      cleanup). For a `--global` prune, this correctly loads the *owning*
      repo's `jjt.toml`/hooks, not the caller's — see `Pool#remove`.

### Distribution

- [ ] Package as a Ruby gem (`gem build` / `gem push`); decide gem-only vs.
      also shipping a standalone install script (curl | sh) like treehouse's
      `install.sh` / `install.ps1`

### Open questions

- [ ] Does jjt need to support plain-git-only repos, or is jj a hard
      requirement? (Colocated jj/git support is the likely minimum bar.)
- [ ] Multi-repo/global pool semantics: how `--global` discovers "every repo"
      without a daemon, matching treehouse's approach of deriving ownership
      from repo metadata using only user-level config
