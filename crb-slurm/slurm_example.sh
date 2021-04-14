#!/usr/bin/bash

touch /tmp/auth_svc.log
chmod 777 /tmp/auth_svc.log || true
echo "HELLO" >> /tmp/auth_svc.log
echo "SLURM_SCRIPT_CONTEXT: $HOSTNAME $SLURM_SCRIPT_CONTEXT" >> /tmp/auth_svc.log
echo "ID: $(id)" >> /tmp/auth_svc.log
echo "PATH: $PATH" >> /tmp/auth_svc.log
echo "CEREBRAS_WKR_AUTH_FILE: $CEREBRAS_WKR_AUTH_FILE" >> /tmp/auth_svc.log

# Example Slurm prolog/epilog script
#
# For more information on Slurm prolog and epilog scripts:
# https://slurm.schedmd.com/prolog_epilog.html
#
# The provided slurmd prolog assumes root but will issue file system
# operations as the job user.

# Cerebras auth service URI components
AUTH_SVC_IP="10.11.12.13"
AUTH_SVC_PORT="8001"
AUTH_SVC_BASE="/api/v1/auth"

# SSL environment
SERVER_CERT="/etc/ssl/certs/cerebras_cm_cert.pem"
CLIENT_CERT="/etc/ssl/certs/cerebras_client_cert.pem"
CLIENT_KEY="/etc/ssl/private/cerebras_client_key.pem"

# Set PROMISC_SSL=1 to disable certificate validation checks
PROMISC_SSL=""

# The slurmd prolog runs on each exec node before any of the tasks
# begin. User credentials will be written in a protected user directory
# under this. It must have rwxrwxrwt perms. The task prolog provides the
# file path to the task.
BASE_AUTH_DIR="/tmp"

# Required commands for operation
REQUIRED_ROOT_CMDS=(curl /usr/sbin/runuser jq)

echo "REQUIRED_ROOT_CMDS: $REQUIRED_ROOT_CMDS" >> /tmp/auth_svc.log 
type "${REQUIRED_ROOT_CMDS[@]}" >> /tmp/auth_svc.log  
echo "$?" >> /tmp/auth_svc.log                        

function warn() {
    echo "$1" 1>&2
}

function die() {
    echo "DIE: $1" >> /tmp/auth_svc.log 
    if [ "$1" ]; then
	warn "$1"
    else
	warn "Aborting"
    fi
    exit 1
}

function usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Slurm prolog and epilog script for managing CS1 auth credentials"
    echo ""
    echo "Install this as the slurmd prolog and epilog, and as the"
    echo "task epilog on all workers. Slurmd must be running as root."
    echo ""
    echo ""
    echo "Options:"
    echo -e "\t-i IP\tServer IP address"
    echo -e "\t-p PORT\tServer port"
    echo -e "\t-S SERVER\tServer validation certificate"
    echo -e "\t-C CERT\tClient certificate"
    echo -e "\t-K KEY\tClient key"
    echo -e "\t-P\t\tDo not validate the server certificate"
    echo -e "\t-d DIR\tBase directory"
}

function verify_env() {
    if [ -z "${SLURM_JOB_ID:-}" -o \
	    -z "${SLURM_JOB_USER:-}" -o \
	    -z "${SLURM_SCRIPT_CONTEXT:-}" ]; then
	echo "die incomplete env." 1>&2 >> /tmp/auth_svc.log
	echo "SLURM_JOB_ID: $SLURM_JOB_ID SLURM_JOB_USER: $SLURM_JOB_USER SLURM_SCRIPT_CONTEXT: $SLURM_SCRIPT_CONTEXT"  1>&2 >> /tmp/auth_svc.log
	die "Incomplete Slurm environment"
    fi

    if ! [ -d "$BASE_AUTH_DIR" ]; then
	die "Base directory does not exist"
    fi
}

function verify_env_root() {
    if [ "$(id -u)" -ne 0 ]; then
	echo "User ID $(id -u) die not running as root" 1>&2 >> /tmp/auth_svc.log
	die "Must run as root"
    fi

    #if ! type "${REQUIRED_ROOT_CMDS[@]}" &>/dev/null; then
	#	die "Missing required root commands: ${REQUIRED_ROOT_CMDS[*]}"
    #fi


    if ! [ -f "$SERVER_CERT" -a -f "$CLIENT_CERT" -a -f "$CLIENT_KEY" ]; then
	die "SSL certs or keys are missing"
    fi
}

