#! /bin/bash
set -e

# ######################################################################################
#
# Copyright (c) 2021, Oracle and/or its affiliates. All rights reserved.
#
# Un-installer script for Management Agent
# Usage:  uninstaller.sh
# Usage:  uninstaller.sh service-name
# ######################################################################################

# Set default locale
export LC_ALL=C

if [ ! "$BASH_VERSION" ] ; then
    echo "Unsupported shell: please execute as /bin/bash $0 or invoke it directly as ./$0"
    exit 1
fi

# In docker user may pass UID/GID to override default mgmt_agent user
DOCKER_USER_OVERRIDE=${DOCKER_USER_OVERRIDE:-false}

if [[ $EUID -ne 0 && "$DOCKER_USER_OVERRIDE" == "false" ]]; then
   echo "This script must be executed as root" 
   exit 1
fi

CURRENT_DIR=$(dirname "$0")
INSTALL_PARENT_DIR="/opt/oracle"

if [[ "$DOCKER_USER_OVERRIDE" == "true" ]]; then
	INSTALL_PARENT_DIR=${DOCKER_BASE_DIR:-${PWD}}
fi

SERVICE_NAME="mgmt_agent"
INSTALL_BASE_DIR="${INSTALL_PARENT_DIR}/${SERVICE_NAME}"
STATE_DIR="${INSTALL_BASE_DIR}/agent_inst"
BIN_DIR="${STATE_DIR}/bin"

###########################################################
# Update parameters required to uninstall agent
# Input: service-name
function update_service_params() {
  SERVICE_NAME="$1"
  INSTALL_BASE_DIR="${INSTALL_PARENT_DIR}/${SERVICE_NAME}"
  STATE_DIR="${INSTALL_BASE_DIR}/agent_inst"
  BIN_DIR="${STATE_DIR}/bin"
}

###########################################################
# Display help and exit script
function show_usage() {
	printf "Usage:  uninstaller.sh [service-name]"
	printf "\n\t - to uninstall: uninstaller.sh"
	printf "\n\t - to uninstall with service name: uninstaller.sh <service name>\n"
	exit 1
}

###########################################################
# Check if multiple agent installs exist
# Returns: 0 if exists, otherwise 1
function is_multiagents_present() {
  local childcount=0
  local dirpath="${INSTALL_PARENT_DIR}"
  for child in "$dirpath"/* ; do
  	if [[ -d "${child}" ]] && [[ "${child##*/}" =~ ^mgmt_agent.*$ ]]; then
  		childcount=$(($childcount+1))
  		if [ $childcount -gt 1 ]; then
  		  return 0
  		fi
  	fi
  done
  return 1
}

###########################################################
# Validate service with given name exists
# Input: abc-123_xyz
# Returns: 0 if exists, otherwise exit script with error
function validate_service() {
  if ! [ -d "${INSTALL_PARENT_DIR}/${SERVICE_NAME}" ]; then
    echo "No such Service (${SERVICE_NAME}), exiting ..."
    exit 1
  fi
}

# optional arg to specify service name used for multi-agent installs
if [[ $# -eq 1 ]]; then
	update_service_params "$1"
else
	if is_multiagents_present ; then
      echo "Multiple instances of Management Agent exist, service name is required to uninstall"
      show_usage
	fi
fi

validate_service

# Send 0 flag to indicate uninstall
/bin/bash ${BIN_DIR}/preremovescript.sh 0 ${SERVICE_NAME}

/bin/bash ${BIN_DIR}/postremovescript.sh 0 ${SERVICE_NAME}
