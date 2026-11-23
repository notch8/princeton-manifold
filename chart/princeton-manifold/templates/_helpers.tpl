{{/*
Expand the name of the chart.
*/}}
{{- define "princeton-manifold.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "princeton-manifold.fullname" -}}
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
{{- define "princeton-manifold.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "princeton-manifold.labels" -}}
helm.sh/chart: {{ include "princeton-manifold.chart" . }}
{{ include "princeton-manifold.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "princeton-manifold.selectorLabels" -}}
app.kubernetes.io/name: {{ include "princeton-manifold.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "princeton-manifold.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "princeton-manifold.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create default fully qualified service names.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "princeton-manifold.redis.fullname" -}}
{{- printf "%s-%s" .Release.Name "redis" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "princeton-manifold.redis.host" -}}
{{- printf "%s-master" (include "princeton-manifold.redis.fullname" .) -}}
{{- end -}}

{{- define "princeton-manifold.redis.url" -}}
{{- printf "redis://:%s@%s:%s" .Values.redis.auth.password (include "princeton-manifold.redis.host" .) "6379/0" -}}
{{- end -}}

{{/*
Probes for a component: include with (dict "root" $ "probes" .Values.<component>.probes)
*/}}
{{- define "princeton-manifold.probes" -}}
{{- if .root.Values.startupProbe.enabled }}
startupProbe:
  {{- toYaml .probes.startup | nindent 2 }}
{{- end }}
{{- if .root.Values.livenessProbe.enabled }}
livenessProbe:
  {{- toYaml .probes.liveness | nindent 2 }}
{{- end }}
{{- if .root.Values.readinessProbe.enabled }}
readinessProbe:
  {{- toYaml .probes.readiness | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Env ConfigMap data, shared with the pre-upgrade hook copy
*/}}
{{- define "princeton-manifold.envData" -}}
ALLOW_SIGNUP: "false"
API_CABLE_HOST: {{ .Values.api.cable.host }}
API_CABLE_PORT: "3021"
API_HOST: {{ .Values.api.rails.host }}
API_PORT: "3020"
CLIENT_BROWSER_API_CABLE_URL: {{ .Values.client.browserApiCableUrl }}
CLIENT_BROWSER_API_URL: {{ .Values.client.browserApiUrl }}
CLIENT_SERVER_API_URL: {{ .Values.client.serverApiUrl }}
CLIENT_SERVER_HOST: {{ .Values.client.serverHost }}
CLIENT_SERVER_PORT: "3010"
CLIENT_SERVER_PROXIES: "true"
DOMAIN: {{ .Values.env.domain }}
ELASTICSEARCH_URL: {{ .Values.env.elasticsearchUrl }}
NODE_ENV: production
RAILS_DB_HOST: {{ .Values.env.railsDbHost }}
RAILS_DB_NAME: {{ .Values.postgresql.auth.database }}
RAILS_DB_PASS: {{ .Values.postgresql.auth.password }}
RAILS_DB_PORT: "5432"
RAILS_DB_USER: {{ .Values.postgresql.auth.username }}
RAILS_ENV: production
RAILS_REDIS_URL: {{ template "princeton-manifold.redis.url" . }}
RAILS_SECRET_KEY: {{ .Values.env.railsSecretKey }}
REDIS_URL: {{ template "princeton-manifold.redis.url" . }}
SENTRY_DSN: {{ .Values.env.sentryDsn }}
SENTRY_ENVIRONMENT: {{ .Values.env.sentryEnvironment }}
SSL_ENABLED: "true"
{{- end -}}
