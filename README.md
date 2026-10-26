# monitoring-only

The multi-tenant monitoring stack on its own, for a Kubernetes cluster where the platform (ArgoCD, storage, Istio, cert-manager) already exists. Everything is deployed by ArgoCD from this directory once it is in a Git repo.

| Component | What it provides |
|---|---|
| kube-prometheus-stack | Prometheus (7d retention), Alertmanager, Grafana, node-exporter, kube-state-metrics |
| Loki + Grafana Alloy | Logs (single-tenant Loki), collected through the Kubernetes API |
| Tenancy | One shared Grafana org with one Prometheus and one Loki datasource; each tenant gets read-only Viewer logins, a team, a folder and two dashboards (metrics overview, logs with the four golden signals) |
| Exposure | Grafana through an existing Istio ingress gateway with a cert-manager certificate (optional) |

## Prerequisites on the target cluster

| Need | Notes |
|---|---|
| ArgoCD 2.6+ | multi-source Applications, ApplicationSet controller |
| Default-capable StorageClass | `longhorn` is used by default; change `storageClassName` / `storageClass` in `values/*.yaml` |
| Istio ingress gateway + cert-manager issuer | only for the Grafana exposure; otherwise set `exposure.enabled: false` in `charts/monitoring-config/values.yaml` and use `kubectl port-forward` |
| Outbound access to the Helm repos and image registries | `prometheus-community`, `grafana` charts; `quay.io`, `docker.io`, `registry.k8s.io` images |

RKE2 control-plane metrics need these settings in `/etc/rancher/rke2/config.yaml` on the servers (restart `rke2-server` afterwards); without them the etcd, scheduler, controller-manager and kube-proxy targets show down:

```yaml
etcd-expose-metrics: true
kube-controller-manager-arg: [bind-address=0.0.0.0]
kube-scheduler-arg: [bind-address=0.0.0.0]
kube-proxy-arg: [metrics-bind-address=0.0.0.0:10249]
```

On other distributions, turn off what does not apply in `values/kube-prometheus-stack.yaml` (`kubeEtcd.enabled`, `kubeScheduler.enabled`, `kubeControllerManager.enabled`, `kubeProxy.enabled`). Control-plane taints are tolerated by node-exporter and Alloy.

## Configure

1. Put this directory in a Git repo and replace the placeholder URL:
   ```bash
   ./scripts/set-repo-url.sh https://github.com/<owner>/<repo>.git        # optional 2nd arg: branch
   ```
2. Review the environment settings:

| Setting | Where | Default |
|---|---|---|
| Grafana hostname | `values/kube-prometheus-stack.yaml` (`grafana.grafana.ini.server`) and `charts/monitoring-config/values.yaml` (`exposure.host`) | `grafana.poc.local` |
| StorageClass | `values/kube-prometheus-stack.yaml` (3 places), `values/loki.yaml` | `longhorn` |
| Grafana admin password | `values/kube-prometheus-stack.yaml` (`grafana.adminPassword`) | `Adm1n-Poc-2026` (change it) |
| Gateway namespace/name/selector, TLS issuer | `charts/monitoring-config/values.yaml` | `istio-ingress`, `main-gateway`, issuer `poc-ca` |
| Existing gateway instead of a new one | `exposure.gateway.create: false` | creates `main-gateway` |
| Platform ServiceMonitors (Longhorn, Istio) | `charts/monitoring-config/values.yaml` | enabled; harmless if absent |
| RKE2 CIS CoreDNS scrape policy | `charts/monitoring-base/values.yaml` (`rke2Cis.allowCorednsScrape`) | `true` |
| Retention, sizes, resources | `values/*.yaml` | metrics 7d, logs 60d (Loki volume 20Gi); other sizes are small PoC values |

The monitoring namespace is fixed to `monitoring`.

## Deploy

```bash
export KUBECONFIG=<target cluster kubeconfig>
# private repo: registers it in ArgoCD with a token and applies the root app
./scripts/register-repo.sh https://github.com/<owner>/<repo>.git <token-file> [git-user]
# public repo: kubectl apply -f bootstrap/root-app.yaml
kubectl -n argocd get applications
```

