# sshKeyRotate
#
# script to automate the rotation of ssh keys for remote users on linux hosts
#
# partial reimplementation of the "ssh-copy-id" script, with corrections and enhancements where possible.
#
# sequence:
#     1. generate a new PKA key pair
#     2. copy the public key to the "~/.ssh/authorized_keys" file on the remote host (remote directory and file will be created if necessary)
#     3. connect to the remote host using the new private key to assess the validity of the new PKA key pair
#     4. delete all old related public keys in the "~/.ssh/authorized_keys" file on the remote host
#     5. copy the new private key to the local "~/.ssh/config" file (local directory and file will be created if necessary)
#
# related keys are identified using the comment section of the public key and according to the following json structure:
#     {"sshKeyRotate":"0.0.0","keyId":"abc","keySerial":123}
#
# where:
#     - "sshKeyRotate" contains the version of this script at time of execution
#     - "keyId" contains the hash of the string "local_user@local_host remote_user@remote_host"
#     - "keySerial" contains the Epoch seconds at time of creation of the new PKA key pair

#!/bin/bash
set -euo pipefail

# constants
SCRIPT_VERSION='0.2.0'

# variables setable via command-line arguments
remote_user=''
remote_host=''
key_type='rsa'
key_bits=2048      # 1024/2048/4096
verbosity=0        # verbosity (0: silent, 1: verbose)

# internal variables
local_user="$(whoami)"
local_host="$(uname -n)"
key_filename=''
key_id=''                # hash of the string "local_user@local_host remote_user@remote_host"
key_serial=''            # epoch seconds at time of creation
key_comment=''           # json structure in the comment section of the key (to identify related keys)

# - - - helper functions - - -

# function to set variables according to the provided command-line arguments
# expected arguments: $1 as array of command-line arguments provided to the script
function initialise() {
	while [ $# -gt 0 ]
	do
		case "$1" in
			-u|--user) remote_user="${2-}"; shift ;;
			-h|--host) remote_host="${2-}"; shift ;;
			-t|--type) key_type="${2-}"; shift ;;
			-b|--bits) key_bits="${2-}"; shift ;;
			-v|--verbosity) verbosity=1 ;;
			-V|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
			-H|--help)
				echo 'script: sshKeyRotate'
				echo 'usage:'
				echo '    -u|--user <xxx>: remote user (required)'
				echo '    -h|--host <xxx>: remote host (required)'
				echo "    -t|--type <xxx>: PKI key pair generation algorythm (default: 'rsa')"
				echo '    -b|--bits <000>: key size (default: 2048)'
				echo '    -v|--verbose: enable verbosity'
				echo "    -V|--version: print the script's version (current: $SCRIPT_VERSION)"
				echo '    -H|--help: this help message'
				exit 0 ;;
			*) echo "invalid argument: \"$1\" (try '-H|--help')"; exit 1 ;;
		esac
		shift
	done

	if [ -z "$remote_user" ] || [ -z "$remote_host" ]
	then
		echo "arguments '-u|--user' and '-h|--host' are required (try '-H|--help')"
		exit 1
	fi

	# initial set up
	key_id="$(echo "$local_user@$local_host $remote_user@$remote_host" | md5sum | cut -d ' ' -f 1)"
	key_serial="$(date +%s)"
	key_comment="{\"sshKeyRotate\":\"$SCRIPT_VERSION\",\"keyId\":\"$key_id\",\"keySerial\":$key_serial}"
	key_filename="id_${key_type}_${key_id}_${key_serial}"

	if [ "$verbosity" -gt 0 ]
	then
		echo 'variables set'
		echo "    remote_user: $remote_user"
		echo "    remote_host: $remote_host"
		echo "    key_type: $key_type"
		echo "    key_bits: $key_bits"
		echo "    verbosity: $verbosity"
		echo "    local_user: $local_user"
		echo "    local_host: $local_host"
		echo "    key_id: $key_id"
		echo "    key_serial: $key_serial"
		echo "    key_comment: $key_comment"
		echo "    key_filename: $key_filename"
	fi
}

# - - - main - - -

# initialise variables according to command-line arguments
initialise "$@"

# connect to remote host and set up necessary remote dirs and files
ssh "${remote_user}@${remote_host}" "dir=\"/home/${remote_user}/.ssh\"; file=\"\$dir/authorized_keys\"; if [ ! -d \"\$dir\" ]; then mkdir \"\$dir\" && chmod 700 \"\$dir\"; fi && if [ ! -f \"\$file\" ]; then touch \"\$file\" && chmod 600 \"\$file\"; fi; exit"
if [ "$verbosity" -gt 0 ]; then echo "initial connectivity to remote host: checked"; fi

# generate new local key pair (with empty passphrase)
ssh-keygen -q -t "$key_type" -b "$key_bits" -N "" -C "$key_comment" -f "$key_filename"
if [ "$verbosity" -gt 0 ]; then echo "new local key pair: generated"; fi

# copy new public key to remote host
cat "$key_filename.pub" | ssh "${remote_user}@${remote_host}" "cat >> /home/${remote_user}/.ssh/authorized_keys; exit"
if [ "$verbosity" -gt 0 ]; then echo "new public key: copied"; fi

# check new key pair
ssh -i "$key_filename" "${remote_user}@${remote_host}" 'exit'
if [ "$verbosity" -gt 0 ]; then echo "new key pair: checked"; fi

# delete all old associated keys in the remote host
ssh -i "$key_filename" "${remote_user}@${remote_host}" "sed -i.'bak' -e \"/{\\\"sshKeyRotate\\\":\\\"$SCRIPT_VERSION\\\",\\\"keyId\\\":\\\"$key_id\\\",\\\"keySerial\\\":$key_serial}/p\" -e \"/{\\\"sshKeyRotate\\\":\\\"[^\\\\\\\"]\\+\\\",\\\"keyId\\\":\\\"$key_id\\\",\\\"keySerial\\\":[^}]\\+}/d\" /home/${remote_user}/.ssh/authorized_keys && exit"

# update the local ".ssh/config" file with the new private key to access the remote host
if [ ! -d "/home/${local_user}/.ssh" ]; then mkdir "/home/${local_user}/.ssh" && chmod 700 "/home/${local_user}/.ssh"; fi
if [ ! -f "/home/${local_user}/.ssh/config" ]; then touch "/home/${local_user}/.ssh/config" && chmod 600 "/home/${local_user}/.ssh/config"; fi
if [ ! -e "/home/${local_user}/.ssh/config" ] || [ $(grep -c "HostName $remote_host" "/home/${local_user}/.ssh/config") -eq 0 ]
then
	echo -e "Host $remote_host\n    HostName $remote_host\n    User $remote_user\n    IdentityFile $key_filename" >> "/home/${local_user}/.ssh/config"
else # todo: filter out entries belonging to other hosts
	sed -i'.bak' "s/IdentityFile .*/IdentityFile $key_filename/" "/home/${local_user}/.ssh/config"
fi
