#!/bin/sh
# Run a command with inherited Git/editor session state and observable canaries.
set -u
hostile_dir=$(mktemp -d "${TMPDIR:-/tmp}/helmsman-hostile.XXXXXX") || exit 1
trap 'rm -rf "$hostile_dir"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
hostile_log=$hostile_dir/calls
mkdir "$hostile_dir/hooks"
for hostile_name in askpass credential-helper fsmonitor; do
  cat > "$hostile_dir/$hostile_name" <<CANARY
#!/bin/sh
printf '%s\n' "\$0 \$*" >> "$hostile_log"
exit 1
CANARY
  chmod 700 "$hostile_dir/$hostile_name"
done
for hostile_hook in pre-commit pre-push post-checkout; do
  cp "$hostile_dir/askpass" "$hostile_dir/hooks/$hostile_hook"
done
cat > "$hostile_dir/config" <<CONFIG
[credential]
    helper = !"$hostile_dir/credential-helper"
[core]
    fsmonitor = "$hostile_dir/fsmonitor"
CONFIG
export GIT_ASKPASS=$hostile_dir/askpass SSH_ASKPASS=$hostile_dir/askpass
export SSH_ASKPASS_REQUIRE=force GIT_TERMINAL_PROMPT=0
export VSCODE_GIT_ASKPASS_NODE=$hostile_dir/askpass VSCODE_GIT_ASKPASS_MAIN=$hostile_dir/askpass
export GIT_CONFIG_COUNT=5
export GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=explicit
export GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1="!\"$hostile_dir/credential-helper\""
export GIT_CONFIG_KEY_2=core.fsmonitor GIT_CONFIG_VALUE_2=$hostile_dir/fsmonitor
export GIT_CONFIG_KEY_3=core.hooksPath GIT_CONFIG_VALUE_3=$hostile_dir/hooks
export GIT_CONFIG_KEY_4=credential.interactive GIT_CONFIG_VALUE_4=false
export GIT_CONFIG_PARAMETERS="'core.fsmonitor=$hostile_dir/fsmonitor'"
export GIT_CONFIG_GLOBAL=$hostile_dir/config GIT_CONFIG_SYSTEM=$hostile_dir/config
export GIT_DIR=/nonexistent/hostile
export VSCODE_GIT_IPC_HANDLE=$hostile_dir/git.sock VSCODE_IPC_HOOK_CLI=$hostile_dir/code.sock
export HELMSMAN_PROVIDER_API_KEY=hostile-sentinel HELMSMAN_GIT_TOKEN=hostile-sentinel
"$@"
hostile_status=$?
if [ -s "$hostile_log" ]; then
  printf '%s\n' 'Inherited Git environment canary was called:' >&2
  cat "$hostile_log" >&2
  if [ "$hostile_status" -eq 0 ]; then hostile_status=1; fi
fi
exit "$hostile_status"
