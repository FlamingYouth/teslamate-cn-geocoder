# Upstream workflow archive

These original TeslaMate workflows are preserved here without running in this
unofficial repository. They include upstream publishing, scheduled maintenance
and Nix/Rust jobs that are not the release process for the China geocoder patch.

Only `.github/workflows/publish-cn.yml` is active. It must be manually dispatched
at the image's release Git tag with the already-tested Aliyun digest. Both
architectures are verified on native runners before the exact multi-platform
manifest is mirrored to GHCR. No real Baidu credentials are sent to GitHub.
