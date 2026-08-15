{{/*
Общие метки
*/}}
{{- define "golden-signal-app.labels" -}}
app: golden-signal-app-{{ .Values.team }}
team: {{ .Values.team }}
{{- end }}

{{/*
Селектор меток
*/}}
{{- define "golden-signal-app.selectorLabels" -}}
app: golden-signal-app-{{ .Values.team }}
team: {{ .Values.team }}
{{- end }}

{{/*
Имя приложения
*/}}
{{- define "golden-signal-app.name" -}}
golden-signal-app-{{ .Values.team }}
{{- end }}