# CURSOR_API_KEY inherited from parent env unless overridden; stdin=/dev/null
# NOTE: this run was additionally wrapped in: strace -f -qq -e trace=openat,open,stat,statx,newfstatat,access,mkdir,unlink,rename,execve (strace waited ~300s for the detached worker-server to exit; the CLI itself finished after ~16s)
cd <WORKDIR> && env HOME=<FAKE_HOME> cursor-agent -p --trust --output-format stream-json --model auto Reply\ exactly\ OK
