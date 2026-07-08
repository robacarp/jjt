# jjt

`jjt` is a pool manager for reusable [jj](https://github.com/jj-vcs/jj)
workspaces — the same idea as [treehouse](https://github.com/kunchenguid/treehouse),
which does this for git worktrees, but built on `jj workspace` instead.

Rather than creating and tearing down a workspace for every task, `jjt`
maintains a small pool of them, handing out an idle one (or creating a new
one, up to a configurable limit) and returning it to the pool when you're
done — resetting it to the latest trunk along the way.

## Status

`get`, `status`, `return`, `init`, and `version` work. `prune`, `destroy`,
and `update` are still stubbed out. Pool state lives in a single global
file (`~/.local/state/jjt/state.json`, or under `$XDG_STATE_HOME` if set),
not per-repo — see `.claude/todo.md` for why.

## Installation

```
./install-locally
```

This builds the gem, installs it, and symlinks the `jjt` executable into
`~/.local/bin`. Make sure that directory is on your `PATH`.

To run it from source without installing, use `bundle exec bin/jjt` instead.

## Usage

```
jjt get       # find or create an idle workspace, drop into a subshell
jjt status    # show pool state
jjt return    # return the current workspace to the idle pool
jjt prune     # remove idle, clean, merged workspaces
jjt destroy   # remove a specific workspace
jjt init      # write a default jjt.toml
```

## Development

```
bundle install
bundle exec rspec
```

## License

MIT
