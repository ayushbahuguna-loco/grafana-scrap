# September Load-Test Machine Setup

The controller inventory names are:

| Region | Machine | Provider | Login |
|---|---|---|---|
| Vietnam | `load-test-vietnam-01` | AWS | `ec2-user`, shared Vietnam PEM |
| Vietnam | `load-test-vietnam-02` | AWS | `ec2-user`, shared Vietnam PEM |
| Turkey | `load-test-turkey-01` | LightNode | `root`, per-machine password |
| Turkey | `load-test-turkey-02` | LightNode | `root`, per-machine password |

Real passwords belong only in the ignored `.env` file. The expected variables
are documented in `.env.example`. PEM files are ignored by `*.pem` and must use
mode `0600`.

## Setup sequence

Run commands from the controller repository:

```bash
cd /Users/ayush/work/grafana-scrap
```

Prepare SSH/Git tools, print each remote GitHub public key, and install Go:

```bash
scripts/setup-new-load-test-machines.sh prepare
```

Add every printed public key to the private `getloconow/load-test` repository
under **Settings → Deploy keys**. Read-only access is sufficient for cloning,
fetching, and pulling `perf/viewer`.

After the keys are registered, clone or update the repository and build it:

```bash
scripts/setup-new-load-test-machines.sh repo
```

Verify SSH, Go, repository URL, branch, commit, and worktree state:

```bash
scripts/setup-new-load-test-machines.sh verify
```

Every action accepts a machine subset, which is useful when one node is being
repaired:

```bash
scripts/setup-new-load-test-machines.sh repo \
  load-test-vietnam-01 load-test-vietnam-02
```

The repository action is intentionally safe around an existing checkout: it
fast-forwards the selected branch and does not reset local changes. A non-Git
`~/load-test` directory is moved to a timestamped backup before cloning.

## Run-test controller

The four machines are available as the `september-new` v6 preset. Vietnam has
no assumed traffic target; set the intended regional user count (in thousands)
before running it:

```bash
VIETNAM_USERS_K=<target-in-thousands> \
  ./scripts/run-test-v6.sh --dry-run --no-k8s --no-dstat \
  --preset september-new
```

Remove `--dry-run` only after reviewing the calculated regional and per-machine
RPS. Turkey continues to use its configured 55k regional target.
