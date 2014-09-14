#!/bin/bash
# vim: set fdm=marker:

# Minecraft server management script
# 
# Copyright (c) 2013-2014 Scott Zeid.  Released under the X11 License.  
# <http://code.s.zeid.me/minecraft-server-manager>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
# 
# Except as contained in this notice, the name(s) of the above copyright holders
# shall not be used in advertising or otherwise to promote the sale, use or
# other dealings in this Software without prior written authorization.

# Configuration file parsing #########################################{{{1

# Select user configuration file, using the -c/--config command-line
# flag first, then the default value `./manager.conf`, where .
# is the directory in which this script is contained.
if grep -qe '^-\(c\|-config=\).\+' <<< "$1"; then
 USER_CONFIG_FILE=$(sed -e 's/^-\(c\|-config=\)//' <<< "$1")
 shift
elif [ "$1" = "-c" -o "$1" = "--config" ]; then
 USER_CONFIG_FILE=$2
 shift 2
fi
if [ -z "$USER_CONFIG_FILE" ]; then
 USER_CONFIG_FILE="$(dirname "$0")"/manager.conf
fi

# For each array-type configuration option, declare two arrays:
# a defaults one and a user one.  The user one will then be
# copied to the end of the defaults one, and the defaults array
# will then be re-used as the final value.
declare -a JAVA_OPTS JAVA_OPTS_USER
declare -a EXTRA_WINDOWS EXTRA_WINDOWS_USER

