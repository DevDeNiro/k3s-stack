{{/*
==============================================================================
RBAC TEMPLATES
ServiceAccount, Role, RoleBinding, ClusterRole
==============================================================================
*/}}

{{/*
ServiceAccount template
*/}}
{{- define "common.serviceAccount" -}}
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "common.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ .Values.serviceAccount.automount | default true }}
{{- end }}
{{- end }}

{{/*
RoleBinding template for namespace-scoped permissions
*/}}
{{- define "common.roleBinding" -}}
{{- if and .Values.rbac .Values.rbac.create -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "common.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
  {{- range .Values.rbac.extraSubjects }}
  - kind: {{ .kind }}
    name: {{ .name }}
    namespace: {{ .namespace | default $.Release.Namespace }}
  {{- end }}
roleRef:
  kind: {{ .Values.rbac.roleRef.kind | default "Role" }}
  name: {{ .Values.rbac.roleRef.name | default (include "common.fullname" .) }}
  apiGroup: rbac.authorization.k8s.io
{{- end }}
{{- end }}

{{/*
Role template for namespace-scoped permissions
*/}}
{{- define "common.role" -}}
{{- if and .Values.rbac .Values.rbac.create .Values.rbac.rules -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
rules:
  {{- toYaml .Values.rbac.rules | nindent 2 }}
{{- end }}
{{- end }}

{{/*
ClusterRole template for cluster-wide permissions
*/}}
{{- define "common.clusterRole" -}}
{{- if and .Values.rbac .Values.rbac.create .Values.rbac.clusterWide -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "common.fullname" . }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
rules:
  {{- if .Values.rbac.clusterRules }}
  {{- toYaml .Values.rbac.clusterRules | nindent 2 }}
  {{- else }}
  # Default read-only permissions
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  {{- end }}
{{- end }}
{{- end }}

{{/*
ClusterRoleBinding template
*/}}
{{- define "common.clusterRoleBinding" -}}
{{- if and .Values.rbac .Values.rbac.create .Values.rbac.clusterWide -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "common.fullname" . }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ include "common.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: {{ include "common.fullname" . }}
  apiGroup: rbac.authorization.k8s.io
{{- end }}
{{- end }}

{{/*
Full RBAC setup (ServiceAccount + Role + RoleBinding)
Usage: {{ include "common.rbac.full" . }}
*/}}
{{- define "common.rbac.full" -}}
{{ include "common.serviceAccount" . }}
{{- if and .Values.rbac .Values.rbac.create }}
---
{{ include "common.role" . }}
---
{{ include "common.roleBinding" . }}
{{- if .Values.rbac.clusterWide }}
---
{{ include "common.clusterRole" . }}
---
{{ include "common.clusterRoleBinding" . }}
{{- end }}
{{- end }}
{{- end }}
