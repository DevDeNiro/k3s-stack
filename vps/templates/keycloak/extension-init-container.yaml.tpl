        # Extension image ${EXTENSION_IMAGE}
        # (snippet of extensions-pod.yaml.tpl). Image contract: sh and cp, themes
        # under /themes/<name>/, provider JARs under /providers/; only what exists
        # is copied. A tag is pulled once per node: publish a new tag for each change.
        - name: ${EXTENSION_NAME}
          image: "${EXTENSION_IMAGE}"
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - |
              set -e
              if [ -d /themes ]; then cp -R /themes/. /opt/keycloak/themes/; fi
              if [ -d /providers ]; then cp -R /providers/. /opt/keycloak/providers/; fi
          resources:
            requests:
              memory: "16Mi"
              cpu: "10m"
            limits:
              memory: "64Mi"
              cpu: "200m"
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            runAsNonRoot: true
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: keycloak-themes
              mountPath: /opt/keycloak/themes
            - name: keycloak-providers
              mountPath: /opt/keycloak/providers
