{{- define "code.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "code.fullname" -}}
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

{{- define "code.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "code.labels" -}}
helm.sh/chart: {{ include "code.chart" . }}
{{ include "code.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "code.selectorLabels" -}}
app.kubernetes.io/name: {{ include "code.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "code.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "code.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "code.headlessServiceName" -}}
{{- printf "%s-headless" (include "code.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Secrets are generated once and then preserved across upgrades by reading the
existing Secret back. Regenerating the release cookie on every `helm upgrade`
would partition the cluster; regenerating the admin token would lock out
whatever is holding the old one.
*/}}
{{- define "code.releaseCookie" -}}
{{- if .Values.releaseCookie }}
{{- .Values.releaseCookie }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-secrets" (include "code.fullname" .)) }}
{{- if and $existing $existing.data (index $existing.data "RELEASE_COOKIE") }}
{{- index $existing.data "RELEASE_COOKIE" | b64dec }}
{{- else }}
{{- randAlphaNum 48 }}
{{- end }}
{{- end }}
{{- end }}

{{- define "code.adminToken" -}}
{{- if .Values.adminToken }}
{{- .Values.adminToken }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-secrets" (include "code.fullname" .)) }}
{{- if and $existing $existing.data (index $existing.data "CODE_ADMIN_TOKEN") }}
{{- index $existing.data "CODE_ADMIN_TOKEN" | b64dec }}
{{- else }}
{{- randAlphaNum 48 }}
{{- end }}
{{- end }}
{{- end }}
