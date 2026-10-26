# Project Concepts Guide

This document explains the main concepts behind the monitoring GitOps repository:
Argo CD Applications, upstream Helm charts, values files, local charts, Istio,
tenant onboarding, and the Grafana reconciler.

## The Three Main Layers

The repository combines three layers:

```text
Argo CD Applications
    |
    | choose which charts to deploy
    v
Helm charts
    |
    | contain templates for Kubernetes resources
    v
Kubernetes resources
    |
    | Deployments, StatefulSets, Services, PVCs, ConfigMaps, etc.
    v
Running monitoring tools
```

Values files configure Helm charts. They are not deployments by themselves.

## Argo CD Applications

The root Application is defined in
[bootstrap/root-app.yaml](bootstrap/root-app.yaml). It watches the `apps/`
directory and creates the child Applications found there.

The child Applications are defined in:

- [apps/00-monitoring-base.yaml](apps/00-monitoring-base.yaml)
- [apps/10-monitoring.yaml](apps/10-monitoring.yaml)

The important Applications are:

| Application | Purpose |
| --- | --- |
| `monitoring-base` | Creates the monitoring namespace and base settings |
| `kube-prometheus-stack` | Installs Prometheus, Alertmanager, Grafana, and exporters |
| `loki` | Installs Loki |
| `alloy` | Installs Grafana Alloy |
| `monitoring-config` | Adds networking and monitoring configuration |
| `grafana-reconciler` | Configures Grafana through its API |

An Application is an Argo CD object that says where the source code or chart is,
which revision to use, where to deploy it, and how to synchronize it.

## Automated Sync

The Applications use settings like:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

This means:

- Argo CD watches Git for changes.
- Git changes are applied to the cluster automatically.
- Manual drift is corrected back to the Git state.
- Resources removed from Git can be removed from Kubernetes.

For example, the desired Grafana Service type comes from Git. Argo CD renders the
Helm chart and applies the resulting Service to the `monitoring` namespace.

## Upstream Helm Charts

An upstream chart is a Helm chart maintained outside this repository.

The Prometheus stack Application uses:

```yaml
repoURL: https://prometheus-community.github.io/helm-charts
chart: kube-prometheus-stack
targetRevision: 92.11.0
```

The Loki and Alloy Applications use charts from:

```text
https://grafana.github.io/helm-charts
```

The upstream charts contain the templates. This repository supplies values that
customize those templates.

## Which Tools Come From Which Chart?

### kube-prometheus-stack

Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, and the
Prometheus Operator are installed together by the upstream
`kube-prometheus-stack` chart.

Grafana does not have a local chart in this repository. It is a component of the
Prometheus stack chart.

The configuration is in:

[values/kube-prometheus-stack.yaml](values/kube-prometheus-stack.yaml)

### Loki

Loki is installed by its own upstream chart:

```yaml
chart: loki
targetRevision: 7.5.0
```

Its configuration is in:

[values/loki.yaml](values/loki.yaml)

### Alloy

Alloy is also installed by its own upstream chart:

```yaml
chart: alloy
targetRevision: 1.14.3
```

Its configuration is in:

[values/alloy.yaml](values/alloy.yaml)

The Alloy values file is not the Alloy deployment. It is input to the Alloy Helm
chart, which generates the Kubernetes resources.

## How `$values` Works

The upstream chart is one Argo CD source. The repository values are a second
Argo CD source:

```yaml
sources:
  - repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 92.11.0
    helm:
      valueFiles:
        - $values/values/kube-prometheus-stack.yaml

  - repoURL: https://github.com/SamirPanday/monitoring-via-gitops-2.git
    targetRevision: main
    ref: values
```

The `ref: values` name allows the first source to refer to files in the second
source with `$values`.

Therefore:

```text
$values/values/kube-prometheus-stack.yaml
```

means:

```text
values/kube-prometheus-stack.yaml from the Git source named values
```

Helm combines the chart templates and values, renders Kubernetes YAML, and Argo
CD applies the rendered resources.

