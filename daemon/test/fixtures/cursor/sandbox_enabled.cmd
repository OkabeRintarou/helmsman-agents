# CURSOR_API_KEY inherited from parent env unless overridden; stdin=/dev/null
cd <WORKDIR> && env HOME=<FAKE_HOME> CURSOR_CONFIG_DIR=<SCRATCH>/cfg5 CURSOR_DATA_DIR=<DATA_DIR> XDG_CONFIG_HOME=<SCRATCH>/xdg5 TMPDIR=<SCRATCH>/tmp5 cursor-agent -p --force --sandbox enabled --output-format stream-json --model auto Run\ pwd\ in\ the\ shell\,\ then\ reply\ DONE
