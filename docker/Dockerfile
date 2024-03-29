# -- build-environment --
# see https://docs.docker.com/engine/userguide/eng-image/multistage-build/

FROM quay.io/travelping/alpine-erlang:23.3 AS build-env

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
			zlib \
			yaml-dev \
			tzdata

ADD     . /build
RUN     rebar3 as prod release

# -- runtime image --

FROM alpine:3.14

WORKDIR /
RUN     apk update && \
		apk --no-cache upgrade && \
		apk --no-cache add libgcc libstdc++ zlib ncurses-libs libcrypto1.1 lksctp-tools tini tzdata yaml
COPY    docker/docker-entrypoint.sh /
COPY    config/ergw-c-node.config /etc/ergw-c-node/

RUN     mkdir -p /var/lib/ergw/ && \
		touch /var/lib/ergw/ergw.state

COPY    --from=build-env /build/_build/prod/rel/ /opt/

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
CMD     ["/opt/ergw-c-node/bin/ergw-c-node", "foreground"]
