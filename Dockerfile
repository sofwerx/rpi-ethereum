# NOTE: This Dockerfile must run on an x86_64 host.
FROM multiarch/alpine:armhf-v3.6 as ethereum

RUN apk add --no-cache git
RUN git clone https://github.com/docker-library/golang /docker-golang

RUN apk add --no-cache ca-certificates

ENV GOLANG_VERSION 1.9.2

# no-pic.patch: https://golang.org/issue/14851 (Go 1.8 & 1.7)
RUN mkdir -p /go-alpine-patches/ ; \
    cp /docker-golang/1.9/alpine3.6/*.patch /go-alpine-patches/

RUN set -eux; \
	apk add --no-cache --virtual .build-deps \
		bash \
		gcc \
		musl-dev \
		openssl \
		go \
	; \
	export \
# set GOROOT_BOOTSTRAP such that we can actually build Go
		GOROOT_BOOTSTRAP="$(go env GOROOT)" \
# ... and set "cross-building" related vars to the installed system's values so that we create a build targeting the proper arch
# (for example, if our build host is GOARCH=amd64, but our build env/image is GOARCH=386, our build needs GOARCH=386)
		GOOS="$(go env GOOS)" \
		GOARCH="$(go env GOARCH)" \
		GOHOSTOS="$(go env GOHOSTOS)" \
		GOHOSTARCH="$(go env GOHOSTARCH)" \
	; \
# also explicitly set GO386 and GOARM if appropriate
# https://github.com/docker-library/golang/issues/184
	apkArch="$(apk --print-arch)"; \
	case "$apkArch" in \
		armhf) export GOARM='6' ;; \
		x86) export GO386='387' ;; \
	esac; \
	\
	wget -O go.tgz "https://golang.org/dl/go$GOLANG_VERSION.src.tar.gz"; \
	echo '665f184bf8ac89986cfd5a4460736976f60b57df6b320ad71ad4cef53bb143dc *go.tgz' | sha256sum -c -; \
	tar -C /usr/local -xzf go.tgz; \
	rm go.tgz; \
	\
	cd /usr/local/go/src; \
	for p in /go-alpine-patches/*.patch; do \
		[ -f "$p" ] || continue; \
		patch -p2 -i "$p"; \
	done; \
	./make.bash; \
	\
	rm -rf /go-alpine-patches; \
	apk del .build-deps; \
	\
	export PATH="/usr/local/go/bin:$PATH"; \
	go version

ENV GOPATH /go
ENV PATH $GOPATH/bin:/usr/local/go/bin:$PATH

RUN mkdir -p "$GOPATH/src" "$GOPATH/bin" && chmod -R 777 "$GOPATH"
WORKDIR $GOPATH

RUN cp -a /docker-golang/1.9/alpine3.6/go-wrapper /usr/local/bin/go-wrapper

RUN apk add --no-cache make build-base linux-headers

RUN git clone https://github.com/ethereum/go-ethereum /go-ethereum
WORKDIR /go-ethereum
RUN make all

#
# Build parity for arm
#
FROM ubuntu:14.04 as parity
WORKDIR /build
# install tools and dependencies
RUN apt-get -y update && \
        apt-get install -y --force-yes --no-install-recommends \
        curl git make g++ gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
        libc6-dev-armhf-cross wget file ca-certificates \
        binutils-arm-linux-gnueabihf \
        && \
    apt-get clean

# install rustup
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y

# rustup directory
ENV PATH /root/.cargo/bin:$PATH

ENV RUST_TARGETS="arm-unknown-linux-gnueabihf"

# multirust add arm--linux-gnuabhf toolchain
RUN rustup target add armv7-unknown-linux-gnueabihf

# show backtraces
ENV RUST_BACKTRACE 1

# show tools
RUN rustc -vV && \
    cargo -V 

# build parity
RUN git clone https://github.com/paritytech/parity && \
        cd parity && \
        git checkout beta && \
        git pull && \
        mkdir -p .cargo && \
        echo '[target.armv7-unknown-linux-gnueabihf]\n\
        linker = "arm-linux-gnueabihf-gcc"\n'\
        >>.cargo/config && \
        cat .cargo/config && \
        cargo build --target armv7-unknown-linux-gnueabihf --release --verbose && \
        ls /build/parity/target/armv7-unknown-linux-gnueabihf/release/parity && \
        /usr/bin/arm-linux-gnueabihf-strip /build/parity/target/armv7-unknown-linux-gnueabihf/release/parity

RUN file /build/parity/target/armv7-unknown-linux-gnueabihf/release/parity

#
# Pull all binaries into a second stage deploy alpine container
#
FROM multiarch/alpine:armhf-v3.6

RUN apk add --no-cache ca-certificates
COPY --from=ethereum /go-ethereum/build/bin/* /usr/local/bin/
COPY --from=parity /build/parity/target/arm7-unknown-linux-gnueabihf/release/* /usr/local/bin

EXPOSE 8080 8180 8545 8546 30303 30303/udp 30304/udp

