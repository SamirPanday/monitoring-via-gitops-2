# Monitoring via GitOps

This repository deploys a Kubernetes monitoring platform through Argo CD and Helm.
It combines Prometheus, Alertmanager, Grafana, Loki, Grafana Alloy, optional Istio
exposure, tenant configuration, and a Grafana API reconciler.

## Architecture At A Glance

```text
Git repository
    |
    v
Argo CD root Application
    |
    v
Child Applications in apps/
    |
    +-- monitoring-base
    +-- kube-prometheus-stack
    +-- Loki
    +-- Grafana Alloy
    +-- monitoring-config
    +-- Grafana reconciler
    +-- optional tenant Applications
    |
    v
Kubernetes resources
    |
    +-- metrics --> Prometheus --> Grafana
    +-- logs ----> Loki -------> Grafana
    +-- tenant registry Secrets --> reconciler --> Grafana users, teams, folders
```

The repository is declarative: Git describes the desired state, and Argo CD
continuously attempts to make the cluster match it.

## First Installation

The entry point is [bootstrap/root-app.yaml](bootstrap/root-app.yaml).
Applying this manifest creates an Argo CD Application named `monitoring-root`.
That Application watches the `apps/` directory and creates the child Applications.

A typical installation is:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

The cluster must already provide, or separately install:

- Argo CD
- A Kubernetes cluster
- A storage class named `longhorn`, unless the values are changed
- Istio, if Grafana will be exposed through Istio
- cert-manager, if the chart will create TLS certificates
- Network access to the upstream Helm repositories and Git repository

## Argo CD Application Layout

The child Applications are defined in [apps/00-monitoring-base.yaml](apps/00-monitoring-base.yaml)
and [apps/10-monitoring.yaml](apps/10-monitoring.yaml).

The sync order is controlled with Argo CD sync waves:

| Wave | Application | Purpose |
| --- | --- | --- |
| `-1` | `monitoring-base` | Creates the monitoring namespace and base settings |
| `1` | `kube-prometheus-stack` | Installs Prometheus, Alertmanager, Grafana, and exporters |
| `1` | `loki` | Installs Loki |
| `2` | `alloy` | Installs Grafana Alloy for log collection |
| `2` | `monitoring-config` | Adds ServiceMonitors, policies, and optional Istio exposure |
| `3` | `grafana-reconciler` | Periodically configures Grafana through its API |
| `4` | tenant Applications | Intended tenant onboarding layer |

The wave-4 tenant Application is currently commented out in
[apps/10-monitoring.yaml](apps/10-monitoring.yaml). The ApplicationSet can therefore
require separate activation before tenant onboarding occurs.

The Applications use automated sync, pruning, self-healing, and retry settings.
The monitoring stack uses Argo CD's multi-source Helm Application pattern:

1. An upstream chart is the primary source.
2. This repository is added as a second source with `ref: values`.
3. `$values/...` files provide the repository's Helm overrides.

For example, the Prometheus stack uses:

```yaml
valueFiles:
  - $values/values/kube-prometheus-stack.yaml
```

## Base Namespace

The local chart in [charts/monitoring-base](charts/monitoring-base) creates the
`monitoring` namespace and applies its baseline configuration.

The namespace is configured with privileged Pod Security because node-exporter
and related monitoring components need host-level access. This setting should be
reviewed before using the repository in a production cluster.

## Prometheus, Alertmanager, and Grafana

The upstream `kube-prometheus-stack` chart is configured by
[values/kube-prometheus-stack.yaml](values/kube-prometheus-stack.yaml).

### Prometheus

Current settings include:

- Seven days of retention
- A 12 GB retention size limit
- 30-second scrape and evaluation intervals
- A 15 GiB persistent volume
- `longhorn` as the storage class
- Cluster-wide ServiceMonitor, PodMonitor, rule, and probe selection

The configuration also enables monitoring for RKE2 control-plane components:

- etcd
- kube-controller-manager
- kube-scheduler
- kube-proxy
- CoreDNS
- node-exporter
- kube-state-metrics

Those settings may need adjustment for a non-RKE2 cluster.

### Alertmanager

