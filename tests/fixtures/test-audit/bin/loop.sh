#!/usr/bin/env bash
# Fixture subject for the read-loop case: no suite loads it.
count=0
while IFS= read -r line; do
  count=$((count + 1))
done < /dev/null
until read -r x; do :; done < /dev/null
while [ "$count" -lt 3 ]; do
  count=$((count + 1))
done
