#!/usr/bin/env bash
tag=$1
if [ -z "${tag}" ]; then
    echo "Error: version tag argument is required." >&2
    echo "Usage: $0 vMAJOR.MINOR.PATCH (for example: v1.2.3)" >&2
    exit 1
fi
if echo "${tag}" | grep -qe '^v[0-9]\+\.[0-9]\+\.[0-9]\+$'
then
    echo "Format OK"
else
    echo "Version number does not match required format: v0.0.0"
    exit 1
fi
prettyVer=${tag/v/"Version "}
echo ${prettyVer} > version.txt
git tag -a "${tag}" -m "Release ${tag}"
curr_branch=$(git rev-parse --abbrev-ref HEAD)
cat version.txt
git add version.txt
git commit --amend --no-edit
git tag -a ${tag}
curr_branch=`git rev-parse --abbrev-ref HEAD`
git checkout release && git merge ${curr_branch} --ff-only && git checkout ${curr_branch}

echo "Version ${tag} tagged and merged to release branch"
echo "Please push the changes and tags to the remote repository"
echo "git push origin ${curr_branch} --tags"
