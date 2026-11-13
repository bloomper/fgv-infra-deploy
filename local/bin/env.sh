# Source this file (bash or zsh) to point the deploy repos' scripts at this checkout and Spexregister's deploy repo
# when the repos are grouped per application rather than checked out side by side:
#
#   fgv/
#     fgv-infra-deploy/
#     spexregister/spexregister-deploy/
#     spexify/fgv-spexify-deploy/ ...
#
#   . path/to/fgv-infra-deploy/local/bin/env.sh
#
# Values already set in the environment are kept.

if [ -n "${BASH_SOURCE:-}" ]; then
  _fgv_env_file=${BASH_SOURCE[0]}
elif [ -n "${ZSH_VERSION:-}" ]; then
  _fgv_env_file=${(%):-%x}
else
  echo "env.sh: source it from bash or zsh" >&2
  return 1 2>/dev/null || exit 1
fi

_fgv_infra_deploy=$(cd "$(dirname "$_fgv_env_file")/../.." && pwd)

export INFRA_DEPLOY=${INFRA_DEPLOY:-$_fgv_infra_deploy}
export SPEXREGISTER_DEPLOY=${SPEXREGISTER_DEPLOY:-$(dirname "$_fgv_infra_deploy")/spexregister/spexregister-deploy}

[ -d "$SPEXREGISTER_DEPLOY" ] || echo "env.sh: $SPEXREGISTER_DEPLOY does not exist; set SPEXREGISTER_DEPLOY" >&2

unset _fgv_env_file _fgv_infra_deploy
