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

# The release workflow executes this exact cycle against the matched packaged
# runtime before VHS starts. Each replay file contains the actual command and
# output; the separate marker read keeps VHS completion detection visible.
Type "cd $CONTAINER_COMPOSE_DEMO_ROOT || exit 1"
Enter
Sleep 2s

Set TypingSpeed 1ms
Type "replay() { cat $CONTAINER_COMPOSE_DEMO_TRANSCRIPT/$1; }; marker() { tail -n 1 $CONTAINER_COMPOSE_DEMO_TRANSCRIPT/$1; }; headlog() { sed -n '1,18p' $CONTAINER_COMPOSE_DEMO_TRANSCRIPT/$1; }; taillog() { tail -n 18 $CONTAINER_COMPOSE_DEMO_TRANSCRIPT/$1; }"
Enter
Sleep 1s
Ctrl+L
Sleep 1s
Set TypingSpeed 48ms

Type "replay 00-system-status.log"
Enter
Sleep 3s
Type "marker 00-system-status.log"
Enter
Wait+Screen@30s /TAPE_TRANSCRIPT_SYSTEM_OK/
Sleep 2s
Ctrl+L
Sleep 1s

Type "replay 01-compose-version.log"
Enter
Sleep 3s
Type "marker 01-compose-version.log"
Enter
Wait+Screen@30s /TAPE_TRANSCRIPT_VERSION_OK/
Sleep 2s
Ctrl+L
Sleep 1s

Type "headlog 02-first-up.log"
Enter
Sleep 4s
Ctrl+L
Sleep 1s
Type "taillog 02-first-up.log"
Enter
Sleep 4s
Type "marker 02-first-up.log"
Enter
Wait+Screen@300s /TAPE_TRANSCRIPT_FIRST_UP_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "replay 03-first-stats.log"
Enter
Sleep 4s
Type "marker 03-first-stats.log"
Enter
Wait+Screen@90s /TAPE_TRANSCRIPT_FIRST_STATS_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "replay 04-first-ps.log"
Enter
Sleep 4s
Type "marker 04-first-ps.log"
Enter
Wait+Screen@30s /TAPE_TRANSCRIPT_FIRST_PS_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "replay 05-first-health.log"
Enter
Sleep 4s
Type "marker 05-first-health.log"
Enter
Wait+Screen@120s /TAPE_TRANSCRIPT_FIRST_HEALTH_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "replay 06-retained-down.log"
Enter
Sleep 4s
Type "marker 06-retained-down.log"
Enter
Wait+Screen@120s /TAPE_TRANSCRIPT_RETAINED_DOWN_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "replay 07-retained-volumes.log"
Enter
Sleep 4s
Type "marker 07-retained-volumes.log"
Enter
Wait+Screen@30s /TAPE_TRANSCRIPT_VOLUMES_RETAINED_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "headlog 08-second-up.log"
Enter
Sleep 4s
Ctrl+L
Sleep 1s
Type "taillog 08-second-up.log"
Enter
Sleep 4s
Type "marker 08-second-up.log"
Enter
Wait+Screen@300s /TAPE_TRANSCRIPT_SECOND_UP_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "replay 09-second-stats.log"
Enter
Sleep 4s
Type "marker 09-second-stats.log"
Enter
Wait+Screen@90s /TAPE_TRANSCRIPT_SECOND_STATS_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "replay 10-second-ps.log"
Enter
Sleep 4s
Type "marker 10-second-ps.log"
Enter
Wait+Screen@30s /TAPE_TRANSCRIPT_SECOND_PS_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "replay 11-second-health.log"
Enter
Sleep 4s
Type "marker 11-second-health.log"
Enter
Wait+Screen@120s /TAPE_TRANSCRIPT_SECOND_HEALTH_OK/
Sleep 3s
Ctrl+L
Sleep 1s

Type "replay 12-final-down.log"
Enter
Sleep 4s
Type "marker 12-final-down.log"
Enter
Wait+Screen@120s /TAPE_TRANSCRIPT_FINAL_DOWN_OK/
Sleep 5s
