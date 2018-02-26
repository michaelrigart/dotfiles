#!/bin/bash

# Source the files in the bash folder
# Trying to put some order in everything instead of using one big file. Feels dirty you know
for file in ~/.config/bash/{aliases,fzf,paths,config}; do
	[ -r "$file" ] && source "$file";
done;
unset file;

