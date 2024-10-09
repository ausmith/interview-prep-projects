#!/usr/bin/env bash

set -euo pipefail

if [ -z "$1" ] ; then
  echo "No role (bastion|proxy|webserver-a|webserver-b) provided"
  exit 1
fi
server_role=$1
if [[ "$server_role" =~ (bastion|proxy|webserver-a|webserver-b) ]] ; then
  echo "Setting up nagios for role: ${server_role}"
else
  echo "Did not receive an expected role (bastion|proxy|webserver-a|webserver-b), bailing"
  exit 1
fi
if [[ "$server_role" =~ (proxy|webserver-a|webserver-b) ]] ; then
  if [ -z "$2" ] ; then
    echo "Expected to be provided a nagios server IP address to enable NRPE"
    exit 1
  fi
  nagios_server="$2"
fi

# Set desired version variables
nagios_version="4.5.6"
plugins_version="2.4.12"
nrpe_version="4.1.1"

# An attempt to DRY up the fetch and unpack step that we are doing in multiple places
# * name: nagios, nagios-plugins, nrpe
# * GitHub releases path details: because this pathing is not identical between all the tarballs that will be downloaded, examples:
#     NagiosEnterprises/nagioscore/releases/download/nagios,
#     NagiosEnterprises/nrpe/releases/download/nrpe,
#     nagios-plugins/nagios-plugins/releases/download/release
# * version: semver like "4.1.1"
function fetch_and_unpack_tarball() {
  local name="$1"
  local github_path="$2"
  local version="$3"
  local url_prefix="https://github.com/${github_path}-${version}"
  local tarball="${name}-${version}.tar.gz"

  # Clean up previous downloads and unpacks for safety
  sudo rm -rf "/tmp/${name}*"
  # Fetch
  wget "${url_prefix}/${tarball}" -P /tmp
  # Unpack
  tar xzf "/tmp/${tarball}" -C /tmp
}

# Only install the nagios server and plugins on the bastion host
# Following https://support.nagios.com/kb/article/nagios-core-installing-nagios-core-from-source-96.html#Ubuntu install process
if [[ $server_role == "bastion" ]] && ! sudo systemctl status nagios ; then
  # If this status check fails for nagios, either hitting a failure or not installed
  # Prereqs for nagios core
  sudo apt-get install -y autoconf gcc libc6 make wget unzip apache2 php libapache2-mod-php7.4 libgd-dev
  sudo apt-get install openssl libssl-dev

  # Download
  fetch_and_unpack_tarball "nagios" "NagiosEnterprises/nagioscore/releases/download/nagios" "$nagios_version"

  # Run install steps for nagios core
  pushd "/tmp/nagios-${nagios_version}"
  # Compile code
  sudo ./configure --with-httpd-conf=/etc/apache2/sites-enabled
  sudo make all
  # Create user and group
  sudo make install-groups-users
  sudo usermod -a -G nagios www-data
  # Install binaries
  sudo make install
  # Install daemon (systemctl) -- this is the step that disables the conditional into this block
  sudo make install-daemoninit
  # Install command mode
  sudo make install-commandmode
  # Install config files
  sudo make install-config
  # Install apache config files
  sudo make install-webconf
  sudo a2enmod rewrite
  sudo a2enmod cgi
  # Skipping firewall as we are letting iptables changes happen in that script
  # Set up htaccess, but first ensure the desired etc directory exists
  if [ -d /usr/local/nagios ] && [ ! -d /usr/local/nagios/etc ] ; then
    sudo mkdir /usr/local/nagios/etc
    sudo chown nagios:nagios /usr/local/nagios/etc
  fi
  sudo htpasswd -c /usr/local/nagios/etc/htpasswd.users nagiosadmin
  # Restart apache
  sudo systemctl restart apache2.service
  # Start nagios
  sudo systemctl start nagios.service
  popd # return to directory user was operating in before
fi

