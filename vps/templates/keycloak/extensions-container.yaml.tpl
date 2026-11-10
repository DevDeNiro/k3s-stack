          # Themes and providers copied by the initContainers (snippet of
          # keycloak.yaml.tpl): they replace the README files of the image directories
          volumeMounts:
            - name: keycloak-themes
              mountPath: /opt/keycloak/themes
            - name: keycloak-providers
              mountPath: /opt/keycloak/providers
