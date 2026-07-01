# Releasing Panda

Panda releases are built on GitHub's standard macOS 15 ARM runner when a semantic-version tag is pushed. Release binaries target Apple Silicon and macOS 13 or newer.

## One-time signing setup

Panda deliberately uses a stable self-signed code-signing identity instead of Apple notarization. The identity does not make the app Apple-trusted, but keeping it stable allows macOS to recognize successive Panda builds as the same app. Homebrew removes the quarantine attribute; users still grant Accessibility themselves.

In Keychain Access:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Use the name `panda-codesign-certificate`.
3. Choose **Self Signed Root** and **Code Signing**.
4. Give the certificate a long validity period.
5. Export the certificate and private key as a password-protected PKCS#12 (`.p12`) file.
6. Back up that file and password securely. Replacing the identity can invalidate existing Accessibility approval.

Configure the Panda repository secrets:

```bash
base64 < PandaSigning.p12 | gh secret set PANDA_CODESIGN_P12_BASE64
printf '%s' 'THE_EXPORT_PASSWORD' | gh secret set PANDA_CODESIGN_P12_PASSWORD
```

Never commit the certificate, private key, base64 value, or password.

## Homebrew tap deploy key

Create a dedicated SSH key without a passphrase:

```bash
ssh-keygen -t ed25519 -C panda-release-tap -f panda-homebrew-tap -N ''
```

Add `panda-homebrew-tap.pub` as a deploy key with write access in `willsantiagomedina/homebrew-tap`. Store the private key in the Panda repository:

```bash
gh secret set HOMEBREW_TAP_DEPLOY_KEY < panda-homebrew-tap
```

Delete local key copies after backing them up securely.

## Local release validation

Use explicit ad-hoc signing locally; production releases reject missing signing configuration and import the stable identity in CI.

```bash
PANDA_VERSION=0.1.0 \
PANDA_CODESIGN_IDENTITY=- \
scripts/package-release.sh

PANDA_VERSION=0.1.0 scripts/validate-release.sh
```

Generated files are written to the ignored `dist/` directory.

## Publishing

The tag must match `vMAJOR.MINOR.PATCH` and point to a commit reachable from `main`:

```bash
git switch main
git pull --ff-only
git tag v0.1.0
git push origin v0.1.0
```

The release workflow:

1. validates the tag and commit;
2. runs tests and compile checks;
3. imports the stable signing identity;
4. packages and validates all artifacts;
5. creates a draft GitHub Release and uploads every artifact;
6. publishes it as the latest release;
7. updates the versioned cask and formula in the Homebrew tap.

If tap publication fails after the GitHub Release is published, fix the deploy key or tap failure and rerun the failed workflow. The release assets remain valid and custom-domain downloads continue to work.

## Required GitHub settings

- Actions must be enabled.
- Workflow `GITHUB_TOKEN` permissions must allow repository contents writes.
- Protect tags matching `v*` so only maintainers can create releases.
- Configure all three release secrets before creating the first tag.

## Distribution endpoints

The canonical user-facing URLs remain on `givepanda.tech`. Vercel issues temporary redirects to the assets attached to GitHub's latest release. The repository never commits generated DMGs or archives.
