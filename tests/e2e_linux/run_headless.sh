#!/bin/sh
# run_headless.sh — build hello with -gc none, run under xvfb, list windows, screenshot root.
set -u
V=/root/vsrc/v
PROJ=/mnt/d/MyProjects/vails
APP=/tmp/hello_nogc
SHOT=/tmp/shot.xwd
PNG=$PROJ/tests/e2e_linux/shot.png
LOG=/tmp/hello.log
$V -gc none -o $APP $PROJ/examples/hello
rm -f $SHOT $PNG /tmp/app.pid $LOG
xvfb-run -a -s '-screen 0 1280x800x24' sh -c "unset WAYLAND_DISPLAY; export GDK_BACKEND=x11 WEBKIT_DISABLE_COMPOSITING_MODE=1; $APP > $LOG 2>&1 & echo \$! > /tmp/app.pid; sleep 6; echo '--- xwininfo ---'; xwininfo -root -tree | head -20; echo '--- app alive ---'; (kill -0 \$(cat /tmp/app.pid) && echo ALIVE || echo DEAD); xwd -root -silent -out $SHOT; kill -KILL \$(cat /tmp/app.pid)" || true
echo '--- app log ---'
cat $LOG || true
xwdtopnm < $SHOT | pnmtojpeg > $PNG
ls -la $PNG
