        # ${ORGANIZATION} (snippet of applicationsets.yaml.tpl): repositories whose
        # default branch holds a helm/ directory; the Applications follow main. No
        # glob patterns in pathsExist: the chart path is derived from the repository name.
        -   scmProvider:
                github:
                    organization: ${ORGANIZATION}
                    tokenRef:
                        secretName: scm-token
                        key: token
                    allBranches: false
                cloneProtocol: https
                filters:
                    -   pathsExist:
                            - helm
                values:
                    imageBase: ${IMAGE_BASE}
