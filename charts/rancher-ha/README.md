# rancher-ha

A Rancher server in threes - three replicas, one per node - in a virtual cluster of its own, so
several of them can share one real cluster. A second Rancher is a second release name.

```console
helm repo add helm-dev https://codyrancher.github.io/helm-dev

helm install rancher-a helm-dev/rancher-ha -n rancher-a --create-namespace \
  --set ingress.baseDomain=<your base domain> \
  --set adminPassword=<at least 12 characters>

helm install rancher-b helm-dev/rancher-ha -n rancher-b --create-namespace \
  --set ingress.baseDomain=<your base domain>
```

They come up on `https://rancher-a.<baseDomain>/` and `https://rancher-b.<baseDomain>/`, each
its own Rancher with its own admin, its own clusters and its own everything. Log in as `admin`.

## Why a virtual cluster

Because two Rancher servers cannot share a real one. Everything Rancher insists on owning is
cluster-scoped and fixed-name:

| Thing | Why there can only be one |
| --- | --- |
| `kube-system/cattle-controllers` lease | One holder. A second Rancher waits on "Waiting for initial data to be populated" until it gets it. |
| `cattle-system/imperative-api-extension` Service | Fixed name, and its selector points at one release's pods. |
| `v1.ext.cattle.io` APIService | Cluster-scoped, one per cluster. |
| `management.cattle.io` CRDs and their contents | Two servers on the same CRDs are two servers on one database. |

A virtual cluster gives each Rancher its own API server, so each gets its own copy of all four.
The pods still run on the real nodes - vCluster schedules them out to the host - so three
replicas still means three machines, and the anti-affinity still means one per machine.

Turn it off with `--set virtualCluster=false` to install Rancher straight into the cluster, the
ordinary way. Then the release has to be in `cattle-system` (the chart will tell you why) and
there can be only one.

## What it needs from the cluster

- **Three nodes.** Refused otherwise, in two places: a template-time node count that fails the
  install with a sentence, and `requiredDuringScheduling` pod anti-affinity on
  `kubernetes.io/hostname` so the replicas cannot share a machine even if the check is off.
- **An ingress controller**, and a hostname per release. The controller tells several Ranchers
  apart by `Host` and nothing else, so `ingress.host` or `ingress.baseDomain` is required in
  virtual-cluster mode. With no DNS to hand, a wildcard service does: with
  `ingress.baseDomain=203-0-113-10.sslip.io`, `rancher-a.203-0-113-10.sslip.io` resolves to
  `203.0.113.10` with nothing to set up.
- **A default StorageClass**, for the virtual cluster's control-plane volume. RKE2 and K3s ship
  none; `rancher/local-path-provisioner` is the usual answer. Checked at template time.

## It does not ask you to bootstrap it

A new Rancher normally opens on a bootstrap-password page and then a wizard asking for the
server URL and for the EULA to be accepted. All three are settings, and this chart knows every
answer already - the URL is the ingress host it just created - so it writes them and the site
opens on an ordinary login page.

That includes recording acceptance of the Rancher EULA on your behalf. `skipFirstRun=false`
leaves all three unset and you are asked in the browser instead.

## Finding a running one

Everything worth looking at lives inside the virtual cluster, so whatever deployed this release
- Fleet, argocd, `helm get manifest` - sees only vCluster's own objects and never says where
the Rancher is. The release carries a ConfigMap to answer that:

```console
kubectl get cm -A -l app.kubernetes.io/name=rancher-ha -o custom-columns=\
NS:.metadata.namespace,URL:.data.url,USER:.data.username
```

One line per Rancher on the cluster. The same information is on the Ingress inside the virtual
cluster, and on its synced copy in the release namespace, if you would rather look there.

**A caveat about readiness.** A deploying system watches the resources in the release, and they
are all vCluster's. It will report the release healthy as soon as the virtual cluster is up,
which is a few minutes before Rancher answers. Do not read "Active" as "Rancher is ready" -
check the URL.

## Values

| Key | Default | What it is |
| --- | --- | --- |
| `adminPassword` | `rancher-ha-changeme` | The first admin password. A placeholder that says so - change it. |
| `image` | `rancher/rancher:v2.15.1` | The Rancher server image. Also the image the two hook Jobs use, since it carries kubectl. |
| `ingress.host` | `""` | The hostname this release answers on. |
| `ingress.baseDomain` | `""` | Or set this, and the host becomes `<release>.<baseDomain>`. |
| `virtualCluster` | `true` | Give this Rancher a virtual cluster of its own. |
| `skipFirstRun` | `true` | Answer the first-run screens, including accepting the EULA. |
| `replicas` | `3` | One per node. |
| `addLocal` | `true` | Not really optional - Rancher refuses to start with it off. |
| `nodeCheck.enabled` | `true` | The three-node check. |
| `nodeCheck.minNodes` | `3` | How many nodes it insists on. |
| `vclusterCheck.storageClass` | `true` | The default-StorageClass check. |
| `ingress.enabled` | `true` | Create the Ingress. |
| `ingress.className` | `nginx` | Ingress class. |
| `vcluster.*` | see values.yaml | Passed through to the upstream vCluster chart. |

## How the install works

Helm installs into one cluster, and the virtual cluster does not exist until this release
creates it - so Rancher's manifests cannot simply be part of the release. They are rendered
into a ConfigMap and applied by a `post-install` hook that waits for the virtual cluster to
answer. vCluster's own `experimental.deploy.vcluster.helm` would be the obvious route and does
not work here: it is a subchart value, and Helm does not template subchart values, so the
password, image and hostname somebody just typed could never reach it.

## TLS

The ingress controller answers 443 with its own self-signed certificate, so the browser warns
once. That needs no cert-manager and no real certificate, and it is still TLS, which matters
because Rancher sets secure cookies and a login over plain HTTP does not stick. For a real
certificate, add your issuer's annotations through `ingress.annotations`.
