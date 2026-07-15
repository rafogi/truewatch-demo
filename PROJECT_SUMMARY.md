# Project Summary

A narrative record of what this project is, what was built, and every real
issue hit and fixed along the way. For step-by-step operational commands see
`RUNBOOK.md`; for a line-by-line explanation of the Terraform config see
`TERRAFORM_GUIDE.md`. This file is the "how did we get here" story.

## What this is

A demo built for a job interview: a containerized Flask to-do app deployed
to Azure Kubernetes Service (AKS) via GitHub Actions, instrumented with
OpenTelemetry, monitored by TrueWatch (DataKit agent + APM + RUM), with all
Azure infrastructure provisioned via Terraform. The goal was for it to be
genuinely runnable end-to-end, not just illustrative.

**Repo:** https://github.com/rafogi/truewatch-demo (branch `main`)

## Architecture

```
GitHub Actions (OIDC, no stored secrets)
  ├─ terraform.yml  -> plan on PR, apply on push to main
  └─ deploy.yml     -> build image, push to ACR, roll out to AKS

Azure
  ├─ Resource Group: rg-todo-demo
  ├─ AKS cluster: aks-todo-demo (1 node, Standard_D2s_v7)
  ├─ ACR: acrtododemo637586.azurecr.io
  └─ Role assignment: AKS kubelet identity -> AcrPull on ACR

AKS cluster (namespace: todo-demo)
  ├─ todo-app Deployment + Service (LoadBalancer, public IP)
  └─ datakit DaemonSet (1 per node) -> collects host metrics,
     receives OTLP traces from todo-app, ships to TrueWatch

TrueWatch (SaaS)
  ├─ APM: traces from todo-app
  ├─ RUM: browser sessions from the to-do UI
  ├─ Infrastructure: host metrics from the AKS node
  └─ Dashboard (Terraform-managed): SRE Golden Signals view
```

## Tooling installation (local machine)

Starting state: `kubectl` was already installed; `az` and `terraform` were
not.

1. **Chocolatey** had a broken partial install (folder existed, no
   `choco.exe` on PATH). Fixed by deleting `C:\ProgramData\chocolatey` and
   reinstalling via the official `install.ps1` script in an elevated
   PowerShell window.
2. **Azure CLI + Terraform**: `choco install azure-cli terraform -y` in an
   elevated window.
3. PATH changes from a Chocolatey install don't propagate to an
   already-open terminal session or even a "new" PowerShell window spawned
   from the same process (it inherits the stale environment block) — a full
   terminal *application* restart was needed before `az`/`terraform`
   resolved.
4. Verified: `az version`, `terraform -version`, `kubectl version --client`.
5. `az login` (browser sign-in) and confirmed the correct subscription
   (`Azure subscription 1`).

## Terraform infrastructure

Files: `terraform/providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`.

- Remote state backend: an Azure Storage blob container, bootstrapped
  **once** via a plain `az` CLI script (`scripts/bootstrap-state-backend.sh`)
  rather than Terraform-managed, since Terraform can't create the very
  backend it depends on.
- Resources: resource group, AKS cluster, ACR, and an `AcrPull` role
  assignment from the AKS kubelet identity to the ACR.

### Issues hit and fixed during `terraform apply`

1. **`Microsoft.Storage` resource provider not registered** on the
   subscription (`SubscriptionNotFound` error from the bootstrap script).
   Fixed by `az provider register --namespace Microsoft.Storage` (and
   `Microsoft.ContainerService`, `Microsoft.ContainerRegistry`,
   `Microsoft.Authorization`, `Microsoft.Compute`, `Microsoft.Network`,
   `Microsoft.ManagedIdentity`), which is async and needs polling until
   `registrationState == Registered`.
2. **`azurerm` provider tries to auto-register every resource provider it
   supports** (dozens of `Microsoft.*` namespaces) on every plan/apply, and
   this failed outright when some of those (e.g. `Microsoft.Maps`) were
   unreachable/slow in this environment. Fixed with
   `skip_provider_registration = true` in the `azurerm` provider block,
   since we'd already registered exactly what we needed manually.
