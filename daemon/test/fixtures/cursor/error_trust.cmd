# CURSOR_API_KEY inherited from parent env unless overridden; stdin=/dev/null
cd <WORKDIR> && env HOME=<FAKE_HOME> cursor-agent -p --output-format stream-json --model auto Reply\ exactly\ OK
