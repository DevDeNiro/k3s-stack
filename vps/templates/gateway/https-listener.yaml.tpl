    # ${HOST} (snippet of gateway.yaml.tpl)
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
          from: All