Alertmanager stores data on a 2 GiB PVC and selects AlertmanagerConfig objects
across namespaces. Tenant routes currently use a null receiver, so alerting is
configured for evaluation and routing but does not deliver notifications.

### Grafana

Grafana is configured in the same values file:

```yaml
grafana:
  enabled: true
  fullnameOverride: grafana
  service:
    type: NodePort
```

The Service type can be changed to `ClusterIP`, `NodePort`, or `LoadBalancer`.
The current Grafana Service is therefore expected to be a `NodePort` after Argo CD
syncs the committed and pushed values.

Other Grafana settings include:

- A 2 GiB PVC
- A configured admin account
- Anonymous access disabled
- User sign-up disabled
- Organization creation disabled
- A shared Loki datasource
- Dashboard sidecar discovery across namespaces
- Grafana's built-in alerting systems disabled

The configured hostname and root URL are `grafana.poc.local`. If the access URL
changes, update both the Grafana server settings and the optional exposure settings.

Credentials are currently stored as plaintext values. This is suitable only for a
PoC. Production deployments should use a secret-management approach.

## Loki

Loki is configured in [values/loki.yaml](values/loki.yaml).

The current topology is intentionally small:

- Single-binary deployment
- One replica
- Filesystem storage
- One 20 GiB PVC
- `longhorn` storage
- 60-day retention
- Replication factor one
- No object storage, gateway, cache, or MinIO

This is easy to understand and inexpensive, but it is not highly available. A
node or volume failure can make the log system unavailable or cause data loss.

Grafana and Alloy use the Kubernetes service address:

```text
loki.monitoring.svc.cluster.local:3100
```

## Grafana Alloy

Alloy is configured in [values/alloy.yaml](values/alloy.yaml) and runs as a
DaemonSet, with one pod scheduled on each node.

Each Alloy pod:

1. Discovers pods scheduled on its node.
2. Reads Kubernetes pod logs through the Kubernetes API.
3. Adds `namespace`, `pod`, `container`, and `app` labels.
4. Sends the log entries to Loki.

The dashboards expect structured access-log fields such as `status` and
`request_time`. Logs without those fields are still collected, but the golden
signal panels cannot calculate useful error-rate or latency values from them.

## Monitoring Configuration Chart

The local chart in [charts/monitoring-config](charts/monitoring-config) owns
monitoring resources that are separate from the upstream stack.

Its templates provide:

- Optional Istio Grafana exposure
- Optional network policies
- Optional ServiceMonitors for supporting services

### Istio Exposure

Exposure is disabled by default in [charts/monitoring-config/values.yaml](charts/monitoring-config/values.yaml):

```yaml
exposure:
  enabled: false
```

When enabled, the chart creates an Istio VirtualService routing the configured
host to:

```text
grafana.monitoring.svc.cluster.local:80
```

The default gateway is `istio-ingress/main-gateway`. With `gateway.create: false`,
that Gateway must already exist. TLS is also optional and requires the expected
Gateway and certificate resources to exist or be enabled.

### Network Policies

Network policies are opt-in. When enabled, they restrict traffic between
monitoring components and allow Grafana traffic from the configured gateway
namespace.

Before enabling them, check whether applications require traffic from:

- Istio or another ingress controller
- DNS services
- Other namespaces
- Shared platform services

## Tenant Onboarding

Tenant discovery is defined in [appsets/tenants.yaml](appsets/tenants.yaml).
Each active tenant directory is intended to produce an Argo CD Application.

The tenant chart in [charts/tenant](charts/tenant) can create:

- A tenant namespace
- PrometheusRule resources
- AlertmanagerConfig resources
- Optional namespace network policies
- A registry Secret in the monitoring namespace

A tenant values file describes the tenant name, namespaces, and Grafana members.
The chart serializes that data into a Secret named like:

```text
tenant-<tenant-name>
```

The Secret is labeled:

```text
monitoring.poc/tenant: "true"
```

That label is how the Grafana reconciler finds tenant definitions.

The repository currently has example tenant files under
[examples/tenants](examples/tenants), while the active `tenants/` directory does
not contain corresponding tenant directories. This distinction matters: examples
are not automatically deployed just because they are present in Git.

## Grafana Reconciler

