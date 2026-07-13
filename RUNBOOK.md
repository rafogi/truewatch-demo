# Runbook

End-to-end steps to stand this demo up from scratch. Follow in order —
later steps assume earlier ones are done.

## 0. Prerequisites (done already, verify if resuming)

```
az version
terraform -version
kubectl version --client
az account show   # confirm you're on the right subscription
```

## 1. Bootstrap the Terraform state backend (one-time, manual)

Terraform's own state is stored in an Azure Storage blob container, but
Terraform can't create that container itself (nothing to store state in
yet). Run this once, by hand:

```bash
bash scripts/bootstrap-state-backend.sh
```

This creates a resource group, storage account, and blob container. Their
names must match `terraform/providers.tf`'s `backend "azurerm"` block — the
script and the file already agree by default; only change both together if
you need different names (e.g. the storage account name collides globally).

## 2. Configure Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars if you want a different region/VM size
```

## 3. Init, plan, review

```bash
terraform init
terraform plan
```

Read the plan output carefully — it should show ~4 resources to create
(resource group, ACR, AKS cluster, role assignment). Nothing should show
`destroy` on a first run.

## 4. Apply (creates real Azure resources — costs money while running)

```bash
terraform apply
```

Type `yes` when prompted. This takes several minutes (AKS cluster
provisioning is the slow part). When done, note the outputs:

```bash
terraform output
```

You'll need `acr_login_server` and `aks_cluster_name` for later steps.

## 5. Get cluster credentials locally

```bash
az aks get-credentials --resource-group rg-todo-demo --name aks-todo-demo
kubectl get nodes   # sanity check
```

## 6. Set up GitHub Actions OIDC (no stored client secret)

Create an App Registration and a federated credential trusting GitHub
Actions for this specific repo + branch:

```bash
# Create the app registration
az ad app create --display-name "todo-demo-github-actions"
APP_ID=$(az ad app list --display-name "todo-demo-github-actions" --query "[0].appId" -o tsv)

# Create a service principal for it
az ad sp create --id "$APP_ID"

# Grant it Contributor on the subscription (scope tighter to the resource
# group if you prefer least-privilege)
az role assignment create \
  --assignee "$APP_ID" \
  --role Contributor \
  --scope /subscriptions/<YOUR_SUBSCRIPTION_ID>

# Federated credential: trusts tokens GitHub issues for THIS repo's main
# branch only — no long-lived secret is ever stored.
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "github-main-branch",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<YOUR_GITHUB_ORG>/<YOUR_REPO>:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# Also add one for pull_request events if you want PR-triggered plans:
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "github-pull-request",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<YOUR_GITHUB_ORG>/<YOUR_REPO>:pull_request",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

Grant this identity `AcrPush` on the registry so `deploy.yml` can push
images:

```bash
az role assignment create \
  --assignee "$APP_ID" \
  --role AcrPush \
  --scope $(terraform -chdir=terraform output -raw acr_login_server | xargs -I{} az acr show --name {} --query id -o tsv)
```

## 7. Add GitHub repo secrets and variables

**Secrets** (Settings → Secrets and variables → Actions → Secrets):
- `AZURE_CLIENT_ID` — the `$APP_ID` from step 6
- `AZURE_TENANT_ID` — `az account show --query tenantId -o tsv`
- `AZURE_SUBSCRIPTION_ID` — `az account show --query id -o tsv`

**Variables** (same page, Variables tab):
- `ACR_LOGIN_SERVER` — `terraform output -raw acr_login_server`
- `AKS_RESOURCE_GROUP` — `rg-todo-demo`
- `AKS_CLUSTER_NAME` — `terraform output -raw aks_cluster_name`

## 8. Create the TrueWatch credentials Secret in-cluster (manual, not via CI)

Get your Dataway URL + token from the TrueWatch console (Integrations →
DataKit install), then:

```bash
kubectl create namespace todo-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic truewatch-credentials \
  --namespace todo-demo \
  --from-literal=dataway-url='<YOUR_DATAWAY_URL>' \
  --from-literal=token='<YOUR_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/datakit-daemonset.yaml
```

Deliberately manual and separate from CI so the real token is never
written into a workflow run or a committed file.

## 9. Push to trigger CI/CD

```bash
git push origin main
```

This triggers `deploy.yml`, which builds the image, pushes to ACR, and
rolls out the Deployment.

## 10. Verify

```bash
kubectl get pods -n todo-demo
kubectl get svc todo-app -n todo-demo   # note EXTERNAL-IP once assigned
curl http://<EXTERNAL-IP>/healthz
curl http://<EXTERNAL-IP>/api/todos
```

Then check the TrueWatch console — you should see host metrics from the
node and traces from `todo-app` within a minute or two.

## Teardown

```bash
cd terraform
terraform destroy
# then manually remove the state backend if you're fully done:
az group delete --name rg-tfstate-todo-demo
```
