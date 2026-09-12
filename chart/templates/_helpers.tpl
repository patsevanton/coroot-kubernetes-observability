{{- define "coroot-demo-apps.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "coroot-demo-apps.labels" -}}
helm.sh/chart: {{ include "coroot-demo-apps.chart" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Полное имя образа: если repository уже содержит "/", реестр не добавляется. */}}
{{- define "coroot-demo-apps.image" -}}
{{- $repo := .repository -}}
{{- if not (contains "/" $repo) -}}
{{- $repo = printf "%s/%s" .registry $repo -}}
{{- end -}}
{{- printf "%s:%s" $repo .tag -}}
{{- end }}
