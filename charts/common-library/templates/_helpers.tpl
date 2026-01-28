{{/*
Return release namespace
*/}}
{{- define "common.namespace.name" -}}
{{- $ctx := . -}}
{{- if .context -}}
{{- $ctx = .context -}}
{{- end -}}
{{- if and $ctx.Values $ctx.Values.global $ctx.Values.global.isMonoRepo -}}
{{ $ctx.Values.global.environment | default "dev" }}
{{- else -}}
{{- $project := "" -}}
{{- if and $ctx.Values $ctx.Values.global -}}
{{- $project = $ctx.Values.global.project -}}
{{- end -}}
{{- if not $project -}}
{{- if $ctx.Chart -}}
{{- $project = $ctx.Chart.Name -}}
{{- else -}}
{{- $project = "default" -}}
{{- end -}}
{{- end -}}
{{- $env := "dev" -}}
{{- if and $ctx.Values $ctx.Values.global $ctx.Values.global.environment -}}
{{- $env = $ctx.Values.global.environment -}}
{{- end -}}
{{ $project }}-{{ $env }}
{{- end -}}
{{- end }}

{{/*
Base name
*/}}
{{- define "common.name" -}}
{{- $ctx := . -}}
{{- if .context -}}
{{- $ctx = .context -}}
{{- end -}}
{{- $name := "" -}}
{{- if $ctx.Values -}}
{{- $name = $ctx.Values.nameOverride -}}
{{- end -}}
{{- if not $name -}}
{{- if $ctx.Chart -}}
{{- $name = $ctx.Chart.Name -}}
{{- else -}}
{{- $name = "default" -}}
{{- end -}}
{{- end -}}
{{ $name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name: release-name-servicename
*/}}
{{- define "common.fullname" -}}
{{- $ctx := . -}}
{{- if .context -}}
{{- $ctx = .context -}}
{{- end -}}
{{- if and $ctx.Values $ctx.Values.fullnameOverride -}}
{{- $ctx.Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := "" -}}
{{- if $ctx.Values -}}
{{- $name = $ctx.Values.nameOverride -}}
{{- end -}}
{{- if not $name -}}
{{- if $ctx.Chart -}}
{{- $name = $ctx.Chart.Name -}}
{{- else -}}
{{- $name = "default" -}}
{{- end -}}
{{- end -}}
{{- if contains $name $ctx.Release.Name -}}
{{- $ctx.Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" $ctx.Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Standard labels
*/}}
{{- define "common.labels.standard" -}}
{{- $ctx := . -}}
{{- if .context -}}
{{- $ctx = .context -}}
{{- end -}}
app.kubernetes.io/name: {{ include "common.name" $ctx }}
app.kubernetes.io/instance: {{ $ctx.Release.Name }}
{{- if $ctx.Chart }}
app.kubernetes.io/version: {{ $ctx.Chart.AppVersion | default $ctx.Chart.Version }}
{{- else }}
app.kubernetes.io/version: "0.1.0"
{{- end }}
app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
helm.sh/chart: {{ include "common.chart" $ctx }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "common.labels.selector" -}}
{{- $ctx := . -}}
{{- if .context -}}
{{- $ctx = .context -}}
{{- end -}}
app.kubernetes.io/name: {{ include "common.name" $ctx }}
app.kubernetes.io/instance: {{ $ctx.Release.Name }}
{{- end }}

{{/*
ServiceAccount
*/}}
{{- define "common.serviceAccountName" -}}
{{- if and .Values .Values.serviceAccount .Values.serviceAccount.create -}}
{{- default (include "common.name" .) .Values.serviceAccount.name -}}
{{- else if and .Values .Values.serviceAccount .Values.serviceAccount.name -}}
{{- .Values.serviceAccount.name -}}
{{- else -}}
default
{{- end -}}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "common.chart" -}}
{{- $ctx := . -}}
{{- if .context -}}
{{- $ctx = .context -}}
{{- end -}}
{{- if $ctx.Chart -}}
{{ printf "%s-%s" $ctx.Chart.Name $ctx.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- else -}}
{{ "default-chart" }}
{{- end -}}
{{- end }}

