#!/usr/bin/env ruby
# Check the ApplicationSet template and ImageUpdater resources without a cluster.
require "yaml"

vps = File.expand_path("..", __dir__)
template = File.read(File.join(vps, "templates/argocd/applicationsets.yaml.tpl"))
%w[alpha prod].each do |environment|
  variable = "#{environment.upcase}_GENERATORS"
  placeholder = "${#{variable}}"
  abort "Missing #{placeholder}" unless template.include?(placeholder)
  generator = File.read(File.join(vps, "templates/argocd/generator-#{environment}.yaml.tpl"))
  generator = generator.gsub("${ORGANIZATION}", "example-org").gsub("${IMAGE_BASE}", "ghcr.io/example-org")
  template = template.gsub(placeholder, generator)
end

sets = YAML.load_stream(template).compact.to_h { |item| [item.dig("metadata", "name"), item] }
updaters = YAML.load_stream(File.read(File.join(vps, "manifests/argocd-image-updaters.yaml"))).compact
prefix = "argocd-image-updater.argoproj.io"

def check(condition, message)
  abort "GitOps configuration check failed: #{message}" unless condition
end

{"alpha" => "develop", "prod" => "main"}.each do |environment, branch|
  set = sets.fetch("autodiscover-#{environment}")
  generator = set.dig("spec", "generators").first.fetch("scmProvider")
  check(generator["requeueAfterSeconds"] == 180, "#{environment}: SCM polling interval")
  check(generator.dig("github", "organization") == "example-org" &&
        generator.dig("values", "imageBase") == "ghcr.io/example-org", "#{environment}: organization rendering")
  application = set.dig("spec", "template")
  annotations = application.dig("metadata", "annotations")
  check(annotations["#{prefix}/image-list"] == "app={{values.imageBase}}/{{repository}}",
        "#{environment}: image alias or repository")
  check(annotations["#{prefix}/app.force-update"] == "true", "#{environment}: bootstrap image updates")
  check(annotations["#{prefix}/app.update-strategy"] == "newest-build", "#{environment}: update strategy")
  check(annotations["#{prefix}/app.allow-tags"] == "regexp:^#{branch}-[a-f0-9]{40}$",
        "#{environment}: immutable branch tag filter")
  check(annotations["#{prefix}/app.helm.image-name"] == "image.repository" &&
        annotations["#{prefix}/app.helm.image-tag"] == "image.tag", "#{environment}: Helm image mapping")
  check(annotations["#{prefix}/write-back-method"] == "argocd", "#{environment}: write-back method")
  check(application.dig("spec", "source", "targetRevision") == branch, "#{environment}: Git branch")
  parameters = application.dig("spec", "source", "helm", "parameters")
  check(parameters.any? { |p| p["name"] == "image.tag" && p["value"] == branch },
        "#{environment}: initial image tag")
  ignored = set.dig("spec", "ignoreApplicationDifferences").flat_map { |rule| rule.fetch("jsonPointers", []) }
  check(ignored.include?("/spec/source/helm/parameters"), "#{environment}: preserve image updater parameters")
  updater = updaters.find { |item| item.dig("metadata", "name") == "image-updater-#{environment}" }
  ref = updater&.dig("spec", "applicationRefs")&.first
  check(ref && ref["namePattern"] == "*-#{environment}" && ref["useAnnotations"] == true,
        "#{environment}: ImageUpdater annotation mode")
end

alpha = sets.fetch("autodiscover-alpha").dig("spec", "template", "spec", "syncPolicy", "automated")
prod = sets.fetch("autodiscover-prod")
check(alpha && alpha["prune"] == true && alpha["selfHeal"] == true, "alpha: automatic sync")
check(prod.dig("spec", "template", "spec", "syncPolicy", "automated").nil?, "prod: must remain manual")
check(prod.dig("spec", "syncPolicy", "preserveResourcesOnDeletion") == true, "prod: preserve resources on deletion")
puts "GitOps template checks passed (SCM polling, bootstrap image updates, tag filters, sync policies)."
