#!/usr/bin/env ruby
# Structural checks on the rendered manifests. Never print Secret contents.
require "yaml"

render_dir, root = ARGV
abort "usage: #{$PROGRAM_NAME} <render-dir> <repo-root>" unless render_dir && root

def check(condition, message)
  abort "External chart check failed: #{message}" unless condition
end

def documents(dir, name)
  YAML.load_stream(File.read(File.join(dir, "#{name}.yaml"))).compact
end

def resource(docs, kind, name)
  result = docs.find { |d| d["kind"] == kind && d.dig("metadata", "name") == name }
  check(result, "#{kind}/#{name} missing")
  result
end

def pod_template(workload)
  workload.dig("spec", "template")
end

def container(workload, name)
  result = pod_template(workload).dig("spec", "containers").find { |c| c["name"] == name }
  check(result, "container #{name} missing")
  result
end

def service_selects(service, workload)
  selector = service.dig("spec", "selector") || {}
  labels = pod_template(workload).dig("metadata", "labels") || {}
  !selector.empty? && selector.all? { |key, value| labels[key] == value }
end

%w[vps local].each do |environment|
  pg = documents(render_dir, "#{environment}-postgresql")
  sts = resource(pg, "StatefulSet", "postgresql")
  pg_image = container(sts, "postgresql")["image"]
  digest = YAML.load_file(File.join(root, "vps/values/postgresql-image.yaml")).dig("image", "digest")
  check(digest && pg_image.include?(digest), "#{environment}: PostgreSQL digest changed")
  check(service_selects(resource(pg, "Service", "postgresql"), sts), "#{environment}: PostgreSQL Service selector")
  expected_size = environment == "vps" ? "10Gi" : "5Gi"
  claim = sts.dig("spec", "volumeClaimTemplates").find { |v| v.dig("metadata", "name") == "data" }
  check(claim && claim.dig("spec", "resources", "requests", "storage") == expected_size,
        "#{environment}: PostgreSQL PVC")
  check(pg.none? { |d| d["kind"] == "NetworkPolicy" }, "#{environment}: unexpected PostgreSQL chart NetworkPolicy")

  grafana = documents(render_dir, "#{environment}-grafana")
  deploy = resource(grafana, "Deployment", "grafana")
  check(service_selects(resource(grafana, "Service", "grafana"), deploy), "#{environment}: Grafana Service selector")
  if environment == "vps"
    env = container(deploy, "grafana").fetch("env", [])
    {"GF_SECURITY_ADMIN_USER" => "admin-user", "GF_SECURITY_ADMIN_PASSWORD" => "admin-password"}.each do |name, key|
      ref = env.find { |entry| entry["name"] == name }.to_h.dig("valueFrom", "secretKeyRef")
      check(ref && ref["name"] == "grafana-secret" && ref["key"] == key, "Grafana #{name} Secret reference")
    end
    resource(grafana, "PersistentVolumeClaim", "grafana")
    check(grafana.none? { |d| d["kind"] == "NetworkPolicy" }, "Grafana chart adds a NetworkPolicy")
  end

  sealed = documents(render_dir, "#{environment}-sealed-secrets")
  resource(sealed, "Deployment", "sealed-secrets-controller")
  resource(sealed, "CustomResourceDefinition", "sealedsecrets.bitnami.com")
  resource(documents(render_dir, "#{environment}-argocd"), "Deployment", "argocd-server")
  resource(documents(render_dir, "#{environment}-prometheus"), "Deployment", "prometheus-server")
end

prometheus = documents(render_dir, "vps-prometheus")
prometheus_config = resource(prometheus, "ConfigMap", "prometheus-server").fetch("data")
rule_files = YAML.load(prometheus_config.fetch("prometheus.yml")).fetch("rule_files")
check(rule_files.include?("/etc/config/alerting_rules.yml"), "Prometheus alert rule file")
rules = YAML.load(prometheus_config.fetch("alerting_rules.yml")).fetch("groups").flat_map { |g| g.fetch("rules") }
%w[KubePodCrashLooping KubeJobFailed AppScrapeDown].each do |name|
  check(rules.any? { |r| r["alert"] == name && !r["expr"].to_s.empty? }, "Prometheus alert #{name}")
