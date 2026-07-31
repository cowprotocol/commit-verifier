# commit-verifier

Canonical home of the `allowed_signers` registry and the reusable workflow that
checks every human-authored commit in a PR was SSH-signed by a hardware-backed
(`sk-`, FIDO2) key registered to the author's GitHub account and enrolled in
`allowed_signers`.

## Using it from a repo

```yaml
jobs:
  verify-commit-signatures:
    uses: cowprotocol/commit-verifier/.github/workflows/verify.yml@<full-commit-sha>
    permissions:
      contents: read
      pull-requests: read
```

Pin to a full commit SHA, not a branch or tag. The workflow checks out this
repo at that same SHA, so the script and `allowed_signers` are pinned too.
Never pass `secrets: inherit`; the workflow only needs the automatic
`GITHUB_TOKEN`.

## Enrollment (once per person)

1. **Create a hardware key** (FIDO2 authenticator, e.g. YubiKey; confirm it's
   genuine first: <https://www.yubico.com/genuine/>). It requires a touch to
   sign, which the check enforces.

   ```bash
   ssh-keygen -t ed25519-sk -C "$(whoami) commit signing" -f ~/.ssh/id_ed25519_sk_git
   ```

2. **Register it on GitHub** → _Settings → SSH and GPG keys → New SSH key_,
   type **Signing Key**. Paste the contents of `~/.ssh/id_ed25519_sk_git.pub`.

3. **Tell git to sign with it:**

   ```bash
   git config --global gpg.format ssh
   git config --global user.signingkey ~/.ssh/id_ed25519_sk_git.pub
   git config --global commit.gpgsign true
   ```

4. **Add your key to `allowed_signers`** here: one line, `<your-git-email>
<contents of the .pub>`, and open a PR. A reviewer merging it enrolls you.

The email you commit with must also be on your GitHub account; the check
resolves your account from it.

## How the check works

Runs on `pull_request`. Each commit must pass, in order:

1. the author's GitHub account has an `sk-` signing key;
2. the signature is valid and made by one of those keys;
3. that key is enrolled in `allowed_signers`;
4. the signature carries the user-presence flag: the key was **touched**.

Failing any step is a hard CI failure (aka red X check failure), unless the
commit is from an allow-listed automated account (they have no hardware key);
those warn instead. An automated account is allowed through only when the
**signature** proves.

## Run locally

```bash
GH_TOKEN=$(gh auth token) GITHUB_REPOSITORY=owner/repo \
  ./verify_commits.sh <PR-number>
```
