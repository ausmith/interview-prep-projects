#!/usr/bin/env bash

# Ensure connection tracking is enabled for established and related connections
conntrack_rule='-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
# Necessary for things like `sudo $COMMAND` resolving the hostname
lo_input_accept_rule='-A INPUT -i lo -j ACCEPT'
# Allow SSH inbound, will likely need to tweak this depending on server type later or have separate script do that
ssh_rule='-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT'
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
