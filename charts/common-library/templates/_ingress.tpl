{{/*
==============================================================================
INGRESS TEMPLATE
Supports two modes:
1. Explicit hosts list (ingress.hosts) - like coterie
2. Auto-generated hostname (ingress.autoHost) - pattern: <service>.<env>.<domain>
==============================================================================
*/}}

{{- define "common.ingress" -}}
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
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
    {{- if .Values.ingress.hosts }}
    {{/* Mode 1: Explicit hosts list */}}
    {{- range .Values.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType | default "Prefix" }}
            backend:
              service:
                name: {{ include "common.fullname" $ }}
                port:
                  number: {{ $.Values.service.port | default 80 }}
          {{- end }}
    {{- end }}
    {{- else }}
    {{/* Mode 2: Auto-generated hostname */}}
    - host: {{ include "common.ingress.hostname" . | quote }}
      http:
        paths:
          - path: {{ .Values.ingress.path | default "/" }}
            pathType: {{ .Values.ingress.pathType | default "Prefix" }}
            backend:
              service:
                name: {{ include "common.fullname" . }}
                port:
                  number: {{ .Values.service.port | default 80 }}
    {{- end }}
{{- end }}
{{- end }}
