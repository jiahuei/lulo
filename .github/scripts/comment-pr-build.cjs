const marker = "<!-- lulo-pr-build -->";

module.exports = async ({ github, context }) => {
  const run = context.payload.workflow_run;
  if (run.event !== "pull_request") return;

  const repository = context.repo;
  // Query GitHub's associations: fork workflow_run payloads may omit pull_requests.
  const pulls = await github.paginate(github.rest.repos.listPullRequestsAssociatedWithCommit, {
    ...repository,
    commit_sha: run.head_sha,
    per_page: 100,
  });
  const artifacts =
    run.conclusion === "success"
      ? await github.paginate(github.rest.actions.listWorkflowRunArtifacts, { ...repository, run_id: run.id, per_page: 100 })
      : [];
  const artifact = artifacts.find((item) => item.name === "Lulo-macOS-universal" && !item.expired);
  const runURL = `${context.serverUrl}/${repository.owner}/${repository.repo}/actions/runs/${run.id}`;
  const body = [
    marker,
    "### Lulo test build",
    "",
    `Commit: \`${run.head_sha}\` · [Build details](${runURL})`,
    "",
    ...(artifact
      ? [
          `[**Download Lulo for macOS**](${runURL}/artifacts/${artifact.id})`,
          "",
          "Requires macOS 14 or later; supports Apple Silicon and Intel. Sign in to GitHub to download. This artifact expires after 30 days; rerun the macOS workflow to refresh it.",
          "",
          "1. Unzip the downloaded artifact, then unzip `Lulo-macOS-universal.zip` inside it.",
          "2. Move `Lulo.app` to Applications and open it.",
          "3. This test build is ad-hoc signed with App Sandbox enabled, but is not Apple-notarized. If macOS blocks it, use System Settings → Privacy & Security → Open Anyway after attempting to open it. [Apple's instructions](https://support.apple.com/102445).",
        ]
      : ["No downloadable app is available for this commit. Check the build details above and rerun the workflow after resolving any failure."]),
  ].join("\n");

  for (const candidate of pulls) {
    // Re-read the PR so a slow or rerun build cannot replace a newer commit's link.
    const { data: pr } = await github.rest.pulls.get({ ...repository, pull_number: candidate.number });
    if (pr.state !== "open" || pr.base.repo.full_name !== `${repository.owner}/${repository.repo}` || pr.head.sha !== run.head_sha) continue;
    const comments = await github.paginate(github.rest.issues.listComments, { ...repository, issue_number: pr.number, per_page: 100 });
    const previous = comments.find((comment) => comment.user.login === "github-actions[bot]" && comment.body.startsWith(marker));
    if (previous) {
      await github.rest.issues.updateComment({ ...repository, comment_id: previous.id, body });
    } else {
      await github.rest.issues.createComment({ ...repository, issue_number: pr.number, body });
    }
  }
};
