{{/*
Common ServiceAccount template
*/}}
{{ define "common.serviceAccount" -}}
{{ if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "common.serviceAccountName" . }}
  namespace: {{ include "common.namespace.name" . }}
  labels:
    {{ include "common.labels.standard" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{ toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ .Values.serviceAccount.automount | default false }}
{{- end }}
{{- end }}

{{/*
Common dev-role RoleBinding template for GitLab CI integration
*/}}
{{ define "common.roleBinding" -}}
{{ if .Values.rbac.create -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "common.fullname" . }}-dev-role
  namespace: {{ include "common.namespace.name" . }}
  labels:
    {{ include "common.labels.standard" . | nindent 4 }}
subjects:
- kind: ServiceAccount
  name: {{ include "common.serviceAccountName" . }}
  namespace: {{ include "common.namespace.name" . }}
- kind: ServiceAccount
  name: gitlab-runner
  namespace: gitlab-runner
roleRef:
  kind: ClusterRole
  name: dev-role
  apiGroup: rbac.authorization.k8s.io
{{- end }}
{{- end }}

{{/*
Common ClusterRole for dev environments
*/}}
{{ define "common.clusterRole" -}}
{{ if and .Values.rbac.create .Values.rbac.createClusterRole -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dev-role
  labels:
    {{ include "common.labels.standard" . | nindent 4 }}
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "create"]
{{- end }}
{{- end }}
