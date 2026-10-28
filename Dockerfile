# GIMPS на NVIDIA RTX 30/40/50: PRPLL-NTT (PRP) + mfaktc (TF) на GPU, mprime (P-1/PRP) на CPU,
# AutoPrimeNet, живой журнал прогресса (gimps-watch), внешний бэкап (rclone).
# Требования к хосту: драйвер NVIDIA >= 575 (vast.ai: фильтр «CUDA >= 12.9»), NVIDIA Container Toolkit.
# CUDA 12.9 — последняя 12.x: поддерживает sm_86/89/120 (и B300 sm_103) и работает на большинстве хостов;
# CUDA 13.x потребовала бы драйвер >= 580 и отсекла бы часть офферов без выигрыша для этих программ.
ARG CUDA_VER=12.9.1
ARG UBUNTU=ubuntu24.04

# ---------- сборка ----------
FROM nvidia/cuda:${CUDA_VER}-devel-${UBUNTU} AS build
ARG PRPLL_REF
ARG MFAKTC_REF
ARG APN_REF
ARG MFAKTC_ARCHS
COPY build.sh gimps-start gimps-stop gimps-status gimps-backup gimps-monitor gimps-watch gimps-cpu-setup gimps-notify mprime-setup.exp /src/scripts/
RUN chmod +x /src/scripts/* \
 && /src/scripts/build.sh deps-build \
 && /src/scripts/build.sh versions \
 && /src/scripts/build.sh build

# ---------- рантайм (маленький образ: base + nvrtc) ----------
FROM nvidia/cuda:${CUDA_VER}-base-${UBUNTU}
LABEL org.opencontainers.image.title="gimps-gpu" \
      org.opencontainers.image.description="GIMPS on NVIDIA RTX 30/40/50 + CPU: PRPLL-NTT, mfaktc, mprime, AutoPrimeNet"
COPY build.sh /tmp/build.sh
RUN bash /tmp/build.sh deps-runtime && rm /tmp/build.sh
COPY --from=build /opt/gimps /opt/gimps
RUN echo /opt/gimps/lib > /etc/ld.so.conf.d/gimps.conf && ldconfig \
 && for b in /opt/gimps/bin/*; do ln -sf "$b" /usr/local/bin/; done \
 && ldd /opt/gimps/bin/prpll-cuda | grep -q 'libnvrtc.*=> /' \
 && python3 /opt/gimps/bin/autoprimenet.py --version \
 && python3 -m py_compile /opt/gimps/bin/gimps-monitor /opt/gimps/bin/gimps-notify \
 && test -x /opt/gimps/mprime/mprime \
 && command -v unbuffer expect rclone >/dev/null \
 && echo "PRPLL $(cat /opt/gimps/PRPLL_VERSION) | mfaktc $(cat /opt/gimps/MFAKTC_VERSION) | mprime $(cat /opt/gimps/MPRIME_VERSION)" \
 && printf '%s\n' '[ -t 1 ] && command -v gimps-status >/dev/null && echo "GIMPS: gimps-watch — живой журнал, gimps-status — сводка, gimps-stop — остановка"' >> /root/.bashrc

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    CUDA_DEVICE_ORDER=PCI_BUS_ID \
    DATA_DIR=/data \
    GIMPS_MODE=prp \
    PRPLL_BACKEND=cuda
VOLUME ["/data"]
WORKDIR /data
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["gimps-start"]
