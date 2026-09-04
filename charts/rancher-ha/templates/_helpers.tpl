{{- define "rancher-ha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rancher-ha.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "rancher-ha.labels" -}}
app: {{ include "rancher-ha.fullname" . }}
app.kubernetes.io/name: {{ include "rancher-ha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Where Rancher itself goes.

Always cattle-system inside a virtual cluster - see checkNamespace for why it is not a choice -
and the release's own namespace when this chart installs Rancher directly.
*/}}
{{- define "rancher-ha.targetNamespace" -}}
{{- if .Values.virtualCluster }}cattle-system{{ else }}{{ .Release.Namespace }}{{ end -}}
{{- end -}}

{{/* The virtual cluster's own objects are named after the release, by the vcluster chart. */}}
{{- define "rancher-ha.vclusterService" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "rancher-ha.vclusterSecret" -}}
{{- printf "vc-%s" .Release.Name -}}
{{- end -}}

{{/* The hostname this release answers on: given outright, or built from a base domain. */}}
{{- define "rancher-ha.host" -}}
{{- if .Values.ingress.host -}}
{{- .Values.ingress.host -}}
{{- else if .Values.ingress.baseDomain -}}
{{- printf "%s.%s" .Release.Name .Values.ingress.baseDomain -}}
{{- end -}}
{{- end -}}

{{/*
Rancher has to be in cattle-system, and this is not a convention.

When it starts, Rancher registers the aggregated API `v1.ext.cattle.io` against a Service it
creates itself, always at cattle-system/imperative-api-extension, selecting its own pods by
label. A Service only selects pods in its own namespace, so a release in any other namespace
leaves that Service with no endpoints, the APIService permanently unavailable, and every page
of the UI replaced by the single line "API Aggregation not ready".

Only checked in direct mode. Inside a virtual cluster the chart puts Rancher in cattle-system
itself, and the release namespace on the host is free to be whatever you like - which is what
lets several of these live on one cluster.
*/}}
{{- define "rancher-ha.checkNamespace" -}}
{{- if and (not .Values.virtualCluster) (ne .Release.Namespace "cattle-system") -}}
{{- fail (printf "rancher-ha installs Rancher into the namespace it is released into, and Rancher only works in cattle-system - it registers its aggregated API against cattle-system/imperative-api-extension, which cannot select pods in %s, and the UI comes up as \"API Aggregation not ready\". Either release into cattle-system, or leave vcluster.enabled at true and put each Rancher in a virtual cluster of its own." .Release.Namespace) -}}
{{- end -}}
{{- end -}}

{{/*
Refuse a cluster that cannot hold the replicas, at template time, with a sentence.

`lookup` returns nothing during a dry run or a `helm template`, which is why the count is only
enforced when it answers - a rendering with no cluster behind it must not fail. On a real
install it is the difference between a clear error now and three pods Pending for ever.
*/}}
{{- define "rancher-ha.checkNodes" -}}
{{- if .Values.nodeCheck.enabled -}}
{{- $nodes := (lookup "v1" "Node" "" "") -}}
{{- if $nodes -}}
{{- $count := len $nodes.items -}}
{{- if lt $count (int .Values.nodeCheck.minNodes) -}}
{{- fail (printf "rancher-ha needs a cluster with at least %d nodes and this one has %d. It runs %d Rancher replicas, one per node, so that losing a node leaves a majority. Set nodeCheck.enabled=false to install anyway." (int .Values.nodeCheck.minNodes) $count (int .Values.replicas)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Two things a virtual cluster needs from the host, both found the hard way.

A hostname, because several Ranchers on one cluster are told apart by the ingress controller on
Host and nothing else - the host-less catch-all rule that works for a single install would have
the first release swallow every request. And somewhere to put a volume, because the virtual
cluster's control plane keeps its state in a PVC, and a cluster with no default StorageClass
leaves it Pending with "pod has unbound immediate PersistentVolumeClaims".
*/}}
{{- define "rancher-ha.checkVcluster" -}}
{{- if .Values.virtualCluster -}}
{{- if not (include "rancher-ha.host" .) -}}
{{- fail "rancher-ha in virtual-cluster mode needs a hostname per release: several Ranchers on one cluster are told apart by the ingress controller on Host alone. Set ingress.host, or set ingress.baseDomain and each release answers on <release>.<baseDomain>." -}}
{{- end -}}
{{- if .Values.vclusterCheck.storageClass -}}
{{- $classes := (lookup "storage.k8s.io/v1" "StorageClass" "" "") -}}
{{- if $classes -}}
{{- if not $classes.items -}}
{{- fail "rancher-ha in virtual-cluster mode needs a default StorageClass: the virtual cluster keeps its control-plane state in a PVC, and this cluster has no StorageClass at all, so it would sit Pending. RKE2 and K3s ship none - rancher/local-path-provisioner is the usual answer. Set vclusterCheck.storageClass=false to skip this." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
