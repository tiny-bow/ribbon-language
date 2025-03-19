#!/usr/bin/bash

clear

echo "Rebuilding..."

output=$(zig build run -freference-trace --prominent-compile-errors 2>&1)

if [ $? -eq 0 ]; then
    clear
    echo "Rebuild succeeded"
else
    clear
    echo "$output" \
        | grep -i "error" -m 1 -A 8 \
        | awk -v total_lines=$(echo "$output" | wc -l) '
            {print}
            END {
                if (NR < total_lines) print "... (use single build for more info)"
            }'
    exit 1
fi
