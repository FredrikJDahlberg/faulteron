# The injector image: the compiled program and the CLI that attaches it. It runs privileged in the target
# container's network namespace — docker run --rm --privileged --network container:<name> faulteron:local faulteron ...
FROM debian:bookworm-slim AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends clang libbpf-dev linux-libc-dev \
    && rm -rf /var/lib/apt/lists/*
COPY bpf/faulteron.bpf.c /src/
RUN clang -O2 -g -Wall -Werror -target bpf -I"/usr/include/$(uname -m)-linux-gnu" \
    -c /src/faulteron.bpf.c -o /src/faulteron.bpf.o

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends bpftool iproute2 jq \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/faulteron.bpf.o /usr/lib/faulteron/
COPY bin/faulteron /usr/local/bin/
