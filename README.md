# jjt

`jjt` is a pool manager for reusable [jj](https://github.com/jj-vcs/jj)
workspaces — the same idea as [treehouse](https://github.com/kunchenguid/treehouse),
which does this for git worktrees, but built on `jj workspace` instead.

Rather than creating and tearing down a workspace for every task, `jjt`
maintains a small pool of them, handing out an idle one (or creating a new
one, up to a configurable limit) and returning it to the pool when you're
done — resetting it to the latest trunk along the way.

## Status

Early scaffolding. The CLI commands are stubbed out and not yet implemented.

## Installation

```
bundle install
bundle exec bin/jjt help
```

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
