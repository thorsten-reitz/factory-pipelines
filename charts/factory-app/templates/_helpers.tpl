{{- define "factory.labels" -}}
app.kubernetes.io/part-of: {{ .Values.project | quote }}
app.kubernetes.io/instance: {{ printf "%s-%s" .Values.project .Values.environment | quote }}
app.kubernetes.io/managed-by: factory-pipelines
{{- end }}

{{- define "factory.image" -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- end }}

{{- define "factory.pullSecrets" -}}
{{- if .Values.image.pullSecret }}
imagePullSecrets:
  - name: {{ .Values.image.pullSecret }}
{{- end }}
{{- end }}

{{/* Container für Backup, Restore und Restore-Test: Secrets und delivery.json als Dateien, Volumes unter /data */}}
{{- define "factory.backupVolumeMounts" -}}
- name: secrets
  mountPath: /run/secrets/app
  readOnly: true
- name: delivery
  mountPath: /etc/factory
  readOnly: true
{{- range .root.Values.volumes }}
- name: vol-{{ .name }}
  mountPath: /data/{{ .name }}
  readOnly: {{ $.readOnly }}
{{- end }}
{{- end }}

{{- define "factory.backupVolumes" -}}
- name: secrets
  secret:
    secretName: {{ .Values.secrets.name }}
- name: delivery
  configMap:
    name: factory-delivery
{{- range .Values.volumes }}
- name: vol-{{ .name }}
  persistentVolumeClaim:
    claimName: {{ .name }}
{{- end }}
{{- end }}

{{- define "factory.backupEnv" -}}
- name: PROJECT_ENV
  value: {{ printf "%s-%s" .Values.project .Values.environment | quote }}
{{- end }}
