# CURSOR_API_KEY inherited from parent env unless overridden; stdin=/dev/null
cd <WORKDIR> && env HOME=<FAKE_HOME> CURSOR_API_KEY=invalid cursor-agent -p --force --output-format stream-json --model auto Reply\ exactly\ OK