## Local Helm Charts

The repository also contains charts written locally:

- [charts/monitoring-base](charts/monitoring-base)
- [charts/monitoring-config](charts/monitoring-config)
- [charts/reconciler](charts/reconciler)
- [charts/tenant](charts/tenant)
- [examples/demo-app](examples/demo-app)

A local chart contains its own `Chart.yaml`, `values.yaml`, and `templates/`
directory. Argo CD points directly at the chart path in Git.

## What `monitoring-config` Does

The local chart in [charts/monitoring-config](charts/monitoring-config) does not
install Grafana, Prometheus, Loki, or Alloy.

Those tools are installed by separate Applications and charts.

`monitoring-config` adds surrounding configuration:

- Istio `VirtualService`
- Optional Istio `Gateway`
- Optional cert-manager `Certificate`
- NetworkPolicies
- ServiceMonitors for supporting services

It is a glue and integration chart.

The separation looks like this:

```text
kube-prometheus-stack  -> Prometheus, Grafana, Alertmanager
loki                   -> Loki
alloy                  -> Alloy
monitoring-config      -> networking and monitoring glue
reconciler             -> Grafana API configuration
```

## Loki Single-Binary Mode

The Loki configuration uses a single-binary deployment. One Loki process handles
multiple responsibilities:

- Receiving log writes
- Indexing
- Storing data
- Processing queries
- Returning query results
- Retention work

The current topology is approximately:

```text
One Loki process
       |
       v
One persistent volume
```

This is simple and suitable for a small proof of concept, but it is not highly
available.

A larger Loki installation can use distributed or scalable mode. In that design,
responsibilities are split across components such as:

- Distributor
- Ingester
- Querier
- Query frontend
- Compactor
- Index gateway
- Gateway

Distributed mode can scale components independently and improve availability, but
it requires more configuration and usually object storage.

## Istio: Mesh Versus Exposure

Istio has several capabilities:

- Service-to-service traffic management
- Mutual TLS between meshed workloads
- Traffic routing
- Retries and timeouts
- Observability
- Ingress traffic through gateways

This repository uses Istio mainly for Grafana ingress exposure. That is different
from configuring internal mesh mTLS.

### Internal Service

Grafana already has a Kubernetes Service:

```text
grafana.monitoring.svc.cluster.local
```

That address is normally reachable inside the cluster.

### External Route

An Istio exposure route creates a path from an external client to that internal
Service:

```text
Browser
   |
   v
Istio ingress gateway
   |
   v
Istio VirtualService
   |
   v
Grafana Kubernetes Service
   |
   v
Grafana pods
```

Exposure is disabled by default in
[charts/monitoring-config/values.yaml](charts/monitoring-config/values.yaml):

```yaml
exposure:
  enabled: false
```

When enabled, [charts/monitoring-config/templates/exposure.yaml](charts/monitoring-config/templates/exposure.yaml)
creates a `VirtualService` that routes the configured host to Grafana.

The destination is:

```text
grafana.monitoring.svc.cluster.local:80
```

The Grafana Service does not need to be `NodePort` for Istio to route to it. Istio
can route directly to the internal Kubernetes Service. `NodePort` is a separate
way to expose the Service through node IP addresses.

## Istio Gateway

An Istio `Gateway` is configuration describing how incoming traffic is accepted.
It can specify:

- Which ingress gateway pods handle traffic
- Which ports are open
- Which hostnames are accepted
- Whether HTTP or HTTPS is used
- Which TLS credential is used

The actual ingress gateway pods are normally installed by Istio separately.

The configuration defaults to an existing Gateway:

```yaml
gateway:
  create: false
  namespace: istio-ingress
  name: main-gateway
```

This means the project expects a Gateway named `main-gateway` in the
`istio-ingress` namespace. The chart does not create it unless
`gateway.create` is changed to `true`.

The Grafana Service is in the `monitoring` namespace, so the route uses its fully
qualified Kubernetes DNS name:

