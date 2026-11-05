const assert = require("node:assert/strict");
const test = require("node:test");
const comment = require("./comment-pr-build.cjs");

function fixture({
  event = "pull_request",
  conclusion = "success",
  state = "open",
  head = "abc123",
  base = "jiahuei/lulo",
  artifacts,
  comments = [],
} = {}) {
  const writes = [];
  const calls = [];
  const github = {
    rest: {
      repos: { listPullRequestsAssociatedWithCommit: "pulls" },
      actions: { listWorkflowRunArtifacts: "artifacts" },
      pulls: { get: async () => ({ data: { number: 3, state, head: { sha: head }, base: { repo: { full_name: base } } } }) },
      issues: {
        listComments: "comments",
        createComment: async (input) => writes.push({ method: "create", ...input }),
        updateComment: async (input) => writes.push({ method: "update", ...input }),
      },
    },
    paginate: async (method, input) => {
      calls.push({ method, ...input });
      return {
        pulls: [{ number: 3 }],
        artifacts: artifacts ?? [{ id: 42, name: "Lulo-macOS-universal", expired: false }],
        comments,
      }[method];
    },
  };
  const context = {
    repo: { owner: "jiahuei", repo: "lulo" },
    serverUrl: "https://github.com",
    payload: { workflow_run: { id: 99, event, conclusion, head_sha: "abc123", pull_requests: [] } },
  };
  return { github, context, writes, calls };
}

// Ensures a fork-compatible API association produces a direct download link and laptop instructions.
test("creates a download comment without depending on workflow payload PR associations", async () => {
  const f = fixture();
  await comment(f);
  assert.equal(f.writes.length, 1);
  assert.equal(f.writes[0].method, "create");
  assert.equal(f.writes[0].issue_number, 3);
  assert.match(f.writes[0].body, /https:\/\/github.com\/jiahuei\/lulo\/actions\/runs\/99\/artifacts\/42/);
  assert.match(f.writes[0].body, /abc123/);
  assert.match(f.writes[0].body, /Apple Silicon and Intel/);
  assert.match(f.writes[0].body, /not Apple-notarized/);
  assert.equal(f.calls.find((call) => call.method === "artifacts").run_id, 99);
});

// Ensures reruns update one bot comment without modifying a contributor's matching text.
test("updates only the existing GitHub Actions comment", async () => {
  const f = fixture({
    comments: [
      { id: 1, user: { login: "contributor" }, body: "<!-- lulo-pr-build -->" },
      { id: 2, user: { login: "github-actions[bot]" }, body: "<!-- lulo-pr-build -->\nold build" },
    ],
  });
  await comment(f);
  assert.equal(f.writes.length, 1);
  assert.equal(f.writes[0].method, "update");
  assert.equal(f.writes[0].comment_id, 2);
});

// Ensures outdated, closed, and cross-repository associations cannot receive a build link.
test("skips PRs that no longer match the completed build", async () => {
  for (const options of [{ head: "newer" }, { state: "closed" }, { base: "other/repo" }]) {
    const f = fixture(options);
    await comment(f);
    assert.deepEqual(f.writes, []);
  }
});

// Ensures failed, cancelled, missing, or expired builds never advertise a working download.
test("reports unavailable artifacts instead of retaining a stale success", async () => {
  for (const options of [
    { conclusion: "failure" },
    { conclusion: "cancelled" },
    { artifacts: [] },
    { artifacts: [{ id: 42, name: "Lulo-macOS-universal", expired: true }] },
    { artifacts: [{ id: 43, name: "native-previews", expired: false }] },
  ]) {
    const f = fixture(options);
    await comment(f);
    assert.match(f.writes[0].body, /No downloadable app/);
    assert.doesNotMatch(f.writes[0].body, /\/artifacts\//);
  }
});

// Ensures main-branch pushes do not create PR comments.
test("ignores non-PR runs", async () => {
  const f = fixture({ event: "push" });
  await comment(f);
  assert.deepEqual(f.calls, []);
  assert.deepEqual(f.writes, []);
});