# As the nagios-plugins seem to be responsible for installing the check_wave check, using as indicator if successfully installed
# THIS IS FRAGILE!! If ever check_wave is not delivered by the plugins, this will begin installing every run
# We are installing nagios-plugins regardless of server role as it is necessary for both server and NRPE client
if [ ! -f /usr/local/nagios/libexec/check_wave ] ; then
  # Now we need to install the nagios plugins (all server roles get this)
  # Prereqs
  sudo apt-get install -y autoconf gcc libc6 libmcrypt-dev make libssl-dev wget bc gawk dc build-essential snmp libnet-snmp-perl gettext
  # Download
  fetch_and_unpack_tarball "nagios-plugins" "nagios-plugins/nagios-plugins/releases/download/release" "$plugins_version"

  # Run install steps for nagios-plugins
  pushd "/tmp/nagios-plugins-${plugins_version}"
  # Apparently the ./tools/setup step is only necessary if you download the latest from the master branch
  # https://support.nagios.com/forum/viewtopic.php?t=57997 and https://github.com/nagios-plugins/nagios-plugins/issues/545
  #sudo ./tools/setup
  sudo ./configure
  sudo make
  sudo make install
  popd # return to directory user was operating in before
fi

# If on the nagios server side and do not have the check_nrpe check present, install it
if [[ "$server_role" == "bastion" ]] && [ ! -f /usr/local/nagios/libexec/check_nrpe ] ; then
  # Download
  fetch_and_unpack_tarball "nrpe" "NagiosEnterprises/nrpe/releases/download/nrpe" "$nrpe_version"

  pushd "/tmp/nrpe-${nrpe_version}"
  sudo ./configure
  sudo make check_nrpe
  sudo make install-plugin
  popd # return to directory user was operating in before
fi

# Installing the NRPE client on the monitored hosts (remote hosts)
# Follows guide at https://github.com/NagiosEnterprises/nrpe/blob/master/docs/NRPE.pdf
if [[ "$server_role" =~ (proxy|webserver-a|webserver-b) ]] && ! sudo systemctl status nrpe ; then
  # First take some actions that are handled by the nagios core install but may not be handled by nagios-plugins install
  if ! id nagios ; then
    echo "The nagios user was not created previously, adding it"
    sudo adduser --disabled-password --gecos "" nagios

    # If we had to add the user, it stands to reason we will need to fix up the permissions on the nagios directory
    sudo chown nagios:nagios /usr/local/nagios
    sudo chown -R nagios:nagios /usr/local/nagios/libexec
  fi
  
  # Prereqs
  sudo apt-get install xinetd
  # Download
  fetch_and_unpack_tarball "nrpe" "NagiosEnterprises/nrpe/releases/download/nrpe" "$nrpe_version"

  # Run install steps for nagios-plugins
  pushd "/tmp/nrpe-${nrpe_version}"
  sudo ./configure
  sudo make all
  sudo make install-groups-users
  sudo make install
  sudo make install-config
  sudo make install-inetd
  sudo make install-init
  popd # return to directory user was operating in before

  # Ensure xinetd will receive traffic from the nagios server passed into the script
  sudo sed -i "s/only_from       = 127.0.0.1 ::1$/only_from       = 127.0.0.1 ::1 $nagios_server/" /etc/xinetd.d/nrpe
  # Ensure nrpe.cfg will receive traffic from the nagios server passed into the script
  sudo sed -i "s/^allowed_hosts=127.0.0.1,::1$/allowed_hosts=127.0.0.1,::1,$nagios_server/" /usr/local/nagios/etc/nrpe.cfg
  sudo sed -i 's/^dont_blame_nrpe=.*/dont_blame_nrpe=1/g' /usr/local/nagios/etc/nrpe.cfg

  # Complete installation with a reload and starting of nrpe
  sudo systemctl reload xinetd
  sudo systemctl enable nrpe
  sudo systemctl start nrpe
fi
