        # ${ORGANIZATION} (snippet of applicationsets.yaml.tpl): repositories having a
        # develop branch with a helm/ directory. Every branch is listed and the filter
        # keeps develop: its conditions are combined (AND) and pathsExist is checked
        # on that branch. No glob patterns in pathsExist: the chart path is derived
        # from the repository name.
        -   scmProvider:
                # SCM providers default to 30 minutes, unlike Git generators (3 minutes).
                requeueAfterSeconds: 180
                github:
                    organization: ${ORGANIZATION}
                    tokenRef:
                        secretName: scm-token
                        key: token
                    allBranches: true
                cloneProtocol: https
                filters:
                    -   branchMatch: "^develop$"
                        pathsExist:
                            - helm
                values:
                    imageBase: ${IMAGE_BASE}