3. **`Standard_B2s` VM size not allowed** on this subscription's quota (only
   specific D/E/F/M/N-series families are permitted, no burstable B-series
   at all). Switched to `Standard_D2s_v7`, the smallest permitted
   general-purpose size.
4. **A long-running `terraform apply` hit a transient DNS resolution
   failure** mid-run (`dial tcp: lookup ... no such host`) while the AKS
   cluster was still being created server-side. Terraform lost track of
   state and left a stale blob lease + an `errored.tfstate` file. Recovered
   by: `terraform force-unlock` on the stale lock, then
   `terraform import azurerm_kubernetes_cluster.main <resource-id>` to bring
   the already-created (and healthy) cluster back into Terraform's state
   without recreating it.
5. **Azure defaults some AKS fields** (`oidc_issuer_enabled = true`,
   node-pool `upgrade_settings`) that Terraform then tried to "correct" back
   to unset on every subsequent plan, and Azure rejected disabling
   `oidc_issuer_enabled` once set. Fixed by declaring both explicitly in
   `main.tf` to match what Azure actually enforces, so plans stop showing a
   phantom diff.

## GitHub Actions CI/CD

Files: `.github/workflows/terraform.yml`, `.github/workflows/deploy.yml`.

- **Auth**: OIDC federated credentials (no stored client secret). An Azure
  AD app registration (`todo-demo-github-actions`) trusts GitHub-issued
  tokens scoped to this exact repo's `main` branch and pull requests.
- **Permissions**: `Contributor` scoped to just `rg-todo-demo` (not
  subscription-wide) for Terraform; `AcrPush` scoped to just the one
  registry for image pushes — both deliberately least-privilege.
- **Secrets/variables**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_SUBSCRIPTION_ID` (secrets); `ACR_LOGIN_SERVER`,
  `AKS_RESOURCE_GROUP`, `AKS_CLUSTER_NAME` (variables).

### Issues hit and fixed

1. **`environment: production` set on a workflow *step*** instead of a
   *job* in `terraform.yml` — this is only valid at job level, and the
   malformed workflow file failed to parse at all (zero jobs ran, no useful
   error in the Actions UI). Fixed by splitting into separate `plan` and
   `apply` jobs, with `environment: production` on the `apply` job.
2. **`deploy.yml` applied `k8s/deployment.yaml`'s placeholder image**
   (`todoapp.azurecr.io/todo-app:latest`) before running
   `kubectl set image` with the real just-built tag — briefly scheduling a
   pod that could never pull the placeholder image (`ImagePullBackOff`).
   Fixed by substituting the real image tag into the manifest via `sed`
   before applying, so the placeholder is never actually scheduled.
3. Neither workflow had `workflow_dispatch`, so they could only be
   triggered by a matching push — added it to both for manual reruns from
   the Actions tab.

## The Flask app

Files: `app/app.py`, `app/requirements.txt`, `app/Dockerfile`,
`app/templates/index.html`.

- In-memory to-do list (no database) — the point of the demo is the
  surrounding infra/observability, not data durability.
- Routes: `/`, `/healthz`, `/api/todos` (GET/POST), `/api/todos/<id>`
  (PUT/DELETE).
- Instrumented with `opentelemetry-instrumentation-flask` (auto traces) and
  a hand-configured OTLP HTTP exporter.
- `templates/index.html`: a small vanilla JS/HTML to-do UI (add / check off
  / delete), replacing an earlier API-only JSON response at `/`. Also
  carries the TrueWatch RUM browser SDK snippet.

### Issues hit and fixed

1. **`ModuleNotFoundError: No module named 'pkg_resources'`** crash-looped
   the app on startup. `opentelemetry-instrumentation-flask` needs
   `pkg_resources`, which `python:3.12-slim` no longer bundles by default.
   Fixed by adding `setuptools` to `requirements.txt`.

## Kubernetes manifests

Files: `k8s/namespace.yaml`, `deployment.yaml`, `service.yaml`,
`datakit-daemonset.yaml`.

- `todo-app` Deployment: small resource requests/limits sized for a 1-node
  cluster, readiness/liveness probes on `/healthz`.
- `todo-app` Service: `type: LoadBalancer` for a public IP (simplest
  exposure for a demo, no ingress controller).
- `datakit` DaemonSet: `hostNetwork: true` so app pods can reach it via the
  node's IP (`HOST_IP`, injected via the Kubernetes downward API).

### Issues hit and fixed (DataKit / observability pipeline)

This was the largest source of real bugs in the whole project — getting
traces to actually show up in TrueWatch took several rounds of diagnosis:

1. **DataKit's `Secret` was defined inside `datakit-daemonset.yaml` itself**
   with placeholder values, so every `kubectl apply -f` on the DaemonSet
   silently overwrote the real credentials with the placeholder again.
   Fixed by removing the `Secret` from that file entirely — it's created
   once, directly, via `kubectl create secret` (see `RUNBOOK.md` step 8),
   and the DaemonSet only references it by name.
2. **Wrong env var shape for the Dataway URL.** The scaffold originally
   split it into `ENV_DATAWAY` + `ENV_TOKEN`; DataKit actually expects a
   single `ENV_DATAWAY` value with the token embedded as a query param
   (`https://us1-openway.truewatch.com?token=<token>`).