Sync order (sync waves): `monitoring-base` (namespace) -> `kube-prometheus-stack` and `loki` -> `alloy` and `monitoring-config` -> `grafana-reconciler` -> `tenancy` (one Application per tenant).

Grafana login: `admin` and the password from the values file. With exposure enabled, map the gateway's address to the hostname (for example in `/etc/hosts`) and open `https://<host>`; otherwise:

```bash
kubectl -n monitoring port-forward svc/grafana 3000:80    # http://localhost:3000
```

## Onboard a tenant

A tenant is one or more namespaces whose logs and metrics its members may see. Each `tenants/<name>/` directory becomes one ArgoCD Application.

```bash
cp -r tenants/_template tenants/acme      # edit tenants/acme/values.yaml, then commit and push
```

A tenant whose applications run in several namespaces lists them all:

```yaml
namespaces: [shop, payments, batch]
```

Its dashboards then query all of them, show a namespace filter, and label series with `namespace / pod`. The filter can only narrow the list: the allowed namespaces are fixed in the queries, so a tampered filter returns nothing extra. With a single namespace the filter is hidden.

A person who needs several tenants can be listed under the same login (same password) in each tenant's `members:`; they then see every tenant's folder, and the account is only deleted when no tenant lists it any more.

Within about 2 minutes the `grafana-reconciler` CronJob creates, in the shared Grafana org:

- read-only Viewer accounts for `members:`; removing a login from Git deletes the account (admins are never deleted)
- a team and a folder that only that team can open
- the tenant's **Overview - metrics** and **Logs and golden signals** dashboards, with the namespace baked into every query, as the team's home page

The tenant chart also adds an `AlertmanagerConfig` (null receiver; the operator adds a namespace matcher) and a `PrometheusRule` per namespace. For namespaces that already run workloads, leave `manageNamespace` and `networkPolicy.enabled` at `false`; set them to `true` only for new namespaces that the chart should lock down.

Tenants only see the folder of their team. The admin home is the all-tenants golden-signals dashboard in an admin-only folder, next to the built-in `Platform (admins only)` dashboards.

The HTTP panels (traffic, errors, latency, saturation) read `status` and `request_time` from a JSON access log. Applications that log that way light up fully; other logs still appear in the log view.

### Try it with the sample workload

```bash
cp -r examples/tenants/tenant-a examples/tenants/tenant-b tenants/
kubectl apply -f examples/demo-apps-appset.yaml    # nginx + traffic generator per sample tenant
```

Sample logins: `tenant-a` / `TenantA-Poc-2026`, `tenant-a-viewer2` / `TenantA-Viewer2-2026`, `tenant-b` / `TenantB-Poc-2026`.

## Layout

```
apps/                 ArgoCD Applications, ordered with sync waves
appsets/              ApplicationSet that creates one Application per tenants/<name>
bootstrap/            root Application (apply this once)
charts/
  monitoring-base/    namespace, default service account, RKE2 CIS scrape policy
  monitoring-config/  network policies, ServiceMonitors, Grafana exposure
  tenant/             per-tenant alerting, registry entry, optional namespace/network policy
  reconciler/         CronJob + dashboards that manage Grafana members, teams, folders and datasources
values/               values for kube-prometheus-stack, Loki and Alloy
tenants/              one directory per tenant (_template is ignored)
examples/             sample tenants and a demo workload (not deployed by default)
scripts/              set-repo-url.sh, register-repo.sh
```

## Limitations

- Tenant isolation is by dashboards only: tenants are read-only Viewers with no Explore, and the namespace is fixed in their dashboards. Loki is single-tenant and Grafana has one shared Loki and Prometheus datasource, so Grafana OSS cannot restrict datasource access per user: a tenant who calls Grafana's query API directly could query other namespaces. For hard isolation put an identity-aware gateway in front of Loki and Prometheus, or use one Grafana org per tenant.
- Credentials (Grafana admin, tenant passwords) are plaintext in Git; there is no secret management.
- Removing a tenant directory removes its Kubernetes resources, but its Grafana team, folder and dashboards stay until deleted by hand.
- Alertmanager has a placeholder receiver, so alerts are not sent anywhere. The Grafana alerting UI is disabled.
- Loki uses filesystem storage on a single PVC (no object storage), sized for minimal log volume.
