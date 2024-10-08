#!/usr/bin/env bash

set -euo pipefail

if [ -z "$1" ] ; then
  echo "Must provide username in first parameter"
  exit 1
fi
username=$1
if [ -z "$2" ] ; then
  echo "Must provide path to file with pubkey in it"
  exit 1
fi
pubkey_path=$2
if [ ! -f "$pubkey_path" ] ; then
  echo "File not found at provided pubkey path: $pubkey_path"
  exit 1
fi

function pause_for_confirm() {
  read -p "Are you sure? [y/N]" -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]] ; then
    echo "Proceeding"
  else
    echo "Bailing"
    exit 1
  fi
}

# Check if username exists, else adduser
if ! id "$username" ; then
  echo "User ${username} not found, add user?"
  pause_for_confirm
  sudo adduser --disabled-password --gecos "" "$username"
fi

# Check if user is a member of sudo, else grand user sudo access
if sudo -l -U "$username" | grep "User ${username} is not allowed to run sudo on" ; then
  echo "Looks like ${username} does not have sudo access, give sudo?"
  pause_for_confirm
  sudo usermod -aG sudo "$username"
fi

# Ensure user is not prompted for password on sudo commands
if sudo test ! -f "/etc/sudoers.d/${username}" ; then
  echo "Removing need for sudo password prompts for ${username}"
  sudo tee "/etc/sudoers.d/${username}" <<EOF
${username} ALL=(ALL) NOPASSWD:ALL
EOF
  sudo chmod 0440 "/etc/sudoers.d/${username}"
fi

# Make sure .ssh directory exists for user so we can set authorized_keys content later
user_homedir="/home/${username}"
if [ ! -d "${user_homedir}/.ssh" ] ; then
  if [ ! -d "$user_homedir" ] ; then
    echo "Something went wrong with user creation, home directory '${user_homedir}' does not exist"
    exit 1
  fi
  echo "Creating ${username}'s .ssh directory"
  sudo -u "$username" mkdir -m 0700 "${user_homedir}/.ssh"
fi

# Make sure the authorized_keys file exists, requires explicitly running the conditional as the added user
auth_keys_path="${user_homedir}/.ssh/authorized_keys"
if sudo -u expensify test ! -f "$auth_keys_path" ; then
  echo "Authorized keys file being created"
  sudo -u "$username" touch "$auth_keys_path"
fi

# Append the pubkey data to the authorized_keys file
pubkey_data=$(cat "$pubkey_path")
if ! sudo -u "$username" grep "$pubkey_data" "$auth_keys_path" ; then
  echo "Not finding expected pubkey content in the authorized_keys file for the user:"
  cat "$pubkey_path"
  echo "Add it?"
  pause_for_confirm
  # Using echo over cat because the user we're creating may not be able to reach the pubkey path
  sudo -u "$username" tee -a "$auth_keys_path" <<EOF
$pubkey_data
EOF
fi
