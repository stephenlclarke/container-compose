//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ComposeCore

/// Docker Compose CLI help text captured from Docker Compose 5.2.0.
enum ComposeCLIHelp {
    /// Prints Docker Compose compatible help when the invocation asks for it.
    static func renderIfRequested(arguments: [String]) -> Bool {
        let rewritten = ComposeArgumentRewriter.rewrite(arguments)
        guard rewritten.contains("--help") || rewritten.contains("-h") else {
            return false
        }

        let command = commandPath(in: rewritten)
        if command == ["bridge"] {
            print(bridgeHelp)
            return true
        }
        if command.count == 1, let help = commandHelp[command[0]] {
            print(help)
            return true
        }

        print(rootHelp)
        return true
    }

    private static func commandPath(in arguments: [String]) -> [String] {
        var path: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                break
            }
            if commandNames.contains(argument) {
                path.append(argument)
                if argument == "bridge", arguments.indices.contains(index + 1) {
                    let next = arguments[index + 1]
                    if !next.hasPrefix("-"), next != "--help", next != "-h" {
                        path.append(next)
                    }
                }
                break
            }
            if consumesGlobalValue(argument), !argument.contains("="), arguments.indices.contains(index + 1) {
                index += 2
            } else {
                index += 1
            }
        }
        return path
    }

    private static func consumesGlobalValue(_ argument: String) -> Bool {
        let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        return [
            "--ansi",
            "--env-file",
            "--file",
            "--parallel",
            "--profile",
            "--progress",
            "--project-directory",
            "--project-name",
            "-f",
            "-p",
        ].contains(name)
    }

    private static let commandNames: Set<String> = [
        "attach",
        "bridge",
        "build",
        "commit",
        "config",
        "cp",
        "create",
        "down",
        "events",
        "exec",
        "export",
        "images",
        "kill",
        "logs",
        "ls",
        "pause",
        "port",
        "ps",
        "publish",
        "pull",
        "push",
        "restart",
        "rm",
        "run",
        "scale",
        "start",
        "stats",
        "stop",
        "top",
        "unpause",
        "up",
        "version",
        "volumes",
        "wait",
        "watch",
    ]

    private static let rootHelp = """
    Usage:  container compose [OPTIONS] COMMAND

    Define and run multi-container applications with Docker

    Options:
          --all-resources              Include all resources, even those not used by services
          --ansi string                Control when to print ANSI control characters ("never"|"always"|"auto") (default "auto")
          --compatibility              Run compose in backward compatibility mode
          --dry-run                    Execute command in dry run mode
          --env-file stringArray       Specify an alternate environment file
      -f, --file stringArray           Compose configuration files
          --parallel int               Control max parallelism, -1 for unlimited (default -1)
          --profile stringArray        Specify a profile to enable
          --progress string            Set type of progress output (auto, tty, plain, json, quiet)
          --project-directory string   Specify an alternate working directory
      -p, --project-name string        Project name

    Management Commands:
      bridge                  Convert compose files into another model

    Commands:
      attach                  Attach local standard input, output, and error streams to a service's running container
      build                   Build or rebuild services
      commit                  Create a new image from a service container's changes
      config                  Parse, resolve and render compose file in canonical format
      cp                      Copy files/folders between a service container and the local filesystem
      create                  Creates containers for a service
      down                    Stop and remove containers, networks
      events                  Receive real time events from containers
      exec                    Execute a command in a running container
      export                  Export a service container's filesystem as a tar archive
      images                  List images used by the created containers
      kill                    Force stop service containers
      logs                    View output from containers
      ls                      List running compose projects
      pause                   Pause services
      port                    Print the public port for a port binding
      ps                      List containers
      publish                 Publish compose application
      pull                    Pull service images
      push                    Push service images
      restart                 Restart service containers
      rm                      Removes stopped service containers
      run                     Run a one-off command on a service
      scale                   Scale services
      start                   Start services
      stats                   Display a live stream of container(s) resource usage statistics
      stop                    Stop services
      top                     Display the running processes
      unpause                 Unpause services
      up                      Create and start containers
      version                 Show the Docker Compose version information
      volumes                 List volumes
      wait                    Block until containers of all (or specified) services stop.
      watch                   Watch build context for service and rebuild/refresh containers when files are updated

    Run 'container compose COMMAND --help' for more information on a command.
    """

    private static let bridgeHelp = """
    Usage:  container compose bridge [OPTIONS] COMMAND

    Convert compose files into another model

    Options:
          --dry-run   Execute command in dry run mode

    Management Commands:
      transformations Manage transformation images

    Commands:
      convert         Convert compose files to Kubernetes manifests, Helm charts, or another model

    Run 'container compose bridge COMMAND --help' for more information on a command.
    """

    private static let commandHelp: [String: String] = [
        "attach": """
        Usage:  container compose attach [OPTIONS] SERVICE

        Attach local standard input, output, and error streams to a service's running container

        Options:
              --detach-keys string   Override the key sequence for detaching from a container.
              --dry-run              Execute command in dry run mode
              --index int            index of the container if service has multiple replicas.
              --no-stdin             Do not attach STDIN
              --sig-proxy            Proxy all received signals to the process (default true)
        """,
        "build": """
        Usage:  container compose build [OPTIONS] [SERVICE...]

        Build or rebuild services

        Options:
              --build-arg stringArray   Set build-time variables for services
              --builder string          Set builder to use
              --check                   Check build configuration
              --dry-run                 Execute command in dry run mode
          -m, --memory bytes            Set memory limit for the build container. Not supported by BuildKit.
              --no-cache                Do not use cache when building the image
              --print                   Print equivalent bake file
              --provenance string       Add a provenance attestation
              --pull                    Always attempt to pull a newer version of the image
              --push                    Push service images
          -q, --quiet                   Suppress the build output
              --sbom string             Add a SBOM attestation
              --ssh string              Set SSH authentications used when building service images. (use 'default' for using your default SSH Agent)
              --with-dependencies       Also build dependencies (transitively)
        """,
        "commit": """
        Usage:  container compose commit [OPTIONS] SERVICE [REPOSITORY[:TAG]]

        Create a new image from a service container's changes

        Options:
          -a, --author string    Author
          -c, --change list      Apply Dockerfile instruction to the created image
              --dry-run          Execute command in dry run mode
              --index int        index of the container if service has multiple replicas.
          -m, --message string   Commit message
          -p, --pause            Pause container during commit (default true)
        """,
        "config": """
        Usage:  container compose config [OPTIONS] [SERVICE...]

        Parse, resolve and render compose file in canonical format

        Options:
              --dry-run                 Execute command in dry run mode
              --environment             Print environment used for interpolation.
              --format string           Format the output. Values: [yaml | json]
              --hash string             Print the service config hash, one per line.
              --images                  Print the image names, one per line.
              --lock-image-digests      Produces an override file with image digests
              --models                  Print the model names, one per line.
              --networks                Print the network names, one per line.
              --no-consistency          Don't check model consistency
              --no-env-resolution       Don't resolve service env files
              --no-interpolate          Don't interpolate environment variables
              --no-normalize            Don't normalize compose model
              --no-path-resolution      Don't resolve file paths
          -o, --output string           Save to file
              --profiles                Print the profile names, one per line.
          -q, --quiet                   Only validate the configuration
              --resolve-image-digests   Pin image tags to digests
              --services                Print the service names, one per line.
              --variables               Print model variables and default values.
              --volumes                 Print the volume names, one per line.
        """,
        "cp": """
        Usage:  container compose cp [OPTIONS] SERVICE:SRC_PATH DEST_PATH|-
                container compose cp [OPTIONS] SRC_PATH|- SERVICE:DEST_PATH

        Copy files/folders between a service container and the local filesystem

        Options:
              --all           Include containers created by the run command
          -a, --archive       Archive mode (copy all uid/gid information)
              --dry-run       Execute command in dry run mode
          -L, --follow-link   Always follow symbol link in SRC_PATH
              --index int     Index of the container if service has multiple replicas
        """,
        "create": """
        Usage:  container compose create [OPTIONS] [SERVICE...]

        Creates containers for a service

        Options:
              --build            Build images before starting containers
              --dry-run          Execute command in dry run mode
              --force-recreate   Recreate containers even if their configuration and image haven't changed
              --no-build         Don't build an image, even if it's policy
              --no-recreate      If containers already exist, don't recreate them. Incompatible with --force-recreate.
              --pull string      Pull image before running ("always"|"missing"|"never"|"build") (default "policy")
              --quiet-pull       Pull without printing progress information
              --remove-orphans   Remove containers for services not defined in the Compose file
              --scale scale      Scale SERVICE to NUM instances. Overrides the scale setting in the Compose file if present.
          -y, --yes              Assume "yes" as answer to all prompts and run non-interactively
        """,
        "down": """
        Usage:  container compose down [OPTIONS] [SERVICES]

        Stop and remove containers, networks

        Options:
              --dry-run          Execute command in dry run mode
              --remove-orphans   Remove containers for services not defined in the Compose file
              --rmi string       Remove images used by services. ("local"|"all")
          -t, --timeout int      Specify a shutdown timeout in seconds
          -v, --volumes          Remove named volumes declared in the "volumes" section of the Compose file and anonymous volumes attached to containers
        """,
        "events": """
        Usage:  container compose events [OPTIONS] [SERVICE...]

        Receive real time events from containers

        Options:
              --dry-run        Execute command in dry run mode
              --json           Output events as a stream of json objects
              --since string   Show all events created since timestamp
              --until string   Stream events until this timestamp
        """,
        "exec": """
        Usage:  container compose exec [OPTIONS] SERVICE COMMAND [ARGS...]

        Execute a command in a running container

        Options:
          -d, --detach            Detached mode: Run command in the background
              --dry-run           Execute command in dry run mode
          -e, --env stringArray   Set environment variables
              --index int         Index of the container if service has multiple replicas
          -T, --no-tty            Disable pseudo-TTY allocation
              --privileged        Give extended privileges to the process
          -u, --user string       Run the command as this user
          -w, --workdir string    Path to workdir directory for this command
        """,
        "export": """
        Usage:  container compose export [OPTIONS] SERVICE

        Export a service container's filesystem as a tar archive

        Options:
              --dry-run         Execute command in dry run mode
              --index int       index of the container if service has multiple replicas.
          -o, --output string   Write to a file, instead of STDOUT
        """,
        "images": """
        Usage:  container compose images [OPTIONS] [SERVICE...]

        List images used by the created containers

        Options:
              --dry-run         Execute command in dry run mode
              --format string   Format the output. Values: [table | json] (default "table")
          -q, --quiet           Only display IDs
        """,
        "kill": """
        Usage:  container compose kill [OPTIONS] [SERVICE...]

        Force stop service containers

        Options:
              --dry-run          Execute command in dry run mode
              --remove-orphans   Remove containers for services not defined in the Compose file
          -s, --signal string    SIGNAL to send to the container (default "SIGKILL")
        """,
        "logs": """
        Usage:  container compose logs [OPTIONS] [SERVICE...]

        View output from containers

        Options:
              --dry-run         Execute command in dry run mode
          -f, --follow          Follow log output
              --index int       index of the container if service has multiple replicas
              --no-color        Produce monochrome output
              --no-log-prefix   Don't print prefix in logs
              --since string    Show logs since timestamp or relative duration
          -n, --tail string     Number of lines to show from the end of the logs for each container (default "all")
          -t, --timestamps      Show timestamps
              --until string    Show logs before a timestamp or relative duration
        """,
        "ls": """
        Usage:  container compose ls [OPTIONS]

        List running compose projects

        Options:
          -a, --all             Show all stopped Compose projects
              --dry-run         Execute command in dry run mode
              --filter filter   Filter output based on conditions provided
              --format string   Format the output. Values: [table | json] (default "table")
          -q, --quiet           Only display project names
        """,
        "pause": """
        Usage:  container compose pause [SERVICE...]

        Pause services

        Options:
              --dry-run   Execute command in dry run mode
        """,
        "port": """
        Usage:  container compose port [OPTIONS] SERVICE PRIVATE_PORT

        Print the public port for a port binding

        Options:
              --dry-run           Execute command in dry run mode
              --index int         Index of the container if service has multiple replicas
              --protocol string   tcp or udp (default "tcp")
        """,
        "ps": """
        Usage:  container compose ps [OPTIONS] [SERVICE...]

        List containers

        Options:
          -a, --all                  Show all stopped containers
              --dry-run              Execute command in dry run mode
              --filter string        Filter services by a property (supported filters: status)
              --format string        Format output using a custom template (default "table")
              --no-trunc             Don't truncate output
              --orphans              Include orphaned services (default true)
          -q, --quiet                Only display IDs
              --services             Display services
              --status stringArray   Filter services by status
        """,
        "publish": """
        Usage:  container compose publish [OPTIONS] REPOSITORY[:TAG]

        Publish compose application

        Options:
              --app                     Published compose application
              --dry-run                 Execute command in dry run mode
              --oci-version string      OCI image/artifact specification version
              --resolve-image-digests   Pin image tags to digests
              --with-env                Include environment variables in the published OCI artifact
          -y, --yes                     Assume "yes" as answer to all prompts
        """,
        "pull": """
        Usage:  container compose pull [OPTIONS] [SERVICE...]

        Pull service images

        Options:
              --dry-run                Execute command in dry run mode
              --ignore-buildable       Ignore images that can be built
              --ignore-pull-failures   Pull what it can and ignores images with pull failures
              --include-deps           Also pull services declared as dependencies
              --policy string          Apply pull policy ("missing"|"always")
          -q, --quiet                  Pull without printing progress information
        """,
        "push": """
        Usage:  container compose push [OPTIONS] [SERVICE...]

        Push service images

        Options:
              --dry-run                Execute command in dry run mode
              --ignore-push-failures   Push what it can and ignores images with push failures
              --include-deps           Also push images of services declared as dependencies
          -q, --quiet                  Push without printing progress information
        """,
        "restart": """
        Usage:  container compose restart [OPTIONS] [SERVICE...]

        Restart service containers

        Options:
              --dry-run       Execute command in dry run mode
              --no-deps       Don't restart dependent services
          -t, --timeout int   Specify a shutdown timeout in seconds
        """,
        "rm": """
        Usage:  container compose rm [OPTIONS] [SERVICE...]

        Removes stopped service containers

        Options:
              --dry-run   Execute command in dry run mode
          -f, --force     Don't ask to confirm removal
          -s, --stop      Stop the containers, if required, before removing
          -v, --volumes   Remove any anonymous volumes attached to containers
        """,
        "run": """
        Usage:  container compose run [OPTIONS] SERVICE [COMMAND] [ARGS...]

        Run a one-off command on a service

        Options:
              --build                       Build image before starting container
              --cap-add list                Add Linux capabilities
              --cap-drop list               Drop Linux capabilities
          -d, --detach                      Run container in background and print container ID
              --dry-run                     Execute command in dry run mode
              --entrypoint string           Override the entrypoint of the image
          -e, --env stringArray             Set environment variables
              --env-from-file stringArray   Set environment variables from file
          -i, --interactive                 Keep STDIN open even if not attached (default true)
          -l, --label stringArray           Add or override a label
              --name string                 Assign a name to the container
          -T, --no-TTY                      Disable pseudo-TTY allocation (default true)
              --no-deps                     Don't start linked services
          -p, --publish stringArray         Publish a container's port(s) to the host
              --pull string                 Pull image before running ("always"|"missing"|"never") (default "policy")
          -q, --quiet                       Don't print anything to STDOUT
              --quiet-build                 Suppress progress output from the build process
              --quiet-pull                  Pull without printing progress information
              --remove-orphans              Remove containers for services not defined in the Compose file
              --rm                          Automatically remove the container when it exits
          -P, --service-ports               Run command with all service's ports enabled and mapped to the host
              --use-aliases                 Use the service's network aliases
          -u, --user string                 Run as specified username or uid
          -v, --volume stringArray          Bind mount a volume
          -w, --workdir string              Working directory inside the container
        """,
        "scale": """
        Usage:  container compose scale [SERVICE=REPLICAS...]

        Scale services

        Options:
              --dry-run   Execute command in dry run mode
              --no-deps   Don't start linked services
        """,
        "start": """
        Usage:  container compose start [SERVICE...]

        Start services

        Options:
              --dry-run            Execute command in dry run mode
              --wait               Wait for services to be running|healthy. Implies detached mode.
              --wait-timeout int   Maximum duration in seconds to wait for the project to be running|healthy
        """,
        "stats": """
        Usage:  container compose stats [OPTIONS] [SERVICE]

        Display a live stream of container(s) resource usage statistics

        Options:
          -a, --all             Show all containers (default shows just running)
              --dry-run         Execute command in dry run mode
              --format string   Format output using a custom template
              --no-stream       Disable streaming stats and only pull the first result
              --no-trunc        Do not truncate output
        """,
        "stop": """
        Usage:  container compose stop [OPTIONS] [SERVICE...]

        Stop services

        Options:
              --dry-run       Execute command in dry run mode
          -t, --timeout int   Specify a shutdown timeout in seconds
        """,
        "top": """
        Usage:  container compose top [SERVICES...]

        Display the running processes

        Options:
              --dry-run   Execute command in dry run mode
        """,
        "unpause": """
        Usage:  container compose unpause [SERVICE...]

        Unpause services

        Options:
              --dry-run   Execute command in dry run mode
        """,
        "up": """
        Usage:  container compose up [OPTIONS] [SERVICE...]

        Create and start containers

        Options:
              --abort-on-container-exit      Stops all containers if any container was stopped. Incompatible with -d
              --abort-on-container-failure   Stops all containers if any container exited with failure. Incompatible with -d
              --always-recreate-deps         Recreate dependent containers. Incompatible with --no-recreate.
              --attach stringArray           Restrict attaching to the specified services
              --attach-dependencies          Automatically attach to log output of dependent services
              --build                        Build images before starting containers
          -d, --detach                       Detached mode: Run containers in the background
              --dry-run                      Execute command in dry run mode
              --exit-code-from string        Return the exit code of the selected service container
              --force-recreate               Recreate containers even if their configuration and image haven't changed
              --menu                         Enable interactive shortcuts when running attached
              --no-attach stringArray        Do not attach to the specified services
              --no-build                     Don't build an image, even if it's policy
              --no-color                     Produce monochrome output
              --no-deps                      Don't start linked services
              --no-log-prefix                Don't print prefix in logs
              --no-recreate                  If containers already exist, don't recreate them
              --no-start                     Don't start the services after creating them
              --pull string                  Pull image before running ("always"|"missing"|"never") (default "policy")
              --quiet-build                  Suppress the build output
              --quiet-pull                   Pull without printing progress information
              --remove-orphans               Remove containers for services not defined in the Compose file
          -V, --renew-anon-volumes           Recreate anonymous volumes instead of retrieving data from previous containers
              --scale scale                  Scale SERVICE to NUM instances
          -t, --timeout int                  Use this timeout in seconds for container shutdown
              --timestamps                   Show timestamps
              --wait                         Wait for services to be running|healthy. Implies detached mode.
              --wait-timeout int             Maximum duration in seconds to wait for the project to be running|healthy
          -w, --watch                        Watch source code and rebuild/refresh containers when files are updated
          -y, --yes                          Assume "yes" as answer to all prompts and run non-interactively
        """,
        "version": """
        Usage:  container compose version [OPTIONS]

        Show the Docker Compose version information

        Options:
              --dry-run         Execute command in dry run mode
          -f, --format string   Format the output. Values: [pretty | json]. (Default: pretty)
              --short           Shows only Compose's version number
        """,
        "volumes": """
        Usage:  container compose volumes [OPTIONS] [SERVICE...]

        List volumes

        Options:
              --dry-run         Execute command in dry run mode
              --format string   Format output using a custom template (default "table")
          -q, --quiet           Only display volume names
        """,
        "wait": """
        Usage:  container compose wait SERVICE [SERVICE...] [OPTIONS]

        Block until containers of all (or specified) services stop.

        Options:
              --down-project   Drops project when the first container stops
              --dry-run        Execute command in dry run mode
        """,
        "watch": """
        Usage:  container compose watch [SERVICE...]

        Watch build context for service and rebuild/refresh containers when files are updated

        Options:
              --dry-run   Execute command in dry run mode
              --no-up     Do not build & start services before watching
              --prune     Prune dangling images on rebuild (default true)
              --quiet     hide build output
        """,
    ]
}
