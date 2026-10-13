# CURSOR_API_KEY inherited; stdin=/dev/null; launched with setsid (own process group); SIGTERM sent to the main node PID once a shellToolCall "started" event appeared
cd <WORKDIR> && setsid env HOME=<FAKE_HOME> CURSOR_CONFIG_DIR=<cfg> CURSOR_DATA_DIR=<data> XDG_CONFIG_HOME=<xdg> TMPDIR=<tmp> cursor-agent -p --force --output-format stream-json --model auto "Run sleep 30 in the shell, then reply DONE"
# then: kill -TERM <main pid>
