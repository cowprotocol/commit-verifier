# commit-verifier

Verifies that pull request commits are SSH-signed with enrolled,
hardware-backed (`sk-`, FIDO2) keys. Runs on pull requests and in merge queues as
an organization required workflow; the enrollment registry is
[`allowed_signers`](allowed_signers).

Bot exemptions are per repository: `ALLOWED_BOTS` in
[`verify_commits.sh`](verify_commits.sh) maps `owner/repo` to the bot logins
allowed there, plus a `"*"` list that applies everywhere. A bot listed nowhere
gets no exemption.

## Signed bot commits

[`.github/actions/signed-commit`](.github/actions/signed-commit/action.yml)
commits the staged changes through the GraphQL `createCommitOnBranch` mutation,
so GitHub signs the commit as the app bot whose installation token is passed in.
Such a commit passes as a verified web-flow commit if that bot is in
`ALLOWED_BOTS` for the repository. Pin it by commit SHA:

```yaml
- uses: cowprotocol/commit-verifier/.github/actions/signed-commit@<sha>
  with:
    token: ${{ steps.app-token.outputs.token }}
    branch: my-branch
    message: "Commit message"
```
