# tflite-npu-base

Reusable base image for Verdin i.MX8MP (Torizon OS, Debian Bookworm).

Provides:
- `tflite_runtime` Python package built from NXP/Toradex reference recipes
- TIM-VX + VX delegate (`/usr/lib/libvx_delegate.so`) for i.MX8MP NPU
- OVXLIB runtime (`libovxlib`)
- OpenCV with GStreamer support

## Build stages

The Dockerfile uses three stages:

- `tflite-libs`: builds nn-imx, tim-vx, tensorflow-lite
- `tflite-build`: builds the VX delegate on top of the tflite-libs artifacts
- `base`: final runtime image; copies built artifacts, installs the tflite_runtime wheel, installs OpenCV and GStreamer packages

The `ARG FAST=1` build argument skips rebuilding tensorflow-lite in `tflite-build` and reuses the artifact from `tflite-libs`.

## Build

Native build on the Verdin (arm64):

```bash
docker build --network=host -t <DOCKERHUB_USERNAME>/tflite-npu-base:<tag> .
docker push <DOCKERHUB_USERNAME>/tflite-npu-base:<tag>
```

## Image contract

After build the image provides:

- `python3`
- `tflite_runtime.interpreter` importable
- `/usr/lib/libvx_delegate.so` present
- `libovxlib` installed
- OpenCV importable as `cv2` with GStreamer backend

Environment variable set in image:

- `TFLITE_VX_DELEGATE=/usr/lib/libvx_delegate.so`

## Verify

```bash
docker run --rm <DOCKERHUB_USERNAME>/tflite-npu-base:<tag> \
  python3 -c "import tflite_runtime.interpreter as t; print('tflite_runtime OK')"

docker run --rm <DOCKERHUB_USERNAME>/tflite-npu-base:<tag> \
  sh -c "ls -l /usr/lib/libvx_delegate.so && ldd /usr/lib/libvx_delegate.so | head"
```

## Verify with prebuilt image
```bash
docker run --rm euvoxel/tflite-npu-base:latest \
  python3 -c "import tflite_runtime.interpreter as t; print('tflite_runtime OK')"

docker run --rm euvoxel/tflite-npu-base:latest \
  sh -c "ls -l /usr/lib/libvx_delegate.so && ldd /usr/lib/libvx_delegate.so | head"
```

## Usage in app images

```dockerfile
FROM kadirguzel/tflite-npu-base:<tag>

WORKDIR /app
COPY src /app/src

ENTRYPOINT ["python3", "-u", "/app/src/app.py"]
```

## Development (bind-mount workflow)

`docker-compose.dev.yml` starts a long-running container with a host directory mounted at `/workspace`:

```bash
docker compose -f docker-compose.dev.yml up -d
docker exec -it tflite-dev sh
```

Mount path defaults to `./workspace`. Edit `docker-compose.dev.yml` to change the host path.