function auth_post() {
    local curl_insec_arg=""
    if [ -n "$PROMISC_SSL" ]; then
	curl_insec_arg="--insecure"
    fi

    curl -f -s -d "$2" \
	 --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
	 --cacert "$SERVER_CERT" $curl_insec_arg \
	 "https://${AUTH_SVC_IP}:${AUTH_SVC_PORT}${AUTH_SVC_BASE}/$1"
}

function client_id() {
    echo -n "slurm_cs1_credential_${SLURM_JOB_USER}_${SLURM_JOB_ID}"
}

function user_cred_path() {
    echo -n "${BASE_AUTH_DIR}/slurm_cs1_credentials_${SLURM_JOB_USER}/cs1_credential_${SLURM_JOB_ID}.txt"
}

function prolog_slurmd() {
    # The slurmd prolog runs as root on every executor before the task starts.
    verify_env
    verify_env_root

    local reqstr
    local token
    local bdir

    bdir="$(dirname "$(user_cred_path)")"
    /usr/sbin/runuser -u "$SLURM_JOB_USER" -- \
	    mkdir -p -m 700 "$bdir" &>/dev/null || :

    reqstr="$( echo '{}' | jq -a -c --arg client_id "$(client_id)" '.client_id=$client_id|.activate=true' )"
    token="$(auth_post "request" "$reqstr" | jq -r '.credential.token' 2>/dev/null )"
    #if [ "$?" -ne 0 ]; then
#	die "Failed to request client"
#    fi

    if [ -z "$token" ]; then
	die "Failed to get a token"
    fi

    echo "$token" | /usr/sbin/runuser -u "$SLURM_JOB_USER" -- \
			    dd of="$(user_cred_path)" &>/dev/null
    if [ "$?" -ne 0 ]; then
        echo "SLURM_JOB_USER: $SLURM_JOB_USER" >> /tmp/auth_svc.log
        echo "user_cred_path: $(user_cred_path)" >> /tmp/auth_svc.log
	die "Failed to write token"
    fi
}

function epilog_slurmd() {
    # Slurmd epilog runs as root on every executor at job termination
    verify_env
    verify_env_root

    local reqstr

    reqstr="$( echo '{}' | jq -a -c --arg client_id "$(client_id)" '.client_id=$client_id' )"
    auth_post "remove" "$reqstr" &>/dev/null

    echo "/usr/sbin/runuser -u "$SLURM_JOB_USER" -- rm -f $(user_cred_path)" >> /tmp/auth_svc.log

    /usr/sbin/runuser -u "$SLURM_JOB_USER" -- rm -f "$(user_cred_path)" &>/dev/null
    

}

function prolog_task() {
    # The task prolog runs as the job user in the job environment before
    # launching the task. Stdout provides commands.
    verify_env
    echo "print setting cerebras credential file path: $(user_cred_path)" >> /tmp/auth_svc.log
    echo "export CEREBRAS_WKR_AUTH_FILE=$(user_cred_path)"
}

while getopts "hi:p:S:C:K:Pd:" OPTION; do
    case "$OPTION" in
	'h')
	    usage
	    exit 0
	    ;;

	'i')
	    AUTH_SVC_IP="$OPTARG"
	    ;;

	'p')
	    AUTH_SVC_PORT="$OPTARG"
	    ;;

	'S')
	    SERVER_CERT="$OPTARG"
	    ;;

	'C')
	    CLIENT_CERT="$OPTARG"
	    ;;

	'K')
	    CLIENT_KEY="$OPTARG"
	    ;;

	'P')
	    PROMISC_SSL=1
	    ;;

	'd')
	    BASE_AUTH_DIR="$OPTARG"
	    ;;

	*)
	    warn "Invalid command line arg: $OPTION"
	    warn ""
	    usage
	    exit 1
    esac
done

case "${SLURM_SCRIPT_CONTEXT:-}" in
    "prolog_slurmctld")
	;;
	
    "epilog_slurmctld")
	;;
	
    "prolog_slurmd")
	prolog_slurmd
	;;

    "epilog_slurmd")
	epilog_slurmd
	;;

    "prolog_task")
	prolog_task
	;;

    "epilog_task")
	;;

    "prolog_srun")
	;;

    "epilog_srun")
	;;

    *)
	die "Unknown slurm context: $SLURM_SCRIPT_CONTEXT"
	;;
esac

exit 0
