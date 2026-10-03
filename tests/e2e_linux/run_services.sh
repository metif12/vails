#!/bin/sh
# run_services.sh - build examples/services with -gc none, run it under xvfb
# with the requested probe, and screenshot the result into a file named after
# that probe.
#
# Same shape as run_headless.sh, but for the Phase 5 S1 proof runs: a probe
# drives one service and the page's status line reports what came back, so the
# screenshot is the round trip through the real backend with no human in the
# loop (ADR-0015 for clipboard/opener/notification, ADR-0017 for menu/tray).
#
#   VAILS_SERVICES_PROBE=clipboard sh run_services.sh   # -> services.png
#   VAILS_SERVICES_PROBE=menu      sh run_services.sh   # -> menu.png
#   VAILS_SERVICES_PROBE=tray      sh run_services.sh   # -> tray.png
#   VAILS_SERVICES_PROBE=opener    sh run_services.sh   # (no desktop handler in
#                                                       #  the container, so the
#                                                       #  status line shows the
#                                                       #  GIO error - that is the
#                                                       #  honest Linux answer)
#
# The output file is per-probe ON PURPOSE. It used to be a single services.png
# for every probe, which meant the last run silently overwrote every earlier
# proof: services.png and notification.png ended up byte-identical, and the
# clipboard round trip the README cites as proven had been destroyed by a later
# notification run. A proof that a later run can erase is not a proof.
set -u
V=/root/vsrc/v
PROJ=/mnt/d/MyProjects/vails
APP=/tmp/vails_services
SHOT=/tmp/services.xwd
LOG=/tmp/vails_services.log
PROBE=${VAILS_SERVICES_PROBE:-clipboard}

# clipboard is the historical name for that probe's screenshot; everything else
# is named after itself.
case $PROBE in
  clipboard) PNG=$PROJ/tests/e2e_linux/services.png ;;
  *)         PNG=$PROJ/tests/e2e_linux/$PROBE.png ;;
esac

# A window menu bar is not modal: nothing is "up" waiting to be dismissed, so
# the only way to photograph the proof is to click an item and let the page
# report the menu:clicked it received. That makes this probe the one thing here
# that is provable without a human - and it is provable *further* than the
# popup, because the bar is a normal widget in the window rather than an
# override-redirect one, so the click lands (the popup's does not: with no
# window manager under Xvfb it takes the first click as a focus click).
#
# The coordinates are the bar's own: it is packed at row 0, so "File" is the
# first item at the top-left. Fixed rather than discovered, because the bar's
# height is a GTK theme decision and a geometry search would be a race.
case $PROBE in
  menubar) PROBE_CLICK="xdotool mousemove 16 12 click 1; sleep 2" ;;
  *)       PROBE_CLICK=": " ;;
esac

# -gc none is required for GUI apps on this setup (ADR-0005); unset
# WAYLAND_DISPLAY / force x11 because WSLg would otherwise hijack the display.
$V -gc none -o $APP $PROJ/examples/services || exit 1
rm -f $SHOT $PNG /tmp/app.pid $LOG

xvfb-run -a -s '-screen 0 1100x1200x24' sh -c "
  unset WAYLAND_DISPLAY
  export GDK_BACKEND=x11 WEBKIT_DISABLE_COMPOSITING_MODE=1
  export VAILS_SERVICES_PROBE=$PROBE
  cd $PROJ
  $APP > $LOG 2>&1 &
  echo \$! > /tmp/app.pid
  sleep 12
  echo '--- xwininfo ---'
  xwininfo -root -tree | head -12
  echo '--- app alive ---'
  (kill -0 \$(cat /tmp/app.pid) && echo ALIVE || echo DEAD)
  $PROBE_CLICK
  xwd -root -silent -out $SHOT
  kill -KILL \$(cat /tmp/app.pid)
" || true

echo '--- app log ---'
cat $LOG || true
xwdtopnm < $SHOT | pnmtojpeg > $PNG
ls -la $PNG
