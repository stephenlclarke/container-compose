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

Type "container system status"
Enter
Sleep 4s

Type "container system version"
Enter
Sleep 3s

Type "container compose version"
Enter
Sleep 3s

Type "container compose up --help | sed -n '1,18p'"
Enter
Sleep 3s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml down --volumes --remove-orphans"
Enter
Sleep 3s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml up --detach --wait --wait-timeout 120"
Enter
Sleep 6s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml stats --no-stream"
Enter
Sleep 4s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml ps"
Enter
Sleep 4s

Type "curl --fail --silent http://localhost:8080/healthz"
Enter
Sleep 3s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml down --volumes --remove-orphans && container compose -f examples/monitoring-stack/docker-compose.yaml ps --all"
Enter
Sleep 20s
