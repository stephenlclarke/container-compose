process COLLECT_COMPOSE_PACKAGE_DEPENDENCIES {
    tag 'dependencies:compose-package'
    cache 'deep'
    errorStrategy 'terminate'

    input:
    path buildEvidence
    val validationReady
    path collector

    output:
    path 'compose-package-dependencies', emit: prepared

    script:
    "/bin/bash -p ${collector} ${validationReady}"
}
