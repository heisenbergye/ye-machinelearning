FROM nvcr.io/nvidia/pytorch:25.06-py3

ARG GDRCOPY_VERSION=v2.5.1
ARG EFA_VERSION="1.43.3"
ARG CUDA_HOME="/usr/local/cuda"
ARG OPEN_MPI_PATH="/opt/amazon/openmpi"

# Update and remove the IB libverbs
RUN apt-get update -y && apt-get upgrade -y
RUN apt-get remove -y --allow-change-held-packages \
    ibverbs-utils \
    libibverbs-dev \
    libibverbs1 \
    libmlx5-1

RUN rm -rf /opt/hpcx/ompi \
    && rm -rf /usr/local/mpi \
    && rm -rf /usr/local/ucx \
    && ldconfig

## Install NVIDIA GDRCopy
RUN mkdir /tmp/gdrcopy \
    && git clone -b ${GDRCOPY_VERSION} https://github.com/NVIDIA/gdrcopy.git /tmp/gdrcopy \
    && cd /tmp/gdrcopy \
    && make prefix=/opt/gdrcopy install \
    && rm -rf /tmp/gdrcopy 

ENV LD_LIBRARY_PATH /opt/gdrcopy/lib:/usr/local/cuda/compat:$LD_LIBRARY_PATH
ENV LIBRARY_PATH /opt/gdrcopy/lib:/usr/local/cuda/compat/:$LIBRARY_PATH
ENV CPATH /opt/gdrcopy/include:$CPATH
ENV PATH /opt/gdrcopy/bin:$PATH

# Install build time tools
RUN apt-get update && apt-get install -y --allow-change-held-packages --no-install-recommends \
   curl \
   build-essential \
   cmake \
   git

# Install EFA
RUN mkdir /tmp/efa \
    && cd /tmp/efa \
    && curl -O https://s3-us-west-2.amazonaws.com/aws-efa-installer/aws-efa-installer-${EFA_VERSION}.tar.gz \
    && tar -xf aws-efa-installer-${EFA_VERSION}.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y --skip-kmod --skip-limit-conf --no-verify \
    && rm -rf /tmp/efa \
    && ln -sf /opt/amazon/ofi-nccl/lib/x86_64-linux-gnu/libnccl-net-ofi.so \
        /opt/amazon/ofi-nccl/lib/x86_64-linux-gnu/libnccl-net-aws-ofi.so

ENV LD_LIBRARY_PATH=/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
ENV PATH=/opt/amazon/openmpi/bin/:/opt/amazon/efa/bin:/usr/bin:/usr/local/bin:$PATH

# Configure Open MPI and configure NCCL parameters
RUN mv $OPEN_MPI_PATH/bin/mpirun $OPEN_MPI_PATH/bin/mpirun.real \
    && echo '#!/bin/bash' > $OPEN_MPI_PATH/bin/mpirun \
    && echo '/opt/amazon/openmpi/bin/mpirun.real "$@"' >> $OPEN_MPI_PATH/bin/mpirun \
    && chmod a+x $OPEN_MPI_PATH/bin/mpirun \
    && echo "hwloc_base_binding_policy = none" >> ${OPEN_MPI_PATH}/etc/openmpi-mca-params.conf \
    && echo "rmaps_base_mapping_policy = slot" >> ${OPEN_MPI_PATH}/etc/openmpi-mca-params.conf \
    && echo NCCL_DEBUG=INFO >> /etc/nccl.conf \
    && echo NCCL_SOCKET_IFNAME=^docker0,lo >> /etc/nccl.conf

# Install SSH
RUN apt-get install -y --no-install-recommends \
        openssh-client \
        openssh-server
RUN mkdir -p /var/run/sshd \
    && cat /etc/ssh/ssh_config | grep -v StrictHostKeyChecking > /etc/ssh/ssh_config.new \
    && echo "    StrictHostKeyChecking no" >> /etc/ssh/ssh_config.new \
    && mv /etc/ssh/ssh_config.new /etc/ssh/ssh_config \
    && echo "Port 2022" >>/etc/ssh/sshd_config \
    && sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd

# Configure OpenSSH so that nodes can communicate with each other
RUN rm -rf /root/.ssh/ \
    && mkdir -p /root/.ssh/ \
    && ssh-keygen -q -t rsa -N '' -f /root/.ssh/id_rsa \
    && cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys \
    && printf "Host *\n StrictHostKeyChecking no\n" >> /root/.ssh/config

# Set OFI NCCL plugin
ENV OPAL_PREFIX /opt/amazon/openmpi \
    NCCL_NET_PLUGIN ofi \
    NCCL_TUNER_PLUGIN ofi

## Turn off PMIx Error https://github.com/open-mpi/ompi/issues/7516
ENV PMIX_MCA_gds=hash

RUN apt-get clean && rm -rf /var/lib/apt/list/*
