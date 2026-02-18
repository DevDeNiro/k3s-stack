{{/*
==============================================================================
NAMESPACE TEMPLATE
Creates namespace with optional ResourceQuota and LimitRange
==============================================================================
*/}}

{{- define "common.namespace" -}}
{{- if .Values.namespace.create -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
    app.kubernetes.io/environment: {{ .Values.namespace.environment | default .Values.global.environment | default "dev" }}
{{- end }}
{{- end }}

{{/*
ResourceQuota template
*/}}
{{- define "common.resourceQuota" -}}
{{- if and .Values.namespace.create .Values.namespace.resourceQuota.enabled -}}
apiVersion: v1
kind: ResourceQuota
metadata:
  name: {{ include "common.fullname" . }}-quota
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  hard:
    {{- toYaml .Values.namespace.resourceQuota.hard | nindent 4 }}
{{- end }}
{{- end }}

{{/*
LimitRange template
*/}}
{{- define "common.limitRange" -}}
{{- if and .Values.namespace.create .Values.namespace.limitRange.enabled -}}
apiVersion: v1
kind: LimitRange
metadata:
  name: {{ include "common.fullname" . }}-limits
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  limits:
    - type: Container
      default:
        {{- toYaml .Values.namespace.limitRange.default | nindent 8 }}
      defaultRequest:
        {{- toYaml .Values.namespace.limitRange.defaultRequest | nindent 8 }}
{{- end }}
{{- end }}

{{/*
Full namespace setup (namespace + quota + limits)
Usage: {{ include "common.namespace.full" . }}
*/}}
{{- define "common.namespace.full" -}}
{{ include "common.namespace" . }}
{{- if and .Values.namespace.create .Values.namespace.resourceQuota.enabled }}
---
{{ include "common.resourceQuota" . }}
{{- end }}
{{- if and .Values.namespace.create .Values.namespace.limitRange.enabled }}
---
{{ include "common.limitRange" . }}
{{- end }}
{{- end }}
