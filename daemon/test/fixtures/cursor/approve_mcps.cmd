# CURSOR_API_KEY inherited from parent env unless overridden; stdin=/dev/null
cd <WORKDIR> && env HOME=<FAKE_HOME> HELMSMAN_RUN_TOKEN=hmr_probe_DUMMY_12345 cursor-agent -p --force --approve-mcps --output-format stream-json --model auto Reply\ exactly\ OK