```text
grafana.monitoring.svc.cluster.local
```

### TLS Clarification

There are two separate TLS concepts:

1. External TLS from a browser to the Istio ingress gateway.
2. Internal mutual TLS between workloads in the service mesh.

The exposure chart can configure external HTTPS and certificates. It does not by
itself enable mesh-wide mTLS. That depends on the Istio installation and its
`PeerAuthentication` configuration.

## Tenant Onboarding

A tenant is a logical customer or team with:

- One or more Kubernetes namespaces
- Prometheus alerting rules
- Alertmanager routing
- Grafana users
- A Grafana team
- A Grafana folder
- Tenant-specific dashboards

Tenant discovery is intended to be handled by the ApplicationSet in
[appsets/tenants.yaml](appsets/tenants.yaml).

The intended directory shape is:

```text
tenants/
  tenant-a/
    values.yaml
  tenant-b/
    values.yaml
```

The ApplicationSet watches `tenants/*` and is intended to generate Applications
such as:

```text
onboard-tenant-a
onboard-tenant-b
```

Each generated Application deploys the local chart in [charts/tenant](charts/tenant)
with that tenant's values file.

The tenant chart can create:

- Tenant namespaces
- PrometheusRule resources
- AlertmanagerConfig resources
- Optional network policies
- A registry Secret in the `monitoring` namespace

The registry Secret contains tenant and member information and has this label:

```yaml
monitoring.poc/tenant: "true"
```

The Grafana reconciler searches for that label.

The current repository has an important activation issue: the tenant Application
layer is not fully enabled in the checked-in state, and the ApplicationSet still
contains `CHANGE_ME` repository URLs. Example tenant files are not automatically
deployed merely because they exist under `examples/`.

## Grafana Organization `1`

A Grafana organization is a Grafana-level container for:

- Users
- Teams
- Dashboards
- Folders
- Datasource permissions

It is not a Kubernetes organization or an Argo CD object.

A new Grafana installation normally creates its first organization with numeric
ID `1`. The reconciler assumes that organization exists and uses it here:

[charts/reconciler/files/reconcile.sh](charts/reconciler/files/reconcile.sh)

The script sends requests with:

```text
X-Grafana-Org-Id: 1
```

It also renames organization `1` to `Monitoring`.

The resulting structure is:

```text
Grafana
  |
  +-- Organization 1: Monitoring
          |
          +-- Admin users
          +-- Tenant users
          +-- Tenant teams
          +-- Tenant folders
          +-- Shared datasources
```

All tenants currently share this one Grafana organization. Access is separated
using Viewer roles, teams, folder permissions, and tenant-specific dashboard
queries.

## Grafana Reconciler

The reconciler is not the Grafana installation. Grafana is already running because
`kube-prometheus-stack` installed it.

The reconciler is a CronJob that uses the Grafana HTTP API to make Grafana match
the tenant registry Secrets.

It can:

- Create and update Grafana users
- Force tenant users to the Viewer role
- Create tenant teams
- Add users to teams
- Create tenant folders
- Import tenant dashboards
- Restrict platform folders to administrators
- Remove users when they disappear from Git

The reconciler is therefore an application-level controller implemented as a shell
script, rather than a Kubernetes controller written in Go.

## End-to-End Example

A tenant onboarding flow is intended to look like this:

```text
1. Add tenants/acme/values.yaml
                 |
                 v
2. ApplicationSet creates onboard-acme
                 |
                 v
3. charts/tenant renders namespace, rules, and registry Secret
                 |
                 v
4. Grafana reconciler finds the labeled Secret
                 |
                 v
5. Reconciler creates users, team, folder, and dashboards
                 |
                 v
6. Tenant users log into Grafana as Viewers
```

The monitoring data path is:

```text
Application logs --> Alloy --> Loki --> Grafana
Application metrics --> ServiceMonitor --> Prometheus --> Grafana
```

The optional ingress path is:

```text
Browser --> Istio Gateway --> VirtualService --> Grafana Service --> Grafana pods
```