3. **The `opentelemetry` input isn't a simple env-toggle input.** Inputs
   like `cpu`/`mem`/`disk` turn on purely via `ENV_DEFAULT_ENABLED_INPUTS`,
   but OpenTelemetry needs an actual `.conf` file present under
   `conf.d/opentelemetry/`. Fixed by mounting one via a `ConfigMap`.
4. **Wrong OTLP path.** DataKit's OpenTelemetry input listens on
   `/otel/v1/trace`, not the OTel-standard `/v1/traces` the Python exporter
   defaults to appending. Fixed by pointing the exporter at the
   DataKit-specific path explicitly.
5. **DataKit's HTTP API defaults to `localhost:9529`**, which only accepts
   connections from processes sharing its exact network namespace — app
   pods reaching it via the node's real IP got `Connection refused`. Fixed
   with `ENV_HTTP_LISTEN=0.0.0.0:9529`.
6. **DataKit 1.32.0 had a nil-pointer panic in its OTLP HTTP trace
   handler.** Every real trace POST triggered
   `runtime error: invalid memory address or nil pointer dereference` in a
   `GuanceCloud/timeout` middleware wrapper. Gin's recovery middleware
   caught the panic and still returned `200 OK` to the client, so the
   Python exporter never saw an error — traces were silently dropped with
   no visible symptom on either side. Diagnosed only by turning on DataKit's
   debug logs and generating live traffic while tailing them. Fixed by
   upgrading the image to `1.35.0`.

Each of these individually looked like "it's probably fine" (no client-side
errors) until confirmed by directly querying DataKit's local
`/v1/query/raw` endpoint and seeing real trace counts.

## TrueWatch dashboard (Infrastructure-as-Code)

Directory: `terraform/dashboard/` (separate Terraform working directory
from the Azure infra, since it uses a different provider entirely).

- Provider: `TrueWatchTech/truewatch` (a community Terraform provider,
  forked from `GuanceCloud/terraform-provider-guance`).
- Resource: `truewatch_dashboard`, with the dashboard layout defined as a
  JSON file (`dashboard.json`) passed via `template_info = file(...)`.
- Auth: `TRUEWATCH_ACCESS_TOKEN` read from a gitignored `terraform.tfvars`
  — never committed, never inlined into a shell command.

### Issues hit and fixed

1. **The provider's exact API paths/schema aren't documented on the
   JS-rendered docs site** (`docs.truewatch.com`) in a way that's fetchable
   by a simple HTTP GET. Resolved by reading the actual Go source of the
   `terraform-provider-truewatch` GitHub repo directly (`internal/api/*.go`)
   for ground-truth endpoint paths, and its `examples/dashboard/` folder for
   a working `dashboard.json` structure to build from.
