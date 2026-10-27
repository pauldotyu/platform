# Platform Engineering Demo with Crossplane + OpenTofu on Azure

Provision Azure environments through a Backstage request, Git approval, Argo CD,
Crossplane, and the OpenTofu provider.

## Intended flow

1. Backstage opens a PR containing an `XAgentEnvironment` request.
2. Review and merge approve provisioning.
3. A shared Argo CD Application syncs `requests/` into Kubernetes.
4. Crossplane creates an OpenTofu Workspace for each request.
5. The provider creates the resource group and requester role assignment.

The first milestone provisions a resource group and access, not a running agent.
AKS workload namespaces, model access, and application-delivery wiring are outside
this milestone.

The configuration below describes the shared-request design. Confirm that the
corresponding manifests have been added and published before bootstrapping it.
The original API used a single `name` parameter; the expanded contract uses
`team`, `project`, `environment`, `location`, `requesterObjectId`, and `costCenter`.
The XRD, Composition, module, and Backstage template must agree on that contract.

## Ownership and layout

The platform team owns the shared `agent-environments` namespace, provider
credentials, API definitions, and GitOps configuration. Each request is a
namespaced XR whose composed Workspace lives in the same namespace.

Requesting developers use Backstage and GitHub; this design does not grant them
read access to the shared Kubernetes namespace. Provisioning status should be
made available without exposing other teams' Workspaces, credentials, or state.
The Azure resource group is the developer's environment boundary.

```text
api/agent-environment/     XRD and Composition
argocd/                   Platform-owned GitOps bootstrap manifests
modules/resource-group/   OpenTofu implementation
requests/<team>/<project>/<environment>/environment.yaml
```

One request watcher handles every environment. A new request does not require a
new namespace, AppProject, or Application. A free-text team name is metadata,
not proof of membership; PR review is the initial authorization gate.

## Prerequisites

- Argo CD and Crossplane v2 are installed in the control cluster.
- The OpenTofu provider, `function-go-templating`, and `function-auto-ready` are
  installed and healthy.
- `ClusterProviderConfig/provider-opentofu` is configured for Workspaces in
  `agent-environments`, including the provider's Azure workload identity setup.
- The provisioning identity can create resource groups and the requested role
  assignments.
- Argo CD can read this repository.
- The Backstage template emits the expanded API contract and resolves a trusted
  requester identity before opening a PR.

Review the role in the module explicitly: Owner permits access delegation;
Contributor does not. Template catalog ownership does not grant either role.

## Bootstrap shared request syncing

Keep the existing API Application watching `api/`. Save the following separately
as `argocd/agent-environments.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: agent-environments
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: agent-environments
  namespace: argocd
spec:
  description: Approved agent environment requests
  sourceRepos:
    - https://github.com/pauldotyu/platform.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: agent-environments
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: platform.example.org
      kind: XAgentEnvironment
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: agent-environments
  namespace: argocd
spec:
  project: agent-environments
  source:
    repoURL: https://github.com/pauldotyu/platform.git
    targetRevision: main
    path: requests
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: agent-environments
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 1m
```

Publish the API and corrected requests to `main`, then bootstrap once:

```bash
kubectl config current-context
kubectl apply -f argocd/agent-environments.yaml
```

The API Application must successfully install the XRD and Composition before
requests can be reconciled. Keep bootstrap resources outside `requests/`.

## Validate the API and request

In `api/agent-environment/xrd.yaml`, `scope: Namespaced` belongs directly under
`spec`, not under a version. Keep the existing versions and schema beneath it.

Validate team, project, and environment as lowercase name segments, for example
`^[a-z0-9]+(-[a-z0-9]+)*$`, with explicit length limits. Require nonempty location
and cost center and validate requester object IDs as UUIDs. Match the form's
constraints to the API, including maximum lengths. Do not apply DNS-style naming
restrictions to cost-center tags unless that is the actual business requirement.

For the expanded contract, a request looks like:

```yaml
apiVersion: platform.example.org/v1alpha1
kind: XAgentEnvironment
metadata:
  name: blue-sundae-funday-dev
  namespace: agent-environments
spec:
  parameters:
    team: blue
    project: sundae-funday
    environment: dev
    location: westus3
    costCenter: cc-143
    requesterObjectId: "<trusted-requester-entra-object-id>"
```

The placeholder must be replaced by the trusted requester identity. UUID
validation checks format, not authorization.

