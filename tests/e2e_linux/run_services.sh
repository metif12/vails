#!/bin/sh
# run_services.sh - build examples/services with -gc none, run it under xvfb
# with the clipboard probe, and screenshot the result.
#
# Same shape as run_headless.sh, but for the Phase 5 S1 wave 2 proof: the page
# writes a known non-ASCII string to the GTK clipboard and reads it back, so
# the screenshot is the round trip through the real GTK clipboard with no
# human in the loop (ADR-0015).
#
#   VAILS_SERVICES_PROBE=clipboard ./run_services.sh
#   VAILS_SERVICES_PROBE=opener   ./run_services.sh   # (no desktop handler in
#                                                       #  the container, so the
#                                                       #  status line shows the
#                                                       #  GIO error - that is the
#                                                       #  honest Linux answer)
set -u
V=/root/vsrc/v
PROJ=/mnt/d/MyProjects/vails
APP=/tmp/vails_services
SHOT=/tmp/services.xwd
PNG=$PROJ/tests/e2e_linux/services.png
LOG=/tmp/vails_services.log
PROBE=${VAILS_SERVICES_PROBE:-clipboard}

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
  xwd -root -silent -out $SHOT
  kill -KILL \$(cat /tmp/app.pid)
" || true

echo '--- app log ---'
cat $LOG || true
xwdtopnm < $SHOT | pnmtojpeg > $PNG
ls -la $PNG