2. **Dashboard created via the API key's identity was invisible to the
   logged-in console user** ("no permission to view the page, only visible
   to creator"). Fixed by setting `is_public = 1` and
   `read_permission_set = ["*"]` on the resource.
3. **DQL query syntax guesses were initially wrong** (e.g.
   `T::todo-app:(...)` instead of the correct
   `T::re(`.*`):(...) {`service`='todo-app'}` wildcard-plus-filter
   pattern). Diagnosed by testing DQL queries directly against DataKit's
   local `/v1/query/raw` endpoint before trusting them in the dashboard
   JSON, which also surfaced real field/tag names (`status`, `duration`,
   `docker_containers` measurement with `container_name`/`cpu_usage`/
   `mem_usage` fields) instead of guessing.
4. **A percentage computed via two filtered `count()` aggregates in one DQL
   expression didn't parse** (`dql.parseError`). Simplified to a plain
   error *count* panel instead of an error *rate* percentage.

Current dashboard layout (identifier `todo-app-demo`), organized around SRE
Golden Signals:

- **Golden Signals**: Request Rate (Traffic), Latency P50/P95/P99, Error
  Count
- **Saturation**: todo-app pod CPU/memory usage, DataKit agent's own
  CPU usage (cost of observability itself)
- **Infrastructure**: host CPU / memory / network-in for the AKS node

## RUM (frontend monitoring)

`app/templates/index.html` embeds the TrueWatch RUM browser SDK, created
via RUM → Applications → Create Application (Web type) in the console.
Configured with `traceType: 'w3c_traceparent'` to match the vanilla
OpenTelemetry SDK used server-side (as opposed to `ddtrace`-style headers),
so RUM sessions correlate with backend APM traces.

## Known gaps / explicitly deferred

- **Cloud Billing (cost monitoring)**: TrueWatch's Cloud Billing feature
  requires DataFlux Func, and the cloud-hosted ("Automata") version of Func
  isn't available on this workspace's plan — only self-hosted Func is
  offered, which needs its own server to deploy and maintain. An Azure AD
  app registration + `Monitoring Reader` role was created for this, then
  deleted again once we decided not to pursue it, to avoid leaving an
  unused credential with broad read access sitting in the subscription.
- **SLI/SLO + error budgets**: TrueWatch has a native `truewatch_slo`
  Terraform resource, but its own example README states it "is not
  registered by the provider in the current release branch" — it exists in
  the provider's source but can't actually be applied yet. SLO/SLI setup
  would need to be done manually in the console (not yet done).
- **Pod restart count / Kubernetes object health** (crash-loop detection,
  pod readiness): DataKit's `docker_containers` metric measurement doesn't
  carry a `restarts` field; that data lives in Kubernetes object metadata,
  which needs enabling DataKit's separate `kubernetes` input plus a
  ServiceAccount + RBAC grant for API server read access. Scoped as a
  distinct follow-up requiring an explicit permission decision, not yet
  done.

## Installation steps (reproducing from scratch)

See `RUNBOOK.md` for the full, current, ordered command list. Short version:

1. Install `az`, `terraform`, `kubectl`; `az login`.
2. `bash scripts/bootstrap-state-backend.sh` (one-time state backend).
3. `cd terraform && terraform init && terraform plan && terraform apply`.
4. `az aks get-credentials --resource-group rg-todo-demo --name aks-todo-demo`.
5. Set up GitHub Actions OIDC (app registration + federated credentials +
   role assignments) — see `RUNBOOK.md` step 6.
6. Add GitHub repo secrets/variables — step 7.
7. Get a TrueWatch Dataway URL (with token embedded) from the TrueWatch
   console, create the in-cluster Secret, apply
   `k8s/datakit-daemonset.yaml` — step 8.
8. `git push origin main` — triggers CI/CD to build, push, and deploy.
9. Verify: `kubectl get pods -n todo-demo`, hit the LoadBalancer's external
   IP, check TrueWatch's APM/Infrastructure views for data.
10. (Optional) `cd terraform/dashboard && terraform init && terraform apply`
    with a `terraform.tfvars` containing `truewatch_access_token` to
    recreate the Golden Signals dashboard.
