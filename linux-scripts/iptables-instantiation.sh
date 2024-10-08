#!/usr/bin/env bash

set -euo pipefail

if [ -z "$1" ] ; then
  echo "No role (proxy|webserver-a|webserver-b) provided"
  exit 1
fi
server_role=$1
if [[ "$server_role" =~ (proxy|webserver-a|webserver-b|bastion) ]] ; then
  echo "Setting up iptables for role: ${server_role}"
else
  echo "Did not receive an expected role (proxy|webserver-a|webserver-b|bastion), bailing"
  exit 1
fi

# Ensure connection tracking is enabled for established and related connections
conntrack_rule='-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'

# Necessary for things like `sudo $COMMAND` resolving the hostname
lo_input_accept_rule='-A INPUT -i lo -j ACCEPT'

# Allow SSH inbound from appropriate source depending on server role
if [[ "$server_role" = "bastion" ]] ; then
  # Everywhere!
  ssh_rule='-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT'
else
  # Only from local network
  ssh_rule='-A INPUT -s 172.16.0.0/12 -p tcp -m tcp --dport 22 -j ACCEPT'
fi

# Allow port 80 inbound on local network if one of the webservers
webserver_rule=''
if [[ "$server_role" =~ (webserver-a|webserver-b) ]] ; then
  webserver_rule='-A INPUT -s 172.16.0.0/12 -p tcp -m tcp --dport 80 -j ACCEPT'
fi

# Allow ports 60k-65k inbound from anywhere if proxy role
proxy_rule=''
if [[ "$server_role" = "proxy" ]] ; then
  proxy_rule='-A INPUT -p tcp -m tcp --dport 60000:65000 -j ACCEPT'
fi

# Finally drop all other inputs, allowing additional rules to open pinholes
drop_rule='-P INPUT DROP'

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

function write_rule_if_not_present() {
  # Expecting $1 will be the rule we are going to check for
  local rule="$1"
  #local current_rules="$rule\nabc123" # line for testing logic
  local current_rules=$(sudo iptables-save)
  if echo "$current_rules" | grep -q -- "$rule" ; then
    # then the rule is present, no action necessary
    echo "Found '$rule', no action to take"
  else
    echo "Did not find '$rule' and would need to add it"
    pause_for_confirm
    #echo "would run: sudo iptables $rule" # line for testing logic
    sudo iptables $rule
  fi
}

# Add each rule
write_rule_if_not_present "$conntrack_rule"
write_rule_if_not_present "$lo_input_accept_rule"
write_rule_if_not_present "$ssh_rule"
if [ ! -z "$webserver_rule" ] ; then
  write_rule_if_not_present "$webserver_rule"
fi
if [ ! -z "$proxy_rule" ] ; then
  write_rule_if_not_present "$proxy_rule"
fi

# Drop rule is extra scary AND has a different search parameter
current_rules=$(sudo iptables-save)
if echo "$current_rules" | grep -q -- ":INPUT DROP" ; then
  echo "INPUT already dropping"
else
  echo "$current_rules"
  echo
  echo "INPUT DROP rule not present"
  pause_for_confirm
  sudo iptables $drop_rule
fi
