# GIMPS на NVIDIA GPU: PRPLL-NTT (PRP) + mfaktc (TF) + AutoPrimeNet
# Требования к хосту: драйвер NVIDIA >= 570 (CUDA 12.8), NVIDIA Container Toolkit.
ARG CUDA_VER=12.8.1
ARG UBUNTU=ubuntu24.04

# ---------- сборка ----------
FROM nvidia/cuda:${CUDA_VER}-devel-${UBUNTU} AS build
ARG PRPLL_REF
ARG MFAKTC_REF
ARG APN_REF
ARG MFAKTC_ARCHS
COPY scripts/ /src/scripts/
RUN chmod +x /src/scripts/* && /src/scripts/build.sh deps-build \
 && PRPLL_REF=${PRPLL_REF:-5ce7df1} MFAKTC_REF=${MFAKTC_REF:-0.24.1} \
    APN_REF=${APN_REF:-b4426a13f96c874cf6202aefa3b8f97345069245} \
    MFAKTC_ARCHS="${MFAKTC_ARCHS:-70 75 80 86 89 90 100 120}" \
    /src/scripts/build.sh build

# ---------- рантайм (маленький образ: base + nvrtc) ----------
FROM nvidia/cuda:${CUDA_VER}-base-${UBUNTU}
LABEL org.opencontainers.image.title="gimps-gpu" \
      org.opencontainers.image.description="GIMPS Mersenne prime search on NVIDIA GPUs: PRPLL-NTT, mfaktc, AutoPrimeNet"
COPY scripts/build.sh /tmp/build.sh
RUN bash /tmp/build.sh deps-runtime && rm /tmp/build.sh
COPY --from=build /opt/gimps /opt/gimps
RUN echo /opt/gimps/lib > /etc/ld.so.conf.d/gimps.conf && ldconfig \
 && for b in /opt/gimps/bin/*; do ln -sf "$b" /usr/local/bin/; done \
 && ldd /opt/gimps/bin/prpll-cuda | grep -q 'libnvrtc.*=> /' \
 && python3 /opt/gimps/bin/autoprimenet.py --version

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    DATA_DIR=/data \
    GIMPS_MODE=prp \
    PRPLL_BACKEND=cuda
VOLUME ["/data"]
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["gimps-start"]
