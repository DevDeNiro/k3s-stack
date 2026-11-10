      # Extension images (KEYCLOAK_EXTENSION_IMAGES, snippet of keycloak.yaml.tpl):
      # the initContainers run in order, a later image overwrites the files of an
      # earlier one. ${PULL_SECRET} holds the GHCR credentials of
      # export-secrets.sh set-scm-credentials; public images do not need it.
      imagePullSecrets:
        - name: ${PULL_SECRET}
      initContainers:
${INIT_CONTAINERS}
      volumes:
        - name: keycloak-themes
          emptyDir:
            sizeLimit: 256Mi
        - name: keycloak-providers
          emptyDir:
            sizeLimit: 256Mi
