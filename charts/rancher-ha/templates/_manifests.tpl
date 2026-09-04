{{/*
Everything that makes up the Rancher server, as one template.

It is written once and used two ways, which is why it is a template rather than a set of files:
rendered straight out into the release when this chart installs Rancher directly, and rendered
into a ConfigMap when it installs Rancher inside a virtual cluster - where a Job applies it on
the other side. Two copies of these manifests would drift within a week.

Namespaces come from `rancher-ha.targetNamespace`, not `.Release.Namespace`, because in
virtual-cluster mode the release lives in one namespace on the host and Rancher lives in
cattle-system on the inside.
*/}}
{{- define "rancher-ha.manifests" -}}
{{- $ns := include "rancher-ha.targetNamespace" . -}}
{{- $name := include "rancher-ha.fullname" . -}}
{{- $host := include "rancher-ha.host" . -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
{{ include "rancher-ha.labels" . | indent 4 }}
---
# Rancher is a controller of the cluster it runs in, and the upstream chart binds it to
# cluster-admin for exactly that reason. Copied rather than narrowed: a Rancher on a smaller
# role fails in ways that look like bugs in Rancher.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ $name }}
  labels:
{{ include "rancher-ha.labels" . | indent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ $name }}
    namespace: {{ $ns }}
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
# The password the first login uses. Rancher reads it while bootstrapping a cluster that has no
# admin yet and stores a hash, so changing it afterwards changes nothing.
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}-bootstrap
  namespace: {{ $ns }}
  labels:
{{ include "rancher-ha.labels" . | indent 4 }}
type: Opaque
stringData:
  bootstrapPassword: {{ required "adminPassword must not be empty" .Values.adminPassword | quote }}
---
# Two services, and the second is not decoration. The first is what the ingress sends traffic
# to. The second is how the replicas find each other: CATTLE_PEER_SERVICE names a service and
# Rancher reads its endpoints to learn the pods it shares leadership with. Without it, three
# replicas are three separate Ranchers.
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
{{ include "rancher-ha.labels" . | indent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
      name: http
    - port: 443
      targetPort: 443
      protocol: TCP
      name: https
  selector:
    app: {{ $name }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}-internal
  namespace: {{ $ns }}
  labels:
{{ include "rancher-ha.labels" . | indent 4 }}
spec:
  type: ClusterIP
  ports:
    - port: 443
      targetPort: 444
      protocol: TCP
      name: https-internal
  selector:
    app: {{ $name }}
---
# Rancher itself: three replicas, one per node.
#
# The anti-affinity is `required`, not `preferred`, and that is the whole of what makes this HA
# rather than three pods that might share a machine. It is also half of the node requirement -
# the other half is the check in _helpers.tpl, which says it in words.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
{{ include "rancher-ha.labels" . | indent 4 }}
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels:
      app: {{ $name }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: {{ $name }}
    spec:
      serviceAccountName: {{ $name }}
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - {{ $name }}
              topologyKey: kubernetes.io/hostname
      {{- with .Values.nodeSelector }}
      nodeSelector: {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations: {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: rancher
          image: {{ .Values.image | quote }}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
              protocol: TCP
            - containerPort: 443
              protocol: TCP
            - containerPort: 444
              protocol: TCP
            - containerPort: 6666
              protocol: TCP
          args:
            # TLS is terminated by the ingress controller in front of this, so Rancher neither
            # serves a CA of its own nor needs its trust store cleared for one.
            - --no-cacerts
            - --http-listen-port=80
            - --https-listen-port=443
            - --add-local={{ .Values.addLocal }}
          env:
            - name: CATTLE_NAMESPACE
              value: {{ $ns }}
            - name: CATTLE_PEER_SERVICE
              value: {{ $name }}
            - name: CATTLE_BOOTSTRAP_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ $name }}-bootstrap
                  key: bootstrapPassword
            - name: IMPERATIVE_API_DIRECT
              value: "true"
            - name: IMPERATIVE_API_APP_SELECTOR
              value: {{ $name }}
          startupProbe:
            httpGet: { path: /healthz, port: 80 }
            timeoutSeconds: 5
            periodSeconds: 10
            failureThreshold: 30
          livenessProbe:
            httpGet: { path: /healthz, port: 80 }
            timeoutSeconds: 5
            periodSeconds: 30
            failureThreshold: 5
          # Readiness is /healthz, and it has to be, however tempting the alternative looks.
          #
          # A replica answers `503 API Aggregation not ready` to every UI request until its own
          # view of the aggregated API is satisfied, while /healthz returns 200 throughout - so
          # probing a UI path instead would take the bad replica out of the Service. It also
          # deadlocks: that APIService is backed by cattle-system/imperative-api-extension, a
          # Service selecting these pods, and a Service only lists ready pods. Gate readiness on
          # the UI and no pod is ever ready, so the Service is empty, so the APIService is never
          # available, so the UI never comes up. Nothing starts, and the cause is invisible.
          #
          # The 503s are handled where they show up instead - see the ingress annotations.
          readinessProbe:
            httpGet: { path: /healthz, port: 80 }
            timeoutSeconds: 5
            periodSeconds: 15
            failureThreshold: 3
          {{- with .Values.resources }}
          resources: {{- toYaml . | nindent 12 }}
          {{- end }}
{{- if .Values.ingress.enabled }}
---
# How the browser gets in.
#
# In virtual-cluster mode this Ingress is created inside the virtual cluster and vCluster syncs
# it out to the host, where the real ingress controller serves it - which is why every release
# needs a hostname of its own: the controller tells them apart by Host and nothing else.
#
# The controller answers 443 with its own self-signed certificate, so the browser warns once
# and the session is still TLS - which matters, because Rancher sets secure cookies and a login
# over plain HTTP does not stick.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
{{ include "rancher-ha.labels" . | indent 4 }}
  annotations:
    # Rancher's own numbers. The long read timeout is what keeps its websockets - the shell, log
    # tailing, every live-updating page - from being cut at the proxy after a minute.
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "1800"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "1800"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    # A replica that is up but not yet serving the UI answers 503 rather than failing to
    # connect, and its readiness cannot be made to reflect that without deadlocking the
    # aggregated API it is waiting for (see the readiness probe). So the retry lives here: on a
    # 503 nginx tries the next replica instead of handing the visitor the error. Without it,
    # with three replicas, one request in three fails for as long as one of them is behind.
    nginx.ingress.kubernetes.io/proxy-next-upstream: "error timeout http_502 http_503"
    nginx.ingress.kubernetes.io/proxy-next-upstream-tries: "3"
    nginx.ingress.kubernetes.io/proxy-next-upstream-timeout: "30"
{{- with .Values.ingress.annotations }}
{{ toYaml . | indent 4 }}
{{- end }}
spec:
  {{- with .Values.ingress.className }}
  ingressClassName: {{ . }}
  {{- end }}
  rules:
    - {{ if $host }}host: {{ $host | quote }}
      {{ end }}http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ $name }}
                port:
                  number: 80
{{- end }}
{{- end -}}
