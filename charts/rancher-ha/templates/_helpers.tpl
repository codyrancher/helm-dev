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
Refuse a cluster that cannot hold the replicas, at template time, with a sentence.

`lookup` returns nothing during a dry run or a `helm template`, which is why the count is only
enforced when it actually answers - a rendering with no cluster behind it must not fail. On a
real install it is the difference between a clear error now and three pods Pending for ever.
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
Rancher has to be in cattle-system, and this is not a convention.

When it starts, Rancher registers the aggregated API `v1.ext.cattle.io` against a Service it
creates itself, always at cattle-system/imperative-api-extension, selecting its own pods by
label. A Service only selects pods in its own namespace, so a release in any other namespace
leaves that Service with no endpoints, the APIService permanently unavailable, and every page
of the UI replaced by the single line "API Aggregation not ready".

Nothing in the failure points at the namespace, which is why it is worth failing here instead.
*/}}
{{- define "rancher-ha.checkNamespace" -}}
{{- if ne .Release.Namespace "cattle-system" -}}
{{- fail (printf "rancher-ha must be installed into the cattle-system namespace, not %s. Rancher registers its aggregated API against cattle-system/imperative-api-extension, which cannot select pods in another namespace, and the UI comes up as \"API Aggregation not ready\". Reinstall with --namespace cattle-system --create-namespace." .Release.Namespace) -}}
{{- end -}}
{{- end -}}
