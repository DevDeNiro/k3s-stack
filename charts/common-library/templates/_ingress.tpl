{{/*
Common ingress template with branch-based hostname
*/}}
{{ define "common.ingress" -}}
{{ if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ include "common.namespace.name" . }}
  labels:
    {{ include "common.labels.standard" . | nindent 4 }}
  annotations:
    {{- range $key, $value := .Values.ingress.annotations }}
    {{ $key }}: {{ $value | quote }}
    {{- end }}
spec:
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
                name: {{ include "common.fullname" . }}
                port:
                  number: {{ .Values.service.port | default 80 }}
{{- end }}
{{- end }}

{{/*
Generate ingress hostname following pattern: <service>.<env>.<base-domain>
*/}}
{{- define "common.ingress.hostname" -}}
{{- $serviceName := include "common.name" . -}}
{{- $environment := .Values.global.environment | default "dev" -}}
{{- $baseDomain := .Values.global.baseDomain | default "local" -}}
{{ printf "%s.%s.%s" $serviceName $environment $baseDomain }}
{{- end }}
