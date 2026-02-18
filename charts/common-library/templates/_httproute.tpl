{{/*
==============================================================================
HTTPROUTE TEMPLATE (Gateway API)
Supports two modes:
1. Explicit hostnames list (httpRoute.hostnames) - like coterie
2. Auto-generated hostname (httpRoute.autoHost) - pattern: <service>.<env>.<domain>

Replaces Ingress for Gateway API migration.
==============================================================================
*/}}

{{/*
Generate auto hostname for HTTPRoute
Pattern: <chart-name>.<environment>.<baseDomain>
*/}}
{{- define "common.httpRoute.hostname" -}}
{{- $env := .Values.global.environment | default "dev" -}}
{{- $domain := .Values.global.baseDomain | default "local" -}}
{{- $name := include "common.name" . -}}
{{- printf "%s.%s.%s" $name $env $domain -}}
{{- end }}

{{/*
Main HTTPRoute template
*/}}
{{- define "common.httpRoute" -}}
{{- if .Values.httpRoute.enabled -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
  {{- with .Values.httpRoute.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{/* Parent Gateway reference(s) */}}
  parentRefs:
    {{- if .Values.httpRoute.parentRefs }}
    {{- range .Values.httpRoute.parentRefs }}
    - name: {{ .name }}
      {{- if .namespace }}
      namespace: {{ .namespace }}
      {{- end }}
      {{- if .sectionName }}
      sectionName: {{ .sectionName }}
      {{- end }}
      {{- if .port }}
      port: {{ .port }}
      {{- end }}
    {{- end }}
    {{- else }}
    {{/* Default: infrastructure-gateway in nginx-gateway namespace */}}
    - name: {{ .Values.httpRoute.gatewayName | default "infrastructure-gateway" }}
      namespace: {{ .Values.httpRoute.gatewayNamespace | default "nginx-gateway" }}
    {{- end }}
  
  {{/* Hostnames */}}
  hostnames:
    {{- if .Values.httpRoute.hostnames }}
    {{/* Mode 1: Explicit hostnames list */}}
    {{- range .Values.httpRoute.hostnames }}
    - {{ . | quote }}
    {{- end }}
    {{- else }}
    {{/* Mode 2: Auto-generated hostname */}}
    - {{ include "common.httpRoute.hostname" . | quote }}
    {{- end }}
  
  {{/* Routing rules */}}
  rules:
    {{- if .Values.httpRoute.rules }}
    {{/* Custom rules provided */}}
    {{- range .Values.httpRoute.rules }}
    - {{- if .matches }}
      matches:
        {{- range .matches }}
        - {{- if .path }}
          path:
            type: {{ .path.type | default "PathPrefix" }}
            value: {{ .path.value | default "/" }}
          {{- end }}
          {{- if .headers }}
          headers:
            {{- toYaml .headers | nindent 12 }}
          {{- end }}
          {{- if .queryParams }}
          queryParams:
            {{- toYaml .queryParams | nindent 12 }}
          {{- end }}
          {{- if .method }}
          method: {{ .method }}
          {{- end }}
        {{- end }}
      {{- end }}
      {{- if .filters }}
      filters:
        {{- toYaml .filters | nindent 8 }}
      {{- end }}
      backendRefs:
        {{- if .backendRefs }}
        {{- range .backendRefs }}
        - name: {{ .name | default (include "common.fullname" $) }}
          port: {{ .port | default ($.Values.service.port | default 80) }}
          {{- if .weight }}
          weight: {{ .weight }}
          {{- end }}
        {{- end }}
        {{- else }}
        - name: {{ include "common.fullname" $ }}
          port: {{ $.Values.service.port | default 80 }}
        {{- end }}
    {{- end }}
    {{- else }}
    {{/* Default rule: path prefix "/" to service */}}
    - matches:
        - path:
            type: {{ .Values.httpRoute.pathType | default "PathPrefix" }}
            value: {{ .Values.httpRoute.path | default "/" }}
      backendRefs:
        - name: {{ include "common.fullname" . }}
          port: {{ .Values.service.port | default 80 }}
    {{- end }}
{{- end }}
{{- end }}

{{/*
HTTPRoute with HTTPS redirect companion
Creates both the main HTTPRoute and an HTTP->HTTPS redirect if TLS is implied
*/}}
{{- define "common.httpRoute.withRedirect" -}}
{{ include "common.httpRoute" . }}
{{- end }}
