#!/bin/bash
source global_variables.sh

# IMPORTANT: Export artifacts to /out (same contract as the working tflite-rtsp Dockerfile).
# global_variables.sh sets D=/build, but the runtime stage copies /out -> /.
# If we don't install into /out here, libvx_delegate.so never reaches the final image.
D='/out'
mkdir -p "${D}"

PN='tensorflow-lite'
PV='2.9.1'
# tensorflow-lite_2.9.1.sh clones into ${WORKDIR}/tensorflow-imx
T=${WORKDIR}'/tensorflow-imx'
S=${WORKDIR}'/tflite-vx-delegate-imx'
SRCBRANCH='lf-5.15.52_2.1.0'
BUILD_NUM_JOBS=16
STAGING_BINDIR_NATIVE='/usr/bin'
VX_IMX_SRC='https://github.com/nxp-imx/tflite-vx-delegate-imx.git'
B='/tflite-vx-delegate-imx-build'

rm -rf "${S}" "${B}"
pushd ${WORKDIR} && git clone -b ${SRCBRANCH} ${VX_IMX_SRC} ${S} && popd

# Fail fast if the tensorflow-imx sources aren't available where we expect.
if [ ! -d "${T}/tensorflow/lite" ]; then
        echo "ERROR: expected tensorflow sources at ${T}/tensorflow/lite" >&2
        echo "Hint: tensorflow-lite_2.9.1.sh should have cloned tensorflow-imx into ${WORKDIR}/tensorflow-imx" >&2
        ls -la "${WORKDIR}" || true
        exit 1
fi

# -----------------------------------------------------------------------------
# Compatibility patches
#
# This delegate branch expects newer TIM-VX APIs than the TIM-VX version we pin
# in this base image. Patch the sources to compile with the installed headers.
# -----------------------------------------------------------------------------

OP_MAP_CC="${S}/op_map.cc"
cd "${S}"

if [ ! -f "${OP_MAP_CC}" ]; then
        echo "ERROR: expected ${OP_MAP_CC} to exist" >&2
        exit 1
fi

# 1) tim::vx::TensorSpec::GetElementNum() doesn't exist in our TIM-VX.
#    Older TIM-VX also doesn't expose a readable shape accessor on TensorSpec.
#    The check is only used as a guard; replace it with a constant `true` to
#    keep behavior simple and compatible.
if grep -n -E "GetElementNum\(\)|\.Size\(\)" "${OP_MAP_CC}" >/dev/null 2>&1; then
        sed -i -E 's/in->GetSpec\(\)\.GetElementNum\(\)[[:space:]]*!=[[:space:]]*0/true/g' "${OP_MAP_CC}"
        sed -i -E 's/in->GetSpec\(\)\.Size\(\)[[:space:]]*!=[[:space:]]*0/true/g' "${OP_MAP_CC}"
fi

# 2) tim::vx::ops::Broadcast is missing. Replace it with Tile (exists in TIM-VX).
if grep -n -F "tim::vx::ops::Broadcast" "${OP_MAP_CC}" >/dev/null 2>&1; then
	sed -i 's/tim::vx::ops::Broadcast/tim::vx::ops::Tile/g' "${OP_MAP_CC}"
fi

# The Broadcast code uses std::vector<int> broadcast_param; Tile expects a
# std::vector<uint32_t> multipliers.
if grep -n -E "std::vector< *int *> *broadcast_param" "${OP_MAP_CC}" >/dev/null 2>&1; then
	sed -i -E 's/std::vector< *int *> *broadcast_param/std::vector<uint32_t> broadcast_param/g' "${OP_MAP_CC}"
fi

