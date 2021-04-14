#!/usr/bin/bash
export CEREBRAS_WKR_AUTH_FILE
/etc/slurm/slurm_example.sh -i 10.255.253.96 -p 8001 \
    -S /etc/slurm/cm_cert.pem  -C /etc/slurm/cm_client_validation.pem -K /etc/slurm/cm_client_validation_key.pem -P
