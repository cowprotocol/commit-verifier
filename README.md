# commit-verifier

Verifies that pull request commits are SSH-signed with enrolled,
hardware-backed (`sk-`, FIDO2) keys. Runs on pull requests and in merge queues as
an organization required workflow; the enrollment registry is
[`allowed_signers`](allowed_signers).

Bot exemptions are per repository: `ALLOWED_BOTS` in
[`verify_commits.sh`](verify_commits.sh) maps `owner/repo` to the bot logins
allowed there, plus a `"*"` list that applies everywhere. A bot listed nowhere
gets no exemption.
