#!/bin/bash

if [[ "$1" == "--check-only" ]]; then
  SHFMT_ARGS="-i 2 -bn -ci -sr -d"
else
  SHFMT_ARGS="-i 2 -bn -ci -sr -w"
fi

EXIT_STATUS=0
set +e
while IFS= read -d '' -r script; do
  shfmt "$SHFMT_ARGS" "$script"
  ((EXIT_STATUS |= $?))
done < <(find . -maxdepth 2 -type f \( -iname "PKGBUILD" -or -iname "*.sh" \) \( ! -iwholename "./mips64-elf*" \) -print0 | sort -nr)

exit $EXIT_STATUS
