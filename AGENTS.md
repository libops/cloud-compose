# cloud-compose repository instructions

This file is the concise entry point for agents and contributors. Start at
[docs/index.md](docs/index.md) for architecture, then
[docs/runtime-contracts.md](docs/runtime-contracts.md) for the trust boundary
this module enforces.

## Required contract

```bash
make lint-check
```

This runs `terraform fmt -check`, `actionlint`, the shell contract suite, and
`terraform-validate` (init + validate + test) across every directory in the
repo that contains `.tf` files.

## Local `.terraform.lock.hcl` drift on a machine that hasn't touched a
## directory's providers yet

`terraform-validate` will fail with `missing or corrupted provider plugins:
... does not match any of the checksums recorded in the dependency lock
file` the first time you run it from a machine/architecture whose provider
fetch path hasn't previously contributed a hash to that directory's lock
file. This is not corruption and not a network problem: HashiCorp's registry
can legitimately serve a byte-different (but equally valid, signed) archive
for the same provider version depending on which CDN edge answers the
request, and Terraform's `h1:` package hash is computed from that archive's
contents. `.terraform.lock.hcl` supports recording multiple valid `h1:`
hashes per version specifically for this; a plain `terraform init` refuses to
silently trust an unrecorded hash (that refusal is the actual integrity
protection working as intended), while `-upgrade` recomputes and appends the
new legitimate one.

The repo has more than one directory with its own `.tf` files and its own
`.terraform.lock.hcl` (root, `providers/*`, `modules/*`, `examples/*`,
`tests/smoke/*`). A lock file only picks up a new machine's hash for the
providers *that specific directory* declares, so hitting this in one
directory does not fix it anywhere else. If you hit this failure — most
likely the first time you run `terraform-validate` locally on a machine that
hasn't run it before (a new contributor, a new laptop, or after switching
architectures) — update every directory's lock file in one pass rather than
chasing failures one at a time:

```bash
for dir in $(find . -path "*/.terraform" -prune -o -path "./docs/site" -prune -o -name "*.tf" -exec dirname {} \; | sort -u); do
  echo "=== $dir ==="
  (cd "$dir" && terraform init -backend=false -upgrade -input=false >/dev/null && echo ok)
done
git status --short
```

Commit the resulting `.terraform.lock.hcl` changes alongside your actual
change — recording the additional legitimate hash for cross-platform (Mac +
Linux CI) contributors is expected, not scope creep. Then rerun
`bash ci/terraform-validate.sh` to confirm every directory is clean before
declaring the change complete.

## macOS-specific local caveats

- `ci/application-env-contract.sh` deliberately runs part of its check under
  `env -i PATH=/usr/bin:/bin bash --noprofile --norc -c '...'` to exercise
  the application-env trust boundary under a minimal, untrusted-style
  environment. On macOS, `/bin/bash` (and `/usr/bin/bash`) is always the
  frozen GPLv2 bash 3.2.57 system shell, regardless of what modern bash you
  have installed via Homebrew or earlier in your `PATH` — that hardcoded
  `PATH` inside the check ignores your shell entirely. This is expected and
  cannot be fixed by installing a newer bash; run this specific check inside
  a Linux container if you need to reproduce it locally, or trust CI for it.