{{/*
Generate ingress hostname following pattern: <service>.<env>.<base-domain>
*/}}
{{- define "common.ingress.hostname" -}}
{{- $serviceName := include "common.name" . -}}
{{- $environment := "dev" -}}
{{- if and .Values .Values.global .Values.global.environment -}}
{{- $environment = .Values.global.environment -}}
{{- end -}}
{{- $baseDomain := "local" -}}
{{- if and .Values .Values.global .Values.global.baseDomain -}}
{{- $baseDomain = .Values.global.baseDomain -}}
{{- end -}}
{{ printf "%s.%s.%s" $serviceName $environment $baseDomain }}
{{- end }}

{{/*
Namespace template
*/}}
{{- define "common-library.namespace" -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ include "common.namespace.name" . }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
{{- end }}

{{/*
RBAC template
*/}}
{{- define "common-library.rbac" -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "common.serviceAccountName" . }}
  namespace: {{ include "common.namespace.name" . }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "common.fullname" . }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
rules:
- apiGroups: [""]
  resources: ["pods", "services", "endpoints"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "common.fullname" . }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "common.fullname" . }}
subjects:
- kind: ServiceAccount
  name: {{ include "common.serviceAccountName" . }}
  namespace: {{ include "common.namespace.name" . }}
{{- end }}

{{/*
Deployment template
*/}}
{{- define "common.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.fullname" . }}-{{ .serviceName }}
  namespace: {{ include "common.namespace.name" . }}
  labels:
    app.kubernetes.io/component: {{ .serviceName }}
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount | default 1 }}
  selector:
    matchLabels:
      app.kubernetes.io/component: {{ .serviceName }}
      {{- include "common.labels.selector" . | nindent 6 }}
  template:
    metadata:
      labels:
        app.kubernetes.io/component: {{ .serviceName }}
        {{- include "common.labels.selector" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "common.serviceAccountName" . }}
      containers:
        - name: {{ .serviceName }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort | default 3000 }}
              protocol: TCP
          {{- if .Values.healthcheck }}
          livenessProbe:
            httpGet:
              path: {{ .Values.healthcheck.path | default "/health" }}
              port: http
            initialDelaySeconds: {{ .Values.healthcheck.initialDelaySeconds | default 30 }}
            periodSeconds: {{ .Values.healthcheck.periodSeconds | default 10 }}
          readinessProbe:
            httpGet:
              path: {{ .Values.healthcheck.path | default "/health" }}
              port: http
            initialDelaySeconds: {{ .Values.healthcheck.initialDelaySeconds | default 5 }}
            periodSeconds: {{ .Values.healthcheck.periodSeconds | default 5 }}
          {{- end }}
          {{- if .Values.env }}
          env:
          {{- range $key, $value := .Values.env }}
            - name: {{ $key }}
              value: {{ $value | quote }}
          {{- end }}
          {{- end }}
          {{- if .Values.envSecrets }}
          envFrom:
            - secretRef:
                name: {{ include "common.fullname" . }}-{{ .serviceName }}-secrets
          {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
{{- end }}

{{/*
Service template
*/}}
{{- define "common.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "common.fullname" . }}-{{ .serviceName }}
  namespace: {{ include "common.namespace.name" . }}
  labels:
    app.kubernetes.io/component: {{ .serviceName }}
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort | default .Values.service.port }}
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/component: {{ .serviceName }}
    {{- include "common.labels.selector" . | nindent 4 }}
{{- end }}

{{/*
Ingress template
*/}}
{{- define "common-library.ingress" -}}
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "common.fullname" . }}-{{ .serviceName }}
  namespace: {{ include "common.namespace.name" . }}
  labels:
    app.kubernetes.io/component: {{ .serviceName }}
    {{- include "common.labels.standard" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if .Values.ingress.className }}
  ingressClassName: {{ .Values.ingress.className }}
  {{- end }}
  {{- if .Values.ingress.tls }}
  tls:
    {{- range .Values.ingress.tls }}
    - hosts:
        {{- range .hosts }}
        - {{ . | quote }}
        {{- end }}
      secretName: {{ .secretName }}
    {{- end }}
  {{- end }}
  rules:
    - host: {{ include "common.ingress.hostname" . }}
      http:
        paths:
          - path: {{ .Values.ingress.path | default "/" }}
            pathType: {{ .Values.ingress.pathType | default "Prefix" }}
            backend:
              service:
                name: {{ include "common.fullname" . }}-{{ .serviceName }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
{{- end }}
