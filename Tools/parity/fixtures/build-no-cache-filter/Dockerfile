FROM alpine:3.20 AS base
RUN date -u +%s > /base-token

FROM alpine:3.20 AS compile
RUN date -u +%s > /compile-token

FROM alpine:3.20
COPY --from=base /base-token /base-token
COPY --from=compile /compile-token /compile-token
CMD ["cat", "/base-token"]
