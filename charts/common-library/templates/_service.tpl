{{/*
Common service template
*/}}
{{ define "common.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ include "common.namespace.name" . }}
  labels:
    {{ include "common.labels.standard" . | nindent 4 }}
spec:
  type: {{ .Values.service.type | default "ClusterIP" }}
  ports:
    - port: {{ .Values.service.port | default 80 }}
      targetPort: {{ .Values.service.targetPort | default 3333 }}
      protocol: TCP
      name: http
  selector:
    {{ include "common.labels.selector" . | nindent 4 }}
{{- end }}
