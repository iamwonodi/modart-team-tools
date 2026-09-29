# aws-team-tools-b1

The team's own tools (DbGate, CloudBeaver) on core's platform. A blueprint: nothing project-specific is committed; values ship as `CHANGE_ME` and `scripts/init-tools.sh` sets them.

## Ground rules

- Everything comes from core's platform contract (`/<project>/platform/config`), never core's state.
- Everything this repository creates carries `Service=team-tools` (the provider's default tags): core's `tools-role` lets it create and change only that. The Auto Scaling group must be named `<project>-<environment>-team-tools-asg`, IAM must live under `/services/team-tools/` with the contract's `service_boundary_arn`, and the state key must stay under `team-tools/`.
- Images are pinned in `tools/images.json`, never `:latest`. The schedule is `tools/schedule.json`, read by both Terraform and `scripts/ci/start-tools.sh`.
- No password is stored anywhere: DbGate `askUser`, CloudBeaver saves none. The CloudBeaver administrator is random per start, root-only on the server.
- The start-up script must stay under EC2's 16 KB of user data (the module refuses more); large files (the RDS bundle) are downloaded and checked, never embedded.
- File layout: every top-level `locals` block in `locals.tf`, every `data` block in `data.tf`. Workflows run on `ubuntu-24.04`, never `ubuntu-latest`. `scripts/ci/check-file-layout.sh` fails CI otherwise.

## Environments

The tools run in the environments listed in `.github/environments.json` (any of development, staging, production; only ones core runs). Anything that acts on an environment asks `scripts/ci/enabled-environments.sh`; never assume all three exist.

## Checks before a commit

```bash
terraform fmt -check -recursive
(cd modules/tools-fleet && terraform init -backend=false && terraform test)
bash scripts/ci/tests/run-all.sh
bash scripts/ci/check-file-layout.sh .
shellcheck -S warning scripts/*.sh scripts/ci/*.sh
for e in development staging production; do bash scripts/ci/check-lock-files.sh infrastructure/$e; done
```

## Contracts with the other repositories

- **Core** generates this repository's role from `team_tools_repository` in each environment's tfvars (printed by `init-tools.sh`), creates the team-tools security group the databases admit, the front door (`team_front_door`) and the permissions boundary.
- **The engines repository** opens development's engine ports to the team-tools group.
- **Service repositories** declare their agents; people sign in to the databases as those agents, or as `platform.<name>`.

## To confirm on the first real start

- The image tags in `tools/images.json` exist on Docker Hub (they were taken from the projects' release tags).
- DocumentDB writes through DbGate: `retryWrites=false` rides in the port field (`modules/tools-fleet/locals.tf`).
- CloudBeaver's MySQL connection over TLS with the truststore built at start.
