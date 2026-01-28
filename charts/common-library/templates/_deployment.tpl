{{/*
Common deployment template
*/}}
{{ define "common.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ include "common.namespace.name" . }}
  labels:
    {{ include "common.labels.standard" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount | default 1 }}
  selector:
    matchLabels:
      {{ include "common.labels.selector" . | nindent 6 }}
  template:
    metadata:
      annotations:
        {{- with .Values.podAnnotations }}
        {{ toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{ include "common.labels.selector" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "common.serviceAccountName" . }}
      {{- with .Values.podSecurityContext }}
      securityContext:
        {{ toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .Chart.Name }}
          {{- with .Values.securityContext }}
          securityContext:
            {{ toYaml . | nindent 12 }}
          {{- end }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort | default 3333 }}
              protocol: TCP
          livenessProbe:
            httpGet:
              path: {{ .Values.healthcheck.path | default "/health" }}
              port: http
            initialDelaySeconds: {{ .Values.healthcheck.initialDelaySeconds | default 30 }}
            periodSeconds: {{ .Values.healthcheck.periodSeconds | default 10 }}
          readinessProbe:
            httpGet:
              path: {{ .Values.healthcheck.path | default "/health" }}
              port: http
            initialDelaySeconds: {{ .Values.healthcheck.initialDelaySeconds | default 5 }}
            periodSeconds: {{ .Values.healthcheck.periodSeconds | default 5 }}
          {{- with .Values.resources }}
          resources:
            {{ toYaml . | nindent 12 }}
          {{- end }}
          env:
            {{- range $key, $value := .Values.env }}
            - name: {{ $key }}
              value: {{ $value | quote }}
            {{- end }}
            {{- range $key, $value := .Values.envSecrets }}
            - name: {{ $key }}
              valueFrom:
                secretKeyRef:
                  name: {{ include "common.fullname" $ }}-secrets
                  key: {{ $key }}
            {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{ toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{ toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{ toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
