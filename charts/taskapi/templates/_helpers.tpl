{{/* Base name, e.g. "taskapi". */}}
{{- define "taskapi.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Full name of the API resources. */}}
{{- define "taskapi.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Name of the PostgreSQL resources. */}}
{{- define "taskapi.dbname" -}}
{{- printf "%s-postgresql" (include "taskapi.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels shared by every resource (Kubernetes recommended labels). */}}
{{- define "taskapi.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/part-of: taskapi
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.environment }}
{{- end -}}

{{/* Selector labels: must never change after the first install. */}}
{{- define "taskapi.apiSelectorLabels" -}}
app.kubernetes.io/name: {{ include "taskapi.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api
{{- end -}}

{{- define "taskapi.dbSelectorLabels" -}}
app.kubernetes.io/name: postgresql
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: database
{{- end -}}

{{- define "taskapi.imageTag" -}}
{{- required "image.tag is required (CI writes it in environments/<env>/values.yaml)" .Values.image.tag -}}
{{- end -}}

{{- define "taskapi.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "taskapi.imageTag" .) -}}
{{- end -}}