end
alertmanager = YAML.load(resource(prometheus, "ConfigMap", "prometheus-alertmanager").dig("data", "alertmanager.yml"))
discord = alertmanager.fetch("receivers").find { |r| r["name"] == "discord" }
check(discord && discord.fetch("discord_configs").any? { |c|
  c["webhook_url_file"] == "/etc/alertmanager/secrets/discord/webhook-url"
}, "Alertmanager Discord webhook file")

loki = documents(render_dir, "vps-loki")
sts = resource(loki, "StatefulSet", "loki")
check(sts.dig("spec", "replicas") == 1 && sts.dig("spec", "serviceName") == "loki-headless", "Loki monolithic StatefulSet")
check(service_selects(resource(loki, "Service", "loki"), sts), "Loki Service selector")
resource(loki, "Service", "loki-headless")
claim = sts.dig("spec", "volumeClaimTemplates").find { |v| v.dig("metadata", "name") == "storage" }
check(claim && claim.dig("spec", "resources", "requests", "storage") == "5Gi", "Loki PVC template")
check(loki.none? { |d| d["kind"] == "NetworkPolicy" }, "Loki chart adds a NetworkPolicy")

alloy = documents(render_dir, "vps-alloy")
ds = resource(alloy, "DaemonSet", "alloy")
alloy_container = container(ds, "alloy")
check(alloy_container.fetch("args").include?("--storage.path=/var/lib/alloy"), "Alloy persistent storage path")
hostname = alloy_container.fetch("env").find { |entry| entry["name"] == "HOSTNAME" }
check(hostname.to_h.dig("valueFrom", "fieldRef", "fieldPath") == "spec.nodeName", "Alloy node-local discovery")
mounts = alloy_container.fetch("volumeMounts")
%w[/var/log/pods /var/lib/docker/containers /run/promtail].each do |path|
  check(mounts.any? { |m| m["mountPath"] == path && m["readOnly"] }, "Alloy read-only mount #{path}")
end
check(mounts.any? { |m| m["mountPath"] == "/var/lib/alloy" && !m["readOnly"] }, "Alloy positions mount")
volumes = pod_template(ds).dig("spec", "volumes")
check(volumes.any? { |v| v.dig("hostPath", "path") == "/var/lib/alloy" }, "Alloy host positions")
role = resource(alloy, "ClusterRole", "alloy")
check(role.fetch("rules").all? { |r| r["apiGroups"] == [""] && r["resources"] == ["pods"] &&
  (r["verbs"] - %w[get list watch]).empty? }, "Alloy RBAC must only read pods")
config = resource(alloy, "ConfigMap", "alloy").dig("data", "config.alloy")
check(config.include?('legacy_positions_file = "/run/promtail/positions.yaml"'), "Alloy legacy positions")
check(config.scan("stage.replace").size == 2 && config.include?("session_state") &&
  config.include?("id_token_hint") && config.include?("/stop/"), "Alloy redaction stages")
check(alloy.none? { |d| d["kind"] == "NetworkPolicy" }, "Alloy chart adds a NetworkPolicy")

cert = documents(render_dir, "vps-cert-manager")
resource(cert, "CustomResourceDefinition", "certificates.cert-manager.io")
updater = documents(render_dir, "vps-image-updater")
resource(updater, "Deployment", "argocd-image-updater-controller")
resource(updater, "CustomResourceDefinition", "imageupdaters.argocd-image-updater.argoproj.io")
puts "Structural assertions passed (PVCs, selectors, CRDs, Secrets references, Alloy mounts and RBAC)."
