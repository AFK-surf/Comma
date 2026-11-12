#!/bin/sh
# apt-get update on a CI runner from the Ubuntu archive alone. The runner images also list Google's and
# Microsoft's repositories, which CI installs nothing from; when one of them is caught mid-publish its index
# fails its hash check and the whole update fails with it.
set -eu
ubuntu=/etc/apt/sources.list.d/ubuntu.sources
if [ ! -f "$ubuntu" ]; then
  exec sudo apt-get update "$@"
fi
parts=$(mktemp -d)
trap 'rm -rf "$parts"' EXIT
ln -s "$ubuntu" "$parts/ubuntu.sources"
sudo apt-get update -o Dir::Etc::SourceParts="$parts" "$@"
