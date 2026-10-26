# The egress proxy image: one smokescreen per caller network, started and supervised by
# the Rust entrypoint /proxy, which generates each network's policy at start from the
# mounted local config. compose builds it locally; no prebuilt image is pulled.
ARG TARGETARCH

# smokescreen v0.1.0 (github.com/stripe/smokescreen, tag commit 609eb8931420453daf5893509be0b25b21bd9edb):
# the official release tarballs, pinned by the release's SHA256SUMS.
FROM debian:trixie-20261005-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f AS fetch-amd64
ADD --checksum=sha256:4e1e447449e3cc653dae956208588722b5c8fe8ce894f633adc756a851d1ec46 https://github.com/stripe/smokescreen/releases/download/v0.1.0/smokescreen_v0.1.0_linux_amd64.tar.gz /tmp/smokescreen.tar.gz

FROM debian:trixie-20261005-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f AS fetch-arm64
ADD --checksum=sha256:f15ddd0dc2b2cbc6d7318f441928939eb9bedfab2a1881508af3096a1e24b7c9 https://github.com/stripe/smokescreen/releases/download/v0.1.0/smokescreen_v0.1.0_linux_arm64.tar.gz /tmp/smokescreen.tar.gz

FROM fetch-${TARGETARCH} AS fetch
RUN tar -xzf /tmp/smokescreen.tar.gz -C /tmp --strip-components=1 && test -x /tmp/smokescreen

FROM rust:1.99.1-slim-trixie@sha256:1a939748a7cbab172de91a014e3804a97af1394a8c844faa67fce9401c4e40fb AS build
WORKDIR /src
COPY proxy/ ./
RUN cargo build --release --locked && install -m 0555 target/release/proxy /proxy

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:3ee00291cf386ec52a552e6a858d555debd74776eb4bfa53fa3df2cd6677515e
COPY --from=fetch --chmod=0555 /tmp/smokescreen /smokescreen
COPY --from=build /proxy /proxy
USER 65532:65532
# The checks run per network in parallel and take at most about 8 s (proxy/src/health.rs).
HEALTHCHECK --interval=15s --timeout=10s --start-period=20s --start-interval=2s --retries=2 CMD ["/proxy", "health"]
ENTRYPOINT ["/proxy"]
CMD ["run"]
