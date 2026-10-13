# private HOME, CURSOR_CONFIG_DIR, CURSOR_DATA_DIR, TMPDIR; empty work directory; AGENT_CLI_CREDENTIAL_STORE=memory
cd <WORKDIR> && env HOME=<FAKE_HOME> CURSOR_CONFIG_DIR=<cfg> CURSOR_DATA_DIR=<data> TMPDIR=<tmp> cursor-agent mcp list
