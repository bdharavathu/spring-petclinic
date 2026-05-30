{{- define "petclinic.labels" -}}
app.kubernetes.io/name: petclinic
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: petclinic
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "petclinic.selectorLabels" -}}
app.kubernetes.io/name: petclinic
{{- end -}}

{{- define "postgres.selectorLabels" -}}
app.kubernetes.io/name: postgres
{{- end -}}
