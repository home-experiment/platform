# platform

Shared GCP infrastructure for the small apps in `home-experiment`: one VM, one network, one set of buckets, one GitHub deploy identity. An app adds itself with one Terraform module call in its own repository. Nothing in this repository changes when an app is added.

## What this is

Everything lives in one GCP project, `pytsekas` (region `us-central1`, zone `us-central1-a`). VM apps share one VM, `film-picker-vm`, an `e2-micro` by default. The GCP resource names still say `film-picker` because renaming them would recreate them.

Shared by all apps:

- the project, its APIs and the budget alert (whole project, alerts at 50 % and 100 %)
- the VPC, subnet and firewall (80 and 443 public, SSH only from IAP) and the static IP
- the VM, its service account and its MariaDB server
- Caddy, which terminates HTTPS for every app host name
- the releases bucket and the backups bucket (one folder per app)
- the Workload Identity Federation (WIF) pool `github` and its provider `github`
- the scripts `platform-sync`, `platform-deploy` and `platform-backup`
- the Terraform state bucket `pytsekas-film-picker-tfstate` (one prefix per root: `platform`, `film-picker`, `stash`, `pimik`)

Per app, created by `modules/vm-app` from the app's own repository:

- a deploy service account, trusted only for that repository
- a Secret Manager secret `<name>-env` that holds the app's config file
- a project metadata key `vm-app-<name>` (name, port, domains, database, health path, deploy user), which `platform-sync` turns into a Linux user, directories, a Caddy site, a deploy wrapper and a database
- DNS records for the app's host names (done by hand, pointing at the static IP)
- the app's code, its CI workflow and its own Terraform state prefix

The WIF provider trusts only pushes to `main` from repositories of `github_owner`, pinned by `github_owner_id`, so a renamed or recreated organisation cannot inherit the trust. Each deploy service account is further limited to its own repository.

## Layout

- `live/`: the shared resources, applied by hand (network, VM, buckets, WIF, budget, `startup.sh`).
- `modules/github-deployer/`: a deploy service account and its WIF binding for one repository.
- `modules/vm-app/`: one app on the shared VM; uses `github-deployer`. Inputs: `name`, `github_repo`, `port`, `domains`, `db`, `health_path`, `platform`. Outputs: `deploy_service_account`, `secret_id`.
- `scripts/`: `platform-common.sh`, `platform-sync.sh`, `platform-deploy.sh`, `platform-backup.sh` and their tests in `scripts/tests/`. `live/startup.sh` installs them on the VM.

The header comment of each script lists its knobs. Read them there; this file does not repeat them.

## Applying `live/`

Run from the repository root. The Terraform state is in `gs://pytsekas-film-picker-tfstate`, prefix `platform`.

```bash
cp live/terraform.tfvars.example live/terraform.tfvars   # then fill in
terraform -chdir=live init -backend-config=bucket=pytsekas-film-picker-tfstate
terraform -chdir=live plan -out=live.tfplan
terraform -chdir=live apply live.tfplan
```

`billing_account_id` and `alert_email` are required. The optional variables are `budget_amount` (default 10), `machine_type` (default `e2-micro`), `github_owner` (default `home-experiment`) and `github_owner_id` (default `348538226`, the numeric id of `home-experiment`).

After any change to `live/startup.sh` or `scripts/`, apply, then re-run the startup script on the VM. The apply only updates the VM's metadata; the VM picks the new scripts up when the startup script runs.

```bash
gcloud compute ssh film-picker-vm --zone us-central1-a --project pytsekas --tunnel-through-iap -- sudo google_metadata_script_runner startup
```

`terraform -chdir=live output` shows `static_ip`, `releases_bucket`, `backups_bucket`, `wif_provider_name`, `ssh_command` and `db_tunnel_command`.

## Adding a VM app

App names are 2 to 23 characters: lowercase letters, digits and dashes, starting with a letter. Database names are lowercase letters, digits and underscores, starting with a letter.

1. In the app repository add an `infra/` root. It reads the platform outputs with `terraform_remote_state` (backend `gcs`, bucket `pytsekas-film-picker-tfstate`, prefix `platform`) and calls the module:

   ```hcl
   module "vm_app" {
     source      = "git::https://github.com/home-experiment/platform.git//modules/vm-app?ref=v1.0.0"
     name        = "<name>"
     github_repo = "home-experiment/<repository>"
     port        = <port>
     domains     = ["<host name>"]
     db          = "<database>"
     platform    = data.terraform_remote_state.platform.outputs
   }
   ```

   The `ref` tag must exist in the platform repository (see Development). The app's own backend prefix is the app name.
2. Apply the app root.
3. Put the app's config file into the secret the module created:

   ```bash
   gcloud secrets versions add <name>-env --data-file=<file> --project pytsekas
   ```
4. Before the first deploy, run `sudo platform-sync` on the VM (over `ssh_command`) or re-run the startup script (command above). The first deploy fails without this: the deploy account can only run the wrapper, and `platform-sync` writes the wrapper and its sudoers rule. The sync creates the Linux user `app-<name>`, `/srv/<name>`, the database, the Caddy site and the deploy wrapper `/usr/local/bin/deploy-<name>`.
5. Create the database user once, over SSH (`terraform -chdir=live output -raw ssh_command`):

   ```bash
   sudo mariadb -e "CREATE USER '<user>'@'localhost' IDENTIFIED BY '<password>'; GRANT ALL ON <db>.* TO '<user>'@'localhost';"
   ```

   Put the same values in the config file of step 3 and add a new secret version. The values reach the app's config file on the VM only with the next deploy. Never create `/root/.my.cnf`. The platform scripts run as root and log in to MariaDB over the socket, and a login file written for one app breaks database creation and backups for the others.
