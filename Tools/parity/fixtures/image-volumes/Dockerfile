FROM alpine:3.22

RUN mkdir -p /image-data /image-cache \
    && printf 'image-data-seed\n' > /image-data/seed.txt \
    && printf 'image-cache-seed\n' > /image-cache/seed.txt

VOLUME ["/image-data", "/image-cache"]

CMD ["sh", "-ec", "while :; do sleep 600; done"]
