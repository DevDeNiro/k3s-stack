{{/*
Common namespace template
*/}}
{{ define "common.namespace" -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ include "common.namespace.name" . }}
  labels:
    {{ include "common.labels.standard" . | nindent 4 }}
    environment: {{ .Values.global.environment | default "dev" }}
    project: {{ .Values.global.project | default .Chart.Name }}
  annotations:
    created-by: {{ .Values.global.createdBy | default "helm" }}
{{- end }}

{{/*
Generate namespace name based on environment strategy
*/}}
{{ define "common.namespace.name" -}}
{{ if .Values.global.isMonoRepo -}}
{{ .Values.global.environment | default "dev" }}
{{ else -}}
{{ .Values.global.project | default .Chart.Name }}-{{ .Values.global.environment | default "dev" }}
{{ end -}}
{{- end }}
