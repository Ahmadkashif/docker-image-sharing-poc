# syntax=docker/dockerfile:1
# Cross-compiling build with NO RUN in the target stage:
#  - the Go toolchain runs on the BUILD platform only (native amd64 on a Linux box, native arm64 on Apple Silicon);
#  - the runtime stage is distroless + COPY, so building linux/arm64 on an amd64 host needs no QEMU/binfmt at all
#    (and vice versa). Any RUN in the final stage would execute as the TARGET arch and need emulation.
ARG GO_VERSION=1.27.2
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build
ARG TARGETOS TARGETARCH VERSION=dev COMMIT=none
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=$VERSION -X main.commit=$COMMIT" -o /out/pingboard .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/pingboard /pingboard
USER nonroot:nonroot
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s CMD ["/pingboard", "-healthcheck"]
ENTRYPOINT ["/pingboard"]
