# rancher-ha

A Rancher server in threes: three replicas, one per node, behind the cluster's own ingress
controller, reachable on the public address of any node.

```console
helm repo add helm-dev https://codyrancher.github.io/helm-dev
helm install rancher-ha helm-dev/rancher-ha \
  --namespace cattle-system --create-namespace \
  --set adminPassword=<at least 12 characters>
```

Then open `https://<any node address>/` and log in as `admin`.

## It has to be cattle-system

Not a convention - the chart refuses any other namespace. On startup Rancher registers the
aggregated API `v1.ext.cattle.io` against a Service it creates itself, always at
`cattle-system/imperative-api-extension`, selecting its own pods by label. A Service only
selects pods in its own namespace, so a release anywhere else leaves that Service with no
endpoints and every page of the UI replaced by the one line `API Aggregation not ready`.
Nothing in that failure points at the namespace, so the chart fails at template time instead.

## It needs three nodes

Not as a recommendation - the chart refuses a smaller cluster, in two places:

- a template-time check that fails the install with a sentence, whenever Helm can reach the
  API to count nodes;
- `requiredDuringSchedulingIgnoredDuringExecution` pod anti-affinity on
  `kubernetes.io/hostname`, so the three replicas cannot share a machine even if the check is
  turned off.

Three is the number that makes losing one node survivable. `nodeCheck.enabled=false` disables
the check for a deliberate single-node trial; the anti-affinity still applies, so the extra
replicas stay Pending, which is the honest outcome.

## Values

| Key | Default | What it is |
| --- | --- | --- |
| `adminPassword` | `rancher-ha-changeme` | The first admin password. A placeholder that says so - change it. |
| `image` | `rancher/rancher:v2.15.1` | The Rancher server image. |
| `replicas` | `3` | One per node. |
| `addLocal` | `false` | Whether this Rancher adopts the cluster it runs on. See below. |
| `nodeCheck.enabled` | `true` | The three-node check. |
| `nodeCheck.minNodes` | `3` | How many nodes it insists on. |
| `ingress.enabled` | `true` | Create the Ingress. |
| `ingress.className` | `nginx` | Ingress class. |
| `ingress.host` | `""` | Empty means the rule matches any host, so any node address works. |
| `service.type` | `ClusterIP` | Service type. |
| `resources` | `{}` | Container resources. |

## Give it a cluster of its own

Rancher adopts the cluster it runs on as its `local` cluster, and there is no way round it:
`addLocal` has been deprecated since Rancher 2.5 and the server refuses to start with it off.
So the new Rancher installs its own webhook, Fleet and provisioning controllers into
`cattle-system` and `cattle-fleet-system`.

Install this onto a cluster that another Rancher already manages and the two of them reconcile
the same namespaces. `fleet-agent` is the sharp edge: it has exactly one owner, the new Rancher
takes it over, and the managing Rancher loses the cluster. Nothing is lost that cannot be
rebuilt, but it is not a state to be surprised by.

## TLS

The ingress controller answers 443 with its own self-signed certificate, so the browser warns
once. That is deliberate: it needs no cert-manager and no DNS, and it is still TLS, which
matters because Rancher sets secure cookies and a login over plain HTTP does not stick. For a
real certificate, set `ingress.host` and add your issuer's annotations through
`ingress.annotations`.
