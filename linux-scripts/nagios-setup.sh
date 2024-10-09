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

# Only install the nagios server and plugins on the bastion host
# Following https://support.nagios.com/kb/article/nagios-core-installing-nagios-core-from-source-96.html#Ubuntu install process
if [[ $server_role == "bastion" ]] && ! sudo systemctl status nagios ; then
  # If this status check fails for nagios, either hitting a failure or not installed
  # Prereqs for nagios core
  sudo apt-get install -y autoconf gcc libc6 make wget unzip apache2 php libapache2-mod-php7.4 libgd-dev
  sudo apt-get install openssl libssl-dev

  # Download current release and unpack the tarball to a temp directory
  current_release="4.5.6"
  url_prefix="https://github.com/NagiosEnterprises/nagioscore/releases/download/nagios-${current_release}"
  tarball="nagios-${current_release}.tar.gz"
  # Clean previous downloads and unpacks for safety (have to use sudo because install steps run with sudo...)
  sudo rm -rf "/tmp/nagios*"
  wget "${url_prefix}/${tarball}" -P /tmp
  tar xzf "/tmp/${tarball}" -C /tmp

  # Run install steps for nagios core
  pushd "/tmp/nagios-${current_release}"
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
  current_release="2.4.12"
  url_prefix="https://github.com/nagios-plugins/nagios-plugins/releases/download/release-${current_release}"
  tarball="nagios-plugins-${current_release}.tar.gz"
  # Clean previous downloads and unpacks for safety
  sudo rm -rf "/tmp/nagios-plugins*"
  wget "${url_prefix}/${tarball}" -P /tmp
  tar xzf "/tmp/${tarball}" -C /tmp

  # Run install steps for nagios-plugins
  pushd "/tmp/nagios-plugins-${current_release}"
  # Apparently the ./tools/setup step is only necessary if you download the latest from the master branch
  # https://support.nagios.com/forum/viewtopic.php?t=57997 and https://github.com/nagios-plugins/nagios-plugins/issues/545
  #sudo ./tools/setup
  sudo ./configure
  sudo make
  sudo make install
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
  current_release="4.1.1"
  # https://github.com/NagiosEnterprises/nrpe/releases/download/nrpe-4.1.1/nrpe-4.1.1.tar.gz
  url_prefix="https://github.com/NagiosEnterprises/nrpe/releases/download/nrpe-${current_release}"
  tarball="nrpe-${current_release}.tar.gz"
  # Clean previous downloads and upacks for safety
  sudo rm -rf "/tmp/nrpe*"
  wget "${url_prefix}/${tarball}" -P /tmp
  tar xzf "/tmp/${tarball}" -C /tmp

  # Run install steps for nagios-plugins
  pushd "/tmp/nrpe-${current_release}"
  sudo ./configure
  sudo make all
  sudo make install-groups-users
  sudo make install
  sudo make install-config
  sudo make install-inetd
  sudo make install-init
  popd # return to directory user was operating in before

  # Complete installation with a reload and starting of nrpe
  sudo systemctl reload xinetd
  sudo systemctl enable nrpe
  sudo systemctl start nrpe
fi
