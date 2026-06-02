{{/*
Release / table-derived names. The Service is always `engine-{table}` so the
SDK's default resolver template (`engine-{table}.{ns}.svc:9090`) resolves to
it without any per-table override.
*/}}

{{- define "table-pipeline.fullname" -}}
{{- printf "engine-%s" (required "values.table is required" .Values.table | replace "_" "-" | lower) -}}
{{- end -}}

{{- define "table-pipeline.labels" -}}
app.kubernetes.io/name: {{ include "table-pipeline.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: engine
app.kubernetes.io/part-of: micewriter
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
micewriter.io/table: {{ .Values.table | quote }}
{{- end -}}

{{- define "table-pipeline.selectorLabels" -}}
app.kubernetes.io/name: {{ include "table-pipeline.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
