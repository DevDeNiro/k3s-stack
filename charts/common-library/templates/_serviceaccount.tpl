{{/*
==============================================================================
SERVICEACCOUNT TEMPLATE
Creates a ServiceAccount with optional annotations and automount configuration
==============================================================================
*/}}

{{/*
Get the ServiceAccount name
*/}}
{{- define "common.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{- default (include "common.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
    {{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
Main ServiceAccount template
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
