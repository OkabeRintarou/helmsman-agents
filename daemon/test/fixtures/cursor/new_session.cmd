# R1: work directory reached through a symlink; prompt on stdin
cd <LINK_TO_WORK> && env HOME=<FAKE_HOME> CURSOR_CONFIG_DIR=<cfg> CURSOR_DATA_DIR=<data> TMPDIR=<tmp> AGENT_CLI_CREDENTIAL_STORE=memory DIRENV_DISABLE=1 cursor-agent -p --force --output-format stream-json --sandbox disabled --disable-codebase-ref --disable-project-configs --model auto --new-session-id <uuid> < prompt
