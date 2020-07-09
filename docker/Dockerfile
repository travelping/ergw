# -- build-environment --
# see https://docs.docker.com/engine/userguide/eng-image/multistage-build/

FROM erlang:23.0.3-alpine AS build-env

WORKDIR /build
RUN     apk update && apk --no-cache upgrade && \
		apk --no-cache add \
			gcc \
			git \
			libc-dev libc-utils \
			libgcc \
			linux-headers \
			make bash \
			musl-dev musl-utils \
			ncurses-dev \
			pcre2 \
			pkgconf \
			scanelf \
			zlib

ADD     . /build
RUN     rebar3 as prod release

# -- runtime image --

FROM alpine:3.11

WORKDIR /
RUN     apk update && \
		apk --no-cache upgrade && \
		apk --no-cache add zlib ncurses-libs libcrypto1.1 lksctp-tools tini
COPY    docker/docker-entrypoint.sh /
COPY    config/ergw-c-node.config /etc/ergw-c-node/

RUN     mkdir -p /var/lib/ergw/ && \
		touch /var/lib/ergw/ergw.state

COPY    --from=build-env /build/_build/prod/rel/ /opt/

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
CMD     ["/opt/ergw-c-node/bin/ergw-c-node", "foreground"]
