{{/*
==============================================================================
MIGRATION JOB TEMPLATE (ArgoCD PreSync Hook)
Runs database migrations BEFORE deployment via ArgoCD PreSync hook.
Supports: Liquibase (Spring Boot), Flyway, or custom commands.
==============================================================================
*/}}

{{- define "common.migrationJob" -}}
{{- if .Values.migration.enabled -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "common.fullname" . }}-migration-{{ .Release.Revision }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
    app.kubernetes.io/component: migration
  annotations:
    # ArgoCD PreSync hook - runs before main deployment
    argocd.argoproj.io/hook: PreSync
    # Delete job after successful completion
    argocd.argoproj.io/hook-delete-policy: {{ .Values.migration.hookDeletePolicy | default "HookSucceeded" }}
    {{- with .Values.migration.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  backoffLimit: {{ .Values.migration.backoffLimit | default 3 }}
  ttlSecondsAfterFinished: {{ .Values.migration.ttlSecondsAfterFinished | default 3600 }}
  template:
    metadata:
      labels:
        {{- include "common.labels.matchLabels" . | nindent 8 }}
        app.kubernetes.io/component: migration
    spec:
      restartPolicy: Never
      # Use default SA - the app's SA is created during Sync phase, after PreSync
      serviceAccountName: {{ .Values.migration.serviceAccountName | default "default" }}
      {{- with .Values.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: migration
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
          {{- with .Values.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if .Values.migration.command }}
          command:
            {{- toYaml .Values.migration.command | nindent 12 }}
          {{- end }}
          {{- if .Values.migration.args }}
          args:
            {{- toYaml .Values.migration.args | nindent 12 }}
          {{- end }}
          env:
            {{/* Database connection - common pattern */}}
            {{- if .Values.database }}
            - name: DATABASE_HOST
              value: {{ .Values.database.host | quote }}
            - name: DATABASE_PORT
              value: {{ .Values.database.port | default 5432 | quote }}
            - name: DATABASE_NAME
              value: {{ .Values.database.name | quote }}
            - name: DATABASE_USERNAME
              value: {{ .Values.database.username | quote }}
            - name: DATABASE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.database.existingSecret }}
                  key: {{ .Values.database.secretKey | default "password" }}
            {{- end }}
            {{/* Migration-specific env vars */}}
            {{- with .Values.migration.env }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
            {{/* Extra env vars from values */}}
            {{- with .Values.migration.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          {{- with .Values.migration.envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          resources:
            {{- if .Values.migration.resources }}
            {{- toYaml .Values.migration.resources | nindent 12 }}
            {{- else }}
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
            {{- end }}
          volumeMounts:
            # /tmp for readonly filesystem compatibility
            - name: tmp
              mountPath: /tmp
            {{- with .Values.migration.volumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
      volumes:
        - name: tmp
          emptyDir: {}
        {{- with .Values.migration.volumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
{{- end }}

{{/*
==============================================================================
SPRING BOOT MIGRATION JOB
Specialized template for Spring Boot + Liquibase/Flyway migrations
==============================================================================
*/}}
{{- define "common.migrationJob.springBoot" -}}
{{- if .Values.migration.enabled -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "common.fullname" . }}-migration-{{ .Release.Revision }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
    app.kubernetes.io/component: migration
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: {{ .Values.migration.hookDeletePolicy | default "HookSucceeded" }}
spec:
  backoffLimit: {{ .Values.migration.backoffLimit | default 3 }}
  ttlSecondsAfterFinished: {{ .Values.migration.ttlSecondsAfterFinished | default 3600 }}
  template:
    metadata:
      labels:
        {{- include "common.labels.matchLabels" . | nindent 8 }}
        app.kubernetes.io/component: migration
    spec:
      restartPolicy: Never
      serviceAccountName: {{ .Values.migration.serviceAccountName | default "default" }}
      {{- with .Values.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: migration
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
          {{- with .Values.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          env:
            # Spring profile for migrations
            # Uses migration.springProfile if set, otherwise falls back to app profile
            # Best practice: use a dedicated "migration" profile that disables web beans
            - name: SPRING_PROFILES_ACTIVE
              value: {{ .Values.migration.springProfile | default .Values.spring.profiles.active | default "prod" | quote }}
            # JDBC datasource for migrations
            - name: SPRING_DATASOURCE_URL
              value: "jdbc:postgresql://{{ .Values.database.host }}:{{ .Values.database.port | default 5432 }}/{{ .Values.database.name }}"
            - name: SPRING_DATASOURCE_USERNAME
              value: {{ .Values.database.username | quote }}
            - name: SPRING_DATASOURCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.database.existingSecret }}
                  key: {{ .Values.database.secretKey | default "password" }}
            # Disable web server - migration only
            - name: SPRING_MAIN_WEB_APPLICATION_TYPE
              value: "none"
            # Enable migration tool
            {{- if eq (.Values.migration.type | default "liquibase") "liquibase" }}
            - name: SPRING_LIQUIBASE_ENABLED
              value: "true"
            {{- else if eq .Values.migration.type "flyway" }}
            - name: SPRING_FLYWAY_ENABLED
              value: "true"
            {{- end }}
            # Exit after migrations
            - name: SPRING_MAIN_REGISTER_SHUTDOWN_HOOK
              value: "false"
            # JVM options
            - name: JAVA_OPTS
              value: {{ .Values.migration.javaOpts | default "-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0" | quote }}
            {{- with .Values.migration.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          resources:
            {{- if .Values.migration.resources }}
            {{- toYaml .Values.migration.resources | nindent 12 }}
            {{- else }}
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
            {{- end }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
{{- end }}
