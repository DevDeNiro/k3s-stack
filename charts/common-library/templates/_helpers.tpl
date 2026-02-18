{{/*
==============================================================================
COMMON-LIBRARY HELM HELPERS
Reusable templates for K3s stack applications
==============================================================================
*/}}

{{/*
------------------------------------------------------------------------------
NAMING HELPERS
------------------------------------------------------------------------------
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncate at 63 chars (DNS naming spec limit).
*/}}
{{- define "common.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Generate namespace name.
Pattern: <project>-<environment> or just <environment> if isMonoRepo
*/}}
{{- define "common.namespace.name" -}}
{{- if .Values.global.isMonoRepo -}}
{{- .Values.global.environment | default "dev" }}
{{- else -}}
{{- $project := .Values.global.project | default .Chart.Name -}}
{{- $env := .Values.global.environment | default "dev" -}}
{{- printf "%s-%s" $project $env }}
{{- end -}}
{{- end }}

{{/*
------------------------------------------------------------------------------
LABELS
------------------------------------------------------------------------------
*/}}

{{/*
Standard labels for all resources
*/}}
{{- define "common.labels.standard" -}}
helm.sh/chart: {{ include "common.chart" . }}
{{ include "common.labels.selector" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.global }}
{{- if .Values.global.environment }}
app.kubernetes.io/environment: {{ .Values.global.environment }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Selector labels (used for pod selection)
*/}}
{{- define "common.labels.selector" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
------------------------------------------------------------------------------
SERVICE ACCOUNT
------------------------------------------------------------------------------
*/}}

{{/*
Create the name of the service account to use
*/}}
{{- define "common.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "common.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
------------------------------------------------------------------------------
LABELS (additional)
------------------------------------------------------------------------------
*/}}

{{/*
Match labels (alias for selector labels - used in migration job)
*/}}
{{- define "common.labels.matchLabels" -}}
{{ include "common.labels.selector" . }}
{{- end }}