# Convenience functions to add values to the arrays.  These are
# used in the config files.
function default_java_opt() {
 JAVA_OPTS[${#JAVA_OPTS[@]}]="$1"
}
function java_opt() {
 JAVA_OPTS_USER[${#JAVA_OPTS_USER[@]}]="$1"
}
function default_extra_window() {
 EXTRA_WINDOWS[${#EXTRA_WINDOWS[@]}]="$1"
}
function extra_window() {
 EXTRA_WINDOWS_USER[${#EXTRA_WINDOWS_USER[@]}]="$1"
}

# Load user settings
[ -e "$USER_CONFIG_FILE" ] && . "$USER_CONFIG_FILE"

# Load default settings
. "$(dirname "$0")"/manager.conf.defaults

# Append user Java options to $JAVA_OPTS
# so that the defaults come first
for (( i = 0; i < ${#JAVA_OPTS_USER[@]}; i++ )); do
 default_java_opt "${JAVA_OPTS_USER[i]}"
done
# Append user extra windows to $EXTRA_WINDOWS
# so that the defaults come first
for (( i = 0; i < ${#EXTRA_WINDOWS_USER[@]}; i++ )); do
 default_extra_window "${EXTRA_WINDOWS_USER[i]}"
done

# Helper functions ###################################################{{{1

function tmux() {
 env tmux -L "$SOCKET_NAME" "$@"
}

function tmux-option() {
 if [ "$1" = "--debug" -o "$CB_DEBUG" = "1" ]; then
  shift
  tmux set-option -t "$SESSION_NAME" "$@"
 else
  tmux set-option -t "$SESSION_NAME" "$@" > /dev/null
 fi
}

function setup-tmux() {
 tmux bind-key -n C-c detach-client
 tmux-option status-bg "$STATUS_BG"
 tmux-option status-fg "$STATUS_FG"
 tmux-option status-position "$STATUS_POSITION"
 tmux-option status-left "$STATUS_LEFT"
 tmux-option status-left-length 11
 tmux-option status-right "$STATUS_RIGHT"
 tmux-option status-right-length 37
 tmux-option -w window-status-current-format 'on #H'
 tmux-option -w window-status-format 'on #H (window #I)'
 tmux-option -w window-status-separator ' '
}

SCRIPT=$0
function echo_error() {
 echo "$SCRIPT: error: $@"
}
function echo_warning() {
 echo "$SCRIPT: warning: $@"
}

# Commands ###########################################################{{{1

case "$1" in
 start)
  if [ -z "`pgrep -f -n "$JAR_PATH"`" ]; then
   BASE_PATH_ESC="`sed -r "s/( \\\"'\\\$)/\\\\\\\\\1/g" <<< "$BASE_PATH"`"
   JAR_PATH_ESC="`sed -r "s/( \\\"'\\\$)/\\\\\\\\\1/g" <<< "$JAR_PATH"`"
   JAVA_OPTS_ESC=""
   for (( i = 0; i < ${#JAVA_OPTS[@]}; i++)); do
    JAVA_OPTS_ESC+="`sed -r "s/( \\\"'\\\$)/\\\\\\\\\1/g" <<< "${JAVA_OPTS[i]}"` "
   done
   rm -f "$PID_FILE"
   tmux new-session -d -s "$SESSION_NAME" -n "$WINDOW_NAME" -d "cd $BASE_PATH_ESC; exec java -Xms$MIN_MEMORY -Xmx$MAX_MEMORY $JAVA_OPTS_ESC -jar $JAR_PATH_ESC nogui"
   if [ $? -gt 0 ]; then
    exit 1
   fi
   sleep 1
   setup-tmux
   tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_pid}' | tee "$PID_FILE" > /dev/null
   for ((i = 0; i < ${#EXTRA_WINDOWS[@]}; i++)); do
    tmux new-window -d -c "$BASE_PATH" "${EXTRA_WINDOWS[i]}"
    r=$?
    if [ $r -ne 0 ]; then
     echo_warning "warning: failed to open tmux window with the command" \
                  " \`${EXTRA_WINDOW[i]}\`:  tmux exited with code $r"
    fi
   done
  else
   echo_error "$FRIENDLY_NAME is already running (PID $(cat "$PID_FILE"))."
   exit 1
  fi
  ;;
  
 stop)
  tmux send-keys -t "$SESSION_NAME" 'stop' C-m
  while true; do
   ps -p `cat "$PID_FILE"` &> /dev/null
   if [ $? -ne 0 ]; then
    break
   fi
  done
  rm -f "$PID_FILE"
  if [ -n "`tmux list-sessions 2>/dev/null`" ]; then
   tmux kill-server
  fi
  ;;
 
 status)
  if [ -f "$PID_FILE" ]; then
   if [ -n "`ps -p $(cat "$PID_FILE") -o args=|grep "$JAR_PATH"`" ];then
    echo "$FRIENDLY_NAME is running (PID $(cat "$PID_FILE"))."
   else
    echo_error "the PID file does not exist"
    exit 2
   fi
  else
   echo "$FRIENDLY_NAME is not running."
   exit 1
  fi
  ;;
  
 restart)
  "$0" stop
  sleep 0.1
  "$0" start
  ;;
 
 backup)
  "$0" backup-worlds
  "$0" backup-plugins
  "$0" backup-log
  ;;
 
 backup-worlds)
  tmux send-keys -t "$SESSION_NAME" 'save-off' C-m &>/dev/null
  tmux send-keys -t "$SESSION_NAME" 'save-all' C-m &>/dev/null
  DIR="$BACKUP_PATH/worlds/`date +%Y-%m-%dT%H-%M-%S`"
  mkdir -p "$DIR"
  CURDIR="$PWD"
  cd "$WORLD_PATH"
  for world in $WORLD_PATH/*; do
   world="`basename "$world"`"
   tar -cf "$DIR/$world.tar.xz" -I "$(dirname "$0")/compressor" "$world"
  done
  cd "$CURDIR"
  tmux send-keys -t "$SESSION_NAME" 'save-on' C-m &>/dev/null
  ;;
 
 backup-plugins)
  tmux send-keys -t "$SESSION_NAME" 'save-off' C-m &>/dev/null
  tmux send-keys -t "$SESSION_NAME" 'save-all' C-m &>/dev/null
  DIR="$BACKUP_PATH/plugins"
  FILE="$DIR/plugins_`date +%Y-%m-%dT%H-%H-%S`.tar.xz"
  mkdir -p "$DIR"
  CURDIR="$PWD"
  cd "$(dirname "$PLUGIN_PATH")"
  tar -cJf "$FILE" "$(basename "$PLUGIN_PATH")"
  cd "$CURDIR"
  tmux send-keys -t "$SESSION_NAME" 'save-on' C-m &>/dev/null
  ;;
 
 backup-log)
  LOG="$BASE_PATH/server.log"
  DIR="$BACKUP_PATH/logs"
  FILE="$DIR/server_`date +%Y-%m-%dT%H-%H-%S`.log"
  mkdir -p "$DIR"
  cp "$LOG" "$FILE" && xz "$FILE"
  if [ $? -eq 0 ]; then
   cp /dev/null "$LOG"
   echo "Previous logs rolled to $FILE.xz" > "$LOG"
  else
   echo_error "Problem backing up server.log"
   exit 1
  fi
  ;;
 
 cmd)
  shift
  CMD=$@
  tmux send-keys -t "$SESSION_NAME" "$CMD" C-m
  ;;
 
 console)
  tmux attach -t "$SESSION_NAME"
  ;;
 
 setup-tmux)
  setup-tmux
  ;;
 
 tmux-option)
  shift
  tmux-option "$@"
  ;;
 
 tmux-options)
  shift
  tmux show-options -t "$SESSION_NAME" "$@"
  ;;
 
 dump-config)
  cat <<END
# General options #

  FRIENDLY_NAME:  $FRIENDLY_NAME
      BASE_PATH:  $BASE_PATH
       JAR_PATH:  $JAR_PATH
       PID_FILE:  $PID_FILE
     WORLD_PATH:  $WORLD_PATH
    PLUGIN_PATH:  $PLUGIN_PATH
    BACKUP_PATH:  $BACKUP_PATH

# tmux options #

    STATUS_LEFT:  $STATUS_LEFT
   STATUS_RIGHT:  $STATUS_RIGHT
STATUS_POSITION:  $STATUS_POSITION
      STATUS_BG:  $STATUS_BG
      STATUS_FG:  $STATUS_FG

# Advanced tmux options #

    SOCKET_NAME:  $SOCKET_NAME
   SESSION_NAME:  $SESSION_NAME
    WINDOW_NAME:  $WINDOW_NAME
END
  ;;
 
 *)
  echo "Usage: $0 \\"
  echo "        [-c config-file|--config=config-file] \\"
  echo "        {start|stop|restart|status|backup{|-worlds|-plugins|-log}|cmd|console"
  echo "         |setup-tmux|tmux-option|tmux-options|dump-config}"
  exit 1
 
esac

exit 0