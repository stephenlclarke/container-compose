FROM ghcr.io/linuxcontainers/alpine:3.20
RUN --mount=type=secret,id=api_token,required=true \
    test "$(cat /run/secrets/api_token)" = "external-build-secret-parity-ok" \
    && printf '%s\n' "external-build-secret-parity-ok" > /result
