# commit-verifier

Verifies that pull request commits are SSH-signed with enrolled,
hardware-backed (`sk-`, FIDO2) keys. Runs on pull requests as an organization
required workflow; the enrollment registry is [`allowed_signers`](allowed_signers).
