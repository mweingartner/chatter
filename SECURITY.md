# Security

Chatter is intended for personal use with explicitly authorized clients. Local HTTP binds only to loopback. Remote connections require the separate HTTPS listener, an explicitly verified certificate fingerprint, and a scoped client token. Browser origins are rejected. Do not expose Chatter through router port forwarding.

Report vulnerabilities privately through [GitHub's vulnerability reporting page](https://github.com/mweingartner/chatter/security/advisories/new). Do not post tokens, personal audio, transcripts, or exploit details in public issues. Include the version, prerequisites, expected behavior, observed result, and a reproduction using synthetic data.

The [API reference](docs/API.md) documents authorization and limits. The [architecture](docs/ARCHITECTURE.md) records the security design and remaining boundaries. [Build instructions](docs/BUILDING.md) distinguish local development signing from production notarization.

## Maintenance and distribution

CI and a weekly job check vendored hashes, accidentally tracked runtime data, and OSV advisories against pinned Swift and native components. The audit emits a CycloneDX component inventory. Advisory coverage is incomplete; a clean result is not proof that dependencies have no vulnerabilities. GitHub Actions versions are pinned and monitored separately.

Production packaging requires a Developer ID Application signing identity and a notarytool Keychain profile. The script verifies signatures, notarizes, staples and assesses the app. `--development` explicitly creates local development archives and is not suitable for a public production release. Signing credentials must remain outside the repository.

The app's speech helper is restricted from network access and from reading user files outside its models, voice references, staged media, bundle, system services, cache and temporary directories. These process restrictions are defense in depth, not a claim that the complete application uses Apple's App Sandbox. They currently use macOS's bundled sandbox-exec facility, which must be revalidated on supported macOS releases.
