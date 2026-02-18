{{/*
==============================================================================
NETWORK POLICY TEMPLATE
Configurable ingress/egress rules for secure pod communication
Uses Gateway API namespace (nginx-gateway) for traffic from gateway
==============================================================================
*/}}

{{- define "common.networkPolicy" -}}
{{- if .Values.networkPolicy.enabled -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "common.labels.selector" . | nindent 6 }}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow traffic from Gateway (nginx-gateway namespace)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.networkPolicy.gatewayNamespace | default "nginx-gateway" }}
      ports:
        - protocol: TCP
          port: {{ .Values.service.targetPort | default .Values.service.port | default 8080 }}
    {{- if .Values.networkPolicy.allowMonitoring }}
    # Allow traffic from monitoring (Prometheus scraping)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.networkPolicy.monitoringNamespace | default "monitoring" }}
      ports:
        - protocol: TCP
          port: {{ .Values.service.targetPort | default .Values.service.port | default 8080 }}
    {{- end }}
    {{- with .Values.networkPolicy.extraIngress }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  egress:
    # Allow DNS
    - to: []
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    {{- if .Values.networkPolicy.allowDatabase }}
    # Allow connections to database
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.networkPolicy.databaseNamespace | default "storage" }}
      ports:
        - protocol: TCP
          port: {{ .Values.networkPolicy.databasePort | default 5432 }}
    {{- end }}
    {{- if .Values.networkPolicy.allowAuth }}
    # Allow connections to auth service (Keycloak)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.networkPolicy.authNamespace | default "security" }}
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 8080
    {{- end }}
    {{- if .Values.networkPolicy.allowOtel }}
    # Allow connections to OpenTelemetry collector
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.networkPolicy.monitoringNamespace | default "monitoring" }}
      ports:
        - protocol: TCP
          port: 4317
        - protocol: TCP
          port: 4318
    {{- end }}
    {{- if .Values.networkPolicy.allowExternal }}
    # Allow external HTTPS (for external APIs)
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 80
    {{- end }}
    {{- with .Values.networkPolicy.extraEgress }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
{{- end }}
{{- end }}
