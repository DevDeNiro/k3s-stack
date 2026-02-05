{{/*
==============================================================================
SEALED SECRETS TEMPLATE
Encrypted secrets that can be safely committed to Git
Requires Sealed Secrets Controller in the cluster
==============================================================================
*/}}

{{- define "common.sealedSecrets" -}}
{{- if .Values.sealedSecrets.enabled }}

{{/*
Docker Registry Secret (for pulling private images)
Usage in values.yaml:
  sealedSecrets:
    enabled: true
    dockerRegistry:
      name: ghcr-secret
      encryptedData: "AgA..."
*/}}
{{- if and .Values.sealedSecrets.dockerRegistry .Values.sealedSecrets.dockerRegistry.encryptedData }}
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: {{ .Values.sealedSecrets.dockerRegistry.name | default "docker-registry-secret" }}
  namespace: {{ .Release.Namespace }}
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  encryptedData:
    .dockerconfigjson: {{ .Values.sealedSecrets.dockerRegistry.encryptedData | quote }}
  template:
    metadata:
      name: {{ .Values.sealedSecrets.dockerRegistry.name | default "docker-registry-secret" }}
      namespace: {{ .Release.Namespace }}
    type: kubernetes.io/dockerconfigjson
{{- end }}

{{/*
Generic Opaque Secrets
Usage in values.yaml:
  sealedSecrets:
    enabled: true
    secrets:
      - name: postgresql
        data:
          password: "AgB..."
          username: "AgC..."
      - name: keycloak-client
        data:
          client-secret: "AgD..."
*/}}
{{- range .Values.sealedSecrets.secrets }}
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: {{ .name }}
  namespace: {{ $.Release.Namespace }}
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
  labels:
    {{- include "common.labels.standard" $ | nindent 4 }}
spec:
  encryptedData:
    {{- range $key, $value := .data }}
    {{ $key }}: {{ $value | quote }}
    {{- end }}
  template:
    metadata:
      name: {{ .name }}
      namespace: {{ $.Release.Namespace }}
    type: Opaque
{{- end }}

{{- end }}
{{- end }}

{{/*
==============================================================================
LEGACY SEALED SECRETS TEMPLATE
For backward compatibility with coterie-webapp structure
==============================================================================
*/}}

{{- define "common.sealedSecrets.legacy" -}}
{{- if .Values.sealedSecrets.enabled }}

{{/* GHCR Docker Registry Secret */}}
{{- if and .Values.sealedSecrets.ghcr .Values.sealedSecrets.ghcr.encryptedData }}
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: ghcr-secret
  namespace: {{ .Release.Namespace }}
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  encryptedData:
    .dockerconfigjson: {{ .Values.sealedSecrets.ghcr.encryptedData | quote }}
  template:
    metadata:
      name: ghcr-secret
      namespace: {{ .Release.Namespace }}
    type: kubernetes.io/dockerconfigjson
{{- end }}

{{/* PostgreSQL Secret */}}
{{- if and .Values.sealedSecrets.postgresql .Values.sealedSecrets.postgresql.encryptedData }}
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: {{ .Values.database.existingSecret | default "postgresql" }}
  namespace: {{ .Release.Namespace }}
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  encryptedData:
    {{ .Values.database.secretKey | default "password" }}: {{ .Values.sealedSecrets.postgresql.encryptedData | quote }}
  template:
    metadata:
      name: {{ .Values.database.existingSecret | default "postgresql" }}
      namespace: {{ .Release.Namespace }}
    type: Opaque
{{- end }}

{{/* Keycloak Client Secret */}}
{{- if and .Values.sealedSecrets.keycloak .Values.sealedSecrets.keycloak.encryptedData }}
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: {{ .Values.keycloak.existingSecret | default "keycloak-client" }}
  namespace: {{ .Release.Namespace }}
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  encryptedData:
    {{ .Values.keycloak.secretKey | default "client-secret" }}: {{ .Values.sealedSecrets.keycloak.encryptedData | quote }}
  template:
    metadata:
      name: {{ .Values.keycloak.existingSecret | default "keycloak-client" }}
      namespace: {{ .Release.Namespace }}
    type: Opaque
{{- end }}

{{- end }}
{{- end }}
