ARG BASE_NAME=debian
ARG IMAGE_ARCH=linux/arm64/v8
ARG IMAGE_TAG=3-bookworm
ARG DOCKER_REGISTRY=torizon

FROM --platform=$IMAGE_ARCH $DOCKER_REGISTRY/$BASE_NAME:$IMAGE_TAG AS tflite-libs

RUN apt-get -y update && apt-get install -y \
    python3 python3-dev python3-numpy python3-pybind11 \
    python3-pip python3-setuptools python3-wheel \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

RUN apt-get -y update && apt-get install -y \
        cmake build-essential gcc g++ git wget unzip patchelf \
        autoconf automake libtool curl gfortran \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

RUN apt-get -y update && apt-get install -y \
        zlib1g zlib1g-dev libssl-dev \
        imx-gpu-viv-wayland-dev openssl libffi-dev libjpeg-dev \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY recipes /build

RUN ./nn-imx_1.3.0.sh
RUN ./tim-vx.sh
RUN ./tensorflow-lite_2.9.1.sh


FROM --platform=$IMAGE_ARCH $DOCKER_REGISTRY/$BASE_NAME:$IMAGE_TAG AS tflite-build

ARG FAST=0

RUN apt-get -y update && apt-get install -y \
    python3 python3-dev python3-numpy python3-pybind11 \
    python3-pip python3-setuptools python3-wheel \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

RUN apt-get -y update && apt-get install -y \
        cmake build-essential gcc g++ git wget unzip patchelf \
        autoconf automake libtool curl gfortran \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

RUN apt-get -y update && apt-get install -y \
        zlib1g zlib1g-dev libssl-dev \
        imx-gpu-viv-wayland-dev openssl libffi-dev libjpeg-dev \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY recipes /build

RUN ./nn-imx_1.3.0.sh
RUN ./tim-vx.sh

COPY --from=tflite-libs /build /build
COPY --from=tflite-libs /out /out
COPY --from=tflite-libs /workdir /workdir

RUN if [ "${FAST}" = "1" ]; then echo "Using cached tensorflow-lite from tflite-libs stage"; else ./tensorflow-lite_2.9.1.sh; fi
RUN ./tflite-vx-delegate.sh

RUN set -eux; \
    echo "uname: $(uname -m)"; \
    ls -la /out/usr/lib || true; \
    find /out -maxdepth 6 -type f \( -name 'libvx_delegate.so' -o -name '*delegate*.so*' \) -print 2>/dev/null || true


FROM --platform=$IMAGE_ARCH $DOCKER_REGISTRY/$BASE_NAME:$IMAGE_TAG AS base

LABEL org.opencontainers.image.title="tflite-npu-base"
LABEL org.opencontainers.image.description="Reusable TFLite runtime + i.MX8MP VX delegate base image"

RUN apt-get -y update && apt-get install -y \
    python3 python3-numpy python3-pip \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

COPY --from=tflite-build /out /out
COPY --from=tflite-build /build /build
RUN cp -r /build/* / && rm -rf /build
RUN cp -r /out/* / && rm -rf /out

RUN ldconfig

RUN test -f /usr/lib/libvx_delegate.so || test -f /usr/lib/aarch64-linux-gnu/libvx_delegate.so || \
    (echo "ERROR: libvx_delegate.so not found in base image" && \
     find /usr -maxdepth 4 -type f -name 'libvx_delegate.so' -print || true && \
     exit 1)

RUN pip3 install --break-system-packages --no-cache-dir /tflite_runtime-*.whl && rm -rf /tflite_runtime-*.whl

RUN apt-get -y update && apt-get install -y \
        libovxlib \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

RUN apt-get -y update && apt-get install -y --no-install-recommends \
        python3-opencv \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

RUN apt-get -y update && apt-get install -y --no-install-recommends \
        pkg-config libavcodec-dev libavformat-dev libswscale-dev \
        libtbbmalloc2 libtbb-dev libjpeg-dev libpng-dev libdc1394-25 \
        libdc1394-dev protobuf-compiler libgflags-dev libgoogle-glog-dev \
        libblas-dev libhdf5-serial-dev liblmdb-dev libleveldb-dev liblapack-dev \
        libsnappy-dev libprotobuf-dev libopenblas-dev libboost-dev \
        libboost-all-dev libeigen3-dev libatlas-base-dev libne10-10 libne10-dev \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

RUN apt-get -y update && apt-get install -y --no-install-recommends libgstreamer1.0-0 \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly gstreamer1.0-tools gstreamer1.0-OpenCV \
        python3-gst-1.0 \
    && apt-get clean && apt-get autoremove && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1
ENV TFLITE_VX_DELEGATE=/usr/lib/libvx_delegate.so

WORKDIR /app
