# helm-dev

A Helm repository, and the source of the charts in it.

```console
helm repo add helm-dev https://codyrancher.github.io/helm-dev
helm repo update
helm search repo helm-dev
```

In Rancher: **Apps → Repositories → Create**, with that same URL as the Index URL.

## Charts

| Chart | What it is |
| --- | --- |
| [rancher-ha](charts/rancher-ha) | A Rancher server in threes - three replicas, one per node, reachable on any node address. Asks for an admin password and an image. |

## How this repository is laid out

`charts/` is the source. The repository index and the packaged `.tgz` files sit at the root of
the `gh-pages` branch, which is what `helm repo add` reads. Publishing a new version means
packaging the chart, dropping the tarball beside the others and regenerating `index.yaml`.
