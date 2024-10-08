#!/usr/bin/env bash

set -euo pipefail

# Following https://support.nagios.com/kb/article/nagios-core-installing-nagios-core-from-source-96.html#Ubuntu install process
# Nagios is either not installed or we should walk the install steps again because failing/stopped
if ! sudo systemctl status nagios ; then
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

  # Now we need to install the nagios plugins
  # Prereqs
  sudo apt-get install -y autoconf gcc libc6 libmcrypt-dev make libssl-dev wget bc gawk dc build-essential snmp libnet-snmp-perl gettext
  # Download
  current_release="2.4.12"
  url_prefix="https://github.com/nagios-plugins/nagios-plugins/releases/download/release-${current_release}"
  tarball="nagios-plugins-${current_release}.tar.gz"
  # Can skip clean up of previous install attempts here as we did that step right before fetching nagios core
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
  # Directions do NOT indicate a need to restart nagios.service after plugins have been installed
  popd # return to directory user was operating in before
fi
