# CURSOR_API_KEY inherited from parent env unless overridden; stdin=/dev/null
cd <WORKDIR> && env HOME=<FAKE_HOME> CURSOR_CONFIG_DIR=<SCRATCH>/cfgB CURSOR_DATA_DIR=<DATA_DIR_b> XDG_CONFIG_HOME=<SCRATCH>/xdgB TMPDIR=<SCRATCH>/tmpB cursor-agent -p --force --exclude-workspace-context --disable-codebase-ref --disable-indexing --output-format stream-json --model auto Reply\ exactly\ OK
