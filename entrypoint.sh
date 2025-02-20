#!/bin/bash

set -e

REPO_NAME=$(jq -r ".repository.full_name" "$GITHUB_EVENT_PATH")

onerror() {
	gh pr comment $PR_NUMBER --body "‼️ cherry-pick action failed.<br/>See: https://github.com/$REPO_NAME/actions/runs/$GITHUB_RUN_ID"
	exit 1
}
trap onerror ERR

if [ -z "$PR_NUMBER" ]; then
	PR_NUMBER=$(jq -r ".pull_request.number" "$GITHUB_EVENT_PATH")
	if [[ "$PR_NUMBER" == "null" ]]; then
		PR_NUMBER=$(jq -r ".issue.number" "$GITHUB_EVENT_PATH")
	fi
	if [[ "$PR_NUMBER" == "null" ]]; then
		echo "Failed to determine PR Number."
		exit 1
	fi
fi

COMMENT_BODY=$(jq -r ".comment.body" "$GITHUB_EVENT_PATH")
PR_TITLE=$(jq -r ".issue.title" "$GITHUB_EVENT_PATH")
PR_BODY=$(jq -r ".issue.body" "$GITHUB_EVENT_PATH")
BODY="## Original Pull Request Description
$PR_BODY
---
## Cherry-Picked Pull Request
Validation: 
- _Please include new validation on the target branch_
"

echo "Collecting information about PR #$PR_NUMBER of $GITHUB_REPOSITORY..."

if [[ -z "$GITHUB_TOKEN" ]]; then
	echo "Set the GITHUB_TOKEN env variable."
	exit 1
fi

URI=https://api.github.com
API_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token $GITHUB_TOKEN"

MAX_RETRIES=${MAX_RETRIES:-6}
RETRY_INTERVAL=${RETRY_INTERVAL:-10}
MERGED=""
MERGE_COMMIT=""
pr_resp=""
commits=""
reviewers=""

for ((i = 0 ; i < $MAX_RETRIES ; i++)); do
	pr_resp=$(gh api "${URI}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER")
	commits=$(gh api "${URI}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/commits?per_page=200")
	reviewers=$(gh api "${URI}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews")
	MERGED=$(echo "$pr_resp" | jq -r .merged)
	MERGE_COMMIT=$(echo "$pr_resp" | jq -r .merge_commit_sha)
	if [[ "$MERGED" == "null" ]]; then
		echo "The PR is not ready to cherry-pick, retry after $RETRY_INTERVAL seconds"
		sleep $RETRY_INTERVAL
		continue
	else
		break
	fi
done

# get all commit shas except merge commits
COMMIT_SHA_VALUES=$(echo "$commits" | jq -r '.[] | select(.commit.message | contains("Merge") | not) | .sha')
echo $COMMIT_SHA_VALUES

#get requested reviewer names from the PR
PR_REVIEWERS=$(echo "$reviewers" | jq -r 'map(select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | .user.login) | unique | join(",")')
echo "Reviewers: $PR_REVIEWERS"

# See https://github.com/actions/checkout/issues/766 for motivation.
git config --global --add safe.directory /github/workspace

if [[ "$MERGED" != "true" ]] ; then
	echo "PR is not merged! Can't cherry pick it."
	gh pr comment $PR_NUMBER --body "‼️ PR can't be cherry-picked, please merge it first."
	exit 1
fi

BASE_REPO=$(echo "$pr_resp" | jq -r .base.repo.full_name)
HEAD_BRANCH=$(echo "$pr_resp" | jq -r .head.ref)

TARGET_BRANCH=$(jq -r ".comment.body" "$GITHUB_EVENT_PATH" | awk '{ print $2 }'  | tr -d '[:space:]')
TEMP_BRANCH=cherry/${TARGET_BRANCH}/${HEAD_BRANCH}

USER_LOGIN=$(jq -r ".comment.user.login" "$GITHUB_EVENT_PATH")

if [[ "$USER_LOGIN" == "null" ]]; then
	USER_LOGIN=$(jq -r ".pull_request.user.login" "$GITHUB_EVENT_PATH")
fi

user_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
	"${URI}/users/${USER_LOGIN}")

USER_NAME=$(echo "$user_resp" | jq -r ".name")
if [[ "$USER_NAME" == "null" ]]; then
	USER_NAME=$USER_LOGIN
fi
USER_NAME="${USER_NAME} (Cherry Pick PR Action)"

