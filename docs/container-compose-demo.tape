Output docs/images/container-compose-demo.gif

Set Shell "zsh"
Set FontSize 18
Set Width 1000
Set Height 620
Set Theme "Catppuccin Mocha"
Set TypingSpeed 24ms
Set Padding 24
Set Margin 0
Set MarginFill "#0b1020"

Type "container system version"
Enter
Sleep 2s

Type "container compose version"
Enter
Sleep 2s

Type "container compose up --help | sed -n '1,18p'"
Enter
Sleep 2s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml down --dry-run --volumes --remove-orphans"
Enter
Sleep 2s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml up --dry-run --wait"
Enter
Sleep 3s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml ps --dry-run"
Enter
Sleep 2s

Type "container compose -f examples/monitoring-stack/docker-compose.yaml down --dry-run --volumes --remove-orphans"
Enter
Sleep 2s