6. Point DNS at the static IP: `terraform -chdir=live output -raw static_ip`. Caddy can only get a certificate once the host name resolves to it.
7. Set these GitHub repository variables on the app's repository. The repository must belong to `home-experiment`; the WIF provider rejects any other owner.

   | Variable | Value |
   |----------|-------|
   | `GCP_PROJECT` | `pytsekas` |
   | `GCP_ZONE` | `us-central1-a` |
   | `GCP_WIF_PROVIDER` | platform output `wif_provider_name` |
   | `GCP_DEPLOY_SA` | app output `deploy_service_account` |
   | `GCP_RELEASES_BUCKET` | platform output `releases_bucket` |

8. Build a release tarball that follows the release contract and add a deploy step to the workflow. Deploys run only on pushes to `main`.

   Release contract. The tarball root contains:

   - `ecosystem.config.cjs`, with every process in the namespace `<name>`, a `cwd` inside the release and a `max_memory_restart`
   - optionally `.platform/links`, one line per link: `<shared path> <release path>` (for example `app.env apps/api/.env`; shared paths are relative to `/srv/<name>/shared`)
   - optionally `.platform/pre-start`, executable, run from the release root

   Releases are stored as `gs://<releases bucket>/<name>/<release>.tar.gz`. The config secret `<name>-env` is written to `/srv/<name>/shared/app.env`.

   The deploy step uploads the tarball and activates it:

   ```bash
   gcloud storage cp release.tar.gz gs://$BUCKET/<name>/$SHA.tar.gz
   gcloud compute ssh film-picker-vm --zone "$ZONE" --tunnel-through-iap --quiet --strict-host-key-checking=no --ssh-key-expire-after=30m --command "sudo /usr/local/bin/deploy-<name> activate gs://$BUCKET/<name>/$SHA.tar.gz"
   ```

The app's deploy account can do two things only (this is about what it can do, not its role list; it also holds the grants SSH through IAP needs: `compute.viewer`, IAP tunnel access and `serviceAccountUser` on the VM's service account): upload objects under `<name>/` in the releases bucket, and run `sudo /usr/local/bin/deploy-<name>` on the VM (OS Login without admin rights plus a sudoers rule for that one wrapper).

## Operating the VM

Connect with `terraform -chdir=live output -raw ssh_command`, or use the SSH command from the startup section.

```bash
sudo platform-deploy --app <name> status      # current release and PM2 process list
sudo platform-deploy --app <name> rollback    # point current at the previous release and restart
sudo platform-sync                            # re-apply the project metadata (users, Caddy, wrappers, firewall rules)
sudo systemctl start platform-backup          # back up every app database now
journalctl -u platform-backup                 # result of the last backups
sudo -u app-<name> pm2 status                 # one app's processes
```

Backups are written to `gs://pytsekas-film-picker-backups/<name>/<name>-YYYY-MM-DD-HHMMSS.sql.gz`. A systemd timer runs `platform-backup` every night at 04:30 (Europe/Tallinn). One failing app does not stop the others; the unit then exits non-zero.

### Isolation between apps

- Each app runs as its own Linux user `app-<name>` with its own PM2 daemon, started at boot by `pm2-app-<name>.service`. `sudo -u app-<name> pm2 ...` talks to that daemon.
- `/srv/<name>` belongs to that user and is mode 750. Operators read app files with `sudo -u app-<name>`.
- App users cannot reach the GCP metadata server, which hands out the VM service account's credentials. `platform-sync` writes an nftables table to `/etc/nftables.d/platform.nft`, and `nftables.service` loads it at boot. Only DNS on that address stays open. Users of removed apps stay blocked.
- Only root calls `gcloud`. `platform-deploy` downloads the release and the app's config secret into `/run/platform/<name>` (not readable by other apps) and hands them to the app user, then removes them.
- An app that needs GCP APIs from the VM is not supported yet.

## Sizing

The default `e2-micro` has 1 GB of RAM and the startup script adds 2 GB of swap. MariaDB and every app's Node processes share that memory, so each app must set `max_memory_restart` for every process in its `ecosystem.config.cjs`. Check the load with `free -m` and `sudo -u app-<name> pm2 status`.

When swap use stays high or health checks start to fail, set `machine_type = "e2-small"` in `live/terraform.tfvars` and apply (about $12 to $13 a month). The VM restarts.

## Development

```bash
for t in scripts/tests/*.test.sh; do bash "$t"; done
shellcheck -S warning scripts/*.sh scripts/tests/*.sh live/startup.sh
terraform fmt -check -recursive
```

The tests are plain Bash files that put stubs on `PATH`. CI runs the same three commands plus `terraform validate`.

Modules are released by tagging `vX.Y.Z`. Apps pin the tag in the module `source` (`?ref=v1.0.0`; the tag must exist before an app can use it), so a change to a module reaches an app only when the app bumps its tag and applies.
