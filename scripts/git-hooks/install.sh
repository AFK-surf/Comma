#!/bin/sh
# Points git at scripts/git-hooks. Leaves a hooks path the developer chose
# for this checkout alone and replaces the retired husky path. Outside a git
# checkout it does nothing. `make`, `mix deps.get` in systems/ and
# `pnpm install` run it.
cd "$(dirname "$0")/../.." || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
case "$(git config --local --get core.hooksPath)" in
  "" | clients/.husky/_) git config core.hooksPath scripts/git-hooks ;;
esac
exit 0
