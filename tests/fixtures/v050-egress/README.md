# A v0.5.0-layout source checkout

`start.sh` and `compose.yaml` exactly as commit `122d7454` (WDRC-220) has them: the
checkout callers' installers before the image (v0.5.0) put in `~/.egress/versions/<commit>/`,
linked from `~/.egress/current` and ran with `EGRESS_CONFIG_DIR=~/.egress`. Its `start.sh`
builds the image `egress-proxy` from the checkout and writes `compose.networks.yaml` beside
the config. `tests/install-integration.sh`'s migration section installs them, with a
`Dockerfile` built FROM the installed image in place of the Rust build, as the
source-checkout install to migrate and to roll back to (FR-11). Never edit them.