USER_EMAIL=$(echo "$user_resp" | jq -r ".email")
if [[ "$USER_EMAIL" == "null" ]]; then
	USER_EMAIL="$USER_LOGIN@users.noreply.github.com"
fi

if [[ -z "$TARGET_BRANCH" ]]; then
	echo "Cannot get target branch information for PR #$PR_NUMBER!"
	gh pr comment $PR_NUMBER --body "‼️ Cannot get target branch information."
	exit 1
fi

echo "Target branch for PR #$PR_NUMBER is $TARGET_BRANCH"

USER_TOKEN=${USER_LOGIN//-/_}_TOKEN
UNTRIMMED_COMMITTER_TOKEN=${!USER_TOKEN:-$GITHUB_TOKEN}
COMMITTER_TOKEN="$(echo -e "${UNTRIMMED_COMMITTER_TOKEN}" | tr -d '[:space:]')"

git remote set-url origin https://$USER_LOGIN:$COMMITTER_TOKEN@github.com/$GITHUB_REPOSITORY.git
git config --global user.email "$USER_EMAIL"
git config --global user.name "$USER_NAME"

git remote add upstream https://$USER_LOGIN:$COMMITTER_TOKEN@github.com/$REPO_NAME.git

set -o xtrace

# make sure branches are up-to-date
git fetch origin $TARGET_BRANCH
git fetch upstream $TARGET_BRANCH

# do the cherry-picks for each commit
git checkout -b upstream/$TEMP_BRANCH upstream/$TARGET_BRANCH

for sha in $COMMIT_SHA_VALUES; do
	echo $sha
	git cherry-pick -xs $sha &> /tmp/error.log || (
		gh pr comment $PR_NUMBER --body "‼️ Attempted to cherry-pick the following commits: $(echo $COMMIT_SHA_VALUES)<br/><br/>Error during cherry-pick at $sha.<br/><br/>$(cat /tmp/error.log)"
		exit 1
	)
done

# push back
git push upstream upstream/$TEMP_BRANCH:$TEMP_BRANCH &> /tmp/error.log || (
	gh pr comment $PR_NUMBER --body "‼️ Error during push.<br/><br/>$(cat /tmp/error.log)"
	exit 1
)

ERROR_LOG="/tmp/error.log"

if [ -z "$PR_REVIEWERS" ] || [[ "$PR_REVIEWERS" == "null" ]]; then
	cherry_pr_url=$(gh pr create --base $TARGET_BRANCH --head $TEMP_BRANCH --title "$PR_TITLE" --body "$BODY" --draft 2> "$ERROR_LOG" || {
		if grep -q "Draft pull requests are not supported" "$ERROR_LOG"; then
			second_cherry_pr_url=$(gh pr create --base $TARGET_BRANCH --head $TEMP_BRANCH --title "$PR_TITLE" --body "$BODY" 2> "$ERROR_LOG" || {
				gh pr comment $PR_NUMBER --body "‼️ Error during PR creation.<br/><br/>$(cat "$ERROR_LOG")"
				exit 1
			})
      			echo "$second_cherry_pr_url"
		else
			gh pr comment $PR_NUMBER --body "‼️ Error during PR creation.<br/><br/>$(cat "$ERROR_LOG")"
			exit 1
		fi
	})
else
	cherry_pr_url=$(gh pr create --base $TARGET_BRANCH --head $TEMP_BRANCH --title "$PR_TITLE" --body "$BODY" --reviewer "$PR_REVIEWERS" --draft 2> "$ERROR_LOG" || {
	    if grep -q "Draft pull requests are not supported" "$ERROR_LOG"; then
			second_cherry_pr_url=$(gh pr create --base $TARGET_BRANCH --head $TEMP_BRANCH --title "$PR_TITLE" --body "$BODY" --reviewer "$PR_REVIEWERS" 2> "$ERROR_LOG" || {
				gh pr comment $PR_NUMBER --body "‼️ Error during PR creation.<br/><br/>$(cat "$ERROR_LOG")"
				exit 1
			})
   			echo "$second_cherry_pr_url"
	    else
			gh pr comment $PR_NUMBER --body "‼️ Error during PR creation.<br/><br/>$(cat "$ERROR_LOG")"
			exit 1
	    fi
	})
fi

echo $cherry_pr_url

gh pr comment $PR_NUMBER --body "cherry-pick action finished successfully 🎉!<br/>New PR created at: $cherry_pr_url <br/>Action run: https://github.com/$REPO_NAME/actions/runs/$GITHUB_RUN_ID"