# 3) tim::vx::ops::Gather ctor in our TIM-VX is (Graph*, axis) rather than
#    (Graph*, axis, batch_dims). Drop extra args and keep (graph, axis).
if grep -n -E "CreateOperation<tim::vx::ops::Gather>\(" "${OP_MAP_CC}" >/dev/null 2>&1; then
        # Be tolerant to whitespace/newlines inside the call.
        # Reduce any Gather CreateOperation with >= 3 args down to (graph, axis).
        sed -i -z -E 's/CreateOperation<tim::vx::ops::Gather>\(\s*([^,\)]+)\s*,\s*([^,\)]+)\s*,\s*[^\)]*\)/CreateOperation<tim::vx::ops::Gather>(\1, \2)/g' "${OP_MAP_CC}"

        # Also handle the common pattern in this delegate: graph->CreateOperation<Gather>(axis, batch_dims)
        # Our TIM-VX only supports Gather(axis).
        sed -i -z -E 's/CreateOperation<tim::vx::ops::Gather>\(\s*([^,\)]+)\s*,\s*[^\)]*\)/CreateOperation<tim::vx::ops::Gather>(\1)/g' "${OP_MAP_CC}"
fi



mkdir ${B}
cd ${B}

# Fail fast on missing TIM-VX staging. tim-vx.sh installs into /out (this recipe's D).
if [ ! -f "${D}${includedir}/tim/vx/graph.h" ]; then
        echo "ERROR: TIM-VX headers not found at ${D}${includedir}/tim/vx/graph.h" >&2
        echo "Hint: ensure tim-vx.sh completed successfully and installed into /out." >&2
        ls -la "${D}${includedir}/tim/vx" || true
        exit 1
fi
if [ ! -f "${D}${libdir}/libtim-vx.so" ]; then
        echo "ERROR: TIM-VX library not found at ${D}${libdir}/libtim-vx.so" >&2
        echo "Hint: ensure tim-vx.sh installed libtim-vx.so into /out/usr/lib." >&2
        ls -la "${D}${libdir}" || true
        exit 1
fi

# tensorflow-lite_2.9.1.sh currently stages the TFLite shared library into
# ${D}${libdir} where global_variables.sh defines D=/build.
# The delegate's Findtensorflow.cmake expects an explicit path via TFLITE_LIB_LOC.
TFLITE_LIB_BUILDROOT="/build${libdir}/libtensorflow-lite.so"
if [ ! -f "${TFLITE_LIB_BUILDROOT}" ]; then
        echo "ERROR: tensorflow-lite library not found: ${TFLITE_LIB_BUILDROOT}" >&2
        echo "Hint: tensorflow-lite_2.9.1.sh installs into /build by default; either stage it to /out or keep this pointer in sync." >&2
        ls -la "/build${libdir}" || true
        exit 1
fi

cmake ${S} \
        -DFETCHCONTENT_FULLY_DISCONNECTED=OFF \
        -DTIM_VX_INSTALL=${D}/usr \
        -DFETCHCONTENT_SOURCE_DIR_TENSORFLOW=${T} \
        -DTFLITE_LIB_LOC=${TFLITE_LIB_BUILDROOT} 
make vx_delegate -j 16
#make . -j 16
make benchmark_model -j 16
make label_image -j 16
make install

# install libraries
install -d ${D}${libdir}

# The delegate output location varies by upstream version:
#   - some versions: ${B}/vx_delegate/libvx_delegate.so
#   - current observed: ${B}/libvx_delegate.so
DELEGATE_SO="${B}/vx_delegate/libvx_delegate.so"
if [ ! -f "${DELEGATE_SO}" ]; then
        if [ -f "${B}/libvx_delegate.so" ]; then
                DELEGATE_SO="${B}/libvx_delegate.so"
        fi
fi
if [ ! -f "${DELEGATE_SO}" ]; then
        echo "ERROR: expected libvx_delegate.so to exist under ${B}" >&2
        find "${B}" -maxdepth 4 -type f -name 'libvx_delegate.so' -print || true
        exit 1
fi
cp --no-preserve=ownership -d "${DELEGATE_SO}" "${D}${libdir}/libvx_delegate.so"
cp --no-preserve=ownership -d ${B}/libvx_custom_op.a ${D}${libdir}

cp ${B}/_deps/tensorflow-build/tools/benchmark/benchmark_model ${D}
cp ${B}/_deps/tensorflow-build/examples/label_image/label_image ${D}
# install header files
install -d ${D}${includedir}/tensorflow-lite-vx-delegate
cd ${S}
cp --parents \
    $(find . -name "*.h*") \
    ${D}${includedir}/tensorflow-lite-vx-delegate