Keep only the XR in this request file. The Argo CD Application belongs in
`argocd/agent-environments.yaml`.

The Backstage skeleton must also emit `namespace: agent-environments` so future
requests use the same namespace. Changing a previously deployed XR's namespace
creates a new object; do not let two Workspaces manage the same Azure resources.

## Expose the resource group ID on the XR

First add a status property to the XRD's
`spec.versions[].schema.openAPIV3Schema.properties`, alongside `spec`:

```yaml
status:
  type: object
  properties:
    resourceGroupId:
      type: string
```

Then append the following YAML document inside the Composition's existing
`inline.template: |` string, after the Workspace document. Preserve the existing
Workspace and its annotation
`gotemplating.fn.crossplane.io/composition-resource-name: opentofu-workspace`.

```yaml
{{- $workspace := getComposedResource . "opentofu-workspace" }}
{{- $resourceGroupId := dig "status" "atProvider" "outputs" "resource_group_id" "" ($workspace | default (dict)) }}
{{- if $resourceGroupId }}
---
apiVersion: platform.example.org/v1alpha1
kind: XAgentEnvironment
status:
  resourceGroupId: {{ $resourceGroupId | quote }}
{{- end }}
```

Indent these lines to match the existing template text. This is Go-template
content within the Composition, not a standalone manifest.

The function recognizes the composite type without a composition-resource-name
annotation as a status update to the XR, not another composed resource. It reads
the observed Workspace output after provisioning; the first reconciliation has
no output yet. Verify the installed provider exposes the output at
`status.atProvider.outputs.resource_group_id`.

The resource group ID is an output, not a readiness signal. Use the XR and
Workspace conditions to establish provisioning health.

## Verify provisioning

```bash
kubectl -n argocd get application agent-environments \
  -o jsonpath='{.status.sync.status}{"\n"}{.status.conditions}{"\n"}'

kubectl -n agent-environments get xagentenvironments
kubectl -n agent-environments describe xagentenvironment blue-sundae-funday-dev
kubectl -n agent-environments get workspaces.opentofu.m.upbound.io

kubectl -n agent-environments get xagentenvironment blue-sundae-funday-dev \
  -o jsonpath='{.status.resourceGroupId}{"\n"}'
```

Argo CD `Synced` means the request reached Kubernetes, not that Azure provisioning
finished. Inspect XR and Workspace conditions for readiness and reconciliation
errors, then confirm the Azure resource group's name, region, tags, and role
assignment. Verify a second environment works without GitOps configuration
changes.

## Use your environment

The following snippet demonstrates how to configure a pod to use the environment's service account and platform context ConfigMap:

```yaml
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: foundry            # a key from status.binding.serviceAccounts
      containers:
        - name: agent
          envFrom:
            - configMapRef:
                name: platform-context       # status.binding.configMapName
```

## Updates and teardown

Treat the team/project/environment tuple as the environment's identity. Update
its existing request through a reviewed PR rather than creating another request
for the same resource group.

The request Application enables automatic pruning and `allowEmpty`, so removing
a request from Git deletes its live XR, including when it is the last request.
Keep pruning disabled on the separate API Application.

The self-service deletion flow is:

1. Use the Backstage deletion template to propose removal of exactly
   `requests/<team>/<project>/<environment>/environment.yaml`.
2. A platform reviewer verifies the target, destruction scope, and provider
   deletion settings, then approves and merges the removal PR.
3. Argo CD prunes the XR. Crossplane deletes the composed Workspace, and the
   OpenTofu provider destroys its resources if its deletion policy permits it.
4. Monitor Workspace cleanup and confirm the resource group and role assignment
   are gone. A completed Backstage task means the PR was created, not that Azure
   teardown completed.

Protect `main` with required review; the template itself is not an authorization
boundary. Any removal from the watched path is destructive, including an
accidental move or rename. With `allowEmpty`, an accidentally emptied request
directory can delete all environments. Test the complete path on a disposable
environment before broader use.

Deleting a resource group can also delete resources added outside OpenTofu.
AzureRM's nonempty-resource-group protection may instead block deletion. Review
that behavior, state, locks, and retention requirements before approving teardown.
Do not delete the XR directly while its request remains in Git: self-heal can
recreate it.

Do not strip finalizers to bypass failed cleanup. Investigate provider errors
and preserve state until the external resources are accounted for.
