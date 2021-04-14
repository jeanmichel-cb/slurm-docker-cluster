from giovtorres/slurm-docker-cluster:latest
ENV PATH="/usr/sbin:${PATH}"
RUN yum install -y singularity-runtime singularity net-tools nc openssl jq curl
RUN  adduser lab -m -u 1000
COPY slurm.conf /etc/slurm/slurm.conf
COPY slurmdbd.conf /etc/slurm/slurmdbd.conf
COPY slurm_example.sh /etc/slurm/
COPY auth_svc.sh /etc/slurm/
COPY cm_cert.pem  cm_client_validation_key.pem  cm_client_validation.pem  cm_key.pem  /etc/slurm/
WORKDIR /monolith

