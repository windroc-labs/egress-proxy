# The S3 installer files

`install.sh`, `egress-install` and `start.sh` exactly as commit `820a30d` (WDRC-256, S3)
shipped them in the image's `/egress`: the first installer of interface 1, written before
the rules file (S4) and the rollback (S5). `tests/install-selftest.sh` case
`rollback_s3_entry` installs them as the previous version's image, to check that a newer
installer rolls back through an older version's install entry (NFR-6). Never edit them.
