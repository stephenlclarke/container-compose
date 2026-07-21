Output docs/images/container-compose-demo.gif

Set Shell "zsh"
Set FontSize 18
Set Width 1100
Set Height 720
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

Type "container system start --app-root $CONTAINER_APP_ROOT --install-root $CONTAINER_INSTALL_ROOT --enable-kernel-install --timeout 60 && container system status"
Enter
Wait+Screen@900s /status +running/
Sleep 2s
Ctrl+L
Sleep 1s

Type "container compose version"
Enter
Wait+Screen@30s /version/
Sleep 2s
Ctrl+L
Sleep 1s

Type "container compose --ansi never --progress plain -f examples/monitoring-stack/docker-compose.yaml up --detach --wait --wait-timeout 900 && container compose -f examples/monitoring-stack/docker-compose.yaml ps"
Enter
Wait+Screen@900s /alertmanager.*running/
Sleep 4s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml stats --no-stream"
Enter
Wait+Screen@90s /NAME/
Sleep 3s
Ctrl+L
Sleep 1s

Type "curl -4fsS --retry 30 --retry-all-errors --retry-connrefused --retry-delay 1 http://127.0.0.1:8080/healthz"
Enter
Wait+Screen@120s /ok/
Sleep 2s

Type "curl -4fsS --retry 30 --retry-all-errors --retry-connrefused --retry-delay 1 http://127.0.0.1:9093/alertmanager/-/ready"
Enter
Wait+Screen@120s /OK/
Sleep 2s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml exec --no-tty nginx sh -c 'echo container-compose-volume-reuse-ok > /var/cache/nginx/.container-compose-volume-reuse && cat /var/cache/nginx/.container-compose-volume-reuse'"
Enter
Wait+Screen@30s /container-compose-volume-reuse-ok/
Sleep 3s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml down --remove-orphans"
Enter
Wait+Screen@120s /Removed/
Sleep 4s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml volumes --format json"
Enter
Wait+Screen@30s /nginx_cache/
Sleep 4s
Ctrl+L
Sleep 1s

Type "container compose --ansi never --progress plain -f examples/monitoring-stack/docker-compose.yaml up --detach --wait --wait-timeout 900 && container compose -f examples/monitoring-stack/docker-compose.yaml ps"
Enter
Wait+Screen@900s /alertmanager.*running/
Sleep 5s
Ctrl+L
Sleep 1s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml stats --no-stream"
Enter
Wait+Screen@90s /NAME/
Sleep 3s
Ctrl+L
Sleep 1s

Type "curl -4fsS --retry 30 --retry-all-errors --retry-connrefused --retry-delay 1 http://127.0.0.1:8080/healthz"
Enter
Wait+Screen@120s /ok/
Sleep 2s

Type "curl -4fsS --retry 30 --retry-all-errors --retry-connrefused --retry-delay 1 http://127.0.0.1:9093/alertmanager/-/ready"
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

Type "container compose -f examples/monitoring-stack/docker-compose.yaml down --volumes --remove-orphans"
Enter
Wait+Screen@120s /Removed/
Sleep 4s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml ps --all"
Enter
Sleep 4s

Type "container system stop; container system status"
Enter
Wait+Screen@30s /not running/
Sleep 3s
