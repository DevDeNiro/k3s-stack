    # ${HOST} (snippet of gateway.yaml.tpl): only the HTTPRoutes of the namespaces
    # declared for it in GATEWAY_HOSTNAMES attach to this listener. The label
    # kubernetes.io/metadata.name is set by the API server and cannot be forged.
    - name: https-${HOST_SLUG}
      hostname: "${HOST}"
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: tls-${HOST_SLUG}
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchExpressions:
              - key: kubernetes.io/metadata.name
                operator: In
                values: [${ALLOWED_NAMESPACES}]