The reconciler chart is in [charts/reconciler](charts/reconciler).
It creates a CronJob that runs every two minutes using the script in
[charts/reconciler/files/reconcile.sh](charts/reconciler/files/reconcile.sh).

The script waits for Grafana to become healthy and then uses the Grafana API to:

- Ensure organization `1` is named `Monitoring`
- Create and protect platform folders
- Import the all-tenant golden-signals dashboard
- Set the administrator home dashboard
- Read tenant registry Secrets
- Create or update Grafana users
- Force tenant users to the Viewer role
- Create tenant teams and folders
- Add users to the appropriate teams
- Create tenant overview and log dashboards
- Bake allowed namespaces into Prometheus and Loki queries
- Remove users from teams when they are no longer configured
- Delete users that are no longer used elsewhere, except administrators

The dashboard source files are:

- [golden-signals-logs.json](charts/reconciler/files/golden-signals-logs.json)
- [tenant-overview.json](charts/reconciler/files/tenant-overview.json)
- [tenant-logs.json](charts/reconciler/files/tenant-logs.json)

The reconciler gives users a restricted Grafana experience, but this is not a
strong security boundary. Shared Prometheus and Loki backends, direct datasource
access, or Grafana API access can bypass dashboard-level namespace filters.

## Demo Applications

The demo ApplicationSet is in [examples/demo-apps-appset.yaml](examples/demo-apps-appset.yaml).
The workload chart is [examples/demo-app](examples/demo-app).

The demo workload includes:

- Unprivileged Nginx
- An Nginx Prometheus exporter
- A Service and ServiceMonitor
- Structured JSON access logs
- A traffic generator
- Simulated 500 responses
- Simulated 503 responses
- Simulated slow responses

This gives Prometheus and Loki realistic data for the Grafana dashboards.

## Repository URLs

Several files contain repository URLs. The root and monitoring Applications currently
use a hard-coded GitHub URL, while the tenant and demo ApplicationSets use
`CHANGE_ME` placeholders.

The replacement helper in [scripts/set-repo-url.sh](scripts/set-repo-url.sh) only
replaces `CHANGE_ME`; it does not replace the hard-coded URLs. When using a fork,
verify every Argo CD source URL before bootstrapping.

## Common Operations

Check the Argo CD Application:

```bash
argocd app get kube-prometheus-stack
```

Synchronize the Prometheus/Grafana stack:

```bash
argocd app sync kube-prometheus-stack
```

Check the live Grafana Service:

```bash
kubectl -n monitoring get svc grafana
```

Check only the Service type:

```bash
kubectl -n monitoring get svc grafana \
  -o jsonpath='{.spec.type}{"\n"}'
```

Inspect what Argo CD believes differs from Git:

```bash
argocd app diff kube-prometheus-stack
```

Inspect the rendered resources from Helm before applying them:

```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 92.11.0 \
  --namespace monitoring \
  -f values/kube-prometheus-stack.yaml
```

## Important Caveats

- A commit must be pushed to the branch Argo CD watches before it can sync.
- Grafana and tenant passwords are currently stored in Git.
- Loki is single-replica and non-redundant.
- Tenant onboarding is not fully active in the checked-in state.
- Removing a tenant may leave old Grafana teams, folders, dashboards, or users.
- Network policies can disrupt existing traffic when enabled.
- The control-plane settings assume RKE2.
- The repository does not currently include a complete automated Helm-render or
  live-cluster validation workflow.
- The tenant and demo ApplicationSets may not point at the same repository as the
  root Application.

## Recommended Reading Order

1. [README.md](README.md)
2. [bootstrap/root-app.yaml](bootstrap/root-app.yaml)
3. [apps/10-monitoring.yaml](apps/10-monitoring.yaml)
4. [values/kube-prometheus-stack.yaml](values/kube-prometheus-stack.yaml)
5. [values/loki.yaml](values/loki.yaml)
6. [values/alloy.yaml](values/alloy.yaml)
7. [charts/monitoring-config](charts/monitoring-config)
8. [charts/tenant](charts/tenant)
9. [charts/reconciler/files/reconcile.sh](charts/reconciler/files/reconcile.sh)
10. [examples/demo-app/templates/demo-app.yaml](examples/demo-app/templates/demo-app.yaml)
