# Releasing

## Versioning

[Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`.

While the version is `0.x`, a breaking API change bumps **MINOR**
(`0.1.0 → 0.2.0`) and everything else bumps **PATCH** (`0.1.0 → 0.1.1`).
From `1.0.0`: breaking → MAJOR, new features → MINOR, fixes → PATCH.

The version lives in three places — keep them equal:

* `pubspec.yaml` → `version:`
* `ios/health_workout_sync.podspec` → `s.version`
* `CHANGELOG.md` → a `## x.y.z` heading describing the release

## Checklist

1. Update the three version spots above and write the CHANGELOG entry.
2. `flutter analyze && flutter test`
3. `cd example && flutter analyze && flutter build apk --debug`
4. `flutter pub publish --dry-run` — must report 0 warnings.
5. Commit: `git commit -am "release: vX.Y.Z"`
6. Tag and push: `git tag vX.Y.Z && git push origin main --tags`

## Publishing

**First release (manual, once):** `flutter pub publish` from a machine logged
in to the pub.dev account that should own the package. Then on
pub.dev → the package → **Admin**:

* Move it to your verified publisher (optional, recommended).
* **Automated publishing** → enable *Publishing from GitHub Actions*,
  repository `usaman9040/health_workout_sync`, tag pattern `v{{version}}`.

**Every release after that:** push a tag `vX.Y.Z` (step 6). The
`publish.yml` workflow publishes it — no credentials stored in GitHub.
