Output docs/images/container-compose-demo.gif

Set Shell "zsh"
Set FontSize 18
Set Width 1600
Set Height 720
Set Framerate 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 48ms
Set Padding 24
Set Margin 0
Set MarginFill "#0b1020"

# This recording drives the packaged matched runtime directly.  Every command
# shown below is typed into the terminal and its live result remains visible;
# the screen waits only for output produced by that command.
Type "cd $CONTAINER_COMPOSE_DEMO_ROOT || exit 1"
Enter
Sleep 2s

Type "(container system start --app-root $CONTAINER_APP_ROOT --install-root $CONTAINER_INSTALL_ROOT --init-image-archive $CONTAINER_COMPOSE_DEMO_INIT_IMAGE_ARCHIVE --enable-kernel-install --timeout 60 || { sleep 5; container system start --app-root $CONTAINER_APP_ROOT --install-root $CONTAINER_INSTALL_ROOT --init-image-archive $CONTAINER_COMPOSE_DEMO_INIT_IMAGE_ARCHIVE --enable-kernel-install --timeout 60; }) && engine_status= && for attempt in {1..6}; do engine_status=$(python3 $CONTAINER_COMPOSE_DEMO_DEADLINE_RUNNER --seconds 10 --grace-seconds 2 -- container system status --format json 2>/dev/null | /usr/bin/plutil -extract engineStatus raw -o - - 2>/dev/null) || true; [[ $engine_status == running ]] && break; sleep 2; done; [[ $engine_status == running ]] && printf '\nContainer Engine %s\ncontainer-compose-system-%s\n' running ready || { printf '\ncontainer-compose-system-%s\n' failed; exit 1; }"
Enter
Wait+Screen@300s /container-compose-system-(ready|failed)/
Sleep 2s
Ctrl+L
Sleep 1s

Type "container compose version"
Enter
Wait+Screen@30s /container-compose [0-9]/
Sleep 2s
Ctrl+L
Sleep 1s

# Keep the first cold image pulls visible so the recording never appears idle.
Type "container compose --ansi never --progress plain -f examples/monitoring-stack/docker-compose.yaml up --detach --wait --wait-timeout 900 nginx alertmanager && clear && container compose -f examples/monitoring-stack/docker-compose.yaml ps"
Enter
Wait+Screen@900s /nginx.*r[[:space:]]*unning/
Sleep 4s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml stats --no-stream nginx alertmanager"
Enter
Wait+Screen@90s /CONTAINER ID/
Sleep 3s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml exec --no-tty nginx wget -qO- http://127.0.0.1/healthz"
Enter
Wait+Screen@120s /ok/
Sleep 2s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml exec --no-tty alertmanager wget -qO- http://127.0.0.1:9093/alertmanager/-/ready"
Enter
Wait+Screen@120s /OK/
Sleep 2s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml exec --no-tty nginx sh -c 'echo container-compose-volume-reuse-''ok > /var/cache/nginx/.container-compose-volume-reuse && cat /var/cache/nginx/.container-compose-volume-reuse'"
Enter
Wait+Screen@30s /container-compose-volume-reuse-ok/
Sleep 3s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml down --remove-orphans && clear && container compose -f examples/monitoring-stack/docker-compose.yaml volumes --format json"
Enter
Wait+Screen@120s /nginx_cache/
Sleep 4s
Ctrl+L
Sleep 1s

Type "container compose --ansi never --progress plain -f examples/monitoring-stack/docker-compose.yaml up --detach --wait --wait-timeout 900 --quiet-pull nginx alertmanager && clear && container compose -f examples/monitoring-stack/docker-compose.yaml ps"
Enter
Wait+Screen@900s /nginx.*r[[:space:]]*unning/
Sleep 5s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml stats --no-stream nginx alertmanager"
Enter
Wait+Screen@90s /CONTAINER ID/
Sleep 3s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml exec --no-tty nginx wget -qO- http://127.0.0.1/healthz"
Enter
Wait+Screen@120s /ok/
Sleep 2s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml exec --no-tty alertmanager wget -qO- http://127.0.0.1:9093/alertmanager/-/ready"
Enter
Wait+Screen@120s /OK/
Sleep 2s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml exec --no-tty nginx cat /var/cache/nginx/.container-compose-volume-reuse"
Enter
Wait+Screen@30s /container-compose-volume-reuse-ok/
Sleep 3s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml down --volumes --remove-orphans && project_containers=$(container compose -f examples/monitoring-stack/docker-compose.yaml ps --all --quiet) && project_volumes=$(container compose -f examples/monitoring-stack/docker-compose.yaml volumes --quiet) && [[ -z $project_containers && -z $project_volumes ]] && printf '\nProject containers and volumes %s\n' removed"
Enter
Wait+Screen@120s /Project containers and volumes removed/
Sleep 3s
Ctrl+L
Sleep 1s

Type "container system stop; container system status"
Enter
Wait+Screen@30s /not running/
Sleep 3s
