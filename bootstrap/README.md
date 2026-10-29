# Demo platform bootstrap

The platform team runs this bootstrap to provision the shared infrastructure and configure the control cluster used by this demo platform. Developers request environments through Backstage and Git-reviewed manifests; they do not run this Terraform root.

## Scope and ownership

This directory manages:

- Control and workload AKS clusters.
- Shared Azure monitoring and model resources.
- Azure DNS, identities, role assignments, and Backstage Key Vault resources.
- Crossplane, cert-manager, External Secrets Operator, and the Argo CD extension.
- Generated Kubernetes manifests for configuring platform components.

The rest of the repository manages the developer-facing platform contract:

- `../api/`: Crossplane XRDs and Compositions.
- `../modules/agent-environment/`: OpenTofu code for each requested environment.
- `../argocd/`: GitOps applications for platform APIs and environment requests.
- `../requests/agent-environments/`: Approved environment requests.

Backstage application code and its Helm chart live in [pauldotyu/backstage](https://github.com/pauldotyu/backstage).

This directory supplies its infrastructure and deployment configuration.

## State and migration safety

This demo platform deployment currently has no explicit remote backend, so its bootstrap state is local by default.

The storage account created for Crossplane's OpenTofu provider serves a separate purpose. Configuring that provider's backend does not move this bootstrap's state into Azure Storage.

Do not commit:

- `.terraform/`
- State files or state backups.
- Actual `.tfvars` files.
- Saved plan files.
- Generated files under `kubernetes/`.

Commit `.terraform.lock.hcl` and the sanitized `terraform.tfvars.example`.

State, saved plans, and generated configuration can contain secrets. In particular, the current Backstage values template receives an Entra client ID and client secret. Treat generated files as sensitive even when Git ignores them.

## Prerequisites

Install:

- OpenTofu or Terraform
- Azure CLI, authenticated to the intended tenant and subscription
- kubectl and kubelogin
- Helm with OCI registry support

OpenTofu runs this bootstrap. Crossplane uses OpenTofu to provision developer environments; these are separate execution contexts.

You also need:

- Azure permissions to create the configured resources and role assignments.
- Microsoft Entra permissions for the configured applications, groups, and grants.
- Access to the parent DNS zone or registrar to configure delegation.
- A GitHub token with the permissions required by the Backstage templates.
- AKS and model capacity in the selected region.

Review `variables.tf` and `aks.tf` before deploying. The configuration includes specific Kubernetes versions, model settings, and preview AKS APIs. Confirm their availability and prerequisites in the target subscription.

## Provision shared infrastructure

For a new deployment, create your local variables file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Replace the placeholders with your DNS zone, certificate contact email, GitHub token, and Entra user object IDs. Review optional overrides in `variables.tf`.

For an existing deployment, recover the original values instead of starting from the example.

Confirm the Azure account:

```bash
az account show --output table
```

If necessary, select the intended subscription:

```bash
az account set --subscription "<subscription-id>"
```

Initialize and review a saved plan:

```bash
cd bootstrap
tofu init
tofu plan -out=bootstrap.tfplan
```

Proceed only after reviewing the proposed changes:

```bash
tofu apply bootstrap.tfplan
```

Remove the sensitive saved plan after a successful apply to avoid leaking secrets:

```bash
rm -- bootstrap.tfplan
```

The apply provisions infrastructure and writes configuration into `kubernetes/`. It does not apply every generated manifest or install the Backstage chart.

## Configure DNS and cluster access

Read the bootstrap outputs:

```bash
RG_NAME="$(tofu output -raw rg_name)"
AKS_CONTROL_NAME="$(tofu output -raw aks_control_name)"
AKS_WORKER_NAME="$(tofu output -raw aks_worker_name)"
DNS_ZONE_NAME="$(tofu output -raw dns_zone_name)"

tofu output dns_name_servers
```

Delegate the configured DNS zone to those Azure DNS name servers through its parent zone or registrar. Allow delegation to propagate before expecting certificate issuance to succeed.

Connect to the control cluster, where the platform components run:

```bash
az aks get-credentials \
  --resource-group "$RG_NAME" \
  --name "$AKS_CONTROL_NAME"

kubectl config current-context

# To connect to the workload cluster:
az aks get-credentials \
  --resource-group "$RG_NAME" \
  --name "$AKS_WORKER_NAME"

kubectl config current-context

kubectl config use-context "$AKS_CONTROL_NAME"
```

Verify the context before applying any manifests below. These commands target the control cluster, not the workload cluster. To connect to the workload cluster, use `$AKS_WORKER_NAME` instead of `$AKS_CONTROL_NAME`.

## Configure DNS automation and certificates

Apply the generated external-dns and cert-manager configuration:

```bash
kubectl --context "$AKS_CONTROL_NAME" apply -f kubernetes/control/external-dns.yaml
kubectl --context "$AKS_CONTROL_NAME" apply -f kubernetes/control/cert-manager.yaml

kubectl --context "$AKS_CONTROL_NAME" get clusterissuer
```

## Configure Crossplane

Install the providers, composition functions, runtime configuration, and shared environment settings:

```bash
kubectl --context "$AKS_CONTROL_NAME" apply -f kubernetes/control/crossplane.yaml

kubectl --context "$AKS_CONTROL_NAME" wait --for=condition=Healthy \
  provider.pkg.crossplane.io/provider-opentofu \
  provider.pkg.crossplane.io/provider-kubernetes \
  --timeout=300s

kubectl --context "$AKS_CONTROL_NAME" wait --for=condition=Healthy \
  function.pkg.crossplane.io/function-go-templating \
  function.pkg.crossplane.io/function-auto-ready \
  function.pkg.crossplane.io/function-environment-configs \
  --timeout=300s
```

Once the OpenTofu provider is healthy and its CRDs are available, configure its state backend:

```bash
kubectl --context "$AKS_CONTROL_NAME" apply -f kubernetes/control/opentofu-state.yaml

kubectl --context "$AKS_CONTROL_NAME" get clusterproviderconfigs.opentofu.m.upbound.io provider-opentofu
```

### Shared environment configuration

`crossplane.tmpl` defines the cluster-scoped `EnvironmentConfig/workload`. `crossplane.tf` supplies its values and renders it into `kubernetes/control/crossplane.yaml`.

It provides the Composition with:

- Workload cluster ID, OIDC issuer URL, and location.
- Azure Monitor and Log Analytics workspace IDs.
- Shared model resource ID and name.

Inspect the deployed object:

```bash
kubectl get environmentconfigs.apiextensions.crossplane.io workload -o yaml
```

Change the source template and Terraform inputs, regenerate the manifest through a reviewed apply, then apply the generated manifest. Do not maintain permanent changes only in generated YAML or through manual cluster edits.

The current template does not include `moduleRevision`. If module pinning is enabled in the Composition, add that field and its Terraform input wiring here before deploying a Composition that requires it.

### Workload-cluster provider configuration

The Composition creates ServiceAccounts and the `platform-context` ConfigMap in the worker cluster through `ClusterProviderConfig/workload-kubernetes`. provider-kubernetes authenticates with its own workload identity (`provider-kubernetes`), which has `Azure Kubernetes Service RBAC Writer` on the worker cluster only.

Apply the `ClusterProviderConfig` to enable Crossplane to connect to the workload cluster:

```bash
kubectl --context "$AKS_CONTROL_NAME" apply -f kubernetes/control/workload-kubernetes.yaml
```

After provider-kubernetes is healthy, create the connection Secret (server address and CA only) and apply the provider config:

```bash
az aks get-credentials -g $RG_NAME -n $AKS_WORKER_NAME --format exec --file /tmp/worker.kubeconfig
kubectl -n crossplane-system create secret generic workload-kubeconfig --from-file=kubeconfig=/tmp/worker.kubeconfig
rm /tmp/worker.kubeconfig
```

> The first environment request is the real test: `status.waitingFor` must get past `serviceaccount:` and `configmap:`. A 401 in the provider logs means the federated credential or client ID is wrong. A 403 means the role assignment is missing or still propagating.

Ensure it exists and is configured to authenticate to the workload cluster with the required permissions:

```bash
kubectl --context "$AKS_CONTROL_NAME" get clusterproviderconfigs.kubernetes.m.crossplane.io workload-kubernetes
```

## Configure the Argo CD endpoint

Apply its certificate, Gateway, and HTTPRoute:

```bash
kubectl --context "$AKS_CONTROL_NAME" apply -f kubernetes/control/argo-cd.yaml

kubectl --context "$AKS_CONTROL_NAME" get gateway -n argocd argocd-gateway
kubectl --context "$AKS_CONTROL_NAME" get certificate -n argocd argocd-tls
```

Confirm Gateway programming, DNS resolution, and certificate readiness before opening:

```text
https://argocd.<your-dns-zone-name>
```

## Enable the platform API and request syncing

Ensure the intended API and request manifests are published to the repository's `main` branch. The Argo CD applications watch GitHub, not uncommitted local files.

Install the platform API application:

```bash
kubectl --context "$AKS_CONTROL_NAME" apply -f ../argocd/platform-api.yaml
kubectl --context "$AKS_CONTROL_NAME" get application -n argocd platform-api
```

Confirm that Argo CD has synced the intended revision and that the XRD and Composition are available before enabling requests:

```bash
kubectl --context "$AKS_CONTROL_NAME" get compositeresourcedefinitions.apiextensions.crossplane.io
kubectl --context "$AKS_CONTROL_NAME" get compositions.apiextensions.crossplane.io
```

Then install the request application:

```bash
kubectl --context "$AKS_CONTROL_NAME" apply -f ../argocd/agent-environments.yaml
kubectl --context "$AKS_CONTROL_NAME" get application -n argocd agent-environments
```

This also creates the shared `agent-environments` namespace.

The API application disables automatic pruning. The request application enables pruning and allows an empty source directory. Removing a request from Git can therefore delete its environment, including when it is the last request.

Review existing request files before enabling this application. They may begin provisioning immediately.

## Deploy Backstage

Create its namespace and configure secret synchronization:

```bash
kubectl --context "$AKS_CONTROL_NAME" create namespace backstage --dry-run=client -o yaml | kubectl --context "$AKS_CONTROL_NAME" apply -f -

kubectl --context "$AKS_CONTROL_NAME" apply -f kubernetes/control/external-secrets.yaml

kubectl --context "$AKS_CONTROL_NAME" wait --for=condition=Ready \
  externalsecret.external-secrets.io/backstage-secrets \
  -n backstage \
  --timeout=300s

kubectl --context "$AKS_CONTROL_NAME" get externalsecret.external-secrets.io/backstage-secrets -n backstage
```

Check secret readiness without printing secret contents.

The existing bootstrap runbook pins the following Backstage chart version. Keep it explicit and update it deliberately when adopting a newer chart:

```bash
helm upgrade --install backstage \
  oci://ghcr.io/pauldotyu/charts/backstage \
  --version 0.1.0-sha-41f2b78 \
  --namespace backstage \
  --values kubernetes/control/backstage/values.yaml \
  --wait \
  --timeout 10m
```

Check the endpoint resources:

```bash
kubectl --context "$AKS_CONTROL_NAME" get gateway -n backstage backstage
kubectl --context "$AKS_CONTROL_NAME" get certificate -n backstage backstage-tls
```

> The chart manages the Backstage ingress resources in this flow. Do not also apply `kubernetes/control/backstage.yaml` without checking for overlapping `backstage-tls` resource ownership.

Once DNS and ingress are ready, open:

```text
https://backstage.<your-dns-zone-name>
```

If sign-in fails, inspect the Backstage logs and confirm that the Microsoft Graph catalog provider has synchronized the intended users and groups.

Demo [Backstage repo](https://github.com/pauldotyu/backstage) is configured to [automatically load](https://github.com/pauldotyu/backstage/blob/3415a275a61708992bd267ca2f2e3170403e6408/app-config.yaml#L201) the templates into the catalog.

## Configure network routing on worker

The gateway on the worker cluster needs to be configured to route traffic appropriately to applications deployed via Backstage.

```bash
kubectl --context "$AKS_WORKER_NAME" apply -f kubernetes/worker/cert-manager.yaml
kubectl --context "$AKS_WORKER_NAME" apply -f kubernetes/worker/external-dns.yaml
kubectl --context "$AKS_WORKER_NAME" apply -f kubernetes/worker/gateway.yaml
```

Verify the gateway configuration on the worker cluster:

```bash
kubectl --context "$AKS_WORKER_NAME" -n platform-gateway get certificate,gateway
```

## Verify the developer flow

Use a disposable environment for the first end-to-end check:

1. Submit an environment request through Backstage.
2. Review and merge its generated pull request.
3. Confirm that Argo CD syncs the request.
4. Confirm that Crossplane creates a Workspace and reconciles the environment.
5. Verify the resulting Azure resources, access, and workload ServiceAccount.
6. Exercise the deletion template and verify cleanup.

Inspect the requests and Workspaces:

```bash
kubectl --context "$AKS_CONTROL_NAME" get xagentenvironments -n agent-environments
kubectl --context "$AKS_CONTROL_NAME" get workspaces.opentofu.m.upbound.io -n agent-environments
```

You can also use the `crossplane` CLI to inspect the status of the composite resources and their managed resources:

```bash
crossplane --context "$AKS_CONTROL_NAME" resource trace xagentenviornment <name-of-your-environment-request> -n agent-environments
```

A completed Backstage task means the scaffolding task finished. Argo CD `Synced` means the request reached Kubernetes. Neither alone proves that Azure provisioning or workload configuration succeeded.

Check the worker cluster.

```bash
kubectl --context "$AKS_WORKER_NAME" -n <your-namespace> get sa foundry -o jsonpath='{.metadata.annotations}{"\n"}'
kubectl --context "$AKS_WORKER_NAME" -n <your-namespace> get cm platform-context -o yaml
```

## Updates

Keep the ownership boundaries explicit:

- Change shared infrastructure through this Terraform root and a reviewed plan.
- Change generated Kubernetes configuration through its source templates.
- Publish API and Composition changes through `../api/`.
- Change individual environments through their reviewed request manifests.

After a Terraform apply changes generated configuration, apply the affected manifests or upgrade the Backstage release as appropriate. Regenerating a local file does not update the cluster.

Do not rotate credentials, change provider versions, or change module revisions incidentally as part of a directory move.

## Teardown

Deleting the bootstrap removes shared infrastructure used by every environment.

Before destroying it:

1. Remove environment requests through the approved Git workflow.
2. Wait for Crossplane to delete their external resources while providers and
   state storage are still available.
3. Verify that no managed environments or Workspaces remain.
4. Uninstall Backstage and remove its ExternalSecret and SecretStore while
   External Secrets Operator is still running.
5. Preserve any state or data required for recovery or audit.

Do not delete live requests while leaving their Git manifests active; Argo CD self-heal can recreate them.

Only after those steps, and using the authoritative bootstrap state, review and confirm destruction:

```bash
tofu destroy
```

External Secrets Operator and cert-manager retain CRDs in the configured setup. Retained CRDs disappear when the cluster is deleted. No need to strip finalizers to bypass incomplete cleanup.
